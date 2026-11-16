import AppKit
import AVFoundation
import Combine
import SimbiaCore
import SwiftUI
import UniformTypeIdentifiers

// Two-way sync with a .simbia project file.
//
// The file is shared with Claude. Every edit made here is written back half a second after it
// settles; the file is checked twice a second, and a change made elsewhere (by Claude) is loaded
// in place — one undo step, so Command-Z puts the editor back the way it was.

extension UTType {
    /// Declared as an exported type in Info.plist by build-app.sh.
    static var simbiaProject: UTType {
        UTType(filenameExtension: Project.fileExtension) ?? UTType(exportedAs: "local.simbia.project", conformingTo: .json)
    }
}

/// Files handed to the app by Finder / `open` before the editor exists, and after.
@MainActor final class OpenRequests {
    static let shared = OpenRequests()
    private var pending: [URL] = []
    private var handler: ((URL) -> Void)?

    func open(_ url: URL) {
        if let handler { handler(url) } else { pending.append(url) }
    }

    func attach(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        pending.forEach(handler)
        pending.removeAll()
    }
}

/// What the sync indicator shows: the last revision written or read, and whether Claude wrote it.
struct SyncStatus: Equatable {
    var revision: Int
    var byClaude: Bool
    var at: Date
    /// Claude's change was just loaded into the open editor — the pill says so for a few seconds.
    var announce = false
}

/// Bookkeeping for the sync that the views never look at.
@MainActor final class ProjectSyncState {
    /// The footage library's moments for the gallery, made once per index.
    var moments: [FootageIndex.Moment]?
    /// The bytes last written or read — a file change matching them is our own save.
    var lastData: Data?
    var lastModified: Date?
    /// The project as last saved or loaded, with revision and author blanked: what "changed" means.
    var lastState: Project?
    var lastRevision = 0
    /// Set while a loaded project is being put into the editor, so that does not count as an edit.
    var applying = false
    var subscriptions: Set<AnyCancellable> = []
    var timer: Timer?
    /// Frames drawn when the preview was last seen getting new ones, and since when it hasn't.
    var stall: (frames: Int, since: Date) = (0, Date())
    var buildTask: Task<Void, Never>?
    /// The latest seek, and whether it is still on its way: until it lands the player reports where it was
    /// (a freshly rebuilt item: 0), and the playhead must not jump there meanwhile.
    var seeks = 0
    var seekPending = false
    /// The project as the journal last described it, and the wait before the next description (edits a few
    /// seconds apart are one entry).
    var journalBase: Project?
    var journalTask: Task<Void, Never>?
    /// The picture/sound part of the project the player item was built from.
    var builtFrom: Project?
    var built: BuiltComposition?
    /// A level edit's new levels on their way to the playing taps (`Job.remix`), and whether a whole new player item
    /// is being built.
    var mixTask: Task<Void, Never>?
    var rebuilding = false
    var debug: DebugBridge?
    /// The overlay engine for the current captions, titles and style; dropped whenever they change.
    var renderer: OverlayRenderer?
    /// While a shot edge or title is being dragged the player is not rebuilt; the drop does it.
    var holdRebuild = false
    /// The overlay-track video whose matte the preview shows instead of the picture («Показать маску»).
    var matteLayer: String?
    /// The voice's loudness for the checks and pause removal, and which voice clips it was worked out from.
    var voice: VoiceActivity?
    var voiceKey: String?
    /// A look for cuts inside the shots' clips is under way (and another is wanted once it is done).
    var scanningCuts = false
    var scanCutsAgain = false
}

/// The classic look settings, carried in the project for the "legacy" caption style.
private struct LegacyLook: Codable {
    var look: Look
    var preset: String
    var animation: String
    var outro: String
    var split: String
}

extension LegacyLook {
    /// Reads a stored block, taking anything it lacks (an older app, a hand-written file) from the defaults.
    init?(_ value: JSONValue) {
        guard case .object(var stored) = value,
              case .object(let defaults)? = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Look())) else { return nil }
        var look = defaults
        if case .object(let own)? = stored["look"] { look.merge(own) { _, new in new } }
        stored["look"] = .object(look)
        let fallback: [String: JSONValue] = ["preset": .string(StylePreset.catalog[0].id), "animation": .string(Anim.pop.rawValue),
                                             "outro": .string(Outro.fade.rawValue), "split": .string(CaptionSplit.word.rawValue)]
        stored.merge(fallback) { own, _ in own }
        guard let data = try? JSONEncoder().encode(JSONValue.object(stored)),
              let decoded = try? JSONDecoder().decode(LegacyLook.self, from: data) else { return nil }
        self = decoded
    }
}

extension Cue {
    init(chunk: Chunk) {
        // The editor splits text at spaces and keeps word timings only while the counts match, so a
        // word written with a space inside ("7 Reasons") becomes several sharing its time, and an
        // empty one is dropped — otherwise every save would rewrite the timings.
        var words: [Word] = []
        for w in chunk.words {
            let parts = w.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let step = (w.end - w.start) / Double(max(parts.count, 1))
            for (k, part) in parts.enumerated() {
                words.append(Word(start: w.start + step * Double(k), end: parts.count == 1 ? w.end : w.start + step * Double(k + 1),
                                  text: part, accent: w.accent, voice: parts.count == 1 ? w.voice : nil,
                                  br: k == parts.count - 1 ? w.br : nil))
            }
        }
        self.init(start: chunk.start, end: chunk.end, text: words.map(\.text).joined(separator: " "), words: words)
        key = chunk.id
        paragraph = chunk.paragraph
        accent = chunk.emphasis
        x = chunk.x
        y = chunk.y
    }

    /// Stable id for the project file: the chunk's own, or one derived from the cue's UUID.
    var chunkID: String { key ?? "c" + id.uuidString.prefix(8).lowercased() }
}

extension Project {
    /// What the player item depends on. Captions and title wording are drawn live over the player,
    /// so changing them must not rebuild the composition.
    var pictureKey: Project {
        var p = self
        p.name = ""; p.revision = 0; p.savedBy = ""
        p.captions = CaptionTrack()
        p.grid = nil                           // the bars follow the music; they draw nothing on the picture
        p.colourReference = nil
        // marks don't change the picture; colour, the key and the transform go to the built preview live
        // (Job.pushColour), no rebuild
        p.shots = shots.map { var s = $0; s.issues = []; s.note = nil; s.grade = nil; s.chromaKey = nil; s.transform = nil; return s }
        p.layers = layers.map { var s = $0; s.issues = []; s.note = nil; s.grade = nil; s.chromaKey = nil; s.transform = nil; return s }
        // only motion blur switching on or off changes what the build carries (the late copy of the footage)
        p.look = wantsPreviousFrame ? ColourLook() : nil
        p.filters = []
        p.audio = audio.map { var a = $0; a.label = nil; a.issues = []; a.note = nil; return a }   // marks on sound don't change it
        p.titles = titles.map { TitleItem(id: "", style: $0.style, text: "", start: $0.start, duration: $0.duration, blur: $0.blur) }
        return p
    }

    /// The picture key with every level of the sound set aside — gain, fades and their arcs, ducking: equal for two
    /// projects whose preview differs only in its mix, whose new levels then go to the playing taps (`Job.remix`).
    var mixFree: Project {
        var p = pictureKey
        p.audio = p.audio.map { var a = $0; a.gain = 1; a.fadeIn = 0; a.fadeOut = 0; a.fadeInCurve = 0; a.fadeOutCurve = 0; a.duck = false; a.sidechain = nil; return a }
        return p
    }

    /// Equal for the purpose of "did anything change": revision and author do not count.
    var comparable: Project {
        var p = normalized()
        p.revision = 0; p.savedBy = ""
        return p
    }
}

extension Job {
    var displayName: String {
        project?.name ?? video?.deletingPathExtension().lastPathComponent ?? s.untitled
    }

    // MARK: Start

    func startProjectSync() {
        OpenRequests.shared.attach { [weak self] url in self?.open(url) }

        let edits: [AnyPublisher<Void, Never>] = [
            $cues.map { _ in () }.eraseToAnyPublisher(),
            $look.map { _ in () }.eraseToAnyPublisher(),
            $captionStyle.map { _ in () }.eraseToAnyPublisher(),
            $project.map { _ in () }.eraseToAnyPublisher(),
            $animation.map { _ in () }.eraseToAnyPublisher(),
            $outro.map { _ in () }.eraseToAnyPublisher(),
            $split.map { _ in () }.eraseToAnyPublisher(),
            $stylePreset.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(edits)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { _ = self?.saveIfChanged() } }
            .store(in: &sync.subscriptions)

        Publishers.MergeMany([$cues.map { _ in () }.eraseToAnyPublisher(), $captionStyle.map { _ in () }.eraseToAnyPublisher(),
                              $project.map { _ in () }.eraseToAnyPublisher()])
            .sink { [weak self] in MainActor.assumeIsolated { self?.sync.renderer = nil } }
            .store(in: &sync.subscriptions)

        Publishers.MergeMany([clock.ticks.map { _ in () }.eraseToAnyPublisher(), $cues.map { _ in () }.eraseToAnyPublisher()])
            .receive(on: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.trackPlayingCue() } }
            .store(in: &sync.subscriptions)

        $project
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildIfPictureChanged() } }
            .store(in: &sync.subscriptions)

        // the checks follow the edit, and the voice they listen to when its clips change
        Publishers.MergeMany([$cues.map { _ in () }.eraseToAnyPublisher(), $captionStyle.map { _ in () }.eraseToAnyPublisher(),
                              $project.map { _ in () }.eraseToAnyPublisher(), $glossary.map { _ in () }.eraseToAnyPublisher()])
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.loadVoice(); self?.loadCuts(); self?.refreshIssues() } }
            .store(in: &sync.subscriptions)

        sync.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFile(); self?.watchPreview() }
        }
        // switching to another app saves too, so nothing waits on the timer while the app is in the background
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { _ = self?.saveIfChanged() } }
            .store(in: &sync.subscriptions)
        // an edit made in the last moment before quitting is still waiting for the autosave
        // (AppDelegate ends text editing first, so a draft in a field is committed by then)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { _ = self?.saveIfChanged(); self?.flushJournal() } }
            .store(in: &sync.subscriptions)
        sync.debug = DebugBridge(job: self)
    }

    // MARK: Open / close

    func openProject(_ url: URL) {
        guard !busy else { show(s.waitForCurrent, isError: true); return }
        // Claude opens its projects with `open`: the project already in the editor just takes the new file,
        // as one undo step, without losing the history, the playhead or the selection
        if url.standardizedFileURL == projectURL?.standardizedFileURL {
            saveIfChanged()
            checkFile()
            return
        }
        saveIfChanged()                        // the open project's last edit, before it is replaced
        flushJournal()
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode(Project.self, from: data)
            appendLog("Opened project: \(url.path)")
            rememberRecent(url)
            player.pause()
            video = nil
            projectURL = url
            if let w = Workspace.find(near: url) { useWorkspace(w) }
            sync.builtFrom = nil
            adopt(loaded, data: data, url: url)
            sync.journalBase = document()
            resetHistory()
            selected = cues.first?.id
            currentTime = 0
            fitTimeline()
            editorReady = true
            clipsOpen = false
            show(loaded.shots.isEmpty ? t("\(loaded.name): ещё не собран — список задач в «Проектах»", "\(loaded.name): not built yet — its list is in Projects", "\(loaded.name) : pas encore monté — sa liste est dans Projets")
                 : fill(s.projectOpened, loaded.name), isError: false)
        } catch let error as DecodingError {
            show("\(url.lastPathComponent): \(error)", isError: true)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    // MARK: Projects menu

    /// The last projects opened, newest first (kept between launches).
    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func rememberRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        paths.removeAll { $0 == url.standardizedFileURL.path }
        paths.insert(url.standardizedFileURL.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: "recentProjects")
        objectWillChange.send()
    }

    /// The other projects next to the open one (the same folder: VD 2, VD 6, …).
    var projectsInFolder: [URL] {
        guard let folder = projectURL?.deletingLastPathComponent(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.lowercased().hasSuffix("." + Project.fileExtension) && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appending(path: $0) }
    }

    func projectPicker() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.simbiaProject]
        if let projectURL { panel.directoryURL = projectURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    func closeProject() {
        saveIfChanged()
        sync.buildTask?.cancel()
        project = nil
        projectURL = nil
        syncStatus = nil
        focus = .caption
        captionStyle = "legacy"
        sync.lastData = nil; sync.lastModified = nil; sync.lastState = nil; sync.builtFrom = nil; sync.built = nil
    }

    /// Puts a project into the editor: the captions become cues, everything else stays in `project`.
    /// A reload of the same file keeps each caption's identity, so the selection survives Claude's edits.
    /// A change worked out on the whole project — the checks' fixes, pauses taken out — as one undo step.
    func replaceDocument(_ doc: Project) {
        pushHistory()
        put(doc, keepingIdentity: true)
        refreshIssues()
    }

    func put(_ loaded: Project, keepingIdentity: Bool = false) {
        sync.applying = true
        defer { DispatchQueue.main.async { MainActor.assumeIsolated { self.sync.applying = false } } }
        var rest = loaded
        rest.captions.chunks = []
        // a file without a length takes it from what is in it
        if rest.duration <= 0 {
            rest.duration = max(loaded.shots.map(\.end).max() ?? 0, loaded.captions.chunks.map(\.end).max() ?? 0,
                                loaded.titles.map(\.end).max() ?? 0)
        }
        project = rest
        captionStyle = loaded.captions.style
        if let legacy = loaded.captions.legacy { adoptLegacy(legacy) }
        let known = keepingIdentity ? Dictionary(cues.map { ($0.chunkID, $0.id) }, uniquingKeysWith: { first, _ in first }) : [:]
        var used = Set<Cue.ID>()
        cues = loaded.captions.chunks.map { chunk in
            var cue = Cue(chunk: chunk)
            if let id = known[chunk.id], used.insert(id).inserted { cue.id = id }
            return cue
        }
        duration = max(rest.duration, 0.1)
        videoSize = CGSize(width: loaded.canvas.width, height: loaded.canvas.height)
        keepSelectionValid()
    }

    /// A file read into the editor. What counts as unchanged is the editor's own version of it: the
    /// editor tidies some things (word spacing, order, a missing length), and that alone is no reason
    /// to write the file back.
    private func adopt(_ loaded: Project, data: Data, url: URL, keepingIdentity: Bool = false) {
        put(loaded, keepingIdentity: keepingIdentity)
        remember(data: data, project: loaded, url: url)
        sync.lastState = document().comparable
    }

    private func remember(data: Data, project: Project, url: URL) {
        sync.lastData = data
        sync.lastModified = modified(url)
        sync.lastState = project.comparable
        sync.lastRevision = project.revision
        syncStatus = SyncStatus(revision: project.revision, byClaude: project.savedBy != "app", at: Date())
    }

    /// Bogdan's edits since the journal last looked, as one entry.
    func flushJournal() {
        sync.journalTask?.cancel()
        guard let base = sync.journalBase, project != nil else { return }
        let now = document()
        journal(now.changes(from: base), by: "app", revision: sync.lastRevision)
        sync.journalBase = now
    }

    private func journal(_ changes: [String], by: String, revision: Int) {
        guard let url = projectURL, !changes.isEmpty else { return }
        let shown = changes.count > 14 ? Array(changes.prefix(13)) + [t("и ещё \(changes.count - 13)", "and \(changes.count - 13) more", "et \(changes.count - 13) de plus")] : changes
        Journal.append(JournalEntry(project: url.lastPathComponent, revision: revision, by: by, changes: shown), inFolder: url.deletingLastPathComponent())
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Draws what the preview shows over the video: built from the editor's state on first use.
    var overlayRenderer: OverlayRenderer {
        if let renderer = sync.renderer { return renderer }
        let renderer = OverlayRenderer(project: document(), projectURL: projectURL)
        sync.renderer = renderer
        return renderer
    }

    // MARK: Editor -> file

    /// The editor's state as a project file.
    func document() -> Project {
        var doc = project ?? Project()
        doc.captions.style = captionStyle
        doc.captions.chunks = orderedCues.map { cue in
            var chunk = Chunk(id: cue.chunkID, start: cue.start, end: cue.end,
                              words: timedWords(of: cue).map { w in
                                  var c = ChunkWord(text: w.text, start: w.start, end: w.end, accent: w.accent, voice: w.voice)
                                  c.br = w.br
                                  return c
                              },
                              paragraph: cue.paragraph, emphasis: cue.accent)
            chunk.x = cue.x
            chunk.y = cue.y
            return chunk
        }
        doc.captions.legacy = captionStyle == "legacy" ? legacyValue() : nil
        if doc.duration <= 0 { doc.duration = duration }
        return doc
    }

    /// Writes the editor's state if it differs from the file. Never over a file Claude changed since it
    /// was last read or written here: that is loaded instead (the edit made here stays one ⌘Z away).
    /// False when the file could not be brought up to date.
    @discardableResult func saveIfChanged() -> Bool {
        guard let url = projectURL, project != nil, !sync.applying, editorReady else { return projectURL == nil }
        var doc = document()
        guard doc.comparable != sync.lastState else { return true }
        if let stamp = modified(url), stamp != sync.lastModified, let data = try? Data(contentsOf: url), data != sync.lastData {
            checkFile()
            return false
        }
        doc.revision = sync.lastRevision + 1
        doc.savedBy = "app"
        do {
            let data = try doc.encoded()
            try data.write(to: url, options: .atomic)
            remember(data: data, project: doc, url: url)
            sync.journalTask?.cancel()
            sync.journalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.flushJournal()
            }
            return true
        } catch {
            show(fill(s.projectSaveFailed, error.localizedDescription), isError: true)
            return false
        }
    }

    /// Turns what is open into a project file — a transcribed video becomes a one-shot edit.
    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.simbiaProject]
        panel.nameFieldStringValue = displayName + "." + Project.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ensureProject()
        projectURL = url
        sync.lastState = nil; sync.lastData = nil; sync.lastModified = modified(url)
        if saveIfChanged() { show(fill(s.savedTo, url.lastPathComponent), isError: false) }
    }

    /// A transcribed video gets its project file at once, so nothing done to it is lost on quitting:
    /// Application Support/Simbia Captions/Projects (it shows under Projects › Recent). Opening the
    /// same video again continues it.
    func autosaveVideoProject() {
        guard projectURL == nil, video != nil else { return }
        ensureProject()
        guard let video else { return }
        let url = Self.autosaveURL(for: video, in: workspace)
        projectURL = url
        sync.lastState = nil; sync.lastData = nil; sync.lastModified = nil
        if saveIfChanged() {
            rememberRecent(url)
            appendLog("Autosaving \(video.lastPathComponent) to \(url.path)")
        }
    }

    /// Where a video's own project is kept: in a workspace, its projects folder under the video's name; outside one,
    /// Application Support, its name plus a short checksum of its path so two videos with the same name do not share one.
    static func autosaveURL(for video: URL, in workspace: Workspace? = nil) -> URL {
        if let workspace {
            try? FileManager.default.createDirectory(at: workspace.projects, withIntermediateDirectories: true)
            return workspace.projects.appending(path: video.deletingPathExtension().lastPathComponent + "." + Project.fileExtension)
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Simbia Captions/Projects", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hash: UInt32 = 2_166_136_261                                     // FNV-1a: the same on every launch
        for byte in video.standardizedFileURL.path.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return folder.appending(path: "\(video.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 16)).\(Project.fileExtension)")
    }

    /// A transcribed video becomes a one-shot edit in memory — what titles and shots need.
    func ensureProject() {
        guard project == nil, let video else { return }
        var p = Project()
        p.name = video.deletingPathExtension().lastPathComponent
        p.canvas.width = Int(videoSize.width.rounded())
        p.canvas.height = Int(videoSize.height.rounded())
        p.duration = duration
        p.shots = [Shot(id: "s1", start: 0, end: duration, src: video.path, label: video.lastPathComponent)]
        p.audio = [AudioClip(id: "a1", role: .voice, src: video.path)]
        sync.builtFrom = p.pictureKey          // the player already shows this video as it is
        project = p
    }

    // MARK: Export

    /// The finished video from the native engine — exactly what the preview shows. Classic captions are
    /// burned in afterwards by the libass pass, over the rendered picture.
    func exportProject() {
        guard !cues.isEmpty || !titles.isEmpty else { show(s.needVideoAndCues, isError: true); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = displayName + ".mp4"
        if let projectURL { panel.directoryURL = projectURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let doc = document()
        let base = projectURL
        let legacy = captionStyle == "legacy"
        work { [self] in
            status = t("Экспорт: картинка, субтитры, звук…", "Exporting: picture, captions, sound…", "Export : image, sous-titres, son…")
            progress = 0
            let target = legacy ? temp.appending(path: "native.mp4") : out
            if legacy { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) }
            try await resolveTools()
            var settings = Exporter.Settings()
            settings.ffmpeg = ffmpeg
            try await Exporter.export(doc, projectURL: base, to: target, settings: settings) { [weak self] p in
                Task { @MainActor in self?.progress = Int(p * (legacy ? 60 : 100)) }
            }
            if legacy {
                try await burn(to: out, from: target)
                try? FileManager.default.removeItem(at: target)
            }
            appendLog("Exported \(out.path)")
            status = fill(s.savedTo, out.lastPathComponent)
        }
    }

    // MARK: File -> editor

    /// A change on disk that we did not write is Claude's: load it as one undoable step.
    func checkFile() {
        guard let url = projectURL, !busy, !textEditing,
              let stamp = modified(url), stamp != sync.lastModified,
              let data = try? Data(contentsOf: url) else { return }
        guard data != sync.lastData else { sync.lastModified = stamp; return }
        // A half-written or broken file: leave the stamp alone and look again on the next tick.
        guard let loaded = try? JSONDecoder().decode(Project.self, from: data) else { return }
        sync.lastModified = stamp
        guard loaded.comparable != sync.lastState else { sync.lastData = data; sync.lastRevision = loaded.revision; return }
        flushJournal()
        let before = document()
        pushHistory()
        adopt(loaded, data: data, url: url, keepingIdentity: true)
        journal(document().changes(from: before), by: loaded.savedBy == "app" ? "app" : "claude", revision: loaded.revision)
        sync.journalBase = document()
        syncStatus?.announce = true
        appendLog("Project changed on disk (revision \(loaded.revision) by \(loaded.savedBy)) — reloaded")
        show(s.projectUpdated, isError: false)
    }

    // MARK: Player

    /// Playing, yet no new picture for two seconds (the compositor stalled): written to the log with the player's
    /// state, and the frame asked for again with a seek to where the playhead is.
    func watchPreview() {
        let drawn = SimbiaCompositor.framesDrawn
        guard isPlaying, player.timeControlStatus == .playing, drawn == sync.stall.frames else { sync.stall = (drawn, Date()); return }
        guard Date().timeIntervalSince(sync.stall.since) > 2 else { return }
        let item = player.currentItem
        appendLog(String(format: "Preview stalled at %.2f s: no new frames for 2 s (item %@, error %@) — asked again", currentTime,
                         item?.status == .readyToPlay ? "ready" : item?.status == .failed ? "failed" : "unknown",
                         item?.error?.localizedDescription ?? "-"))
        sync.stall = (drawn, Date())
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func rebuildIfPictureChanged() {
        pushColour()
        guard let project, !sync.holdRebuild else { return }
        let key = project.pictureKey
        guard key != sync.builtFrom else { return }
        // only the sound's levels changed (a fade, its arc, the gain, ducking): the taps of the item that is playing
        // take the new levels — a new item meant a pause and a restart, a click each
        let levelsOnly = sync.builtFrom.map { $0.mixFree == key.mixFree } ?? false
        sync.builtFrom = key
        if levelsOnly, !sync.rebuilding, !(sync.built?.taps.isEmpty ?? true), player.currentItem != nil { remix(project); return }
        rebuildComposition()
    }

    /// A level edit: the sound's new levels worked out (a build of the edit that is never played) and handed to the taps
    /// of the item that plays (`LevelTap.retarget`) — nothing restarts, each level glides to its new value in 20 ms.
    func remix(_ project: Project) {
        let url = projectURL, started = Date()
        sync.mixTask?.cancel()
        sync.mixTask = Task { [weak self] in
            guard let fresh = try? await project.composition(projectURL: url, overlay: false, live: true), let self, !Task.isCancelled,
                  let taps = self.sync.built?.taps else { return }
            guard Set(fresh.taps.keys) == Set(taps.keys) else { self.rebuildComposition(); return }
            for (id, tap) in fresh.taps { taps[id]?.retarget(tap.levels) }
            self.appendLog(String(format: "Levels updated in %.2f s (%@)", Date().timeIntervalSince(started), self.isPlaying ? "playing" : "paused"))
        }
    }

    /// Colour changes reach the preview without a rebuild: the built composition takes the project's grades
    /// and look, and the frame on screen is drawn again.
    func pushColour() {
        guard var project, let context = sync.built?.context else { return }
        if colourCompare {
            project.look = nil
            project.shots = project.shots.map { var s = $0; s.grade = nil; return s }
            project.layers = project.layers.map { var s = $0; s.grade = nil; return s }
        }
        guard context.setColour(of: project) else { return }
        redrawFrame()
        measureKeys(context)
    }

    /// A keyed video's key colour is measured once per clip in the background; the paused picture is drawn again with it.
    func measureKeys(_ context: RenderContext) {
        Task { [weak self] in
            guard await context.prepareKeys(), let self, self.sync.built?.context === context else { return }
            self.redrawFrame()
        }
    }

    /// «Показать маску»: the preview shows a video's matte, white on black, instead of the picture (nil = the picture).
    func showMatte(_ id: String?) {
        sync.matteLayer = id
        guard let context = sync.built?.context, context.showMatte(id) else { return }
        redrawFrame()
    }

    /// The paused picture is drawn again by the compositor (a fresh copy of the video composition makes the
    /// player ask for the current frame anew).
    func redrawFrame() {
        guard let item = player.currentItem, let video = item.videoComposition?.mutableCopy() as? AVVideoComposition else { return }
        item.videoComposition = video
        if !isPlaying { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    func rebuildComposition() {
        guard let project else { return }
        guard !project.shots.isEmpty else { player.replaceCurrentItem(with: nil); return }   // a card not built yet
        let url = projectURL
        sync.buildTask?.cancel()
        sync.mixTask?.cancel()
        sync.rebuilding = true
        let started = Date()
        sync.buildTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.sync.rebuilding = false } }
            do {
                let built = try await project.composition(projectURL: url, overlay: false, live: true)
                guard let self, !Task.isCancelled else { return }
                self.appendLog(String(format: "Preview rebuilt in %.2f s", Date().timeIntervalSince(started)))
                // where the playhead is now — playback went on while the sound was being analysed
                let playing = self.isPlaying, time = self.currentTime
                self.sync.built = built
                built.context.showMatte(self.sync.matteLayer)
                // the blur across cuts is measured in the background (frames don't wait for it); kept across rebuilds
                Task.detached(priority: .utility) { await built.context.prepareEdges() }
                self.measureKeys(built.context)
                if playing { self.player.pause() }         // the new item would play from 0 until the seek lands
                self.player.replaceCurrentItem(with: built.playerItem())
                self.seek(time, thenPlay: playing)
                if !built.missing.isEmpty {
                    let names = built.missing.map { ($0 as NSString).lastPathComponent }
                    self.show(self.t("Не найдены файлы (показаны чёрным): ", "Files not found (shown as black): ", "Fichiers introuvables (affichés en noir) : ")
                              + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : ""), isError: true)
                }
            } catch {
                self?.show(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Legacy look

    private func legacyValue() -> JSONValue? {
        let value = LegacyLook(look: look, preset: stylePreset, animation: animation.rawValue,
                               outro: outro.rawValue, split: split.rawValue)
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func adoptLegacy(_ value: JSONValue) {
        guard let legacy = LegacyLook(value) else { return }
        look = legacy.look
        stylePreset = legacy.preset
        animation = Anim(rawValue: legacy.animation) ?? animation
        outro = Outro(rawValue: legacy.outro) ?? outro
        split = CaptionSplit(rawValue: legacy.split) ?? split
    }
}

extension TextAlign: Codable {}
