import AVFoundation
import Foundation
import SimbiaCore

/// An emoji on a title: the title's id and its place in the title's list.
struct StickerRef: Equatable {
    let title: String
    let index: Int
}

/// What the inspector is showing. Captions keep using `selected` for which one.
enum Focus: Equatable {
    case caption
    case title(String)
    case shot(String)
    /// A motion-graphics scene from the kit (a project overlay).
    case overlay(String)
    /// A clip on the voice or music track.
    case audio(String)
    /// A colour filter over a stretch of the edit.
    case filter(String)
    /// The project's overall filter (look).
    case look
    /// A transition on a cut.
    case transition(String)
}

// Edits behind the inspector and the timeline. Every one is a single undo step.
extension Job {
    /// Two-language string at the call site; both are required, so neither can be forgotten.
    /// A string in the interface's language. French falls back to English where a call has none yet.
    func t(_ ru: String, _ en: String, _ fr: String? = nil) -> String {
        switch language {
        case .ru: ru
        case .en: en
        case .fr: fr ?? en
        }
    }

    // MARK: Captions

    /// The native caption styles draw accent words in their own font and colour; any word can be one.
    func toggleWordAccent(_ id: Cue.ID, word index: Int) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        var words = timedWords(of: cues[i])
        guard words.indices.contains(index) else { return }
        pushHistory()
        words[index].accent.toggle()
        cues[i].words = words
    }

    /// One word retyped: its timing and accent stay; several words share its time; nothing deletes it
    /// (and the caption, if that was its last word).
    func updateWord(_ id: Cue.ID, word index: Int, to text: String) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        var words = timedWords(of: cues[i])
        guard words.indices.contains(index) else { return }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts != [words[index].text] else { return }
        pushHistory()
        let word = words[index]
        let step = (word.end - word.start) / Double(max(parts.count, 1))
        words.replaceSubrange(index...index, with: parts.enumerated().map { k, part in
            Word(start: word.start + step * Double(k), end: k == parts.count - 1 ? word.end : word.start + step * Double(k + 1),
                 text: part, accent: word.accent)
        })
        guard !words.isEmpty else { removeCaptions([id]); return }
        cues[i].words = words
        cues[i].text = words.map(\.text).joined(separator: " ")
    }

    /// A break before the word: a new caption starts with it — or, for the first word of a caption, the
    /// break that is there goes (it joins the caption before).
    func toggleBreak(_ id: Cue.ID, word index: Int) {
        if index > 0 { splitCaption(id, beforeWord: index) } else { mergeWithPrevious(id) }
    }

    func isAccent(_ id: Cue.ID, word index: Int) -> Bool {
        guard let cue = cues.first(where: { $0.id == id }) else { return false }
        let words = timedWords(of: cue)
        return words.indices.contains(index) && words[index].accent
    }

    /// Moves one edge by `delta` seconds, kept inside the neighbours.
    func nudge(_ id: Cue.ID, start delta: Double) {
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        pushHistory()
        retime(id, start: cue.start + delta)
    }

    func nudge(_ id: Cue.ID, end delta: Double) {
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        pushHistory()
        retime(id, end: cue.end + delta)
    }

    /// The caption stays on screen until the next one starts.
    func extendToNext(_ id: Cue.ID) {
        let ordered = orderedCues
        guard let k = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = k + 1 < ordered.count ? ordered[k + 1].start : duration
        pushHistory()
        retime(id, end: target)
    }

    /// Splits before the first word that starts at or after `time` (or in the middle, when the
    /// playhead is outside the caption).
    func splitCaption(_ id: Cue.ID, at time: Double) {
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        let words = timedWords(of: cue)
        guard words.count > 1 else { return }
        var cut = words.firstIndex { $0.start >= time - 0.01 } ?? words.count / 2
        if cut <= 0 || cut >= words.count { cut = words.count / 2 }
        splitCaption(id, beforeWord: cut)
    }

    /// Two captions from one: the words before `index` keep the caption, the rest become the next one.
    func splitCaption(_ id: Cue.ID, beforeWord index: Int) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[i]
        let words = timedWords(of: cue)
        guard index > 0, index < words.count else { return }
        pushHistory()
        let head = Array(words[..<index]), tail = Array(words[index...])
        let cut = min(max(tail[0].start, cue.start + 0.05), cue.end - 0.05)
        var list = cues
        list[i] = Cue(id: cue.id, start: cue.start, end: cut, text: head.map(\.text).joined(separator: " "),
                      words: head, accent: cue.accent, key: cue.key, paragraph: cue.paragraph)
        list.insert(Cue(start: cut, end: cue.end, text: tail.map(\.text).joined(separator: " "),
                        words: tail, accent: cue.accent), at: i + 1)
        cues = list
    }

    func mergeWithNext(_ id: Cue.ID) {
        let ordered = orderedCues
        guard let k = ordered.firstIndex(where: { $0.id == id }), k + 1 < ordered.count else { return }
        pushHistory()
        merge([ordered[k], ordered[k + 1]])
    }

    func mergeWithPrevious(_ id: Cue.ID) {
        let ordered = orderedCues
        guard let k = ordered.firstIndex(where: { $0.id == id }), k > 0 else { return }
        pushHistory()
        merge([ordered[k - 1], ordered[k]])
        selected = ordered[k - 1].id
    }

    /// M: the selected captions join — every unbroken run of selected neighbours becomes one caption.
    /// With one caption selected it joins the next one.
    func mergeSelection() {
        let runs = selectedRuns.filter { $0.count > 1 }
        guard !runs.isEmpty else {
            if let id = selected { mergeWithNext(id) }
            return
        }
        pushHistory()
        runs.forEach(merge)
        selection = Set(runs.map { $0[0].id })
        if let anchor = selected, !selection.contains(anchor) { selected = runs[0][0].id }
    }

    /// Neighbouring captions (in time order) into the first of them; a paragraph break inside goes.
    private func merge(_ run: [Cue]) {
        guard let first = run.first, let i = cues.firstIndex(where: { $0.id == first.id }) else { return }
        let words = run.flatMap(timedWords(of:))
        let gone = Set(run.dropFirst().map(\.id))
        var list = cues
        list[i].end = run.map(\.end).max() ?? first.end
        list[i].words = words
        list[i].text = words.map(\.text).joined(separator: " ")
        list[i].accent = run.contains(where: \.accent)
        list.removeAll { gone.contains($0.id) }
        cues = list
    }

    /// ⌫: the selected captions are removed (one undo step).
    func deleteSelection() {
        let doomed = Set(selectedCues.map(\.id))
        guard !doomed.isEmpty else { return }
        pushHistory()
        removeCaptions(doomed)
    }

    /// A paragraph whose first caption goes starts at the next one that is left.
    func removeCaptions(_ doomed: Set<Cue.ID>) {
        let ordered = orderedCues
        var marks: [Bool] = [], kept: [Cue] = [], carry = false
        for (cue, starts) in zip(ordered, paragraphStarts(ordered)) {
            if doomed.contains(cue.id) { carry = carry || starts; continue }
            kept.append(cue)
            marks.append(starts || carry)
            carry = false
        }
        let after = kept.first { $0.start >= (ordered.last { doomed.contains($0.id) }?.start ?? 0) }
        cues.removeAll { doomed.contains($0.id) }
        if !kept.isEmpty { pin(marks, kept) }
        selected = (after ?? kept.last)?.id
    }

    // MARK: Selection

    /// The selected captions in time order.
    var selectedCues: [Cue] { orderedCues.filter { selection.contains($0.id) } }

    /// The selection as runs of captions that follow each other with nothing unselected between.
    var selectedRuns: [[Cue]] {
        var runs: [[Cue]] = []
        var open = false
        for cue in orderedCues {
            if selection.contains(cue.id) {
                if open { runs[runs.count - 1].append(cue) } else { runs.append([cue]); open = true }
            } else {
                open = false
            }
        }
        return runs
    }

    /// A click on a caption: alone it selects just that one, ⇧ selects the range from the anchor,
    /// ⌘ adds or removes it.
    func click(_ cue: Cue, extend: Bool = false, toggle: Bool = false) {
        focus = .caption
        if extend, let anchor = selected {
            let ordered = orderedCues
            guard let a = ordered.firstIndex(where: { $0.id == anchor }),
                  let b = ordered.firstIndex(where: { $0.id == cue.id }) else { select(cue); return }
            selection = Set(ordered[min(a, b)...max(a, b)].map(\.id))
        } else if toggle {
            if selection.contains(cue.id), selection.count > 1 {
                selection.remove(cue.id)
                if selected == cue.id { selected = selectedCues.first?.id }
            } else {
                selection.insert(cue.id)
                selected = cue.id
            }
        } else {
            select(cue)
        }
    }

    /// ⌘A
    func selectAllCaptions() {
        guard let first = orderedCues.first else { return }
        focus = .caption
        if selected == nil { selected = first.id }
        selection = Set(cues.map(\.id))
    }

    /// Esc: back to the one caption the inspector shows.
    func collapseSelection() {
        if let selected { selection = [selected] }
    }

    // MARK: Paragraphs

    /// The captions in time order, broken into paragraphs.
    var paragraphs: [[Cue]] {
        let (ordered, marks) = orderedAndStarts
        var out: [[Cue]] = []
        for (cue, starts) in zip(ordered, marks) {
            if starts || out.isEmpty { out.append([cue]) } else { out[out.count - 1].append(cue) }
        }
        return out
    }

    /// Which of the (time-ordered) captions begin a paragraph: the marked ones — or, while none is
    /// marked, each one after a sentence or a pause.
    func paragraphStarts(_ ordered: [Cue]) -> [Bool] {
        let marked = ordered.contains(where: \.paragraph)
        return ordered.indices.map { i in
            if i == 0 { return true }
            if marked { return ordered[i].paragraph }
            guard let last = timedWords(of: ordered[i - 1]).last, let next = timedWords(of: ordered[i]).first else { return false }
            return CaptionGrouping.startsParagraph(after: last.text, end: last.end, nextStart: next.start)
        }
    }

    /// Selects every caption of the paragraph that holds `id`.
    func selectParagraph(containing id: Cue.ID) {
        guard let paragraph = paragraphs.first(where: { $0.contains { $0.id == id } }), let first = paragraph.first else { return }
        focus = .caption
        selected = first.id
        selection = Set(paragraph.map(\.id))
        if currentTime < first.start || currentTime >= paragraph.last!.end { seek(first.start) }
    }

    /// A paragraph from this word on: a word inside a caption splits it first (one undo step for both);
    /// a caption's first word toggles the paragraph start as ↩ does.
    func toggleParagraph(at id: Cue.ID, word index: Int) {
        guard index > 0 else { toggleParagraph(at: id); return }
        guard let i = cues.firstIndex(where: { $0.id == id }), index < timedWords(of: cues[i]).count else { return }
        splitCaption(id, beforeWord: index)
        let (ordered, starts) = orderedAndStarts
        guard let k = ordered.firstIndex(where: { $0.id == cues[i + 1].id }) else { return }
        var marks = starts
        marks[k] = true
        pin(marks, ordered)
    }

    /// ↩: the caption begins a new paragraph — or, if it already does, its paragraph joins the one before.
    func toggleParagraph(at id: Cue.ID) {
        let ordered = orderedCues
        guard let k = ordered.firstIndex(where: { $0.id == id }), k > 0 else { return }
        setParagraphStart(id, paragraphStarts(ordered)[k] == false)
    }

    /// The selected captions become one paragraph: the breaks between them go.
    func joinParagraphs(of ids: [Cue.ID]) {
        let ordered = orderedCues
        let wanted = Set(ids)
        guard let first = ordered.firstIndex(where: { wanted.contains($0.id) }),
              let last = ordered.lastIndex(where: { wanted.contains($0.id) }), last > first else { return }
        let starts = paragraphStarts(ordered)
        guard starts[(first + 1)...last].contains(true) else { return }
        pushHistory()
        var marks = starts
        for k in (first + 1)...last { marks[k] = false }
        pin(marks, ordered)
    }

    /// Marks or unmarks one paragraph start. Every start is pinned first, so changing one never moves another.
    private func setParagraphStart(_ id: Cue.ID, _ value: Bool) {
        let ordered = orderedCues
        guard let k = ordered.firstIndex(where: { $0.id == id }), k > 0 else { return }
        var marks = paragraphStarts(ordered)
        guard marks[k] != value else { return }
        pushHistory()
        marks[k] = value
        pin(marks, ordered)
    }

    private func pin(_ marks: [Bool], _ ordered: [Cue]) {
        let mark = Dictionary(zip(ordered.map(\.id), marks), uniquingKeysWith: { a, _ in a })
        var list = cues
        for i in list.indices { list[i].paragraph = mark[list[i].id] ?? false }
        cues = list
    }

    // MARK: Titles

    var titles: [TitleItem] { project?.titles ?? [] }

    func title(_ id: String) -> TitleItem? { titles.first { $0.id == id } }

    func updateTitle(_ id: String, undoable: Bool = true, _ change: (inout TitleItem) -> Void) {
        guard var p = project, let i = p.titles.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushHistory() }
        change(&p.titles[i])
        p.titles[i].duration = max(0.5, p.titles[i].duration)
        p.titles[i].start = max(0, p.titles[i].start)
        p.titles.sort { $0.start < $1.start }
        project = p
    }

    /// «Выровнять все заголовки по этому» (⇧⌘A, the title's right-click menu): every other title gets this one's
    /// height — its hand-set `y` (nil = its own place) — once, in one undo step; nothing links them afterwards, each
    /// moves on its own again. Their `x`, text, timing and style stay.
    func alignTitles(to id: String) {
        guard var p = project, let source = p.titles.first(where: { $0.id == id }) else { return }
        let others = p.titles.indices.filter { p.titles[$0].id != id && p.titles[$0].y != source.y }
        guard !others.isEmpty else { show(t("Все заголовки уже на этой высоте", "Every title is already at this height", "Tous les titres sont déjà à cette hauteur"), isError: false); return }
        pushHistory()
        for k in others { p.titles[k].y = source.y }
        project = p
        show(t("Заголовки выровнены по «\(source.text.replacingOccurrences(of: "|", with: " "))»: \(others.count) · ⌘Z вернёт",
               "Titles aligned to «\(source.text.replacingOccurrences(of: "|", with: " "))»: \(others.count) · ⌘Z undoes", "Titres alignés sur « \(source.text.replacingOccurrences(of: "|", with: " ")) » : \(others.count) · ⌘Z pour annuler"), isError: false)
    }

    /// The title picked now, when there is another to align to it (the menu item and ⇧⌘A are off otherwise).
    var titleToAlignTo: String? {
        guard case .title(let id) = focus, (project?.titles.count ?? 0) > 1 else { return nil }
        return id
    }

    func addTitle(at time: Double, style chosen: String? = nil) {
        guard var p = project else { return }
        pushHistory()
        let style = chosen ?? titles.last { $0.style != "T8" }?.style ?? "T1"          // a review card is added from Graphics
        let item = TitleItem(id: Project.newID("t"), style: style, text: t("Заголовок", "Title", "Titre"),
                             start: max(0, min(time, p.duration - 3.6)), duration: 3.6)
        p.titles.append(item)
        p.titles.sort { $0.start < $1.start }
        project = p
        focus = .title(item.id)
        titleTools = item.id
    }

    func duplicateTitle(_ id: String) {
        guard var p = project, let item = p.titles.first(where: { $0.id == id }) else { return }
        pushHistory()
        var copy = item
        copy.id = Project.newID("t")
        copy.start = min(item.end + 0.5, max(0, p.duration - item.duration))
        p.titles.append(copy)
        p.titles.sort { $0.start < $1.start }
        project = p
        focus = .title(copy.id)
        titleTools = copy.id
    }

    func deleteTitle(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        p.titles.removeAll { $0.id == id }
        project = p
        titleTools = nil
        focus = .caption
    }

    // MARK: Shots

    var shots: [Shot] { project?.shots ?? [] }

    /// A shot, or a video on the overlay track (same window, crop and colour).
    func shot(_ id: String) -> Shot? { shots.first { $0.id == id } ?? layers.first { $0.id == id } }

    /// Changes a video's key or transform: the preview shows it at once, no rebuild (as the colour).
    func updateCutout(_ id: String, undoable: Bool = true, _ change: (inout Shot) -> Void) {
        updateShot(id, undoable: undoable, change)
        pushColour()
    }

    /// The transform moved to `x` / `y` (stage px); one that no longer does anything is dropped.
    static func placed(_ t: LayerTransform?, x: Double, y: Double) -> LayerTransform? {
        var t = t ?? LayerTransform()
        t.x = x; t.y = y
        return t.isIdentity ? nil : t
    }

    func updateShot(_ id: String, undoable: Bool = true, _ change: (inout Shot) -> Void) {
        guard var p = project else { return }
        if let i = p.shots.firstIndex(where: { $0.id == id }) {
            if undoable { pushHistory() }
            change(&p.shots[i])
            p.shots[i].inPoint = max(0, p.shots[i].inPoint)
        } else if let i = p.layers.firstIndex(where: { $0.id == id }) {
            if undoable { pushHistory() }
            change(&p.layers[i])
            p.layers[i].inPoint = max(0, p.layers[i].inPoint)
        } else { return }
        project = p
    }

    /// A shot's speed (or a video's on the overlay track), and its own sound's with it so they stay in sync: it keeps
    /// its place and length and plays `length · speed` of its footage from its in-point; the sound keeps its pitch.
    func setSpeed(_ id: String, _ speed: Double, undoable: Bool = true) {
        guard var p = project, let s = shot(id) else { return }
        let speed = min(10, max(0.1, speed))
        guard abs(s.speed - speed) > 0.0001 else { return }
        if undoable { pushHistory() }
        let own = Set(Self.own(p.audio, of: s).map(\.id))
        for k in p.audio.indices where own.contains(p.audio[k].id) {
            p.audio[k].inPoint = max(0, s.inPoint + (p.audio[k].start - s.start) * speed)
            p.audio[k].speed = speed
        }
        if let i = p.shots.firstIndex(where: { $0.id == id }) { p.shots[i].speed = speed }
        if let i = p.layers.firstIndex(where: { $0.id == id }) { p.layers[i].speed = speed }
        project = p
    }

    /// Slip: the shot keeps its place and length and shows another moment of its clip, from `inPoint` (never past
    /// either end of a clip `length` long); its own sound moves the same way, so the lips stay in sync.
    func slipShot(_ id: String, to inPoint: Double, length: Double?, undoable: Bool = true) {
        guard var p = project, let i = p.shots.firstIndex(where: { $0.id == id }) else { return }
        let s = p.shots[i]
        let new = min(length.map { max(0, $0 - s.footage) } ?? .infinity, max(0, inPoint))
        let delta = new - s.inPoint
        guard abs(delta) > 0.0005 else { return }
        if undoable { pushHistory() }
        let own = Set(Self.own(p.audio, of: s).map(\.id))
        for k in p.audio.indices where own.contains(p.audio[k].id) { p.audio[k].inPoint = max(0, p.audio[k].inPoint + delta) }
        p.shots[i].inPoint = new
        project = p
    }

    /// Rolling edit: the cut between a shot and the next moves, the edit keeps its length. The
    /// following shot starts later (or earlier) in its own footage, so its picture stays in sync. The two shots'
    /// own sound ending or starting on the cut moves with it; a narration across it stays.
    func moveCut(after id: String, to time: Double, snap tolerance: Double = 0, undoable: Bool = true) {
        guard var p = project, let i = p.shots.firstIndex(where: { $0.id == id }), i + 1 < p.shots.count else { return }
        // neither shot runs past its footage: the one before ends where its picture does, the one after starts no
        // earlier than its file (a source shorter than its shot is stretched, i.e. plays slowed down)
        // (footage at a shot's speed: a second of the edit is `speed` seconds of it)
        let most = pictureEnd(p.shots[i]).map { p.shots[i].start + ($0 - p.shots[i].inPoint) / p.shots[i].speed } ?? .infinity
        let low = max(p.shots[i].start + 0.25, p.shots[i + 1].start - p.shots[i + 1].inPoint / p.shots[i + 1].speed)
        let high = min(p.shots[i + 1].end - 0.25, most)
        guard low < high else { return }
        let target = min(high, max(low, snapToGrid(time, tolerance: tolerance)))
        guard abs(target - p.shots[i].end) > 0.0005 else { return }
        if undoable { pushHistory() }
        let delta = target - p.shots[i + 1].start
        let cut = p.shots[i + 1].start
        let before = Set(Self.own(p.audio, of: p.shots[i]).filter { c in
            abs(c.start + (c.duration ?? 0) - cut) < 0.02 && (c.duration ?? 0) + delta > 0.05 }.map(\.id))
        let after = Set(Self.own(p.audio, of: p.shots[i + 1]).filter { c in abs(c.start - cut) < 0.02 && (c.duration ?? 0) - delta > 0.05 }.map(\.id))
        for k in p.audio.indices {
            if before.contains(p.audio[k].id) { p.audio[k].duration? += delta }
            if after.contains(p.audio[k].id) { p.audio[k].start += delta; p.audio[k].inPoint += delta * p.audio[k].speed; p.audio[k].duration? -= delta }
        }
        p.shots[i].end = target
        p.shots[i + 1].start = target
        p.shots[i + 1].inPoint = max(0, p.shots[i + 1].inPoint + delta * p.shots[i + 1].speed)
        project = p
    }

    /// Ripple trim (the cut's lower knob): the shot's end goes to `time` and everything after it — the later
    /// shots, the voice, captions, titles and scenes — slides by the same amount, so no other shot gets
    /// shorter. Longer: the shot's own sound that ends with it runs on with the picture, other voice gets a silent
    /// gap; shorter: that stretch of voice goes, its captions stay and show faster (`squeezeCaptions`). Music is left whole. During a drag, pass the state at its start as `base` so going back and
    /// forth never loses anything.
    func rippleEnd(of id: String, to time: Double, base: (project: Project, cues: [Cue])? = nil, snap tolerance: Double = 0,
                   undoable: Bool = true) {
        guard var p = base?.project ?? project, let i = p.shots.firstIndex(where: { $0.id == id }) else { return }
        var list = Self.anchoringVoice(base?.cues ?? cues, to: p.audio)   // before the squeeze moves words off their voice
        let t = p.shots[i].end
        let most = pictureEnd(p.shots[i]).map { p.shots[i].start + ($0 - p.shots[i].inPoint) / p.shots[i].speed } ?? .infinity   // no longer than its footage
        let target = max(p.shots[i].start + 0.25, min(most, snapToGrid(time, tolerance: tolerance)))
        let d = target - t
        guard abs(d) > 0.0005 || base != nil else { return }
        if undoable { pushHistory() }
        let cutFrom = d < 0 ? t + d : t                     // shortening removes [t + d, t] from every track
        let ends = Set(Self.own(p.audio, of: p.shots[i]).filter { abs($0.start + ($0.duration ?? 0) - t) < 0.02 }.map(\.id))   // its sound up to its last frame
        p.shots[i].end = target
        for k in p.shots.indices where k > i { p.shots[k].start += d; p.shots[k].end += d }
        let tails = Self.tails(p.audio, past: t)                                // a voice running on into the next video stays whole
        let (held, rest) = Self.split(list, over: tails)
        list = rest
        p.audio = Self.ripple(p.audio, at: t, by: d, holding: Set(tails.map(\.id)).union(ends))
        for k in p.audio.indices where ends.contains(p.audio[k].id) { p.audio[k].duration? += d }
        p.audio.removeAll { ends.contains($0.id) && ($0.duration ?? 1) <= 0.05 }
        for k in p.titles.indices where p.titles[k].start >= t - 0.001 { p.titles[k].start += d }
        for k in p.overlays.indices where p.overlays[k].start >= t - 0.001 { p.overlays[k].start += d }
        for k in p.layers.indices where p.layers[k].start >= t - 0.001 { p.layers[k].start += d; p.layers[k].end += d }
        for k in p.filters.indices where p.filters[k].start >= t - 0.001 { p.filters[k].start += d }
        list = d < 0 ? Self.squeezeCaptions(list, cut: cutFrom, t, limit: p.shots[i].start) : list.map { c in
            guard c.start >= t - 0.001 else { return c }
            var c = c; c.start += d; c.end += d
            c.words = c.words.map { var w = $0; w.start += d; w.end += d; return w }
            return c
        }
        p.duration = max(0.1, p.duration + d)
        project = p
        cues = (list + held).sorted { $0.start < $1.start }
    }

    /// Ripple trim of a shot's head (the lower knob on the selected shot's left edge): `time` is where the
    /// edge was dragged. Right = the shot loses that much of its beginning, left = it gets back footage from
    /// before its in-point; the shot before it stays as it is, the shot keeps its place and everything after
    /// slides (that stretch of voice goes with the trimmed footage, its captions show faster, as in `rippleEnd`).
    /// The shot's own sound from its first frame (or from before it) gets back or loses its head with the picture.
    func rippleStart(of id: String, to time: Double, base: (project: Project, cues: [Cue])? = nil, snap tolerance: Double = 0,
                     undoable: Bool = true) {
        guard var p = base?.project ?? project, let i = p.shots.firstIndex(where: { $0.id == id }) else { return }
        var list = Self.anchoringVoice(base?.cues ?? cues, to: p.audio)
        let s = p.shots[i]
        // how much of the head goes: no further back than the footage starts, at least 0.25 s left
        let trim = min(s.end - s.start - 0.25, max(-s.inPoint / s.speed, snapToGrid(time, tolerance: tolerance) - s.start))
        guard abs(trim) > 0.0005 || base != nil else { return }
        if undoable { pushHistory() }
        let d = -trim                                        // what everything after the shot's start moves by
        let at = s.start + max(0, trim)                      // shortening cuts [start, start + trim] out of every track
        p.shots[i].inPoint += trim * s.speed
        p.shots[i].end += d
        for k in p.shots.indices where k > i { p.shots[k].start += d; p.shots[k].end += d }
        let heads = Set(Self.own(p.audio, of: s).filter { $0.start <= s.start + 0.02 }.map(\.id))
        let tails = Self.tails(p.audio, past: s.start).filter { !heads.contains($0.id) }   // the shot before's voice running on into this one stays
        let (held, rest) = Self.split(list, over: tails)
        list = rest
        p.audio = Self.ripple(p.audio, at: at, by: d, holding: Set(tails.map(\.id)).union(heads))
        for k in p.audio.indices where heads.contains(p.audio[k].id) {
            let speed = p.audio[k].speed
            let short = max(0, -(p.audio[k].inPoint + trim * speed)) / speed     // no further back than its file starts
            p.audio[k].start += short
            p.audio[k].inPoint += (trim + short) * speed
            p.audio[k].duration? -= trim + short
        }
        p.audio.removeAll { heads.contains($0.id) && ($0.duration ?? 1) <= 0.05 }
        for k in p.titles.indices where p.titles[k].start >= at - 0.001 { p.titles[k].start += d }
        for k in p.overlays.indices where p.overlays[k].start >= at - 0.001 { p.overlays[k].start += d }
        for k in p.layers.indices where p.layers[k].start >= at - 0.001 { p.layers[k].start += d; p.layers[k].end += d }
        for k in p.filters.indices where p.filters[k].start >= at - 0.001 { p.filters[k].start += d }
        list = d < 0 ? Self.squeezeCaptions(list, cut: at + d, at, limit: s.end) : list.map { c in
            guard c.start >= at - 0.001 else { return c }
            var c = c; c.start += d; c.end += d
            c.words = c.words.map { var w = $0; w.start += d; w.end += d; return w }
            return c
        }
        p.duration = max(0.1, p.duration + d)
        project = p
        cues = (list + held).sorted { $0.start < $1.start }
    }

    /// A voice (or sound) whose tail runs on past the cut `b` into the next video — a few seconds at most and less than
    /// what it has before the cut: a ripple edit there leaves it whole where it is, with its own shot, and its captions
    /// with it. A narration over several shots runs on for longer and is cut as before.
    static func tails(_ clips: [AudioClip], past b: Double) -> [AudioClip] {
        clips.filter { c in
            guard c.role != .music, let length = c.duration else { return false }
            let end = c.start + length
            return c.start < b - 0.001 && end > b + 0.02 && end - b <= 4 && end - b < b - c.start
        }
    }

    /// A shot's own sound: clips from its file, in sync with its picture (at its speed) and over it (not a voice
    /// unhooked by its pivot).
    static func own(_ clips: [AudioClip], of s: Shot) -> [AudioClip] {
        clips.filter { c in
            guard c.role != .music, !c.unlinked, c.src == s.src, let length = c.duration else { return false }
            return abs(c.speed - s.speed) < 0.001 && abs(c.source(at: s.start) - s.inPoint) < 0.05 && c.start < s.end && c.start + length > s.start
        }
    }

    /// The captions over those tails (by their middle), and the rest.
    static func split(_ cues: [Cue], over clips: [AudioClip]) -> (held: [Cue], rest: [Cue]) {
        let spans = clips.map { ($0.start, $0.start + ($0.duration ?? 0)) }
        func over(_ c: Cue) -> Bool { let m = (c.start + c.end) / 2; return spans.contains { m >= $0.0 && m < $0.1 } }
        return (cues.filter(over), cues.filter { !over($0) })
    }

    /// Sound clips around a ripple edit at `t`: clips after it slide by `d`, a clip across it is split there
    /// (shortening also cuts [t + d, t] out of it), except the ones in `holding`. Music is not touched.
    /// A clip put in on a cut (the «+» on a cut → «Видео»): it goes in whole, at most 5 s (a still for 2 s), and
    /// everything after the cut slides along by its length — shots, voice and sounds, captions, titles, scenes,
    /// filters; the music stays where it is, as in every other ripple edit. One step to undo.
    func insertClip(_ url: URL, after id: String) {
        guard let cutShot = project?.shots.first(where: { $0.id == id }) else { return }
        let at = cutShot.end
        Task {
            let still = Project.stillTypes.contains(url.pathExtension.lowercased())
            let seconds = still ? 2 : ((try? await AVURLAsset(url: url).load(.duration).seconds) ?? 2)
            let length = max(0.5, min(5, seconds))
            guard var p = project else { return }
            pushHistory()
            for k in p.shots.indices where p.shots[k].start >= at - 0.001 { p.shots[k].start += length; p.shots[k].end += length }
            let shot = Shot(id: Project.newID("s"), start: at, end: at + length, src: url.path,
                            label: url.deletingPathExtension().lastPathComponent)
            p.shots.append(shot)
            p.shots.sort { $0.start < $1.start }
            let tails = Self.tails(p.audio, past: at)
            let held = Set(Self.split(cues, over: tails).held.map(\.id))
            p.audio = Self.ripple(p.audio, at: at, by: length, holding: Set(tails.map(\.id)))
            for k in p.titles.indices where p.titles[k].start >= at - 0.001 { p.titles[k].start += length }
            for k in p.overlays.indices where p.overlays[k].start >= at - 0.001 { p.overlays[k].start += length }
            for k in p.layers.indices where p.layers[k].start >= at - 0.001 { p.layers[k].start += length; p.layers[k].end += length }
            for k in p.filters.indices where p.filters[k].start >= at - 0.001 { p.filters[k].start += length }
            cues = cues.map { c in
                guard c.start >= at - 0.001, !held.contains(c.id) else { return c }
                var c = c; c.start += length; c.end += length
                c.words = c.words.map { var w = $0; w.start += length; w.end += length; return w }
                return c
            }
            p.duration += length
            project = p
            focus = .shot(shot.id)
        }
    }

    /// Captions over a ripple trim that shortens a shot by [lo, hi): no word goes (words go only when they are
    /// deleted) — the ones spoken in the cut share the time left with the captions next to them, which just show
    /// faster, and what follows moves back by the cut's length. The squeeze takes in as few captions as give each
    /// word ~0.15 s, never past `limit`: the shot's other end (its start for a trimmed end, its end for a trimmed head).
    static func squeezeCaptions(_ cues: [Cue], cut lo: Double, _ hi: Double, limit: Double) -> [Cue] {
        let cut = hi - lo
        guard cut > 0.0005 else { return cues }
        let tail = limit <= lo + 0.0005
        let hit = cues.filter { $0.end > lo + 0.001 && $0.start < hi - 0.001 }
        // [a, b] becomes [a, b - cut]: a trimmed end keeps b at the cut's end, a trimmed head keeps a at its start
        var a = lo, b = hi
        if tail { a = max(limit, min(lo, hit.map(\.start).min() ?? lo)) } else { b = min(limit, max(hi, hit.map(\.end).max() ?? hi)) }
        func words(_ a: Double, _ b: Double) -> Int {
            cues.reduce(0) { n, c in
                n + (c.words.isEmpty ? (c.start < b - 0.001 && c.start >= a - 0.001 ? 1 : 0)
                                     : c.words.filter { $0.start >= a - 0.001 && $0.start < b - 0.001 }.count)
            }
        }
        let starts = cues.map(\.start).sorted(), ends = cues.map(\.end).sorted()
        while b - a - cut < 0.15 * Double(words(a, b)) {
            if tail {
                guard let earlier = starts.last(where: { $0 < a - 0.001 && $0 >= limit - 0.001 }) else { a = limit; break }
                a = earlier
            } else {
                guard let later = ends.first(where: { $0 > b + 0.001 && $0 <= limit + 0.001 }) else { b = limit; break }
                b = later
            }
        }
        let k = max(0, b - a - cut) / max(b - a, 0.001)
        func map(_ x: Double) -> Double { x <= a ? x : x >= b ? x - cut : a + (x - a) * k }
        return cues.map { c in
            var c = c
            c.start = map(c.start); c.end = map(c.end)
            c.words = c.words.map { var w = $0; w.start = map(w.start); w.end = map(w.end); return w }
            return c
        }
    }

    /// Captions over a ripple cut of [lo, hi): that stretch of sound is gone and what follows moves back by its length.
    /// The words spoken in it go; a caption across an edge keeps its words outside it and is cut short at the edge;
    /// a caption left with nothing goes.
    static func cutCaptions(_ cues: [Cue], from lo: Double, to hi: Double) -> [Cue] {
        let d = hi - lo
        return cues.compactMap { c in
            var c = c
            if c.start >= hi - 0.001 {                                   // after the cut: moves back
                c.start -= d; c.end -= d
                c.words = c.words.map { var w = $0; w.start -= d; w.end -= d; return w }
                return c
            }
            if c.end <= lo + 0.001 { return c }                         // before it
            if c.words.isEmpty {                                         // no word timings: what lies outside stays
                if c.start >= lo - 0.001 { if c.end <= hi + 0.001 { return nil }; c.start = lo }
                c.end = c.end > hi ? c.end - d : min(c.end, lo)
                return c
            }
            let count = c.words.count
            c.words = c.words.compactMap { w in
                var w = w
                if w.start >= hi - 0.001 { w.start -= d; w.end -= d; return w }
                if w.start < lo - 0.001 { w.end = w.end > hi ? w.end - d : min(w.end, lo); return w }
                return nil                                               // spoken in the cut
            }
            guard let first = c.words.first, let last = c.words.last else { return nil }
            if c.start >= lo - 0.001 { c.start = first.start }
            // it ends where its words do: past the cut only when it still has words there
            c.end = max(last.end, last.start >= lo - 0.001 && c.end > hi ? c.end - d : min(c.end, lo))
            if c.words.count != count { c.text = c.words.map(\.text).joined(separator: " ") }
            return c
        }
    }

    static func ripple(_ clips: [AudioClip], at t: Double, by d: Double, holding: Set<String> = []) -> [AudioClip] {
        var out: [AudioClip] = []
        let eps = 0.001
        for c in clips {
            if c.role == .music || holding.contains(c.id) { out.append(c); continue }
            if c.start >= t - eps { var m = c; m.start = max(0, c.start + d); out.append(m); continue }
            let end = c.duration.map { c.start + $0 } ?? .infinity
            let cut = d < 0 ? t + d : t
            if end <= cut + eps { out.append(c); continue }  // wholly before the edit
            var left = c
            left.duration = cut - c.start; left.fadeOut = 0
            if (left.duration ?? 0) > 0.05 { out.append(left) }
            if end > t + eps {
                var right = c
                right.id = Project.newID("a")
                right.inPoint = c.source(at: t)
                right.start = t + d
                right.duration = c.duration.map { $0 - (t - c.start) }
                right.fadeIn = 0
                out.append(right)
            }
        }
        return out
    }

    /// A shot dragged along the picture track to another place takes its stretch of the edit with it: the voice
    /// and sound effects under it, its captions (with their word timings), titles, scenes and filters that start
    /// on it. The shots between the old place and the new one move up (or back) with all of theirs. Sound is cut
    /// only where the stretches meet (three cuts at most); music, and voice unhooked by its pivot (with its captions),
    /// stay where they are. `target` is the index among
    /// the other shots that it goes in front of (their count = at the end). `videoOnly`: only the pictures change
    /// places — the voice, sounds, captions, titles, scenes and filters stay where they were.
    func moveShot(_ id: String, toIndex target: Int, videoOnly: Bool = false) {
        guard var p = project else { return }
        let order = p.shots.sorted { $0.start < $1.start }
        guard let i = order.firstIndex(where: { $0.id == id }) else { return }
        var others = order
        let s = others.remove(at: i)
        let to = max(0, min(others.count, target))
        guard to != i else { return }
        pushHistory()
        let a = s.start, b = s.end, length = s.duration
        let x = to < others.count ? others[to].start : (others.last.map { max($0.end, b) } ?? b)   // where it goes, old clock
        let later = x >= b
        let lo = later ? b : x, hi = later ? x : a
        let moved = later ? x - b : x - a, between = later ? -length : length
        /// How far what starts at `t` moves: with the shot, with the shots in between, or not at all.
        func delta(_ t: Double) -> Double? {
            if t >= a - 0.001, t < b - 0.001 { return moved }
            if t >= lo - 0.001, t < hi - 0.001 { return between }
            return nil
        }
        for k in p.shots.indices { if let d = delta(p.shots[k].start) { p.shots[k].start += d; p.shots[k].end += d } }
        p.shots.sort { $0.start < $1.start }
        guard !videoOnly else { project = p; focus = .shot(id); return }
        var audio = p.audio
        for t in [a, b, x] { audio = Self.cutSound(audio, at: t) }
        for k in audio.indices where audio[k].role != .music && !audio[k].unlinked { if let d = delta(audio[k].start) { audio[k].start += d } }
        p.audio = audio
        for k in p.titles.indices { if let d = delta(p.titles[k].start) { p.titles[k].start += d } }
        for k in p.overlays.indices { if let d = delta(p.overlays[k].start) { p.overlays[k].start += d } }
        for k in p.layers.indices { if let d = delta(p.layers[k].start) { p.layers[k].start += d; p.layers[k].end += d } }
        for k in p.filters.indices { if let d = delta(p.filters[k].start) { p.filters[k].start += d } }
        p.titles.sort { $0.start < $1.start }; p.overlays.sort { $0.start < $1.start }; p.filters.sort { $0.start < $1.start }
        let held = p.audio.filter { $0.role == .voice && $0.unlinked }.map { ($0.start, $0.start + ($0.duration ?? .infinity)) }
        let list = cues.map { c -> Cue in
            guard let d = delta(c.start), !held.contains(where: { c.start >= $0.0 - 0.001 && c.start < $0.1 }) else { return c }
            var c = c; c.start += d; c.end += d
            c.words = c.words.map { var w = $0; w.start += d; w.end += d; return w }
            return c
        }
        project = p
        cues = list.sorted { $0.start < $1.start }
        focus = .shot(id)
    }

    /// Voice and effect clips cut in two where `t` falls inside them (music and unhooked voice are left whole).
    static func cutSound(_ clips: [AudioClip], at t: Double) -> [AudioClip] {
        var out: [AudioClip] = []
        for c in clips {
            let end = c.duration.map { c.start + $0 } ?? .infinity
            guard c.role != .music, !c.unlinked, t > c.start + 0.01, t < end - 0.01 else { out.append(c); continue }
            var left = c, right = c
            left.duration = t - c.start; left.fadeOut = 0
            right.id = Project.newID("a"); right.start = t; right.inPoint = c.source(at: t)
            right.duration = c.duration.map { $0 - (t - c.start) }; right.fadeIn = 0
            out += [left, right]
        }
        return out
    }

    /// Cuts a shot at the playhead — or, when the playhead sits at its edge (a click on a shot puts it
    /// at the start), in the middle.
    func splitShotAtPlayhead(_ id: String) {
        guard let s = shot(id) else { return }
        let inside = currentTime > s.start + 0.25 && currentTime < s.end - 0.25
        splitShot(id, at: inside ? currentTime : (s.start + s.end) / 2)
    }

    /// Cuts a shot in two at `time`; the second half continues from the same footage.
    func splitShot(_ id: String, at time: Double) {
        guard var p = project else { return }
        if let i = p.layers.firstIndex(where: { $0.id == id }) {         // a video on the overlay track
            let v = p.layers[i]
            guard time > v.start + 0.2, time < v.end - 0.2 else { return }
            pushHistory()
            var second = v
            second.id = Project.newID("v")
            second.start = time
            second.inPoint = v.source(at: time)
            p.layers[i].end = time
            p.layers.insert(second, at: i + 1)
            project = p
            focus = .shot(second.id)
            return
        }
        guard let i = p.shots.firstIndex(where: { $0.id == id }) else { return }
        let s = p.shots[i]
        let cut = snapToGrid(time)
        guard cut > s.start + 0.2, cut < s.end - 0.2 else { return }
        pushHistory()
        var second = s
        second.id = Project.newID("s")
        second.start = cut
        second.inPoint = s.source(at: cut)
        second.zoom = s.zoom == .in ? .out : (s.zoom == .out ? .in : .none)
        p.shots[i].end = cut
        p.shots.insert(second, at: i + 1)
        project = p
        focus = .shot(second.id)
    }

    /// Deletes a shot. Default: the edit closes up — everything after slides back over it, and that stretch of
    /// voice and its captions goes too (as a ripple trim does). `keepSound`: only the picture goes — the shot before
    /// plays on over its place (the one after starts earlier, when it was the first), timing and sound stay.
    func deleteShot(_ id: String, keepSound: Bool = false) {
        guard var p = project, let i = p.shots.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        let s = p.shots.remove(at: i)
        p.transitions.removeAll { $0.after == id }
        var list = cues
        if keepSound {
            // the gap is filled with footage the neighbours really have — the shot before plays on, the one after
            // starts earlier — and only what is still missing is stretched. Never with the deleted footage itself:
            // the halves of a split clip run straight into it, so there the one after slides in from its own cut.
            let before = p.shots.indices.filter { p.shots[$0].end <= s.start + 0.001 }.max { p.shots[$0].end < p.shots[$1].end }
            let after = p.shots.indices.filter { p.shots[$0].start >= s.end - 0.001 }.min { p.shots[$0].start < p.shots[$1].start }
            /// `b`'s footage carries straight on from `a`'s (two pieces of one clip, cut apart).
            func continues(_ a: Shot, _ b: Shot) -> Bool { a.src == b.src && abs(a.inPoint + a.footage - b.inPoint) < 0.05 }
            let beforeFree = before.map { !continues(p.shots[$0], s) } ?? false
            let afterCarriesOn = after.map { continues(s, p.shots[$0]) } ?? false
            var gap = s.duration
            if let k = before, beforeFree, let length = footageLength(p.shots[k]) {
                let more = min(gap, max(0, length - (p.shots[k].inPoint + p.shots[k].footage)) / p.shots[k].speed)
                p.shots[k].end += more; gap -= more
            }
            if let k = after, gap > 0.001, !afterCarriesOn {
                let more = min(gap, p.shots[k].inPoint / p.shots[k].speed)
                p.shots[k].start -= more; p.shots[k].inPoint -= more * p.shots[k].speed; gap -= more
            }
            if gap > 0.001 {
                if let k = after, afterCarriesOn || !beforeFree { p.shots[k].start -= gap }   // slides in from its own cut
                else if let k = before { p.shots[k].end += gap }
            }
        } else {
            let t = s.end, d = -s.duration
            for k in p.shots.indices where p.shots[k].start >= t - 0.001 { p.shots[k].start += d; p.shots[k].end += d }
            let tails = Self.tails(p.audio, past: s.start)                      // the shot before's voice running on into it stays
            let (held, rest) = Self.split(list, over: tails)
            list = rest
            p.audio = Self.ripple(p.audio, at: t, by: d, holding: Set(tails.map(\.id)))
            for k in p.titles.indices where p.titles[k].start >= t - 0.001 { p.titles[k].start += d }
            for k in p.overlays.indices where p.overlays[k].start >= t - 0.001 { p.overlays[k].start += d }
            for k in p.layers.indices where p.layers[k].start >= t - 0.001 { p.layers[k].start += d; p.layers[k].end += d }
            for k in p.filters.indices where p.filters[k].start >= t - 0.001 { p.filters[k].start += d }
            list = Self.cutCaptions(list, from: s.start, to: t) + held   // its sound was cut out with the shot
            list.sort { $0.start < $1.start }
            p.duration = max(0.1, p.duration + d)
        }
        project = p
        cues = list
        shotTools = nil
        focus = .caption
    }

    /// How long a shot's file runs (nil for a still or when it can't be read).
    private func footageLength(_ shot: Shot) -> Double? {
        guard !Project.stillTypes.contains((shot.src as NSString).pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: Project.resolve(shot.src, relativeTo: projectURL))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var length: Double?
        Task.detached { length = try? await asset.load(.duration).seconds; done.signal() }
        done.wait()
        return length
    }

    /// Where a shot's file has picture up to (its video track's end, as the compositor plays it; nil for a still
    /// or a file that can't be read). Kept per file and its date: an edge drag asks on every step.
    private static var pictureEnds: [String: (date: Date?, end: Double?)] = [:]
    func pictureEnd(_ shot: Shot) -> Double? {
        guard !Project.stillTypes.contains((shot.src as NSString).pathExtension.lowercased()) else { return nil }
        let url = Project.resolve(shot.src, relativeTo: projectURL)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let known = Self.pictureEnds[url.path], known.date == date { return known.end }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var end: Double?
        Task.detached { end = try? await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).end.seconds; done.signal() }
        done.wait()
        Self.pictureEnds[url.path] = (date, end)
        return end
    }

    func replaceClip(_ id: String, with url: URL) {
        updateShot(id) {
            $0.src = url.path
            $0.label = url.deletingPathExtension().lastPathComponent
            $0.inPoint = 0
        }
    }

    // MARK: Moving things on the picture

    /// Where a caption, title or scene is moved to on the picture (stage px), nil = its own place.
    func offset(of piece: OverlayRenderer.Piece) -> CGPoint? {
        func point(_ x: Double?, _ y: Double?) -> CGPoint? { x == nil && y == nil ? nil : CGPoint(x: x ?? 0, y: y ?? 0) }
        switch piece {
        case .caption(let id): return cues.first { $0.chunkID == id }.flatMap { point($0.x, $0.y) }
        case .title(let id): return title(id).flatMap { point($0.x, $0.y) }
        case .overlay(let id): return overlay(id).flatMap { point($0.x, $0.y) }
        case .sticker(let id, let k): return stickerAt(id, k).map { CGPoint(x: $0.x, y: $0.y) }
        case .layer(let id): return shot(id)?.transform.flatMap { point($0.x, $0.y) }
        }
    }

    /// Moves a piece on the picture (nil = back to its own place).
    func setOffset(_ piece: OverlayRenderer.Piece, _ p: CGPoint?, undoable: Bool = true) {
        let x = p.map { Double(($0.x * 2).rounded() / 2) }, y = p.map { Double(($0.y * 2).rounded() / 2) }
        switch piece {
        case .caption(let id):
            guard let i = cues.firstIndex(where: { $0.chunkID == id }) else { return }
            if undoable { pushHistory() }
            cues[i].x = x; cues[i].y = y
        case .title(let id): updateTitle(id, undoable: undoable) { $0.x = x; $0.y = y }
        case .overlay(let id): updateOverlay(id, undoable: undoable) { $0.x = x; $0.y = y }
        case .layer(let id): updateCutout(id, undoable: undoable) { $0.transform = Self.placed($0.transform, x: x ?? 0, y: y ?? 0) }
        case .sticker(let id, let k):
            // a double click (nil) puts the emoji back above the title, upright
            updateSticker(id, k, undoable: undoable) { s in
                s.x = x ?? 0; s.y = y ?? -170
                if p == nil { s.rotation = 0 }
            }
        }
    }

    /// Selects what was grabbed on the picture.
    func select(_ piece: OverlayRenderer.Piece) {
        switch piece {
        case .caption(let id): if let cue = cues.first(where: { $0.chunkID == id }) { focus = .caption; selected = cue.id }
        case .title(let id): focus = .title(id); sticker = nil
        case .overlay(let id): focus = .overlay(id)
        case .layer(let id): focus = .shot(id)
        case .sticker(let id, let k): focus = .title(id); sticker = StickerRef(title: id, index: k)
        }
    }

    // MARK: Emoji on titles

    func stickerAt(_ id: String, _ k: Int) -> Sticker? {
        guard let list = title(id)?.stickers, list.indices.contains(k) else { return nil }
        return list[k]
    }

    /// Adds an emoji to the title, beside the last one (or above the title), and picks it.
    func addSticker(_ emoji: String, to id: String) {
        guard let item = title(id) else { return }
        let last = item.stickers?.last
        let new = Sticker(emoji: emoji, x: last.map { $0.x + $0.size * 0.9 } ?? 0, y: last?.y ?? -170, size: last?.size ?? 150)
        updateTitle(id) { $0.stickers = ($0.stickers ?? []) + [new] }
        focus = .title(id)
        sticker = StickerRef(title: id, index: (title(id)?.stickers?.count ?? 1) - 1)
    }

    func updateSticker(_ id: String, _ k: Int, undoable: Bool = true, _ change: (inout Sticker) -> Void) {
        guard stickerAt(id, k) != nil else { return }
        updateTitle(id, undoable: undoable) { t in
            guard var list = t.stickers, list.indices.contains(k) else { return }
            change(&list[k])
            list[k].size = min(900, max(30, list[k].size))
            list[k].rotation = (list[k].rotation + 540).truncatingRemainder(dividingBy: 360) - 180
            t.stickers = list
        }
    }

    func removeSticker(_ id: String, _ k: Int) {
        guard stickerAt(id, k) != nil else { return }
        updateTitle(id) { t in
            t.stickers?.remove(at: k)
            if t.stickers?.isEmpty == true { t.stickers = nil }
        }
        sticker = nil
    }

    /// The animated emoji set the project's titles play.
    var emojiPack: String { project?.emojiPack ?? AnimatedEmoji.defaultPack }

    func setEmojiPack(_ pack: String) {
        guard var p = project, pack != emojiPack else { return }
        pushHistory()
        p.emojiPack = pack == AnimatedEmoji.defaultPack ? nil : pack
        project = p
    }

    // MARK: Motion graphics

    var overlays: [OverlayClip] { project?.overlays ?? [] }

    func overlay(_ id: String) -> OverlayClip? { overlays.first { $0.id == id } }

    func updateOverlay(_ id: String, undoable: Bool = true, _ change: (inout OverlayClip) -> Void) {
        guard var p = project, let i = p.overlays.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushHistory() }
        change(&p.overlays[i])
        p.overlays[i].start = max(0, p.overlays[i].start)
        p.overlays.sort { $0.start < $1.start }
        project = p
    }

    /// «Заменить на…» on a scene (or a kit scene picked after «Заменить» in its window): another scene in its place —
    /// `src` and `label` change, its time and place on the picture stay, its length too unless `ownLength` (then the new
    /// scene's own). A scene with a `<name>_mask` folder beside it gets glass over that mask (the glass's blur and
    /// refraction kept if it had glass already), any other loses its glass.
    func replaceOverlay(_ id: String, with folder: URL, ownLength: Bool = false) {
        let mask = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + "_mask", directoryHint: .isDirectory)
        let glass = FileManager.default.fileExists(atPath: mask.path)
        updateOverlay(id) { o in
            o.src = folder.path
            o.label = folder.lastPathComponent
            o.glass = glass ? OverlayGlass(mask: mask.path, blur: o.glass?.blur ?? 30, refraction: o.glass?.refraction ?? 1) : nil
            if ownLength { o.duration = nil }
        }
    }

    /// What a scene can be swapped for: the folders beside it named like it up to the first «_» (`end_glass` → `end_seal`,
    /// `end_kinetic`…), not itself, not the glass masks (`…_mask`) and not `end_tapbelow` (Bogdan took it out of the
    /// choice, 11-10). Read again only when the folder changes.
    func overlayVariants(_ clip: OverlayClip) -> [URL] {
        let folder = Project.resolve(clip.src, relativeTo: projectURL)
        let name = folder.lastPathComponent, dir = folder.deletingLastPathComponent()
        guard let cut = name.firstIndex(of: "_") else { return [] }
        let prefix = String(name[...cut])
        let date = (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        let all: [String]
        if let known = Self.sceneFolders[dir.path], known.date == date { all = known.names } else {
            all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            Self.sceneFolders[dir.path] = (date, all)
        }
        return all.filter { $0.hasPrefix(prefix) && $0 != name && !$0.hasSuffix("_mask") && $0 != "end_tapbelow" && !$0.hasPrefix(".") }
            .map { dir.appending(path: $0, directoryHint: .isDirectory) }
    }
    nonisolated(unsafe) static var sceneFolders: [String: (date: Date?, names: [String])] = [:]

    /// A scene of the kit at the playhead.
    func addOverlay(_ scene: MotionLibrary.Scene) {
        ensureProject()
        guard var p = project else { return }
        pushHistory()
        let clip = OverlayClip(id: Project.newID("m"), src: scene.folder.path, start: max(0, min(currentTime, p.duration - scene.duration)),
                               label: scene.name)
        p.overlays.append(clip)
        p.overlays.sort { $0.start < $1.start }
        project = p
        focus = .overlay(clip.id)
        openDrawer(nil)                                  // the choice is made: its settings open
        overlayTools = clip.id
    }

    func deleteOverlay(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        p.overlays.removeAll { $0.id == id }
        project = p
        overlayTools = nil
        focus = .caption
    }

    // MARK: Sound

    func updateAudio(_ id: String, undoable: Bool = true, _ change: (inout AudioClip) -> Void) {
        guard var p = project, let i = p.audio.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushHistory() }
        change(&p.audio[i])
        p.audio[i].gain = max(0, p.audio[i].gain)
        project = p
    }

    func audioClip(_ id: String) -> AudioClip? { project?.audio.first { $0.id == id } }

    /// Moves a sound clip on the edit's clock; what it plays of its source stays the same.
    func moveAudio(_ id: String, to start: Double, undoable: Bool = true) {
        updateAudio(id, undoable: undoable) { $0.start = max(0, start) }
    }

    /// A sound clip's span on the edit's clock. Moving its start cuts off (or brings back) the head of its
    /// source — it can't begin before the source does.
    func trimAudio(_ id: String, from start: Double, to end: Double, undoable: Bool = true) {
        guard let c = audioClip(id) else { return }
        let s = max(0, c.start + max(-c.inPoint / c.speed, start - c.start))
        guard end - s >= 0.1 else { return }
        updateAudio(id, undoable: undoable) { $0.start = s; $0.inPoint = c.source(at: s); $0.duration = end - s }
    }

    /// S on a sound clip: two clips at `time`, the second going on with the same source where the first stops.
    func splitAudio(_ id: String, at time: Double) {
        guard var p = project, let i = p.audio.firstIndex(where: { $0.id == id }) else { return }
        let c = p.audio[i], offset = time - c.start
        guard offset > 0.05, c.duration.map({ offset < $0 - 0.05 }) ?? true else { return }
        pushHistory()
        var second = c
        second.id = Project.newID("a")
        second.start = time
        second.inPoint = c.source(at: time)
        second.duration = c.duration.map { $0 - offset }
        second.fadeIn = 0
        p.audio[i].duration = offset
        p.audio[i].fadeOut = 0                      // the fades stay at the outer ends
        p.audio.insert(second, at: i + 1)
        project = p
        focus = .audio(second.id)
    }

    func deleteAudio(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        p.audio.removeAll { $0.id == id }
        project = p
        audioTools = nil
        focus = .caption
    }

    /// A track dropped from Finder on the music track: it plays from `time` to the edit's end (or its own), at the
    /// level of the music it takes over — or 21 LU under the voice (gain 0.025) when there was none. Music that
    /// played on past `time` stops there.
    func addMusic(_ url: URL, at time: Double) {
        ensureProject()
        let file = url.resolvingSymlinksInPath()
        Task {
            let asset = AVURLAsset(url: file)
            guard let sound = try? await asset.loadTracks(withMediaType: .audio), !sound.isEmpty,
                  let length = try? await asset.load(.duration).seconds, length > 0.1, var p = project else { return }
            let start = max(0, min(time, p.duration - 0.5))
            pushHistory()
            let music = p.audio.filter { $0.role == .music }
            let before = music.last { $0.start <= start } ?? music.first
            p.audio.removeAll { $0.role == .music && $0.start >= start - 0.05 }
            for i in p.audio.indices where p.audio[i].role == .music && (p.audio[i].duration.map { p.audio[i].start + $0 > start } ?? true) {
                p.audio[i].duration = start - p.audio[i].start
                p.audio[i].fadeOut = 0
            }
            var clip = AudioClip(id: Project.newID("a"), role: .music, src: file.path, start: start,
                                 duration: min(length, p.duration - start), gain: before?.gain ?? 0.025, duck: before?.duck ?? false)
            clip.sidechain = before?.sidechain
            clip.label = file.deletingPathExtension().lastPathComponent
            p.audio.append(clip)
            project = p
            focus = .audio(clip.id)
        }
    }

    // MARK: Grid

    /// The beat grid, piece by piece: the music's own — its tempo found in its sound, the bars of each music clip
    /// moving with that clip — or, with no music (or before it is read), the one the project file sets.
    var gridSpans: [GridSpan] {
        guard let p = project else { return [] }
        let spans = p.gridSpans { MediaCache.shared.tempo($0, projectURL: projectURL) }
        if !spans.isEmpty { return spans }
        return p.grid.map { [GridSpan(from: -.infinity, to: .infinity, grid: $0)] } ?? []
    }

    /// The grid of the first music clip (its tempo is the one shown and saved in the file).
    var grid: BeatGrid? { gridSpans.first?.grid }

    func grid(at time: Double) -> BeatGrid? { gridSpans.first { time >= $0.from && time < $0.to }?.grid ?? grid }

    /// Cuts stick to the beat when the magnet is on and the project has a grid — only when they come within
    /// `tolerance` seconds of one, so a short drag between beats still moves (always rounding to the nearest
    /// beat made a small trim spring back, and shortening a shot looked broken).
    func snapToGrid(_ time: Double, tolerance: Double = 0) -> Double {
        guard magnet, tolerance > 0, let grid = grid(at: time) else { return time }
        let beat = grid.snap(time)
        return abs(beat - time) <= tolerance ? beat : time
    }

    // MARK: Splitting at the playhead

    /// S: cut at the playhead — the caption under it (the selected one only when none is), the shot, or the sound clip.
    func splitAtPlayhead() {
        switch focus {
        case .caption:
            let under = cues.first { currentTime > $0.start && currentTime < $0.end }
            if let id = under?.id ?? selected { splitCaption(id, at: currentTime); selected = id }
        case .shot(let id): splitShotAtPlayhead(id)
        case .audio(let id): splitAudio(id, at: currentTime)
        case .title, .overlay, .filter, .look, .transition: break
        }
    }
}
