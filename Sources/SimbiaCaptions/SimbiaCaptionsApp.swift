import AppKit
import AVFoundation
import Combine
import SimbiaCore
import SwiftUI
import UniformTypeIdentifiers

@main struct SimbiaCaptionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One project, one Job. Work/ and captions.ass are fixed paths shared by the whole app,
    /// so a second window would wipe them out from under a running export — hence no New Window.
    @StateObject private var job = Job()

    var body: some Scene {
        // A single window: with a WindowGroup, every double-click on a project while the app was open
        // added one more window showing the same editor.
        Window("Simbia Captions", id: "editor") { EditorView(job: job).frame(minWidth: 1180, minHeight: 780) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1560, height: 980)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(job.s.openVideo) { job.videoPicker() }
                        .keyboardShortcut("o", modifiers: .command)
                        .disabled(job.busy)
                    Button(job.s.importSRT) { job.srtPicker() }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(job.busy || job.video == nil)
                }
                CommandGroup(after: .saveItem) {
                    Button(job.s.saveProjectAs) { job.saveProjectAs() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(!job.editorReady || job.busy)
                    Button(job.s.saveSRT) { job.saveSRT() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(job.cues.isEmpty)
                    Button(job.s.exportVideo) { job.export() }
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(!job.canExport || job.busy)
                }
                // One window, one project: another project replaces this one, picked here
                CommandMenu(job.t("Проекты", "Projects", "Projets")) {
                    Button(job.t("Открыть проект…", "Open Project…", "Ouvrir un projet…")) { job.projectPicker() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                        .disabled(job.busy)
                    // sections bring their own separators
                    let folder = job.projectsInFolder
                    if !folder.isEmpty {
                        Section(job.t("В этой папке", "In this folder", "Dans ce dossier")) {
                            ForEach(folder, id: \.self) { url in projectItem(url) }
                        }
                    }
                    let here = Set(folder.map(\.standardizedFileURL.path))
                    let recent = job.recentProjects.filter { !here.contains($0.standardizedFileURL.path) }
                    if !recent.isEmpty {
                        Section(job.t("Недавние", "Recent", "Récents")) {
                            ForEach(recent, id: \.self) { url in projectItem(url) }
                        }
                    }
                    if let url = job.projectURL {
                        Divider()
                        Button(job.t("Показать проект в Finder", "Show Project in Finder", "Afficher le projet dans le Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                CommandMenu(job.s.language) {
                    Picker(job.s.language, selection: Binding(get: { job.languageChoice }, set: { job.languageChoice = $0 })) {
                        Text(job.t("Как в системе", "Same as the Mac", "Comme le Mac") + " · " + AppLanguage.system.title).tag(AppLanguage?.none)
                        Divider()
                        ForEach(AppLanguage.allCases) { option in Text(option.title).tag(AppLanguage?.some(option)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                CommandGroup(replacing: .undoRedo) {
                    Button(job.s.undo) { job.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!job.canUndo || job.textEditing)
                    Button(job.s.redo) { job.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!job.canRedo || job.textEditing)
                    Divider()
                    Button(job.t("Выровнять все заголовки по выбранному", "Align All Titles to the Selected One", "Aligner tous les titres sur le titre sélectionné")) {
                        if let id = job.titleToAlignTo { job.alignTitles(to: id) }
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(job.titleToAlignTo == nil || job.textEditing)
                }
            }
    }

    /// A project in the Projects menu: ticked when it is the one open, picked to open it in this window.
    private func projectItem(_ url: URL) -> some View {
        Toggle(url.deletingPathExtension().lastPathComponent,
               isOn: Binding(get: { job.projectURL?.standardizedFileURL == url.standardizedFileURL },
                             set: { if $0 { job.open(url) } }))
            .disabled(job.busy)
    }
}

func clearWork() {
    let work = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "Work", directoryHint: .isDirectory)
    guard let files = try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) else { return }
    for file in files { try? FileManager.default.removeItem(at: file) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI focuses the first text field in the window; a stray keystroke would then
    /// overwrite a colour value before the user has clicked anything.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.windows.forEach { $0.makeFirstResponder(nil) } }
    }

    /// A .simbia double-clicked in Finder or passed to `open` — Claude opens its projects this way.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(OpenRequests.shared.open) }
    }

    /// A text field still being typed in commits its draft when it loses focus; give that a moment,
    /// so the last save before quitting has it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NSApp.windows.contains(where: { $0.firstResponder is NSTextView }) else { return .terminateNow }
        NSApp.windows.forEach { $0.makeFirstResponder(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { clearWork() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Domain types

/// One word as the engine actually heard it, with measured start/end.
struct Word: Equatable {
    var start: Double
    var end: Double
    var text: String
    /// Drawn as the accent word by the native caption styles.
    var accent = false
    /// Where the voice says it, for «Пересчитать по словам».
    var voice: VoiceAnchor?
    /// The film caption's line break after it, set by hand (`ChunkWord.br`).
    var br: Bool?
}

/// A word of a caption: the caption and the word's place in it.
struct WordRef: Equatable {
    let cue: Cue.ID
    let index: Int
}

struct Cue: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    /// Per-word timings from the recogniser. Empty for cues loaded from a plain .srt.
    var words: [Word] = []
    /// Marked for emphasis — drawn with the accent font, tilt and size.
    var accent = false
    /// The chunk id in the project file, kept so saving does not renumber Claude's captions.
    var key: String?
    /// Starts a new paragraph (see `Job.paragraphs`).
    var paragraph = false
    /// Moved by hand on the picture: stage px from the style's place.
    var x: Double?
    var y: Double?
}

enum CaptionSplit: String, CaseIterable, Identifiable {
    case word = "1 слово", pair = "2 слова", lines = "2 строки"
    var id: String { rawValue }
    var glyph: String { self == .word ? "1" : self == .pair ? "2" : "¶" }
}

enum TextAlign: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var symbol: String { "text.align\(rawValue)" }
    var swiftUI: TextAlignment { self == .left ? .leading : self == .right ? .trailing : .center }
    /// ASS \an for the middle row: 4 = left, 5 = centre, 6 = right. The middle row keeps the
    /// vertical anchor on the caption's centre, matching the backplate, while still telling
    /// libass how to justify a caption that wraps onto two lines.
    var assAnchor: Int { self == .left ? 4 : self == .right ? 6 : 5 }

    /// \an4 anchors on the text's left edge and \an6 on its right, so the x passed to \pos
    /// has to shift by half the text width to keep the block where the user put it.
    func anchorX(centre: Double, width: Double) -> Double {
        switch self {
        case .left: return centre - width / 2
        case .center: return centre
        case .right: return centre + width / 2
        }
    }
}

/// How a caption arrives. PARTICLES moved to `Outro`, where a scatter belongs.
enum Anim: String, CaseIterable, Identifiable {
    case none, pop, fade, slideUp, bounce, zoomOut, shake, typewriter, wave, glitch
    var id: String { rawValue }

    /// Presets that address each character separately instead of the whole line.
    var splitsGlyphs: Bool { self == .typewriter || self == .wave }


    var curve: Animation {
        switch self {
        case .none: return .linear(duration: 0.01)
        case .fade: return .easeIn(duration: 0.18)
        case .slideUp, .wave: return .easeOut(duration: 0.22)
        case .bounce: return .spring(response: 0.30, dampingFraction: 0.45)
        case .shake, .glitch: return .spring(response: 0.24, dampingFraction: 0.30)
        case .typewriter: return .easeOut(duration: 0.16)
        default: return .spring(response: 0.26, dampingFraction: 0.66)
        }
    }
}

/// How a caption leaves. Emitted as its own Dialogue event over the tail of the cue, so an
/// entrance that uses \move (SLIDE UP) can still be paired with an exit that also needs it.
enum Outro: String, CaseIterable, Identifiable {
    case none, fade, shrink, grow, slideDown, riseUp, blurOut, spin, particles, glitchOut
    var id: String { rawValue }

    var splitsGlyphs: Bool { self == .particles }


    /// Share of the cue given to the exit, capped so short captions stay readable.
    func length(of duration: Double) -> Double {
        self == .none ? 0 : min(0.34, duration * 0.42)
    }
}

/// Platform chrome drawn over the player so you can see what the app will cover.
enum SocialOverlay: String, CaseIterable, Identifiable {
    case off, tiktok, reels
    var id: String { rawValue }

    var next: SocialOverlay {
        switch self {
        case .off: return .tiktok
        case .tiktok: return .reels
        case .reels: return .off
        }
    }

}

struct Notice: Equatable {
    var text: String
    var isError: Bool
}

struct Snapshot {
    var cues: [Cue]
    var look: Look
    var stylePreset: String
    var animation: Anim
    var outro: Outro
    var split: CaptionSplit
    /// Shots, sound, titles — everything of an open project besides the captions.
    var project: Project?
    var captionStyle: String
    var duration: Double
    var videoSize: CGSize
}

/// Everything that decides how a caption is painted. Style presets write into this, and the
/// settings column edits it afterwards.
struct Look: Equatable, Codable {
    var font = "Helvetica Neue"
    var size = 64.0
    var bold = true
    var italic = false
    var uppercase = false
    var tracking = 0.0          // multiple of font size, becomes ASS Spacing
    var alignment: TextAlign = .center
    var posX = 0.5
    /// Above the description block TikTok and Reels draw over the bottom of the frame.
    var posY = 0.72

    var textColor = "#F5F5F5"

    var fillOn = true
    var fillColor = "#0030D0"
    var fillShadow = false

    var outlineOn = false
    var outlineColor = "#000000"
    var outlineWidth = 0.09     // multiple of font size

    var shadowOn = false
    var shadowColor = "#000000"
    var shadowDepth = 0.06      // multiple of font size

    var glow = 0.0              // ASS \\blur radius, for neon looks

    /// Master switch: off means captions are drawn with no motion at all.
    var animationsOn = true

    // Accent: how a caption marked for emphasis differs from the rest.
    var accentFont = "Impact"
    var accentAngle = -5.0      // degrees; ASS rotates about the caption's centre
    var accentScale = 1.18      // multiple of the base size
    var accentColorOn = true
    var accentColor = "#FFE10A"
}

// MARK: - Job

/// The playhead, kept apart from the rest of the editor's state. Its time changes twenty times a
/// second while playing and is deliberately not @Published: a SwiftUI view redrawing for it would
/// re-lay out the whole window each time. What follows it (the playhead line and the overlay, which
/// are Core Animation layers, the playing-caption marker) subscribes to `ticks`.
@MainActor final class PlayClock: ObservableObject {
    var time = 0.0 { didSet { if time != oldValue { ticks.send(time) } } }
    let ticks = PassthroughSubject<Double, Never>()
    @Published var playing = false
}

/// The caption under the playhead, published only when it changes — for the text panel's marker,
/// so the rest of the editor does not redraw each time playback reaches the next caption.
@MainActor final class PlayingCue: ObservableObject {
    @Published var id: Cue.ID?
}

@MainActor final class Job: ObservableObject {
    // Media
    @Published var video: URL?
    @Published var videoSize = CGSize(width: 1920, height: 1080)

    // Captions
    @Published var cues: [Cue] = [] { didSet { derived = nil } }
    /// The captions in time order and their paragraph starts, worked out once per change of `cues` —
    /// every panel asks for them on every redraw.
    private var derived: (ordered: [Cue], starts: [Bool])?
    /// The caption the inspector shows — the anchor of a multiple selection.
    @Published var selected: Cue.ID? {
        didSet { if let selected { if !selection.contains(selected) { selection = [selected] } } else { selection = [] } }
    }
    /// Every selected caption (⇧-click a range, ⌘-click one more); always holds `selected`.
    @Published var selection: Set<Cue.ID> = []
    @Published var split: CaptionSplit = .word

    // Caption style
    @Published var look = Look()
    @Published var stylePreset = StylePreset.catalog[0].id
    @Published var animation: Anim = .pop
    @Published var outro: Outro = .fade
    /// "s1"…"s10" draws the native caption styles; "legacy" uses `look` and the presets.
    @Published var captionStyle = "legacy"

    // Project (.simbia) — shots, sound, titles; the captions live in `cues`
    @Published var project: Project?
    @Published var projectURL: URL?
    /// What the inspector edits: the selected caption, a title or a shot.
    @Published var focus: Focus = .caption
    /// The emoji picked on the focused title: handles on the picture, its size and turn in the title window.
    @Published var sticker: StickerRef?
    /// The tab picked in the right-hand panel; nil follows the focus (text for captions, titles for a title).
    /// Picking one opens the panel again when it is folded away.
    @Published var libraryTab: LibraryTab? { didSet { if libraryTab != nil, libraryCollapsed { libraryCollapsed = false } } }
    /// The right-hand panel folded to its tabs, the timeline taking the room.
    @Published var libraryCollapsed = false
    /// The word whose tools window is open in the text panel.
    @Published var editingWord: WordRef?
    /// The shot whose tools window is open on the timeline.
    @Published var shotTools: String?
    /// The sound clip whose volume window is open (a click on the voice or music track).
    @Published var audioTools: String?
    /// The motion-graphics scene whose window is open (a click on it in the Graphics track).
    @Published var overlayTools: String?
    /// The title or Trustpilot graphic whose settings window is open (a click on it in the timeline).
    @Published var titleTools: String?
    /// The footage library over the whole window, and the shot it fills.
    @Published var galleryOpen = false
    /// «Аудиобиблиотека» over the whole window: a track from `_ASSETS/MUSIC` as the project's music.
    @Published var musicOpen = false
    /// Where a video picked in the clip windows goes on the overlay track (opened from its empty part); nil = into a shot.
    @Published var layerAt: Double?
    @Published var galleryShot: String?
    @Published var galleryCategory = FootageIndex.Category.tube
    @Published var galleryPicked: FootageIndex.Moment?
    /// The project's own videos over the whole window (a double click on a shot), and the shot they replace.
    @Published var clipsOpen = false
    @Published var clipsShot: String?
    /// The cut a video from the clip window goes onto (the «+» on a cut → «Видео»): the shot it follows.
    @Published var clipsInsertAfter: String?
    /// Every project in the folder as cards (the grid button before the project's name).
    @Published var browserOpen = false
    /// The open project's brief, what is done, to check and left, over the whole window (a click on its name).
    @Published var briefOpen = false
    /// The track whose settings are open in the drawer under it on the timeline (nil = none, the tracks take the room).
    @Published var drawer: Lane?
    /// Where what is picked in the drawer goes in (a «+» on an empty stretch); nil = at the playhead.
    @Published var addAt: Double?
    /// The shot being cropped on the picture (its whole frame with the box the edit shows).
    @Published var cropShot: String?
    /// The shot whose covered zones are being drawn on the picture («Закрыть текст»).
    @Published var coverShot: String?
    /// The Trustpilot reviews for the Graphics tab, once read; `reviewsMissing` when none were found.
    @Published var reviews: ReviewLibrary?
    @Published var reviewsMissing = false
    /// The kit's motion-graphics scenes for the Graphics tab, once looked for.
    @Published var motionScenes: [MotionLibrary.Scene]?
    /// Cuts and drags stick to the beat grid (the switch left of the bars; remembered between launches).
    @Published var magnet = UserDefaults.standard.object(forKey: "timeline.magnet") as? Bool ?? true {
        didSet { UserDefaults.standard.set(magnet, forKey: "timeline.magnet") }
    }
    /// The preview shows the footage without any colour (grades and look stay in the project).
    @Published var colourCompare = false
    /// The shot whose colour is being matched right now (the button shows it working).
    @Published var matchingColour: String?
    /// Last save or load of the project file, for the sync indicator.
    @Published var syncStatus: SyncStatus?
    /// Autosave, file watching and the composition behind the player — see ProjectSync.swift.
    let sync = ProjectSyncState()
    /// What is worth fixing before the video goes out, kept current as the edit changes (EditorTools.swift).
    @Published var issues: [Issue] = []
    /// The checks window over the export button; `exportAfterChecks` when Export opened it.
    @Published var checksOpen = false
    @Published var exportAfterChecks = false
    /// The find & replace, glossary or pauses window.
    @Published var toolPanel: ToolPanel?
    /// Words always spelt one way: the recogniser is told to expect them, near misses are put right.
    @Published var glossary = Glossary.load()
    /// The footage library's index, once read.
    @Published var footage: FootageIndex?
    @Published var footageState: FootageState = .idle

    // Transport / view state
    let clock = PlayClock()
    var currentTime: Double { get { clock.time } set { clock.time = newValue } }
    var isPlaying: Bool { get { clock.playing } set { clock.playing = newValue } }
    let playingCue = PlayingCue()
    @Published var duration = 1.0
    @Published var social: SocialOverlay = .off

    /// UI language. Follows the system on first launch, then remembers the choice.
    @Published var language: AppLanguage = .preferred {
        didSet { AppLanguage.current = language }
    }
    /// The Language menu: a language kept for this Mac, or nil to follow the Mac's own language (the default).
    var languageChoice: AppLanguage? {
        get { AppLanguage.saved }
        set {
            objectWillChange.send()
            // macOS's own menu items (File, Edit, Close, Copy…) follow AppleLanguages, read at launch.
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: "language")
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "language")
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            language = newValue ?? .system
        }
    }
    var s: Strings { .table(language) }
    @Published var timelineZoom = 1.0
    @Published var timelineOffset = 0.0

    // Pipeline
    @Published var status = "Выберите видео — язык и субтитры определятся автоматически."
    @Published var busy = false
    @Published var progress = 0
    @Published var editorReady = false

    /// Shown briefly after an operation ends. `status` alone is invisible in the editor once
    /// `busy` goes false, so exports appeared to finish silently — success and failure alike.
    @Published var notice: Notice?

    /// True while a text field has focus, so the menu's Command-Z does not steal the
    /// field's own undo.
    @Published var textEditing = false

    // Undo
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var history: [Snapshot] = []
    private var future: [Snapshot] = []

    let fonts = ["Helvetica Neue", "Arial", "Arial Black", "Avenir Next", "Impact", "Futura",
                 "Gill Sans", "Phosphate", "Georgia", "Optima", "Trebuchet MS", "Verdana",
                 "American Typewriter", "Menlo", "Copperplate", "Didot", "Rockwell", "Chalkboard SE"]
    let temp: URL
    let logFile: URL
    let player = AVPlayer()
    var resolvedFFmpeg: String?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    var index: Int? { cues.firstIndex { $0.id == selected } }
    var selectedCue: Cue? { index.map { cues[$0] } }
    var activeCue: Cue? { cues.first { currentTime >= $0.start && currentTime <= $0.end } }

    init() {
        clearWork()
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        temp = root.appending(path: "Work", directoryHint: .isDirectory)
        logFile = root.appending(path: "Logs/analysis.log")
        status = t("Речь распознаёт сам Mac", "Speech is recognised by the Mac itself", "La parole est reconnue par le Mac lui-même")

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in self?.isPlaying = player.timeControlStatus == .playing }
        }
        appendLog("App started")
        var reported = 0
        SimbiaCompositor.report = { [weak self] message in
            Task { @MainActor in
                guard reported < 20 else { return }                // the first few are enough to tell what is wrong
                reported += 1
                self?.appendLog("Compositor: " + message)
            }
        }
        startProjectSync()
    }

    private func tick(_ seconds: Double) {
        guard !sync.seekPending else { return }
        currentTime = max(0, seconds)
        if isPlaying { followPlayhead() }
    }

    /// Keeps `playingCue` current as the playhead moves or the captions change.
    func trackPlayingCue() {
        let under = cues.first { currentTime >= $0.start && currentTime < $0.end }?.id
        if under != playingCue.id { playingCue.id = under }
    }

    /// `orderedCues` and its paragraph starts, from the cache while `cues` is unchanged.
    var orderedAndStarts: (ordered: [Cue], starts: [Bool]) {
        if let derived { return derived }
        let ordered = cues.sorted { $0.start < $1.start }
        let value = (ordered, paragraphStarts(ordered))
        derived = value
        return value
    }

    // MARK: Caption text shaping

    /// Words with real timings when the engine measured them, proportional division otherwise.
    ///
    /// The engine gives each word a measured start/end; dividing a sentence evenly is only a
    /// fallback for cues typed by hand or loaded from a plain .srt. If the user retypes a word
    /// but keeps the word count, the measured timings still apply — only a change in the number
    /// of words forces the fallback.
    func timedWords(of cue: Cue) -> [Word] {
        let spoken = cue.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !spoken.isEmpty else { return [] }
        if cue.words.count == spoken.count {
            return zip(cue.words, spoken).map { Word(start: $0.start, end: $0.end, text: $1, accent: $0.accent, voice: $0.voice, br: $0.br) }
        }
        let span = max(cue.end - cue.start, 0.01)
        let total = Double(spoken.count)
        return spoken.enumerated().map { index, text in
            Word(start: cue.start + span * Double(index) / total,
                 end: cue.start + span * Double(index + 1) / total,
                 text: text)
        }
    }

    /// Identity of the caption unit on screen right now. The burn-in emits one animated event
    /// per word (or pair), so the preview has to restart its animation on the same boundaries —
    /// keying on the cue alone made it animate once per sentence and then sit still.
    func captionKey(for cue: Cue, at time: Double) -> String {
        guard split != .lines else { return cue.id.uuidString }
        let words = timedWords(of: cue)
        guard !words.isEmpty else { return cue.id.uuidString }
        let step = split == .word ? 1 : 2
        let index = words.firstIndex { time < $0.end } ?? words.count - 1
        return "\(cue.id.uuidString)-\((index / step) * step)"
    }

    func captionText(for cue: Cue, at time: Double) -> String {
        let words = timedWords(of: cue)
        guard !words.isEmpty else { return cue.text }
        switch split {
        case .lines:
            guard words.count > 1 else { return cue.text }
            let cut = (words.count + 1) / 2
            return words[..<cut].map(\.text).joined(separator: " ") + "\n"
                 + words[cut...].map(\.text).joined(separator: " ")
        case .word, .pair:
            let step = split == .word ? 1 : 2
            let index = words.firstIndex { time < $0.end } ?? words.count - 1
            let start = (index / step) * step
            return words[start..<min(words.count, start + step)].map(\.text).joined(separator: " ")
        }
    }

    /// Cues in playback order. Dragging a caption past its neighbour reorders it in time but
    /// not in the array, and prev/next, the SRT writer and the burn-in all assume time order.
    var orderedCues: [Cue] { orderedAndStarts.ordered }

    /// Cues expanded to the units that actually burn in (one per word / pair, or whole lines),
    /// carrying the engine's measured word boundaries rather than an even split.
    ///
    /// Ends are trimmed against the next caption: the preview shows one caption at a time, so
    /// overlapping cues would otherwise stack on top of each other only in the exported file.
    var exportCues: [Cue] {
        let units = expandedCues
        return units.enumerated().map { index, cue in
            var trimmed = cue
            if index + 1 < units.count {
                trimmed.end = min(trimmed.end, max(cue.start + 0.02, units[index + 1].start))
            }
            return trimmed
        }
    }

    private var expandedCues: [Cue] {
        orderedCues.flatMap { cue -> [Cue] in
            let words = timedWords(of: cue)
            guard split != .lines, !words.isEmpty else {
                return [Cue(start: cue.start, end: cue.end,
                            text: captionText(for: cue, at: cue.start), accent: cue.accent)]
            }
            let step = split == .word ? 1 : 2
            return stride(from: 0, to: words.count, by: step).map { index in
                let group = words[index..<min(words.count, index + step)]
                return Cue(start: group.first!.start, end: group.last!.end,
                           text: group.map(\.text).joined(separator: " "), accent: cue.accent)
            }
        }
    }

    // MARK: Geometry

    /// Footage proportions, clamped so a corrupt size cannot produce an absurd layout.
    var aspect: Double { max(0.2, min(4, videoSize.width / max(videoSize.height, 1))) }

    /// Wide footage gets a different editor layout: it cannot use a tall side column.
    var isLandscape: Bool { videoSize.width > videoSize.height }

    /// Where the video image sits inside the preview. The player fills the rounded stage
    /// (aspect-fill), so the frame can extend past the container on one axis.
    func videoRect(in container: CGSize) -> CGRect {
        let scale = max(container.width / max(videoSize.width, 1), container.height / max(videoSize.height, 1))
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Editing + undo

    func snapshot() -> Snapshot {
        Snapshot(cues: cues, look: look, stylePreset: stylePreset, animation: animation, outro: outro, split: split,
                 project: project, captionStyle: captionStyle, duration: duration, videoSize: videoSize)
    }

    /// Something to render: captions, or a project with titles.
    var canExport: Bool { !cues.isEmpty || !titles.isEmpty }

    /// Apply a preset, keeping where the user has already put the captions.
    func applyStyle(_ preset: StylePreset) {
        pushHistory()
        stylePreset = preset.id
        preset.write(into: &look)
    }

    private func apply(_ snapshot: Snapshot) {
        cues = snapshot.cues
        look = snapshot.look
        stylePreset = snapshot.stylePreset
        animation = snapshot.animation
        outro = snapshot.outro
        split = snapshot.split
        // a video saved as a project keeps its project: undoing past that point must not empty the file
        if snapshot.project != nil || projectURL == nil { project = snapshot.project }
        captionStyle = snapshot.captionStyle
        duration = snapshot.duration
        videoSize = snapshot.videoSize
        keepSelectionValid()
        // the inspector must not point at a title or shot the undo took away
        switch focus {
        case .title(let id) where title(id) == nil: focus = .caption
        case .shot(let id) where shot(id) == nil: focus = .caption
        case .overlay(let id) where overlay(id) == nil: focus = .caption
        case .audio(let id) where audioClip(id) == nil: focus = .caption
        case .filter(let id) where filterClip(id) == nil: focus = .caption
        case .transition(let id) where transitionClip(id) == nil: focus = .caption
        default: break
        }
    }

    /// After captions were replaced: drop what no longer exists and, if the anchor went, take the
    /// caption at the playhead (not the first one — undoing a split must not jump to the top).
    func keepSelectionValid() {
        let ids = Set(cues.map(\.id))
        if let selected, ids.contains(selected) {
            selection.formIntersection(ids)
            return
        }
        let near = cues.first { currentTime >= $0.start && currentTime < $0.end }
            ?? cues.min { abs($0.start - currentTime) < abs($1.start - currentTime) }
        selected = near?.id
    }

    func pushHistory() {
        history.append(snapshot())
        if history.count > 120 { history.removeFirst() }
        future.removeAll()
        canUndo = true
        canRedo = false
    }

    /// Record an undo step, then mutate.
    func edit(_ change: (Job) -> Void) {
        pushHistory()
        change(self)
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(snapshot())
        apply(previous)
        canUndo = !history.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(snapshot())
        apply(next)
        canUndo = true
        canRedo = !future.isEmpty
    }

    /// Emphasis is per caption, so it lives on the cue rather than in the shared look.
    func toggleAccent(_ id: Cue.ID) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        cues[i].accent.toggle()
    }

    var accentedCount: Int { cues.filter(\.accent).count }

    func updateText(of id: Cue.ID, to text: String) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        let typed = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // an emptied caption goes, rather than staying on as a block with no words
        guard !typed.isEmpty else { removeCaptions([id]); return }
        var cue = cues[i]
        if typed.count != cue.words.count, !cue.words.isEmpty {
            cue.words = Self.retimed(cue.words, typed, start: cue.start, end: cue.end)
        }
        cue.text = text
        cues[i] = cue
    }

    /// Words for a retyped caption with a different word count: words still there keep their timing
    /// and accent, new ones share the time between their neighbours.
    static func retimed(_ old: [Word], _ typed: [String], start: Double, end: Double) -> [Word] {
        func key(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let a = old.map { key($0.text) }, b = typed.map(key)
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var match = [Int?](repeating: nil, count: b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { match[j] = i; i += 1; j += 1 } else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 }
        }
        var out: [Word] = []
        var k = 0
        while k < typed.count {
            if let m = match[k] {
                out.append(Word(start: old[m].start, end: old[m].end, text: typed[k], accent: old[m].accent))
                k += 1
                continue
            }
            var e = k
            while e < typed.count, match[e] == nil { e += 1 }
            let from = out.last?.end ?? start
            let to = e < typed.count ? old[match[e]!].start : end
            let step = max(0, to - from) / Double(e - k)
            for n in k..<e {
                out.append(Word(start: from + step * Double(n - k), end: from + step * Double(n - k + 1), text: typed[n]))
            }
            k = e
        }
        return out
    }

    func retime(_ id: Cue.ID, start: Double? = nil, end: Double? = nil, snapping tolerance: Double = 0) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        let limit = bounds(for: id)
        if let start {
            let target = snap(start, excluding: id, tolerance: tolerance)
            cues[i].start = max(limit.lower, min(target, cues[i].end - 0.05))
        }
        if let end {
            // Ceiling must never fall below where the cue already ends, or dragging a cue that
            // sits past the video duration snaps it shut. Neighbours cap it too, so captions
            // cannot be dragged into an overlap.
            let target = snap(end, excluding: id, tolerance: tolerance)
            let ceiling = max(min(limit.upper, max(duration, cues[i].end)), cues[i].start + 0.05)
            cues[i].end = max(cues[i].start + 0.05, min(target, ceiling))
        }
    }

    /// What a dragged caption may not cross: its neighbours in time.
    func bounds(for id: Cue.ID) -> (lower: Double, upper: Double) {
        let ordered = orderedCues
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return (0, duration) }
        let lower = index > 0 ? ordered[index - 1].end : 0
        let upper = index + 1 < ordered.count
            ? ordered[index + 1].start
            : max(duration, ordered[index].end)
        return (lower, upper)
    }

    /// Edges the drag should stick to: neighbouring captions, the playhead, and the ends.
    func snap(_ time: Double, excluding id: Cue.ID, tolerance: Double, among list: [Cue]? = nil) -> Double {
        guard tolerance > 0 else { return time }
        var targets = [0, duration, currentTime]
        for cue in list ?? cues where cue.id != id { targets.append(cue.start); targets.append(cue.end) }
        guard let nearest = targets.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    /// Slide a caption without changing how long it lasts; its words go with it. A neighbour it runs into gives
    /// way — its touching edge is trimmed (its words squeezed into what is left), down to `Self.minCaption` —
    /// so captions that touch can still be moved. During a drag pass the captions as they were when it began
    /// as `base`: dragging back gives the neighbours their time back.
    func move(_ id: Cue.ID, to start: Double, keeping length: Double, snapping tolerance: Double = 0, base: [Cue]? = nil) {
        let list = base ?? cues
        guard let original = list.first(where: { $0.id == id }) else { return }
        let ordered = list.sorted { $0.start < $1.start }
        guard let k = ordered.firstIndex(where: { $0.id == id }) else { return }
        let before = k > 0 ? ordered[k - 1] : nil
        let after = k + 1 < ordered.count ? ordered[k + 1] : nil
        // the edges to stick to are the neighbours' as the drag found them, not the ones it is trimming
        var target = snap(start, excluding: id, tolerance: tolerance, among: list)
        // Snapping the trailing edge feels the same as snapping the leading one.
        let tail = snap(start + length, excluding: id, tolerance: tolerance, among: list) - length
        if abs(tail - start) < abs(target - start) { target = tail }
        // as far as the neighbours can give way, never past them
        let lower = max(0, before.map { $0.start + Self.minCaption } ?? 0)
        let upper = (after.map { $0.end - Self.minCaption } ?? max(duration, original.end)) - length
        let s = max(lower, min(target, max(lower, upper)))
        let d = s - original.start
        var out = list
        for i in out.indices {
            let c = out[i]
            if c.id == id {
                out[i].start = s; out[i].end = s + length
                out[i].words = c.words.map { var w = $0; w.start += d; w.end += d; w.voice = nil; return w }   // placed by hand
            } else if c.id == before?.id, c.end > s {
                out[i] = Self.trimmed(c, start: c.start, end: s)
            } else if c.id == after?.id, c.start < s + length {
                out[i] = Self.trimmed(c, start: s + length, end: c.end)
            }
        }
        cues = out
    }

    /// Drag one edge of a caption to make it start or end there — longer or shorter, down to `Self.minCaption`; the
    /// edge sticks like a moved caption's. Its words stay where the voice says them, any now outside it pulled to its
    /// edge; a neighbour it grows into gives way as in `move`. `base` = the captions as the drag found them.
    func trimCaption(_ id: Cue.ID, start: Double? = nil, end: Double? = nil, snapping tolerance: Double = 0, base: [Cue]? = nil) {
        let list = base ?? cues
        let ordered = list.sorted { $0.start < $1.start }
        guard let k = ordered.firstIndex(where: { $0.id == id }) else { return }
        let c = ordered[k]
        let before = k > 0 ? ordered[k - 1] : nil, after = k + 1 < ordered.count ? ordered[k + 1] : nil
        var s = c.start, e = c.end
        if let start {
            let lower = max(0, before.map { $0.start + Self.minCaption } ?? 0)
            s = max(lower, min(snap(start, excluding: id, tolerance: tolerance, among: list), c.end - Self.minCaption))
        }
        if let end {
            let upper = after.map { $0.end - Self.minCaption } ?? max(duration, c.end)
            e = min(upper, max(snap(end, excluding: id, tolerance: tolerance, among: list), c.start + Self.minCaption))
        }
        var out = list
        for i in out.indices {
            let x = out[i]
            if x.id == id {
                out[i].start = s; out[i].end = e
                out[i].words = x.words.map { var w = $0; w.start = min(max(w.start, s), e - 0.01); w.end = min(max(w.end, w.start), e); return w }
            } else if x.id == before?.id, x.end > s {
                out[i] = Self.trimmed(x, start: x.start, end: s)
            } else if x.id == after?.id, x.start < e {
                out[i] = Self.trimmed(x, start: e, end: x.end)
            }
        }
        cues = out
    }

    /// The shortest a neighbour gets when a moved caption pushes into it.
    static let minCaption = 0.15

    /// Slide a whole caption on the captions drawer's mini timeline: the neighbours that touched it stay touching —
    /// the one before ends where it now starts, the one after starts where it now ends, squeezed or stretched (their
    /// words with them); one that did not touch it only gives way when it runs into it. `base` = as the drag found them.
    func slide(_ id: Cue.ID, to start: Double, base: [Cue]) {
        let ordered = base.sorted { $0.start < $1.start }
        guard let k = ordered.firstIndex(where: { $0.id == id }) else { return }
        let c = ordered[k], length = c.end - c.start
        let before = k > 0 ? ordered[k - 1] : nil, after = k + 1 < ordered.count ? ordered[k + 1] : nil
        let lower = before.map { $0.start + Self.minCaption } ?? 0
        let upper = (after.map { $0.end - Self.minCaption } ?? max(duration, c.end)) - length
        let s = max(lower, min(start, max(lower, upper))), d = s - c.start
        let touchesBefore = before.map { $0.end >= c.start - 0.05 } ?? false
        let touchesAfter = after.map { $0.start <= c.end + 0.05 } ?? false
        var out = base
        for i in out.indices {
            let x = out[i]
            if x.id == id {
                out[i].start = s; out[i].end = s + length
                out[i].words = x.words.map { var w = $0; w.start += d; w.end += d; w.voice = nil; return w }   // placed by hand
            } else if x.id == before?.id, touchesBefore || x.end > s {
                out[i] = Self.trimmed(x, start: x.start, end: s)
            } else if x.id == after?.id, touchesAfter || x.start < s + length {
                out[i] = Self.trimmed(x, start: s + length, end: x.end)
            }
        }
        cues = out
    }

    /// A caption cut to [start, end], its words squeezed in proportionally so none falls outside it.
    static func trimmed(_ cue: Cue, start: Double, end: Double) -> Cue {
        var c = cue
        let a = cue.start, span = max(cue.end - cue.start, 0.001), k = (end - start) / span
        c.start = start; c.end = end
        c.words = cue.words.map { var w = $0; w.start = start + (w.start - a) * k; w.end = start + (w.end - a) * k; return w }
        return c
    }

    // MARK: Transport

    func select(_ cue: Cue) {
        selected = cue.id
        focus = .caption
        seek(cue.start)
        reveal(cue)
    }

    /// Scroll the timeline so playback stays visible instead of running off the right edge.
    private func followPlayhead() {
        let visible = duration / timelineZoom
        guard visible < duration else { return }
        guard currentTime > timelineOffset + visible * 0.75 || currentTime < timelineOffset else { return }
        timelineOffset = max(0, min(currentTime - visible * 0.25, duration - visible))
    }

    /// Scroll the timeline so the caption is on screen when it is picked from elsewhere.
    private func reveal(_ cue: Cue) {
        let visible = duration / timelineZoom
        guard cue.start < timelineOffset || cue.end > timelineOffset + visible else { return }
        timelineOffset = max(0, min(cue.start - visible * 0.3, max(0, duration - visible)))
    }

    /// AVPlayer sitting at the end ignores play(), so the button looked dead once the video
    /// finished. Rewind first in that case.
    func play() {
        if currentTime >= duration - 0.08 { seek(0) }
        player.play()
    }

    func seek(_ seconds: Double, thenPlay: Bool = false) {
        let time = min(max(0, seconds), duration)
        currentTime = time
        sync.seeks += 1
        sync.seekPending = true
        let id = sync.seeks
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.sync.seeks == id else { return }   // a later seek took over
                self.sync.seekPending = false
                if thenPlay, finished { self.player.play() }
            }
        }
    }

    func previousCue() {
        let ordered = orderedCues
        guard let cue = ordered.last(where: { $0.start < currentTime - 0.15 }) ?? ordered.first else { return }
        select(cue)
    }

    func nextCue() {
        let ordered = orderedCues
        guard let cue = ordered.first(where: { $0.start > currentTime + 0.05 }) ?? ordered.last else { return }
        select(cue)
    }

    /// Roughly 14 seconds on screen — narrow enough that a caption cell can show its text.
    func fitTimeline() {
        timelineZoom = min(60, max(1, duration / 14))
        timelineOffset = 0
    }

    func zoomTimeline(_ delta: Double) {
        timelineZoom = min(max(60, duration / 0.5), max(1, timelineZoom * (1 + delta)))   // in to half a second on screen
        let visible = duration / timelineZoom
        timelineOffset = min(max(0, timelineOffset), max(0, duration - visible))
    }

    func panTimeline(_ delta: Double) {
        let visible = duration / timelineZoom
        timelineOffset = min(max(0, timelineOffset + delta), max(0, duration - visible))
    }

    // MARK: File pickers

    func videoPicker() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .simbiaProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// A video starts a transcription; a .simbia opens the project as it was saved.
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == Project.fileExtension { openProject(url) } else { openVideo(url) }
    }

    func openVideo(_ url: URL) {
        guard !busy else { show(s.waitForCurrent, isError: true); return }
        // the same video again: carry on with the saved work instead of transcribing it afresh
        let saved = Self.autosaveURL(for: url)
        if FileManager.default.fileExists(atPath: saved.path) {
            appendLog("Selected video: \(url.path) — continuing \(saved.lastPathComponent)")
            openProject(saved)
            show(t("Продолжаю сохранённую работу над этим видео", "Continuing the saved work on this video", "Reprise du travail enregistré sur cette vidéo"), isError: false)
            return
        }
        appendLog("Selected video: \(url.path)")
        closeProject()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.pause()
        video = url
        cues = []
        selected = nil
        editorReady = false
        currentTime = 0
        duration = 1
        resetHistory()
        progress = 2
        transcribe()
    }

    func resetHistory() {
        history.removeAll(); future.removeAll(); canUndo = false; canRedo = false
    }

    /// Duration and display size, or a specific complaint. Leaving `duration` at its 1.0
    /// placeholder used to poison every clamp in the editor, and a stale `videoSize` writes the
    /// wrong PlayResX/PlayResY into the subtitle script, so a failure here has to be fatal.
    private func loadMetrics(of url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let length = try? await asset.load(.duration),
              length.seconds.isFinite, length.seconds > 0.05 else {
            throw NSError(domain: "Simbia", code: 4, userInfo: [NSLocalizedDescriptionKey:
                s.noDuration])
        }
        duration = length.seconds

        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            throw NSError(domain: "Simbia", code: 5, userInfo: [NSLocalizedDescriptionKey:
                s.noVideoTrack])
        }
        // Phone footage stores a rotation matrix; captions must be laid out on what is shown.
        let displayed = natural.applying(transform)
        let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        guard size.width > 1, size.height > 1 else {
            throw NSError(domain: "Simbia", code: 6, userInfo: [NSLocalizedDescriptionKey:
                s.noFrameSize])
        }
        videoSize = size
    }

    func srtPicker() {
        guard !busy, video != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            cues = try parse(try String(contentsOf: url, encoding: .utf8))
            fitTimeline()
            if let first = cues.first { select(first) }
            editorReady = true
            autosaveVideoProject()
            status = fill(s.loadedCues, String(cues.count))
            show(status, isError: false)
        } catch {
            status = error.localizedDescription
            show(status, isError: true)
        }
    }

    // MARK: Pipeline

    func transcribe() {
        guard let video else { return }
        work { [self] in
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try await loadMetrics(of: video)
            // the Mac's own recogniser, the glossary's words as the ones to expect
            status = fill(s.recognising, MacSpeech.name(MacSpeech.locale, in: language.rawValue))
            progress = 2
            let heard = try await MacSpeech.words(in: video, from: 0, to: duration + 1, hints: glossary.words, work: temp,
                                                  downloading: { [weak self] in self?.status = self?.t("Mac загружает язык распознавания…", "The Mac is downloading the speech language…", "Le Mac télécharge la langue de la parole…") ?? "" },
                                                  progress: { [weak self] p in self?.progress = 2 + Int(p * 95) })
            progress = 98
            cues = group(words: heard.map { Word(start: $0.start, end: $0.end, text: glossary.correction(for: $0.text) ?? $0.text) })
            guard !cues.isEmpty else {
                throw NSError(domain: "Simbia", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: s.noSpeech])
            }
            fitTimeline()
            if let first = cues.first { select(first) }
            progress = 100
            status = fill(s.transcribeDone, String(cues.count))
            editorReady = true
            autosaveVideoProject()
            // the recogniser's word edges are approximate: the captions start and end with the voice, and no blink is
            // left between two of them
            if let voice = await voiceActivity() {
                sync.voice = voice
                put(document().fixing(.voice, voice: voice, glossary: glossary).fixing(.gap, voice: voice, glossary: glossary),
                    keepingIdentity: true)
            }
        }
    }

    func saveSRT() {
        guard !cues.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(video?.deletingPathExtension().lastPathComponent ?? "captions").srt"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        do {
            try makeSRT().write(to: out, atomically: true, encoding: .utf8)
            status = fill(s.savedTo, out.lastPathComponent)
            show(status, isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func export(checked: Bool = false) {
        // what the checks find comes up first; from there the video goes out fixed, or as it is
        if !checked {
            refreshIssues()
            if issues.contains(where: \.fixable) { exportAfterChecks = true; checksOpen = true; return }
        }
        // A project (shots, titles, the native styles) renders through the native engine; a transcribed
        // video with nothing added burns its classic captions straight onto the original, as before.
        guard let source = plainVideo else { exportProject(); return }
        guard !cues.isEmpty else { show(s.needVideoAndCues, isError: true); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent)\(t("-субтитры", "-captions", "-sous-titres")).mp4"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        work { [self] in try await burn(to: out, from: source) }
    }

    /// The original video when what is open is just that video with classic captions (one shot, no
    /// titles or graphics) — saved as a project or not.
    var plainVideo: URL? {
        guard let p = project else { return video }
        guard captionStyle == "legacy", p.shots.count == 1, p.titles.isEmpty, p.overlays.isEmpty, p.audio.count <= 1 else { return nil }
        return Project.resolve(p.shots[0].src, relativeTo: projectURL)
    }

    /// The burn-in itself, separated from the save panel so it can be exercised directly.
    func burn(to out: URL, from source: URL? = nil) async throws {
        guard let video = source ?? video else { return }
        try await resolveTools()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let ass = temp.appending(path: Self.assFilename)
        try makeASS().write(to: ass, atomically: true, encoding: .utf8)
        status = s.renderingVideo
        progress = 0
        do {
            try await run(ffmpeg, burnArgs(video: video, out: out, copyAudio: true),
                          marker: "out_time_us=", range: 0...99, in: temp)
        } catch {
            appendLog("Audio stream copy failed, re-encoding audio to AAC.")
            try await run(ffmpeg, burnArgs(video: video, out: out, copyAudio: false),
                          marker: "out_time_us=", range: 0...99, in: temp)
        }
        progress = 100
        status = fill(s.savedTo, out.lastPathComponent)
    }

    /// The subtitle path is passed as a bare filename with ffmpeg running inside the Work
    /// folder. A filtergraph value goes through two levels of parsing, and backslash-escaping
    /// an apostrophe does not survive both — "it's" arrives as "its" and the filter fails. A
    /// fixed ASCII filename sidesteps the whole quoting problem whatever the app is stored in.
    private func burnArgs(video: URL, out: URL, copyAudio: Bool) -> [String] {
        ["-y", "-nostdin", "-loglevel", "error", "-progress", "pipe:2",
         "-i", video.path,
         "-vf", "ass=filename=\(Self.assFilename)",
         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
         "-c:a"] + (copyAudio ? ["copy"] : ["aac", "-b:a", "192k"]) + [out.path]
    }

    static let assFilename = "captions.ass"

    /// Runs a tool while tracking its progress, and always tears the watcher down — the old
    /// code cancelled these only on the success path, so a failed run left a task polling the
    /// log forever.
    private func run(_ tool: String, _ args: [String], marker: String,
                     range: ClosedRange<Int>, in directory: URL? = nil) async throws {
        let watcher = observeProgress(marker: marker, from: logSize(), range: range)
        defer { watcher.cancel() }
        try await command(tool, args, in: directory)
        progress = range.upperBound
    }

    private func logSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? 0
    }

    func work(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }          // one long operation at a time
        busy = true
        notice = nil
        Task {
            do {
                try await action()
                show(status, isError: false)
            } catch {
                appendLog("FAILED: \(error.localizedDescription)")
                status = error.localizedDescription
                show(error.localizedDescription, isError: true)
                progress = 0
            }
            busy = false
        }
    }

    /// Post a message that stays visible for a few seconds after `busy` drops.
    func show(_ text: String, isError: Bool) {
        appendLog((isError ? "Notice (error): " : "Notice: ") + text)
        let entry = Notice(text: text, isError: isError)
        notice = entry
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 9 : 5))
            guard let self, self.notice == entry else { return }
            self.notice = nil
        }
    }

    // MARK: Tools

    /// Resolved by `resolveTools()` before a run; the raw first candidate is only a
    /// placeholder for existence checks and log messages.
    var ffmpeg: String { resolvedFFmpeg ?? Self.ffmpegCandidates[0] }


    /// Follows a tool's progress by reading only what it has written since it started.
    ///
    /// Two bugs lived here. The log is never truncated, and this searched it backwards from the
    /// end, so a new run immediately picked up the *previous* run's last progress value and
    /// jumped to it — an export would open at 99%. It also re-read the entire growing file every
    /// 180 ms on the main actor. Reading forward from a starting offset fixes both.
    func observeProgress(marker: String, from offset: UInt64, range: ClosedRange<Int>) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            let path = self.logFile.path
            let span = self.duration
            var cursor = offset
            var carry = ""

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }

                let (text, next) = await Self.readTail(path: path, from: cursor)
                cursor = next
                guard !text.isEmpty else { continue }

                carry = String((carry + text).suffix(4096))
                guard let percent = Self.lastPercent(in: carry, marker: marker, duration: span) else { continue }
                let width = Double(range.upperBound - range.lowerBound)
                self.progress = min(range.upperBound,
                                    max(range.lowerBound, range.lowerBound + Int(percent * width)))
            }
        }
    }

    /// Reads new bytes off the main actor and reports where to continue from.
    private static func readTail(path: String, from offset: UInt64) async -> (String, UInt64) {
        await Task.detached(priority: .utility) { () -> (String, UInt64) in
            guard let handle = FileHandle(forReadingAtPath: path) else { return ("", offset) }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(), !data.isEmpty else { return ("", offset) }
            return (String(decoding: data, as: UTF8.self), offset + UInt64(data.count))
        }.value
    }

    /// 0...1 from the last marker occurrence. ffmpeg reports microseconds elapsed, whisper a
    /// percentage, so the two are normalised here rather than at every call site.
    private static func lastPercent(in text: String, marker: String, duration: Double) -> Double? {
        guard let hit = text.range(of: marker, options: .backwards) else { return nil }
        let tail = text[hit.upperBound...]

        // Whisper prints "[00:00:01.280 --> 00:00:01.400]  word". With word-level output these
        // arrive constantly, so they give far smoother progress than the 30-second-window
        // percentage callback, which for a short clip only ever fires once at 100%.
        if marker == " --> " {
            let stamp = tail.prefix { $0.isNumber || $0 == ":" || $0 == "." || $0 == "," }
            let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
                  let sec = Double(parts[2]) else { return nil }
            return min(1, (h * 3600 + m * 60 + sec) / max(duration, 0.01))
        }

        let number = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        if marker == "progress = " { return min(1, value / 100) }
        return min(1, value / 1_000_000 / max(duration, 0.01))   // ffmpeg out_time_us
    }

    func appendLog(_ line: String) {
        let folder = logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        if FileManager.default.fileExists(atPath: logFile.path),
           let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(record.utf8))
            try? handle.close()
        } else {
            try? Data(record.utf8).write(to: logFile)
        }
    }

    func command(_ path: String, _ args: [String], in directory: URL? = nil) async throws {
        let failed = t("Команда завершилась с кодом %@. Подробности в Portable/Logs/analysis.log",
                       "The command exited with code %@. Details in Portable/Logs/analysis.log", "La commande s’est terminée avec le code %@. Détails dans Portable/Logs/analysis.log")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let folder = logFile.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logFile.path) {
                    FileManager.default.createFile(atPath: logFile.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logFile)
                try handle.seekToEnd()
                let start = "\n[\(ISO8601DateFormatter().string(from: Date()))] START: \(path) \(args.joined(separator: " "))\n"
                try handle.write(contentsOf: Data(start.utf8))
                let process = Process()
                process.executableURL = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                                            : URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = path.hasPrefix("/") ? args : [path] + args
                process.currentDirectoryURL = directory
                process.standardOutput = handle
                process.standardError = handle
                process.terminationHandler = { task in
                    let record = "\n[\(ISO8601DateFormatter().string(from: Date()))] EXIT \(path): \(task.terminationStatus)\n"
                    try? handle.write(contentsOf: Data(record.utf8))
                    try? handle.close()
                    if task.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "Simbia", code: Int(task.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: fill(failed, String(task.terminationStatus))]))
                    }
                }
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: Subtitle IO

    func parse(_ text: String) throws -> [Cue] {
        let list = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { block -> Cue? in
                let lines = block.components(separatedBy: "\n")
                guard let n = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
                let parts = lines[n].components(separatedBy: " --> ")
                guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1]) else { return nil }
                let body = lines.dropFirst(n + 1).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Whisper emits a blank leading segment, and a blank or zero-length cue would
                // silently break the word-count match that keeps measured timings.
                guard !body.isEmpty, b > a else { return nil }
                return Cue(start: a, end: b, text: body)
            }
        guard !list.isEmpty else {
            throw NSError(domain: "Simbia", code: 2, userInfo: [NSLocalizedDescriptionKey: t("В SRT нет реплик.", "The SRT has no captions.", "Le SRT ne contient aucun sous-titre.")])
        }
        return list
    }

    func time(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }

    func stamp(_ seconds: Double) -> String {
        let c = Int((seconds * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", c / 360_000, (c / 6_000) % 60, (c / 100) % 60, c % 100)
    }

    func srtStamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    func makeSRT() -> String {
        orderedCues.enumerated().map { index, cue in
            "\(index + 1)\n\(srtStamp(cue.start)) --> \(srtStamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }
}
