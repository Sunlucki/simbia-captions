import AppKit
import AVFoundation
import CoreImage
import Foundation
import SimbiaCore

/// Test hook for working on the app without screen access: with SIMBIA_DEBUG set
/// (`open --env SIMBIA_DEBUG=1 -a "Simbia Captions" …`) the app reads commands from
/// Portable/Logs/debug-command.txt, runs them, deletes the file and logs what happened.
///
///   snapshot <png path>        the window as the user sees it (the video layer may come out black)
///   seek <seconds> | play | pause | undo | redo | wait <seconds>
///   select <caption #>         captions counted from 0 in time order
///   accent <caption #> <word #>
///   text <caption #> <new text>
///   style <s1…s10 | legacy>    tab <text | captions | titles | classic>
///   range <a> <b> | add <caption #> | selectall | collapse | selpara <caption #>
///   join | splitword <caption #> <word #> | para <caption #> | delete | splitplay
///   tools <caption #> <word #> | shottools <shot #> | close | wordtext <caption #> <word #> <text>
///   break <caption #> <word #> | parword <caption #> <word #> | snapshotpop <png path> (the open tools window)
///   click <x> <y> [shift] [cmd] | drag <x1> <y1> <x2> <y2> | key <keycode> [cmd]   (points, top-left)
///   dump                       captions, selection, paragraphs, undo, revision
///   checks | fixall | fix <kind> | checkspanel | exportcheck      the checks before export (exportcheck as Export does)
///   panel find|glossary|pauses|none | glossary [add|remove <word>] | replace <find> => <with>
///   pauses <seconds> | cutpauses <seconds> (logged when the voice is read) | shuttle -1|0|1
///   wordstart <caption #> <word #> <seconds> | nudgeword <caption #> <word #> start|end <frames>
///   suggest <shot #> | usesuggest <shot #> <n>                   footage from the library's index
///   music <seconds> <path>     a track dropped on the music track | audio   the sound clips
@MainActor final class DebugBridge {
    private var timer: Timer?
    private let command: URL

    init?(job: Job) {
        guard ProcessInfo.processInfo.environment["SIMBIA_DEBUG"] != nil else { return nil }
        command = job.logFile.deletingLastPathComponent().appending(path: "debug-command.txt")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak job] _ in
            MainActor.assumeIsolated {
                guard let self, let job else { return }
                self.poll(job)
            }
        }
        job.appendLog("Debug bridge on: \(command.path)")
    }

    private func poll(_ job: Job) {
        guard let text = try? String(contentsOf: command, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: command)
        execute(text.split(separator: "\n").map(String.init), job)
    }

    /// Runs lines in order; `wait` lets the UI catch up before the rest.
    private func execute(_ lines: [String], _ job: Job) {
        var rest = lines[...]
        while let line = rest.popFirst() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if line.hasPrefix("wait"), let seconds = Double(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) {
                let remaining = Array(rest)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak job] in
                    MainActor.assumeIsolated { if let self, let job { self.execute(remaining, job) } }
                }
                return
            }
            job.appendLog("debug> \(line): \(run(line, job))")
        }
    }

    private func run(_ line: String, _ job: Job) -> String {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let words = line.split(separator: " ").map(String.init)
        let ordered = job.orderedCues
        func cue(_ s: String) -> Cue? { Int(s).flatMap { ordered.indices.contains($0) ? ordered[$0] : nil } }
        func number(_ i: Int) -> Double? { words.indices.contains(i) ? Double(words[i]) : nil }
        switch parts[0] {
        case "snapshot":
            guard parts.count > 1 else { return "path?" }
            return snapshot(to: parts.dropFirst().joined(separator: " "))
        case "player":                         // the preview player's state
            let item = job.player.currentItem
            let status = item.map { $0.status == .readyToPlay ? "ready" : $0.status == .failed ? "FAILED" : "unknown" } ?? "no item"
            let error = (item?.error as NSError?).map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "-"
            return "item \(status), error \(error), control \(job.player.timeControlStatus.rawValue), waiting \(job.player.reasonForWaitingToPlay?.rawValue ?? "-"), "
                + "rate \(job.player.rate), t \(String(format: "%.2f", job.player.currentTime().seconds)), playhead \(String(format: "%.2f", job.currentTime)), size \(item?.presentationSize ?? .zero), "
                + "instructions \(item?.videoComposition?.instructions.count ?? 0), tracks \(item?.asset.tracks.count ?? 0)"
        case "videoframe":                     // what the player is showing, straight from the composition
            guard parts.count > 1, let item = job.player.currentItem else { return "no player item" }
            return videoFrame(item, at: job.player.currentTime(), to: parts.dropFirst().joined(separator: " "))
        case "media":                          // what the timeline's media cache holds
            let m = MediaCache.shared
            let env = m.envelopes.map { key, v in "\((key as NSString).lastPathComponent): \(v.count) values, max \(v.max() ?? 0), mean \(v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count))" }
            return "thumbnails \(m.thumbnails.count); envelopes [\(env.joined(separator: "; "))]; duck \(m.duck.values.map(\.count))"
        case "exportto":                       // the app's export path without the save panel
            guard parts.count > 1 else { return "path?" }
            let out = URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))
            let doc = job.document(), base = job.projectURL
            job.work {
                try await Exporter.export(doc, projectURL: base, to: out) { p in Task { @MainActor in job.progress = Int(p * 100) } }
                job.appendLog("debug export done: \(out.path)")
            }
            return "exporting to \(out.path)"
        case "open":
            guard parts.count > 1 else { return "path?" }
            job.open(URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))); return "opened"
        case "music":                          // music <seconds> <path>: a track dropped on the music track there
            guard parts.count > 2, let t = Double(parts[1]) else { return "music <seconds> <path>" }
            job.addMusic(URL(fileURLWithPath: parts[2]), at: t); return "adding"
        case "fold":                           // the right-hand panel folded away / opened again
            job.libraryCollapsed.toggle(); return job.libraryCollapsed ? "folded" : "open"
        case "crop":                           // crop <shot id>: the crop window on that shot | crop: which shot is in it
            if parts.count > 1 { job.beginCrop(parts[1]) }
            return job.cropShot ?? "none"
        case "cropkey":                        // cropkey <shot id> key <scale> <panX> <panY> | move <index> <time> | delete <index>: crop keys
            guard words.count > 2, let s = job.shot(words[1]) else { return "cropkey <shot id> key|move|delete …" }
            let n = words.dropFirst(3).compactMap { Double($0) }
            switch words[2] {
            case "key" where n.count == 3: job.setCropKey(s.id, scale: n[0], panX: n[1], panY: n[2], rotation: s.rotation)
            case "move" where n.count == 2: job.moveCropKey(s.id, Int(n[0]), to: n[1])
            case "delete" where n.count == 1: job.deleteCropKey(s.id, Int(n[0]))
            default: return "?"
            }
            return (job.shot(s.id)?.keys ?? []).map { String(format: "%.3f:%.2f/%.2f,%.2f", $0.t, $0.scale, $0.panX, $0.panY) }.joined(separator: " ")
        case "audio":                          // the sound clips: role, span, gain
            return (job.project?.audio ?? []).map { String(format: "%@ %@ %.2f+%.2f g%.3f %@", $0.id, $0.role.rawValue, $0.start, $0.duration ?? -1, $0.gain, ($0.src as NSString).lastPathComponent) }.joined(separator: " | ")
        case "seek":
            guard parts.count > 1, let t = Double(parts[1]) else { return "time?" }
            job.seek(t); return "at \(t)"
        case "play": job.play(); return "playing"
        case "pause": job.player.pause(); return "paused"
        case "undo": job.undo(); return "undone"
        case "redo": job.redo(); return "redone"
        case "select":
            guard parts.count > 1, let c = cue(parts[1]) else { return "caption?" }
            job.select(c); return "selected \"\(c.text)\""
        case "range":
            guard words.count > 2, let a = cue(words[1]), let b = cue(words[2]) else { return "range <a> <b>" }
            job.select(a); job.click(b, extend: true); return "selection \(job.selection.count)"
        case "add":
            guard parts.count > 1, let c = cue(parts[1]) else { return "caption?" }
            job.click(c, toggle: true); return "selection \(job.selection.count)"
        case "selectall": job.selectAllCaptions(); return "selection \(job.selection.count)"
        case "collapse": job.collapseSelection(); return "selection \(job.selection.count)"
        case "selpara":
            guard parts.count > 1, let c = cue(parts[1]) else { return "caption?" }
            job.selectParagraph(containing: c.id); return "selection \(job.selection.count)"
        case "join": job.mergeSelection(); return "\(job.cues.count) captions"
        case "splitword":
            guard words.count > 2, let c = cue(words[1]), let w = Int(words[2]) else { return "splitword <caption> <word>" }
            job.splitCaption(c.id, beforeWord: w); return "\(job.cues.count) captions"
        case "splitplay": job.splitAtPlayhead(); return "\(job.cues.count) captions"
        case "para":
            guard parts.count > 1, let c = cue(parts[1]) else { return "caption?" }
            job.toggleParagraph(at: c.id); return "\(job.paragraphs.count) paragraphs"
        case "delete": job.deleteSelection(); return "\(job.cues.count) captions"
        case "accent":
            guard parts.count > 2, let c = cue(parts[1]), let w = Int(parts[2]) else { return "accent <caption> <word>" }
            job.toggleWordAccent(c.id, word: w)
            return "\"\(c.text)\" word \(w) accent=\(job.isAccent(c.id, word: w))"
        case "text":
            guard parts.count > 2, let c = cue(parts[1]) else { return "text <caption> <text>" }
            job.pushHistory(); job.updateText(of: c.id, to: parts[2]); return "now \"\(parts[2])\""
        case "style":
            guard parts.count > 1 else { return "style?" }
            job.applyCaptionStyle(parts[1]); return "style \(parts[1]): \(job.cues.count) captions"
        case "tab":
            guard parts.count > 1, let tab = LibraryTab(rawValue: parts[1]) else { return "tab?" }
            job.libraryTab = tab; return "tab \(tab.rawValue)"
        case "click":
            guard let x = number(1), let y = number(2) else { return "click <x> <y> [shift] [cmd]" }
            var flags: NSEvent.ModifierFlags = []
            if words.contains("shift") { flags.insert(.shift) }
            if words.contains("cmd") { flags.insert(.command) }
            return click(CGPoint(x: x, y: y), flags: flags, count: words.contains("double") ? 2 : 1)
        case "drag":
            guard let x1 = number(1), let y1 = number(2), let x2 = number(3), let y2 = number(4) else { return "drag x1 y1 x2 y2" }
            return drag(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
        case "key":
            guard words.count > 1, let code = UInt16(words[1]) else { return "key <code> [cmd]" }
            return key(code, flags: words.contains("cmd") ? .command : [])
        case "dump":
            return dump(job)
        case "covers":                         // covers <shot id>: «Закрыть текст» on that shot | covers: which shot is in it
            if words.count > 1 { job.beginCovers(words[1]) }
            return job.coverShot ?? "none"
        case "browser":                        // browser [close]: the project browser
            if words.count > 1 { job.closeBrowser(); return "closed" }
            job.openBrowser(); return "open"
        case "drawer":                         // drawer <titles|graphics|look|filters|shots|captions|close>: a track's drawer
            let lane = Lane.allCases.first { "\($0)" == words[safe: 1] }
            job.openDrawer(lane); return "drawer \(lane.map { "\($0)" } ?? "closed")"
        case "brief":                          // brief [close]: the project's brief and tasks
            if words.count > 1 { job.closeBrief(); return "closed" }
            job.openBrief(); return job.briefOpen ? "open" : "no project"
        case "clipscut":                       // clipscut <shot id>: the clip window for the cut after that shot
            guard words.count > 1 else { return "clipscut <shot id>" }
            job.openClips(insertingAfter: words[1]); return "open"
        case "rippleend":                      // rippleend <shot id> <time>: the shot's end ripple-trimmed to there
            guard words.count > 2, let t = Double(words[2]) else { return "rippleend <shot id> <time>" }
            job.rippleEnd(of: words[1], to: t); return "\(job.cues.count) captions"
        case "syncwords":                      // syncwords [<caption #>]: «Пересчитать по словам», all without a number
            job.syncToVoice(cue(words[safe: 1] ?? "").map { [$0.id] }); return "syncing"
        case "words":                          // words <from> <to>: the captions' words in that stretch
            guard let a = number(1), let b = number(2) else { return "words <from> <to>" }
            return ordered.filter { $0.end > a && $0.start < b }.map { c in
                job.timedWords(of: c).map { String(format: "%@@%.2f", $0.text, $0.start) }.joined(separator: " ")
            }.joined(separator: " | ")
        case "tools":
            guard words.count > 2, let c = cue(words[1]), let w = Int(words[2]) else { return "tools <caption> <word>" }
            job.clickWord(c, w); return "tools for \"\(job.timedWords(of: c)[safe: w]?.text ?? "?")\""
        case "audiotools":                     // audiotools <clip id>: the window a click on that sound clip opens
            guard parts.count > 1, job.audioClip(parts[1]) != nil else { return "clip?" }
            job.focus = .audio(parts[1]); job.audioTools = parts[1]; return "audio tools \(parts[1])"
        case "captionsfrom":                   // captionsfrom <clip id>: «Создать субтитры по звуку»
            guard parts.count > 1, job.audioClip(parts[1]) != nil else { return "clip?" }
            job.captionsFromVoice(parts[1]); return "listening to \(parts[1])"
        case "transition":                     // transition <id>: that transition picked (its settings under the shots)
            guard parts.count > 1, job.transitionClip(parts[1]) != nil else { return "transition?" }
            job.focus = .transition(parts[1]); return "transition \(parts[1])"
        case "pushword":                       // pushword <caption #> <word #> <time>: a word dragged in the captions drawer
            guard words.count > 3, let c = cue(words[1]), let w = Int(words[2]), let t = number(3) else { return "pushword <caption> <word> <time>" }
            job.pushWord(c.id, word: w, to: t, base: job.timedWords(of: c)); return "pushed"
        case "captionsin":                     // captionsin <from> <to>: «+ Субтитры по голосу» on that stretch
            guard let a = number(1), let b = number(2) else { return "captionsin <from> <to>" }
            job.captionsFromVoice(in: a, b); return "listening \(a)–\(b)"
        case "layertools":                     // layertools <#>: the window of a video on the overlay track
            guard parts.count > 1, let k = Int(parts[1]), let v = job.layers[safe: k] else { return "layer?" }
            job.focus = .shot(v.id); job.shotTools = v.id; return "layer tools \(v.id)"
        case "matte":                          // matte <#> | matte off: «Показать маску» for that overlay-track video
            let v = Int(words[safe: 1] ?? "").flatMap { job.layers[safe: $0] }
            job.showMatte(v?.id); return "matte \(v?.id ?? "off")"
        case "shottools":
            guard parts.count > 1, let k = Int(parts[1]), job.shots.indices.contains(k) else { return "shot?" }
            job.focus = .shot(job.shots[k].id); job.shotTools = job.shots[k].id; return "shot tools \(job.shots[k].id)"
        case "edges":                          // edges <shot #> first|last|both|cut|off: the frames a trim / slip / roll there shows over the picture
            guard let k = Int(words[safe: 1] ?? ""), let shot = job.shots[safe: k] else { return "edges <shot #> first|last|both|cut|off" }
            switch words[safe: 2] {
            case "first": job.showEdges(.first, of: shot.id)
            case "last": job.showEdges(.last, of: shot.id)
            case "both": job.showEdges(.both, of: shot.id)
            case "cut": job.showEdges(.cut, of: shot.id)
            default: EdgePreview.shared.clear()
            }
            return "edges \(shot.id) \(words[safe: 2] ?? "off")"
        case "picturemenu":                    // picturemenu <stage x> <stage y> [pick]: the right-click menu on the picture there (pick = its first item)
            guard let x = number(1), let y = number(2), let window else { return "picturemenu <x> <y> [pick]" }
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            guard let view = window.contentView.map(views)?.first(where: { String(describing: type(of: $0)) == "DragView" }) else { return "no picture view" }
            let s = min(view.bounds.width / 1080, view.bounds.height / 1920)
            let at = view.convert(NSPoint(x: (view.bounds.width - 1080 * s) / 2 + x * s, y: view.isFlipped ? y * s : view.bounds.height - y * s), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = view.menu(for: event) else { return "no menu" }
            if words.contains("pick"), let item = menu.items.first, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            return menu.items.map { "\($0.title)\($0.isEnabled ? "" : " (off)")" }.joined(separator: " | ") + " · focus \(job.focus)"
        case "scenevariants":                  // scenevariants <scene #> [<name>]: «Заменить на…» on that scene (with a name: picks it)
            guard let k = Int(words[safe: 1] ?? ""), let clip = job.overlays[safe: k] else { return "scenevariants <scene #> [<name>]" }
            let variants = job.overlayVariants(clip)
            if let name = words[safe: 2], let url = variants.first(where: { $0.lastPathComponent == name }) { job.replaceOverlay(clip.id, with: url) }
            let now = job.overlay(clip.id)
            return variants.map(\.lastPathComponent).joined(separator: ", ") + " · now \(now?.label ?? "-") glass \(now?.glass.map { ($0.mask as NSString).lastPathComponent } ?? "none")"
        case "musiclib":                       // musiclib | musiclib list | musiclib use <words of a track's name> | musiclib close
            switch words[safe: 1] {
            case "close": job.closeMusic(); return "closed"
            case "list", "use":
                guard let root = MusicLibrary.find(near: job.projectURL) else { return "no _ASSETS/MUSIC" }
                let all = MusicLibrary.tracks(in: root)
                let usage = job.projectURL.map { MusicLibrary.usage(projectsIn: $0.deletingLastPathComponent()) } ?? [:]
                if words[safe: 1] == "use" {
                    let want = words.dropFirst(2).map { $0.lowercased() }
                    guard let t = all.first(where: { t in want.allSatisfy { t.name.lowercased().contains($0) } }) else { return "no such track" }
                    job.useMusic(t); return "putting in \(t.name)"
                }
                return "\(all.count) tracks: " + all.map { "\($0.title) [\((usage[$0.url.standardizedFileURL.path] ?? []).joined(separator: ","))]" }.joined(separator: " | ")
            default: job.openMusic(); return "music library open"
            }
        case "aligntitles":                    // aligntitles <title #>: «Выровнять все заголовки по этому»; then every title's y
            guard let k = Int(words[safe: 1] ?? ""), let title = (job.project?.titles ?? [])[safe: k] else { return "aligntitles <title #>" }
            job.focus = .title(title.id)
            job.alignTitles(to: title.id)
            return (job.project?.titles ?? []).map { "\($0.id) y \($0.y.map { String(format: "%.0f", $0) } ?? "-")" }.joined(separator: ", ")
        case "speed":                          // speed <shot #> <x>: «Скорость» in the shot window; then the shot and its own sound
            guard let k = Int(words[safe: 1] ?? ""), let shot = job.shots[safe: k], let x = number(2) else { return "speed <shot #> <x>" }
            job.setSpeed(shot.id, x)
            let now = job.shot(shot.id)
            let sound = (job.project?.audio ?? []).filter { $0.src == shot.src }.map { String(format: "%@ ×%.3f in %.3f", $0.id, $0.speed, $0.inPoint) }
            return String(format: "%@ ×%.3f in %.3f · ", shot.id, now?.speed ?? 0, now?.inPoint ?? 0) + sound.joined(separator: ", ")
        case "menu":                           // the items of one menu in the menu bar
            guard parts.count > 1, let menu = NSApp.mainMenu?.items.first(where: { $0.title == parts.dropFirst().joined(separator: " ") })?.submenu else { return "menu?" }
            menu.delegate?.menuNeedsUpdate?(menu)             // as when it opens: SwiftUI fills its menus then
            menu.update()
            func keys(_ i: NSMenuItem) -> String {
                guard !i.keyEquivalent.isEmpty else { return "" }
                let m = i.keyEquivalentModifierMask
                return " [" + (m.contains(.shift) || i.keyEquivalent != i.keyEquivalent.lowercased() ? "⇧" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.command) ? "⌘" : "") + i.keyEquivalent.uppercased() + "]"
            }
            return menu.items.map { $0.isSeparatorItem ? "—" : "\($0.state == .on ? "✓ " : "")\($0.title)\(keys($0))\($0.isEnabled ? "" : " (off)")" }.joined(separator: " | ")
        case "windows":                        // what is on screen: every visible window
            let list = NSApp.windows.filter(\.isVisible)
            return "\(list.count) visible: " + list.map { "\(type(of: $0)) \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: ", ")
        case "title":
            guard parts.count > 1, let k = Int(parts[1]), job.titles.indices.contains(k) else { return "title?" }
            job.focus = .title(job.titles[k].id); job.titleTools = job.titles[k].id; return "title \(job.titles[k].text)"
        case "sticker":                        // emoji on title #: add <#> <emoji> | pick <#> <k> | set <#> <k> size|rot|x|y <v> | remove <#> <k> | list <#>
            guard let k = Int(words[safe: 2] ?? ""), let t = job.titles[safe: k] else { return "sticker add|pick|set|remove|list <title#> …" }
            switch words[safe: 1] {
            case "add": if let e = words[safe: 3] { job.addSticker(e, to: t.id); job.titleTools = t.id }
            case "pick": if let i = Int(words[safe: 3] ?? "") { job.focus = .title(t.id); job.sticker = StickerRef(title: t.id, index: i) }
            case "set":
                guard let i = Int(words[safe: 3] ?? ""), let v = number(5) else { return "sticker set <#> <k> size|rot|x|y <v>" }
                job.updateSticker(t.id, i) { s in
                    switch words[safe: 4] { case "size": s.size = v; case "rot": s.rotation = v; case "x": s.x = v; default: s.y = v }
                }
            case "remove": if let i = Int(words[safe: 3] ?? "") { job.removeSticker(t.id, i) }
            default: break
            }
            let list = (job.title(t.id)?.stickers ?? []).map { "\($0.emoji) \(Int($0.x)),\(Int($0.y)) \(Int($0.size))px \(Int($0.rotation))°" }
            return "\(list.joined(separator: " | ")) picked \(job.sticker.map { "\($0.index)" } ?? "-")"
        case "emojipack":                      // the title window's pack chips
            if let pack = words[safe: 1] { job.setEmojiPack(pack) }
            return "\(job.emojiPack) of \(AnimatedEmoji.packs), \(AnimatedEmoji.index(job.emojiPack).count) emoji"
        case "addtitle":                       // the timeline's "+ Title"
            job.ensureProject(); job.addTitle(at: job.currentTime)
            if case .title(let id) = job.focus, let t = job.title(id) { return "\(t.id) \(t.style) at \(t.start)" }
            return "?"
        case "shotset":                        // what the shot window's controls do
            let w = line.split(separator: " ").map(String.init)
            guard w.count > 2, let k = Int(w[1]), job.shots.indices.contains(k) else { return "shotset <shot> zoom in|out|none | dim | in <delta> | split" }
            let id = job.shots[k].id
            switch w[2] {
            case "zoom": if w.count > 3, let z = Shot.Zoom(rawValue: w[3]) { job.updateShot(id) { $0.zoom = z } }
            case "dim": job.updateShot(id) { $0.dim.toggle() }
            case "flip": job.updateShot(id) { $0.flip.toggle() }
            case "in": if w.count > 3, let d = Double(w[3]) { job.updateShot(id) { $0.inPoint += d } }
            case "split": job.splitShotAtPlayhead(id)
            case "scale": if w.count > 3, let v = Double(w[3]) { job.updateShot(id) { $0.scale = v } }
            case "crop": job.beginCrop(id)
            case "pan": if w.count > 4, let x = Double(w[3]), let y = Double(w[4]) { job.updateShot(id) { $0.panX = x; $0.panY = y } }
            default: return "?"
            }
            let s = job.shot(id)
            return "shot \(id): zoom \(s?.zoom.rawValue ?? "-"), scale \(s?.scale ?? 1) pan \(s?.panX ?? 0),\(s?.panY ?? 0), dim \(s?.dim ?? false), in \(s?.inPoint ?? -1); \(job.shots.count) shots"
        case "quit":                           // the normal way out: ends text editing, saves, quits
            DispatchQueue.main.async { NSApp.terminate(nil) }; return "quitting"
        case "close":
            job.editingWord = nil; job.shotTools = nil; job.audioTools = nil; job.overlayTools = nil; job.titleTools = nil; job.toolPanel = nil; job.checksOpen = false; return "closed"
        case "wordtext":
            let all = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard all.count > 3, let c = cue(all[1]), let w = Int(all[2]) else { return "wordtext <caption> <word> <text>" }
            job.updateWord(c.id, word: w, to: all[3]); return "now \"\(job.cues.first { $0.id == c.id }?.text ?? "-")\""
        case "break":
            guard words.count > 2, let c = cue(words[1]), let w = Int(words[2]) else { return "break <caption> <word>" }
            job.toggleBreak(c.id, word: w); return "\(job.cues.count) captions"
        case "parword":
            guard words.count > 2, let c = cue(words[1]), let w = Int(words[2]) else { return "parword <caption> <word>" }
            job.toggleParagraph(at: c.id, word: w); return "\(job.paragraphs.count) paragraphs, \(job.cues.count) captions"
        case "snapshotpop":
            guard parts.count > 1 else { return "path?" }
            return snapshot(to: parts.dropFirst().joined(separator: " "), popover: true)
        case "checks":
            job.refreshIssues()
            return "\(job.issues.count) issues: " + job.issues.map { "[\($0.kind.rawValue) \(String(format: "%.2f", $0.time))] \(job.describe($0))" }.joined(separator: " | ")
        case "fixall":
            job.fixAll(); job.refreshIssues(); return "\(job.issues.count) left, \(job.cues.count) captions"
        case "fix":
            guard words.count > 1, let kind = Issue.Kind(rawValue: words[1]) else { return "fix <kind>" }
            job.refreshIssues(); job.fix(job.issues.filter { $0.kind == kind }); return "\(job.issues.count) left"
        case "checkspanel":
            job.refreshIssues(); job.exportAfterChecks = false; job.checksOpen = true; return "\(job.issues.count) issues"
        case "exportcheck":                    // what Export does first; without issues it would open the save panel
            job.refreshIssues()
            guard job.issues.contains(where: \.fixable) else { return "nothing to check: Export goes straight on" }
            job.export(); return "checks open: \(job.checksOpen), before export \(job.exportAfterChecks)"
        case "panel":
            job.toolPanel = words.count > 1 ? ["find": .find, "glossary": .glossary, "pauses": .pauses][words[1]] : nil
            if job.toolPanel == .pauses { job.ensureProject() }
            return "panel \(String(describing: job.toolPanel))"
        case "glossary":
            if words.count > 2, words[1] == "add" { job.addToGlossary(words[2...].joined(separator: " ")) }
            if words.count > 2, words[1] == "remove" { job.removeFromGlossary(words[2...].joined(separator: " ")) }
            return "glossary \(job.glossary.words) → \(Glossary.file.path)"
        case "replace":
            let pair = line.dropFirst("replace ".count).components(separatedBy: " => ")
            guard pair.count == 2 else { return "replace <find> => <with>" }
            return "replaced \(job.replaceAll(pair[0], with: pair[1], wholeWords: true))"
        case "pauses", "cutpauses":
            guard let minimum = number(1) else { return "\(parts[0]) <seconds>" }
            let cut = parts[0] == "cutpauses"
            Task { @MainActor [weak job] in
                guard let job else { return }
                let voice = await job.voiceActivity()
                let found = job.document().pauses(minimum: minimum, voice: voice)
                job.appendLog("debug> pauses \(minimum): \(found.count), " + found.map { String(format: "%.2f–%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: " "))
                if cut {
                    job.removePauses(found)
                    job.appendLog("debug> cut: \(String(format: "%.2f", job.duration)) s, \(job.shots.count) shots, \(job.project?.audio.count ?? 0) sound clips, \(job.cues.count) captions")
                }
            }
            return "listening (voice \(job.sync.voice == nil ? "not read yet" : "ready"))"
        case "grid":                           // the beat grid the timeline shows, and the magnet
            guard let g = job.grid else { return "no grid" }
            return String(format: "%.2f bpm, offset %.3f, magnet %@, file grid %@", g.bpm, g.offset, job.magnet ? "on" : "off",
                          job.project?.grid.map { String(format: "%.2f/%.3f", $0.bpm, $0.offset) } ?? "-")
        case "insertclip":                     // insertclip <shot id> <file>: the «+» on the cut after that shot → «Видео»
            guard words.count > 2 else { return "insertclip <shot id> <file>" }
            job.insertClip(URL(fileURLWithPath: words.dropFirst(2).joined(separator: " ")), after: words[1])
            return "inserting after \(words[1])"
        case "audiomove":                      // audiomove <id> <start>: a sound clip dragged along the timeline
            guard words.count > 2, let t = number(2) else { return "audiomove <id> <start>" }
            job.moveAudio(words[1], to: t)
            return "\(words[1]) at \(job.audioClip(words[1])?.start ?? -1)"
        case "audiotools":                     // the volume window of a sound clip, as a click on its track opens it
            guard words.count > 1, let clip = job.project?.audio.first(where: { $0.role.rawValue == words[1] || $0.id == words[1] }) else { return "audiotools voice|music|<id>" }
            job.audioTools = clip.id
            if let db = number(2) { job.updateAudio(clip.id) { $0.gain = pow(10, db / 20) } }
            return "\(clip.id) gain \(job.project?.audio.first { $0.id == clip.id }?.gain ?? 0)"
        case "shotedit":                       // shots: list | ripple <id> <end> | head <id> <start> | roll <id> <end> | move <id> <index> [video] | flag <id> <key> | note <id> <text>
            let id = words.count > 2 ? words[2] : ""
            switch words.count > 1 ? words[1] : "list" {
            case "ripple": if let t = number(3) { job.rippleEnd(of: id, to: t) }
            case "head": if let t = number(3) { job.rippleStart(of: id, to: t) }
            case "roll": if let t = number(3) { job.moveCut(after: id, to: t) }
            case "move": if let k = number(3) { job.moveShot(id, toIndex: Int(k), videoOnly: words[safe: 4] == "video") }
            case "delete": job.deleteShot(id, keepSound: words[safe: 3] == "keep")
            case "flag": if words.count > 3 { let k = words[3]; job.updateShot(id) { s in if s.issues.contains(k) { s.issues.removeAll { $0 == k } } else { s.issues.append(k) } } }
            case "note": job.updateShot(id) { $0.note = words.dropFirst(3).joined(separator: " ") }
            default: break
            }
            let shots = (job.project?.shots ?? []).map { s in
                "\(s.id) \(String(format: "%.2f-%.2f", s.start, s.end)) in \(String(format: "%.2f", s.inPoint))" + (s.flagged ? " ⚑\(s.issues)\(s.note ?? "")" : "")
            }.joined(separator: " | ")
            let audio = (job.project?.audio ?? []).map { c in
                "\(c.id) at \(String(format: "%.2f", c.start)) in \(String(format: "%.2f", c.inPoint)) for \(c.duration.map { String(format: "%.2f", $0) } ?? "–")"
            }.joined(separator: " | ")
            let caps = job.cues.map { String(format: "%.2f", $0.start) }.joined(separator: ",")
            return "SHOTS \(shots) || AUDIO \(audio) || CUES \(caps) || dur \(String(format: "%.2f", job.project?.duration ?? 0))"
        case "transition":                     // transitions: add <shot#> | set <#> kind|dur|dir <v> | focus <#> | delete <#> | list
            let list = job.transitions
            let k = Int(words[safe: 2] ?? "") ?? -1
            switch words[safe: 1] ?? "" {
            case "add" where job.shots.indices.contains(k): job.addTransition(after: job.shots[k].id)
            case "focus" where list.indices.contains(k): job.focus = .transition(list[k].id); job.libraryTab = .transitions
            case "set" where list.indices.contains(k):
                let v = words[safe: 4] ?? ""
                job.updateTransition(list[k].id) { c in
                    switch words[safe: 3] {
                    case "kind": if let kind = TransitionClip.Kind(rawValue: v) { c.kind = kind }
                    case "dir": if let d = TransitionClip.Direction(rawValue: v) { c.direction = d }
                    default: if let x = Double(v) { c.duration = x }
                    }
                }
            case "delete" where list.indices.contains(k): job.deleteTransition(list[k].id)
            default: break
            }
            return job.transitions.map { "\($0.id) after \($0.after) \($0.kind.rawValue) \($0.duration) \($0.direction.rawValue)" }.joined(separator: " | ")
        case "filter":                         // filters: add | focus <#> | set <#> exposure|contrast|saturation|warmth|tint <v> | move <#> <start> <length> | delete <#> | look
            let list = job.filters
            let k = Int(words[safe: 2] ?? "") ?? -1
            switch words[safe: 1] ?? "" {
            case "add": job.addFilter()
            case "look": job.focus = .look; job.libraryTab = .filters; if job.project?.look == nil { job.updateLook { _ in } }
            case "focus" where list.indices.contains(k): job.focus = .filter(list[k].id); job.libraryTab = .filters
            case "set" where list.indices.contains(k):
                if let v = number(4) {
                    job.updateFilter(list[k].id) { f in
                        switch words[safe: 3] {
                        case "exposure": f.grade.exposure = v; case "contrast": f.grade.contrast = v; case "saturation": f.grade.saturation = v
                        case "warmth": f.grade.warmth = v; default: f.grade.tint = v
                        }
                    }
                }
            case "move" where list.indices.contains(k): if let a = number(3), let b = number(4) { job.updateFilter(list[k].id) { $0.start = a; $0.duration = b } }
            case "delete" where list.indices.contains(k): job.deleteFilter(list[k].id)
            default: break
            }
            return job.filters.map { String(format: "%@ %.2f-%.2f e%.2f w%.2f", $0.id, $0.start, $0.end, $0.grade.exposure, $0.grade.warmth) }.joined(separator: " | ")
        case "capmove":                        // a caption dragged on the timeline: capmove <#> <start> [<#> <start> … one drag]
            let ordered = job.orderedCues
            guard words.count > 2, let k = Int(words[1]), ordered.indices.contains(k) else { return "capmove <#> <start>…" }
            let cue = ordered[k], base = job.cues
            job.pushHistory()
            for t in words.dropFirst(2).compactMap(Double.init) { job.move(cue.id, to: t, keeping: cue.end - cue.start, base: base) }
            return job.orderedCues[max(0, k - 1)...min(ordered.count - 1, k + 1)].map { c in
                String(format: "%.2f-%.2f ", c.start, c.end) + c.text + " [" + c.words.map { String(format: "%.2f", $0.start) }.joined(separator: ",") + "]"
            }.joined(separator: " | ")
        case "audioedit":                      // sound clips: list | move <id> <start> | trim <id> <from> <to> | split <id> <t> | delete <id>
            let id = words.count > 2 ? words[2] : ""
            switch words.count > 1 ? words[1] : "list" {
            case "move": if let t = number(3) { job.moveAudio(id, to: t) }
            case "trim": if let a = number(3), let b = number(4) { job.trimAudio(id, from: a, to: b) }
            case "split": if let t = number(3) { job.focus = .audio(id); job.seek(t); job.splitAtPlayhead() }
            case "delete": job.focus = .audio(id); job.deleteAudio(id)
            default: break
            }
            return (job.project?.audio ?? []).map { c in
                "\(c.id) \(c.role.rawValue) at \(c.start) in \(c.inPoint) for \(c.duration.map { String(format: "%.3f", $0) } ?? "–")"
            }.joined(separator: " | ")
        case "review":                         // the Graphics tab: a review's card at the playhead ("own" = one to fill in)
            if job.reviews == nil { job.loadReviews() }
            guard words.count > 1 else { return "review <#>|own — \(job.reviews?.reviews.count ?? 0) in \(job.reviews?.folder.path ?? "none")" }
            if words[1] == "own" { job.addReview(nil) } else {
                guard let i = Int(words[1]), let r = job.reviews?.reviews[safe: i] else { return "no review \(words[1])" }
                job.addReview(r)
            }
            if case .title(let id) = job.focus, let t = job.title(id) { return "\(t.id) \(t.style) \(t.kicker ?? "") photo \(t.image ?? "-")" }
            return "?"
        case "collage", "slider":              // the Graphics tab's two buttons
            job.addReviewGraphic(style: words[0] == "collage" ? "T9" : "T10")
            if case .title(let id) = job.focus, let t = job.title(id) { return "\(t.id) \(t.style) \(t.reviews?.map(\.name) ?? [])" }
            return "?"
        case "togglereview":                   // a click on a review with a collage or slider selected
            guard case .title(let id) = job.focus, let i = Int(words[safe: 1] ?? ""), let r = job.reviews?.reviews[safe: i] else { return "togglereview <#> (a collage/slider selected)" }
            job.toggleReview(r, in: id)
            return "\(job.title(id)?.reviews?.map(\.name) ?? [])"
        case "scene":                          // a kit scene at the playhead
            if job.motionScenes == nil { job.loadMotion() }
            guard let name = words[safe: 1], let scene = job.motionScenes?.first(where: { $0.name == name }) else {
                return "scene <name> — \(job.motionScenes?.map(\.name) ?? [])"
            }
            job.addOverlay(scene)
            return "\(job.overlays.count) overlays"
        case "overlaylength":                  // the right edge of a scene dragged: overlaylength <#> <seconds> | overlaylength <#> reset
            guard let k = Int(words[safe: 1] ?? ""), let clip = job.overlays[safe: k] else { return "overlaylength <#> <seconds|reset>" }
            if words[safe: 2] == "reset" { job.updateOverlay(clip.id) { $0.duration = nil } }
            else if let s = number(2) { job.updateOverlay(clip.id) { $0.duration = max(0.3, s) } }
            job.rebuildIfPictureChanged()
            let now = job.overlay(clip.id) ?? clip
            return "\(clip.id) \(now.start) + \(MotionLibrary.duration(now, projectURL: job.projectURL)) (set \(now.duration.map { "\($0)" } ?? "-"))"
        case "overlaytools":                   // a click on a scene in the Graphics track
            guard let k = Int(words[safe: 1] ?? ""), let clip = job.overlays[safe: k] else { return "overlaytools <#>" }
            job.focus = .overlay(clip.id); job.overlayTools = clip.id
            return "\(clip.id) \(clip.label ?? "") at \(clip.start)"
        case "dragpiece":                      // a drag on the picture: from stage point (x, y) by (dx, dy); "reset" = double click
            guard let x = number(1), let y = number(2) else { return "dragpiece <x> <y> <dx> <dy> | dragpiece <x> <y> reset" }
            guard let hit = job.overlayRenderer.piece(at: CGPoint(x: x, y: y), time: job.currentTime) else { return "nothing there" }
            if words[safe: 3] == "reset" { job.setOffset(hit, nil); return "\(hit) reset" }
            let from = job.offset(of: hit) ?? .zero
            job.setOffset(hit, CGPoint(x: from.x + (number(3) ?? 0), y: from.y + (number(4) ?? 0)))
            job.rebuildIfPictureChanged()
            return "\(hit) -> \(job.offset(of: hit).map { "\($0.x), \($0.y)" } ?? "-")"
        case "gallery":                        // the footage library for shot # (from the shot window's button)
            guard let k = Int(words[safe: 1] ?? ""), let shot = job.shots[safe: k] else { job.closeGallery(); return "closed" }
            job.openGallery(for: shot.id)
            return "gallery for \(shot.id): \(job.galleryMoments.count) moments"
        case "clips":                          // clips <shot #> [<file>]: the double click on a shot; with a file, puts it in
            guard let k = Int(words[safe: 1] ?? ""), let shot = job.shots[safe: k] else { job.closeClips(); return "closed" }
            if words.count > 2 { job.putClip(URL(fileURLWithPath: words.dropFirst(2).joined(separator: " ")), into: shot.id); return "\(shot.id) <- \(job.shot(shot.id)?.src ?? "-")" }
            job.openClips(for: shot.id)
            return "clips for \(shot.id), folder \(job.clipsFolder?.path ?? "none")"
        case "layers":                         // layers | layers add <time> <file> | layers del <#>: the overlay track
            if words[safe: 1] == "add", let t = number(2), words.count > 3 {
                job.addLayer(URL(fileURLWithPath: words.dropFirst(3).joined(separator: " ")), at: t); return "adding at \(t)"
            }
            if words[safe: 1] == "del", let k = Int(words[safe: 2] ?? ""), let v = job.layers[safe: k] { job.deleteLayer(v.id); return "deleted \(v.id)" }
            return job.layers.map { String(format: "%@ %.2f-%.2f in %.2f %@", $0.id, $0.start, $0.end, $0.inPoint, $0.label ?? $0.src) }
                .joined(separator: " | ")
        case "galleryhide":                    // "Hide from the library" on the picked moment
            guard let m = job.galleryPicked else { return "pick first" }
            job.hideMoment(m, why: words[safe: 1] ?? "pink tip")
            return "hidden \(m.clip) \(m.from)-\(m.to); \(job.galleryMoments.count) moments left"
        case "gallerypick", "galleryuse":      // a click (or double click) on moment # of the open category
            let list = job.galleryMoments.filter { $0.category == job.galleryCategory }
            guard let k = Int(words[safe: 1] ?? ""), let m = list[safe: k] else { return "\(job.galleryCategory.rawValue): \(list.count) moments" }
            job.galleryPicked = m
            if words[0] == "galleryuse", let id = job.galleryShot { job.useMoment(m, for: id); job.closeGallery() }
            return "\(m.clip) \(m.from)-\(m.to)"
        case "capopt":                         // the caption settings: capitals, italic, how plain captions come in
            guard words.count > 1 else { return "capopt upper | italic | accents | entrance pop|words|rise|fade" }
            switch words[1] {
            case "upper": job.setCaptions { $0.uppercase.toggle() }
            case "italic": job.setCaptions { $0.italic.toggle() }
            case "accents": job.setCaptions { $0.accents.toggle() }
            case "entrance":
                guard words.count > 2, let e = CaptionEntrance(rawValue: words[2]) else { return "entrance?" }
                job.setCaptions { $0.entrance = e == .pop ? nil : e }
            default: return "?"
            }
            let c = job.project?.captions
            return "upper \(c?.uppercase ?? false), italic \(c?.italic ?? false), accents \(c?.accents ?? true), entrance \(c?.entrance?.rawValue ?? "pop")"
        case "zoom":                           // the timeline's zoom and where it starts, in seconds
            guard let z = number(1) else { return "zoom <factor> [start]" }
            job.timelineZoom = z; job.timelineOffset = number(2) ?? job.timelineOffset
            return "zoom \(job.timelineZoom) from \(job.timelineOffset)"
        case "shuttle":
            guard words.count > 1, let d = Int(words[1]) else { return "shuttle -1|0|1" }
            job.shuttle(d); return "rate \(job.player.rate), reverse \(job.player.currentItem?.canPlayReverse ?? false)"
        case "wordstart":
            guard words.count > 3, let c = cue(words[1]), let w = Int(words[2]), let t = Double(words[3]) else { return "wordstart <caption> <word> <seconds>" }
            job.pushHistory(); job.moveWordStart(c.id, word: w, to: t)
            return job.timedWords(of: job.cues.first { $0.id == c.id }!).map { "\($0.text)@\(String(format: "%.3f-%.3f", $0.start, $0.end))" }.joined(separator: " ")
        case "nudgeword":
            guard words.count > 4, let c = cue(words[1]), let w = Int(words[2]), let f = Double(words[4]) else { return "nudgeword <caption> <word> start|end <frames>" }
            job.nudgeWord(c.id, word: w, start: words[3] == "start", frames: f)
            let now = job.cues.first { $0.id == c.id }!
            return String(format: "caption %.3f-%.3f: ", now.start, now.end) + job.timedWords(of: now).map { "\($0.text)@\(String(format: "%.3f-%.3f", $0.start, $0.end))" }.joined(separator: " ")
        case "suggest":
            guard words.count > 1, let k = Int(words[1]), job.shots.indices.contains(k) else { return "suggest <shot>" }
            job.loadFootage()
            guard job.footageState == .ready else { return "footage \(job.footageState) — ask again" }
            return job.suggestions(for: job.shots[k]).map { "\($0.clip) @\(String(format: "%.1f", $0.from)) \($0.tag) [\($0.who)] used \($0.usedIn)" }.joined(separator: " | ")
        case "usesuggest":
            guard words.count > 2, let k = Int(words[1]), let n = Int(words[2]), job.shots.indices.contains(k) else { return "usesuggest <shot> <n>" }
            let shot = job.shots[k]
            let list = job.suggestions(for: shot)
            guard list.indices.contains(n) else { return "no suggestion \(n)" }
            job.useFootage(list[n], for: shot.id)
            let now = job.shot(shot.id)
            return "shot \(k): \(now?.label ?? "-") in \(now?.inPoint ?? -1)"
        case "simclaude":                      // the file changes on disk the way Claude changes it
            guard parts.count > 1, let url = job.projectURL, var p = try? Project.load(from: url), !p.titles.isEmpty else { return "no project with titles" }
            p.titles[0].text = parts.dropFirst().joined(separator: " ")
            p.revision += 1
            p.savedBy = "claude"
            do { try p.save(to: url); return "wrote revision \(p.revision)" } catch { return error.localizedDescription }
        default:
            return "unknown command"
        }
    }

    // MARK: State

    private func dump(_ job: Job) -> String {
        let ordered = job.orderedCues
        let index = { (id: Cue.ID?) in ordered.firstIndex { $0.id == id }.map(String.init) ?? "-" }
        let picked = ordered.indices.filter { job.selection.contains(ordered[$0].id) }
        let sizes = job.paragraphs.map(\.count)
        return "captions \(ordered.count), selected \(index(job.selected)), selection \(picked.prefix(12))\(picked.count > 12 ? "…" : "") (\(picked.count)), "
            + "focus \(job.focus), style \(job.captionStyle), paragraphs \(sizes.count) \(sizes.prefix(12)), marked \(job.cues.filter(\.paragraph).count), "
            + "undo \(job.canUndo), revision \(job.syncStatus?.revision ?? -1), tab \(job.libraryTab?.rawValue ?? "auto"), t \(String(format: "%.2f", job.currentTime)), "
            + "active \(NSApp.isActive), key \(window?.isKeyWindow ?? false)"
    }

    // MARK: Synthetic input

    /// The editor window: the largest visible one (a tools popover is a small window of its own).
    private var window: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Window points from the top-left, as in a snapshot divided by its scale.
    private func location(_ p: CGPoint, in window: NSWindow) -> NSPoint {
        NSPoint(x: p.x, y: (window.contentView?.bounds.height ?? 0) - p.y)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags, count: Int, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: location(p, in: window), modifierFlags: flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func click(_ p: CGPoint, flags: NSEvent.ModifierFlags, count: Int) -> String {
        guard let window else { return "no window" }
        for n in 1...count {
            mouse(.leftMouseDown, p, flags: flags, count: n, in: window)
            mouse(.leftMouseUp, p, flags: flags, count: n, in: window)
        }
        return "clicked \(p)"
    }

    private func drag(from a: CGPoint, to b: CGPoint) -> String {
        guard let window else { return "no window" }
        mouse(.leftMouseDown, a, flags: [], count: 1, in: window)
        for k in 1...12 {
            let t = Double(k) / 12
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: [], count: 1, in: window)
        }
        mouse(.leftMouseUp, b, flags: [], count: 1, in: window)
        return "dragged \(a) → \(b)"
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags) -> String {
        guard let window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        else { return "no event" }
        NSApp.postEvent(event, atStart: false)
        return "key \(code)"
    }

    // MARK: Pictures

    private var output: AVPlayerItemVideoOutput?

    private func videoFrame(_ item: AVPlayerItem, at time: CMTime, to path: String) -> String {
        if output == nil || !item.outputs.contains(where: { $0 === output }) {
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(o)
            output = o
            item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            return "output attached — run videoframe again"
        }
        guard let buffer = output?.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return "no frame at \(time.seconds)" }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return "no image" }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "no png" }
        do { try png.write(to: URL(fileURLWithPath: path)); return "wrote \(path) @\(time.seconds)" } catch { return error.localizedDescription }
    }

    private func snapshot(to path: String, popover: Bool = false) -> String {
        let pick = popover ? NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0 !== window }.last : window
        guard let pick, let view = pick.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no window" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "no image" }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return "wrote \(path) — \(Int(view.bounds.width))×\(Int(view.bounds.height)) pt, \(rep.pixelsWide)×\(rep.pixelsHigh) px"
        } catch { return error.localizedDescription }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
