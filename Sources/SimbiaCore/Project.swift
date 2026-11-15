import Foundation

/// A `.simbia` project: the whole edit as data — shots, sound, motion graphics, captions, titles.
///
/// The file is the single source of truth shared with Claude: Claude writes it, the app edits it,
/// and each side picks up the other's changes by reading it back. Times are seconds on the edit's
/// clock; paths are absolute, or relative to the folder the project file sits in. Every field has a
/// default, so a hand-written file only needs what it uses.
public struct Project: Codable, Equatable, Sendable {
    public static let fileExtension = "simbia"

    public var format = "simbia"
    public var version = 1
    public var name = "Untitled"
    public var canvas = Canvas()
    /// Length of the edit; anything past it is cut off.
    public var duration = 0.0
    /// Beat grid the cuts stick to. nil = no grid.
    public var grid: BeatGrid?
    public var shots: [Shot] = []
    /// Video laid over the shots (the «Наложение» track): while one plays it covers the picture under it and leaves
    /// the edit's timing alone. Same fields as a shot; they need not touch each other. One with `chromaKey` or
    /// `transform` (`Shot.cutout`) is laid over the picture under it instead — its screen cut out, made smaller, moved.
    public var layers: [Shot] = []
    public var audio: [AudioClip] = []
    public var overlays: [OverlayClip] = []
    public var captions = CaptionTrack()
    public var titles: [TitleItem] = []
    /// Which animated emoji set plays the titles' emoji: a folder in Application Support/Simbia Captions/Emoji
    /// ("noto" — Google, CC BY 4.0; "telegram" — personal use only). nil = "noto".
    public var emojiPack: String?
    /// The colour style over every shot. nil = none.
    public var look: ColourLook?
    /// Colour filters over stretches of the edit (adjustment layers), on their own track above the picture.
    public var filters: [FilterClip] = []
    /// Transitions on cuts, each by the shot before its cut.
    public var transitions: [TransitionClip] = []
    /// The shot whose colour others are matched to («Эталон цвета» in the shot window).
    public var colourReference: String?
    /// The folder with this project's generated videos: a double click on a shot picks its replacement from it.
    public var clipsFolder: String?
    public var master = MasterBus()
    /// Bumped on every save, so either side can tell which copy is newer.
    public var revision = 0
    /// Who wrote this revision: "app" or "claude".
    public var savedBy = "app"
    /// Where the video is in the work, for the project browser: "new" (still to make), "review" (made, to be
    /// checked), "done" (delivered). nil = new.
    public var status: String?
    /// What has been done and what is left — the list Bogdan and Claude keep together.
    public var tasks: [ProjectTask]?
    /// What the video is for, in a few plain lines — written by Claude from the card, shown full screen by a click on
    /// the project's name.
    public var brief: ProjectBrief?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project()
        format = try c.value(.format, d.format)
        version = try c.value(.version, d.version)
        name = try c.value(.name, d.name)
        canvas = try c.value(.canvas, d.canvas)
        duration = try c.value(.duration, d.duration)
        grid = try c.decodeIfPresent(BeatGrid.self, forKey: .grid)
        shots = try c.value(.shots, d.shots)
        layers = try c.value(.layers, d.layers)
        audio = try c.value(.audio, d.audio)
        overlays = try c.value(.overlays, d.overlays)
        captions = try c.value(.captions, d.captions)
        titles = try c.value(.titles, d.titles)
        emojiPack = try c.decodeIfPresent(String.self, forKey: .emojiPack)
        look = try c.decodeIfPresent(ColourLook.self, forKey: .look)
        filters = try c.value(.filters, d.filters)
        transitions = try c.value(.transitions, d.transitions)
        colourReference = try c.decodeIfPresent(String.self, forKey: .colourReference)
        clipsFolder = try c.decodeIfPresent(String.self, forKey: .clipsFolder)
        master = try c.value(.master, d.master)
        revision = try c.value(.revision, d.revision)
        savedBy = try c.value(.savedBy, d.savedBy)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks)
        brief = try c.decodeIfPresent(ProjectBrief.self, forKey: .brief)
        Self.fillIDs(&shots, "s")
        Self.fillIDs(&layers, "v")
        Self.fillIDs(&audio, "a")
        Self.fillIDs(&overlays, "m")
        Self.fillIDs(&titles, "t")
        Self.fillIDs(&filters, "f")
        Self.fillIDs(&transitions, "x")
    }

    /// An id missing from a hand-written file comes from the item's place ("s3"), so the same file
    /// always reads the same — a random one would make every reload look like a change.
    static func fillIDs<T>(_ items: inout [T], _ prefix: String) where T: Identifiable, T.ID == String, T: IDCarrying {
        var used = Set(items.map(\.id).filter { !$0.isEmpty })
        for i in items.indices where items[i].id.isEmpty {
            var candidate = "\(prefix)\(i + 1)", n = 1
            while used.contains(candidate) { n += 1; candidate = "\(prefix)\(i + 1)_\(n)" }
            items[i].id = candidate
            used.insert(candidate)
        }
    }
}

/// One line of a project's list: a thing done or still to do.
public struct ProjectTask: Codable, Equatable, Sendable {
    public var text: String
    public var done = false
    /// Made, for Bogdan to look at: it stays under «Проверить» until he ticks it.
    public var review: Bool?

    public init(text: String, done: Bool = false, review: Bool? = nil) {
        self.text = text; self.done = done; self.review = review
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        review = try c.decodeIfPresent(Bool.self, forKey: .review)
    }
}

/// A project's brief in plain words: what we are making, what is asked of us, this video's hook and the scenes in order.
public struct ProjectBrief: Codable, Equatable, Sendable {
    /// What we are working on, a sentence or three.
    public var about = ""
    /// What is asked of us, one short line each.
    public var needs: [String] = []
    /// This video's hook as it is on screen.
    public var hook: String?
    public var scenes: [BriefScene] = []
    /// The card it comes from (a link) and the brief's own file.
    public var card: String?
    public var source: String?
    /// The references, at the top of the brief: links, or files on disk (a downloaded reference video, a still).
    public var refs: [BriefLink] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectBrief()
        about = try c.value(.about, d.about)
        needs = try c.value(.needs, d.needs)
        hook = try c.decodeIfPresent(String.self, forKey: .hook)
        scenes = try c.value(.scenes, d.scenes)
        card = try c.decodeIfPresent(String.self, forKey: .card)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        refs = try c.value(.refs, d.refs)
    }
}

/// A reference of the brief: what it is, and its link or the path of its file.
public struct BriefLink: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) { self.title = title; self.url = url }
}

/// One scene of the brief: who, what it is about in a few words, and her words exactly; `diff` = what the edit
/// does differently from it (shown in yellow).
public struct BriefScene: Codable, Equatable, Sendable {
    public var who: String
    public var gist: String
    public var words: String?
    public var diff: String?

    public init(who: String, gist: String, words: String? = nil, diff: String? = nil) {
        self.who = who; self.gist = gist; self.words = words; self.diff = diff
    }
}

/// Items whose id the decoder may fill in.
protocol IDCarrying { var id: String { get set } }
extension Shot: IDCarrying {}
extension AudioClip: IDCarrying {}
extension OverlayClip: IDCarrying {}
extension TitleItem: IDCarrying {}
extension FilterClip: IDCarrying {}
extension TransitionClip: IDCarrying {}
extension Chunk: IDCarrying {}

public struct Canvas: Codable, Equatable, Sendable {
    public var width = 1080
    public var height = 1920
    public var fps = 30.0

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.value(.width, 1080)
        height = try c.value(.height, 1920)
        fps = try c.value(.fps, 30.0)
    }
}

/// Beat k sits at `offset + k * 60 / bpm`.
public struct BeatGrid: Codable, Equatable, Sendable {
    public var bpm = 120.0
    public var offset = 0.0
    /// The music clip it was found from (`Project.beatSignature`); nil = set by hand or by a script.
    public var source: String?

    public init(bpm: Double = 120, offset: Double = 0, source: String? = nil) { self.bpm = bpm; self.offset = offset; self.source = source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.value(.bpm, 120.0)
        offset = try c.value(.offset, 0.0)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    public var beat: Double { 60 / max(bpm, 1) }

    /// The nearest beat to `time`.
    public func snap(_ time: Double) -> Double {
        offset + ((time - offset) / beat).rounded() * beat
    }
}

// MARK: - Picture

/// One cut of footage (or a still) on the picture track. Shots are laid end to end.
public struct Shot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    /// Footage file, or an image for a still.
    public var src: String
    /// Where in the source the shot begins. Ignored for stills.
    public var inPoint = 0.0
    /// Slow push across the shot.
    public var zoom: Zoom = .none
    /// Darker and slightly soft — for shots under text-heavy motion graphics.
    public var dim = false
    /// Mirrored left to right.
    public var flip = false
    /// Reframed by hand: how much bigger than just filling the frame (1 = as filmed), and where the frame sits in
    /// the enlarged picture, −1…1 from its left / top edge to its right / bottom one (0 = centred).
    public var scale = 1.0
    public var panX = 0.0
    public var panY = 0.0
    /// Turned by hand, degrees clockwise as seen; the footage is then cut to the largest upright frame inside it
    /// (no black corners), which `scale` / `pan` frame as before.
    public var rotation = 0.0
    /// Reframing that moves: keys in the footage's own time; between two the frame glides (eased), before the
    /// first and after the last it holds. Empty = `scale` / `pan` for the whole shot.
    public var keys: [CropKey] = []
    /// Name from the footage index, shown on the shot track.
    public var label: String?
    /// What the editor marked as wrong with this shot (keys of `Shot.issueKinds`) — Claude reads them from the file.
    public var issues: [String] = []
    /// The editor's note on what to fix.
    public var note: String?
    /// Colour: the match to its scene and hand adjustments. nil = as shot (the project look still applies).
    public var grade: Grade?
    /// Stretches of the footage painted over from their surroundings — a creator's burned-in captions (`Covers`).
    public var covers: [CoverZone] = []
    /// The screen behind the person cut out — a green screen keyed, as Final Cut's Keyer. Meant for the overlay
    /// track; nil = none.
    public var chromaKey: ChromaKey?
    /// Made smaller and moved over the picture under it, as Final Cut's Transform. Meant for the overlay track;
    /// nil = as a shot, filling the frame.
    public var transform: LayerTransform?
    /// Playback speed: seconds of footage per second of the edit (2 = twice as fast, 0.5 = slow motion). The shot
    /// keeps its place and length and uses `duration · speed` of its footage from `inPoint`; its own sound follows
    /// through `AudioClip.speed`.
    public var speed = 1.0

    public var duration: Double { end - start }
    /// How much of its footage the shot uses (s of the file).
    public var footage: Double { duration * speed }
    /// Where in its footage the shot is at `time` on the edit.
    public func source(at time: Double) -> Double { inPoint + (time - start) * speed }
    /// Drawn over the picture under it (cut out, made smaller or moved) instead of covering it.
    public var cutout: Bool { (chromaKey?.on ?? false) || !(transform?.isIdentity ?? true) }
    public var flagged: Bool { !issues.isEmpty || !(note ?? "").isEmpty }

    /// The reframing at `time` on the edit: from the keys when it has them, else its fixed `scale` / `pan`.
    public func framing(at time: Double) -> (scale: Double, panX: Double, panY: Double) {
        guard let first = keys.first, let last = keys.last else { return (scale, panX, panY) }
        let t = source(at: time)
        if t <= first.t { return (first.scale, first.panX, first.panY) }
        guard let i = keys.firstIndex(where: { $0.t >= t }) else { return (last.scale, last.panX, last.panY) }
        let a = keys[i - 1], b = keys[i]
        let u = Bend.apply(b.t - a.t > 0.0001 ? (t - a.t) / (b.t - a.t) : 1, a.ease ?? 0)
        let e = u * u * (3 - 2 * u)
        return (a.scale + (b.scale - a.scale) * e, a.panX + (b.panX - a.panX) * e, a.panY + (b.panY - a.panY) * e)
    }

    /// The checkboxes in the shot window: key written to the file, Russian and English names.
    public static let issueKinds: [(key: String, ru: String, en: String)] = [
        ("face", "Лицо не похоже", "Wrong face"), ("wardrobe", "Одежда · причёска", "Wardrobe · hair"),
        ("artifacts", "Артефакты · морфинг", "Artifacts · morphing"), ("framing", "Не тот план · ракурс", "Wrong framing"),
        ("eyeline", "Взгляд · в камеру", "Eyeline · into the lens"), ("lipsync", "Губы не в синхрон", "Lip sync"),
        ("voice", "Голос · реплика", "Voice · line"), ("motion", "Фон · предметы двигаются", "Background moves"),
        ("story", "Непонятно · нет логики", "Story unclear"), ("quality", "Мыло · качество", "Soft · low quality"),
        ("redo", "Переделать целиком", "Redo the shot"),
    ]

    public enum Zoom: String, Codable, CaseIterable, Sendable {
        case none, `in`, out
        /// Scale at the start and the end of the shot.
        public var scales: (Double, Double) {
            switch self {
            case .none: return (1, 1)
            case .in: return (1, 1.07)
            case .out: return (1.07, 1)
            }
        }
    }

    enum CodingKeys: String, CodingKey { case id, start, end, src, inPoint = "in", zoom, dim, flip, scale, panX, panY, rotation, keys, label, issues, note, grade, covers, chromaKey, transform, speed }

    public init(id: String, start: Double, end: Double, src: String, inPoint: Double = 0,
                zoom: Zoom = .none, dim: Bool = false, label: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.src = src
        self.inPoint = inPoint; self.zoom = zoom; self.dim = dim; self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        src = try c.decode(String.self, forKey: .src)
        inPoint = try c.value(.inPoint, 0.0)
        zoom = try c.value(.zoom, Zoom.none)
        dim = try c.value(.dim, false)
        flip = try c.value(.flip, false)
        scale = try c.value(.scale, 1.0)
        panX = try c.value(.panX, 0.0)
        panY = try c.value(.panY, 0.0)
        rotation = try c.value(.rotation, 0.0)
        keys = try c.value(.keys, [CropKey]()).sorted { $0.t < $1.t }
        label = try c.decodeIfPresent(String.self, forKey: .label)
        issues = try c.value(.issues, [String]())
        note = try c.decodeIfPresent(String.self, forKey: .note)
        grade = try c.decodeIfPresent(Grade.self, forKey: .grade)
        covers = try c.value(.covers, [CoverZone]())
        chromaKey = try c.decodeIfPresent(ChromaKey.self, forKey: .chromaKey)
        transform = try c.decodeIfPresent(LayerTransform.self, forKey: .transform)
        speed = max(0.05, try c.value(.speed, 1.0))                  // 0 or below would never move on
    }

    /// Unmarked shots are written exactly as before (no empty `issues` in every shot).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        try c.encode(src, forKey: .src); try c.encode(inPoint, forKey: .inPoint); try c.encode(zoom, forKey: .zoom)
        try c.encode(dim, forKey: .dim); try c.encodeIfPresent(label, forKey: .label)
        if flip { try c.encode(flip, forKey: .flip) }
        if scale != 1 { try c.encode(scale, forKey: .scale) }
        if panX != 0 { try c.encode(panX, forKey: .panX) }
        if panY != 0 { try c.encode(panY, forKey: .panY) }
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if !keys.isEmpty { try c.encode(keys, forKey: .keys) }
        if !issues.isEmpty { try c.encode(issues, forKey: .issues) }
        if let note, !note.isEmpty { try c.encode(note, forKey: .note) }
        try c.encodeIfPresent(grade, forKey: .grade)
        if !covers.isEmpty { try c.encode(covers, forKey: .covers) }
        try c.encodeIfPresent(chromaKey, forKey: .chromaKey)
        try c.encodeIfPresent(transform, forKey: .transform)
        if speed != 1 { try c.encode(speed, forKey: .speed) }
    }
}

/// A screen cut out of a shot (`Shot.chromaKey`) — the steps of Final Cut's Keyer, as the reference Python keyer (v3) did,
/// worked out on the video's own pixels, before it is framed or made smaller:
/// 1. the key colour K: `color` (the pipette), else the clip's own — per channel the median of its pixels clearly the
///    screen (screen channel 0.25 above the larger of the other two; 0.12 when too few are) in every 24th of its first
///    15 s of frames, measured once per file;
/// 2. the matte (Strength): d = (screen channel − the larger of the other two) / the same of K;
///    alpha = 1 − smoothstep(low, high, d), low / high = 0.73 · (1 − `strength`) ∓ 0.185 (0.18 / 0.55 at 0.5);
/// 3. matte tools, on the alpha only: shrunk by `shrink` px (below 0: grown), then softened by a `soften`-px box;
/// 4. the edges cleaned: colour − 0.6 · (1 − alpha) · K (the screen mixed into hair taken out, no division by alpha);
/// 5. spill on the whole person: screen channel − `spill` · max(0, it − the average of the other two)
///    (for green: g → g − spill · max(0, g − (r + b) / 2) — the olive cast leaves the hair, skin and white stay).
public struct ChromaKey: Codable, Equatable, Sendable {
    /// Off keeps the settings: the video covers the picture again until it is switched back on.
    public var on = true
    /// The screen's colour, "#RRGGBB" (the pipette); its largest channel says which screen it is (green, blue or red).
    /// nil = green, measured from the clip.
    public var color: String?
    /// 0…1, how much is cut out (moves the fade: 0.5 = the reference keyer's 0.18…0.55).
    public var strength = 0.5
    /// Pixels of the video the matte is shrunk by, −3…3 (below 0 it grows).
    public var shrink = 1.0
    /// Pixels of the video the matte's edge is softened over, 0…3.
    public var soften = 1.0
    /// 0…1, how much green comes off the person (Spill Level).
    public var spill = 0.9

    enum CodingKeys: String, CodingKey { case on, color, strength, shrink, soften, spill }

    public init(on: Bool = true, color: String? = nil, strength: Double = 0.5, shrink: Double = 1, soften: Double = 1, spill: Double = 0.9) {
        self.on = on; self.color = color; self.strength = strength; self.shrink = shrink; self.soften = soften; self.spill = spill
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.value(.on, true)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        strength = try c.value(.strength, 0.5)
        shrink = try c.value(.shrink, 1.0)
        soften = try c.value(.soften, 1.0)
        spill = try c.value(.spill, 0.9)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !on { try c.encode(false, forKey: .on) }
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(strength, forKey: .strength)
        try c.encode(shrink, forKey: .shrink)
        try c.encode(soften, forKey: .soften)
        try c.encode(spill, forKey: .spill)
    }

    /// Where the fade starts and ends, as shares of the key colour's own screen excess.
    public var thresholds: (low: Double, high: Double) {
        let middle = 0.73 * (1 - min(1, max(0, strength)))
        return (middle - 0.185, middle + 0.185)
    }

    /// `color` as 0…1, or nil (found in every frame).
    public var rgb: (r: Double, g: Double, b: Double)? {
        let digits = (color ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let v = Int(digits, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// The screen's channel: 0 red, 1 green, 2 blue.
    public var channel: Int {
        guard let (r, g, b) = rgb else { return 1 }
        return g >= r && g >= b ? 1 : b >= r ? 2 : 0
    }
}

/// A video made smaller, moved and turned (`Shot.transform`): its picture as it would fill the frame (its crop included)
/// is scaled by `scale` about the frame's centre, moved by `x` / `y` stage px (1080 wide, y down) and turned by `rotation`
/// degrees clockwise about the middle of the box it then fills — framed and placed in one scale, after the key.
/// On a 1080 × 1920 frame the box is x 540·(1 − scale) + x … that + 1080·scale, y 960·(1 − scale) + y … that + 1920·scale.
public struct LayerTransform: Codable, Equatable, Sendable {
    public var scale = 1.0
    public var x = 0.0
    public var y = 0.0
    public var rotation = 0.0

    enum CodingKeys: String, CodingKey { case scale, x, y, rotation }

    public init(scale: Double = 1, x: Double = 0, y: Double = 0, rotation: Double = 0) {
        self.scale = scale; self.x = x; self.y = y; self.rotation = rotation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.value(.scale, 1.0)
        x = try c.value(.x, 0.0)
        y = try c.value(.y, 0.0)
        rotation = try c.value(.rotation, 0.0)
    }

    /// `rotation` is written only when the video is turned.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scale, forKey: .scale); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
    }

    public var isIdentity: Bool { abs(scale - 1) < 0.0005 && abs(x) < 0.01 && abs(y) < 0.01 && abs(rotation) < 0.01 }

    /// The box the picture fills before it is turned, stage px (1080 wide, y down) on a stage `height` tall.
    public func box(stageHeight height: Double = 1920) -> CGRect {
        let s = max(0.01, scale)
        return CGRect(x: 540 * (1 - s) + x, y: height / 2 * (1 - s) + y, width: 1080 * s, height: height * s)
    }

    /// Whether a stage point is on the picture as turned.
    public func contains(_ point: CGPoint, stageHeight height: Double = 1920) -> Bool {
        let b = box(stageHeight: height), a = -rotation * .pi / 180, dx = point.x - b.midX, dy = point.y - b.midY
        return abs(dx * cos(a) - dy * sin(a)) <= b.width / 2 && abs(dx * sin(a) + dy * cos(a)) <= b.height / 2
    }
}

/// A zone of a shot's footage painted over: in the footage's own frame as it is turned (0…1, top-left origin), so
/// the crop can change freely. «fill» takes the pixels from the zone's edges inward (as ffmpeg's delogo, with the
/// footage's grain), «blur» blurs it heavily; `soft` 0…1 feathers its edge.
public struct CoverZone: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var mode = "fill"
    public var soft = 0.4

    public init(x: Double, y: Double, w: Double, h: Double, mode: String = "fill", soft: Double = 0.4) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.mode = mode; self.soft = soft
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w); h = try c.decode(Double.self, forKey: .h)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "fill"
        soft = try c.decodeIfPresent(Double.self, forKey: .soft) ?? 0.4
    }
}

/// One key of a shot's moving reframe: at `t` seconds into its footage (the file's own time, so the key stays on its
/// picture when the shot is trimmed or split) the frame is `scale` / `pan` as on `Shot`.
public struct CropKey: Codable, Equatable, Sendable {
    public var t: Double
    public var scale: Double
    public var panX: Double
    public var panY: Double
    /// How the move from this key to the next one runs (`Bend`): above 0 most of it early, below 0 late; nil = even.
    public var ease: Double?

    public init(t: Double, scale: Double, panX: Double, panY: Double) {
        self.t = t; self.scale = scale; self.panX = panX; self.panY = panY
    }
}

/// An arc instead of a straight line from 0 to 1 — a fade's slope, the run between two crop keys. `bend` −1…1:
/// 0 = straight, above 0 most of the way is covered early (u^¼ at 1), below 0 late (u⁴ at −1).
public enum Bend {
    public static func apply(_ u: Double, _ bend: Double) -> Double {
        let u = min(1, max(0, u))
        guard abs(bend) > 0.001 else { return u }
        return pow(u, pow(4, -min(1, max(-1, bend))))
    }
}

// MARK: - Sound

public struct AudioClip: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case voice, music, effect }

    public var id: String
    public var role: Role = .voice
    public var src: String
    /// Where the clip begins on the edit's clock.
    public var start = 0.0
    /// Where in the source it begins.
    public var inPoint = 0.0
    /// nil = until the source (or the edit) ends.
    public var duration: Double?
    /// Linear gain: 1 = as recorded.
    public var gain = 1.0
    /// Music dips under the voice.
    public var duck = false
    /// How it dips, set by hand in the sound window; nil with `duck` on = the old automatic compressor.
    public var sidechain: Sidechain?
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    /// The fades' arcs (`Bend`): 0 = a straight slope; above 0 the sound is loud for longer and the change is sharp at
    /// the silent end, below 0 it comes up (or goes down) gently.
    public var fadeInCurve = 0.0
    public var fadeOutCurve = 0.0
    /// What the clip is, shown on the track ("h126_12 · Fifty-two, and my marriage…").
    public var label: String?
    /// What the editor marked as wrong with this sound (keys of `AudioClip.issueKinds`) and a note — for Claude.
    public var issues: [String] = []
    public var note: String?
    /// Unhooked from the picture by its pivot on the timeline: it (and its captions) stays where it is when a shot
    /// over it is moved with its sound.
    public var unlinked = false
    /// Playback speed, pitch kept: seconds of the source per second of the edit (2 = twice as fast). `duration` stays
    /// the length on the edit; it plays `duration · speed` of the source from `inPoint`. A sped shot's own sound has
    /// the shot's speed.
    public var speed = 1.0

    /// Where in its source the clip is at `time` on the edit.
    public func source(at time: Double) -> Double { inPoint + (time - start) * speed }

    public var flagged: Bool { !issues.isEmpty || !(note ?? "").isEmpty }

    /// The checkboxes in the sound window: key written to the file, Russian and English names.
    public static let issueKinds: [(key: String, ru: String, en: String)] = [
        ("glitch", "Глитч · щелчок", "Glitch · click"), ("cut", "Слово обрезано", "Word cut off"),
        ("voice", "Не тот голос", "Wrong voice"), ("sync", "Не в синхрон", "Out of sync"), ("level", "Громкость", "Level"),
        ("pause", "Лишняя пауза", "Pause too long"), ("redo", "Переозвучить", "Record again"),
    ]

    enum CodingKeys: String, CodingKey { case id, role, src, start, inPoint = "in", duration, gain, duck, sidechain, fadeIn, fadeOut, fadeInCurve, fadeOutCurve, label, issues, note, unlinked, speed }

    public init(id: String, role: Role, src: String, start: Double = 0, inPoint: Double = 0,
                duration: Double? = nil, gain: Double = 1, duck: Bool = false,
                fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.role = role; self.src = src; self.start = start; self.inPoint = inPoint
        self.duration = duration; self.gain = gain; self.duck = duck; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        role = try c.value(.role, Role.voice)
        src = try c.decode(String.self, forKey: .src)
        start = try c.value(.start, 0.0)
        inPoint = try c.value(.inPoint, 0.0)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        gain = try c.value(.gain, 1.0)
        duck = try c.value(.duck, false)
        sidechain = try c.decodeIfPresent(Sidechain.self, forKey: .sidechain)
        fadeIn = try c.value(.fadeIn, 0.0)
        fadeOut = try c.value(.fadeOut, 0.0)
        fadeInCurve = try c.value(.fadeInCurve, 0.0)
        fadeOutCurve = try c.value(.fadeOutCurve, 0.0)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        issues = try c.value(.issues, [String]())
        note = try c.decodeIfPresent(String.self, forKey: .note)
        unlinked = try c.value(.unlinked, false)
        speed = max(0.05, try c.value(.speed, 1.0))                  // 0 or below would never move on
    }

    /// Unmarked clips are written as before (no empty `issues`, no `unlinked` while hooked).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(role, forKey: .role); try c.encode(src, forKey: .src)
        try c.encode(start, forKey: .start); try c.encode(inPoint, forKey: .inPoint); try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(gain, forKey: .gain); try c.encode(duck, forKey: .duck)
        try c.encodeIfPresent(sidechain, forKey: .sidechain); try c.encode(fadeIn, forKey: .fadeIn); try c.encode(fadeOut, forKey: .fadeOut)
        if fadeInCurve != 0 { try c.encode(fadeInCurve, forKey: .fadeInCurve) }
        if fadeOutCurve != 0 { try c.encode(fadeOutCurve, forKey: .fadeOutCurve) }
        try c.encodeIfPresent(label, forKey: .label)
        if !issues.isEmpty { try c.encode(issues, forKey: .issues) }
        if let note, !note.isEmpty { try c.encode(note, forKey: .note) }
        if unlinked { try c.encode(true, forKey: .unlinked) }
        if speed != 1 { try c.encode(speed, forKey: .speed) }
    }
}

/// A sidechain on music: while anyone speaks the music goes down by `depth`, and comes back in the pauses.
public struct Sidechain: Codable, Equatable, Sendable {
    /// How far down, dB.
    public var depth = 12.0
    /// How long the music takes to go down, s — it starts that much before the voice, so the first word is clear.
    public var attack = 0.15
    /// How long it takes to come back up once the voice stops, s.
    public var release = 0.5

    public init(depth: Double = 12, attack: Double = 0.15, release: Double = 0.5) {
        self.depth = depth; self.attack = attack; self.release = release
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depth = try c.value(.depth, 12.0)
        attack = try c.value(.attack, 0.15)
        release = try c.value(.release, 0.5)
    }
}

// MARK: - Motion graphics

/// A pre-rendered scene laid over the picture: a folder of numbered PNG frames with alpha.
public struct OverlayClip: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var src: String
    public var start: Double
    public var fps = 30.0
    public var label: String?
    /// Moved by hand on the picture: stage px (1080 wide, y down) from where the scene draws itself.
    public var x: Double?
    public var y: Double?
    /// How long it stays on screen, set by hand: longer than the scene, it holds its full frame before its fade-out;
    /// shorter, it fades out sooner.
    /// nil = the scene's own length.
    public var duration: Double?
    /// Glass under the scene: the picture beneath it blurred and bent where `OverlayGlass.mask` says; nil = none.
    public var glass: OverlayGlass?

    public init(id: String, src: String, start: Double, fps: Double = 30, label: String? = nil) {
        self.id = id; self.src = src; self.start = start; self.fps = fps; self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        src = try c.decode(String.self, forKey: .src)
        start = try c.decode(Double.self, forKey: .start)
        fps = try c.value(.fps, 30.0)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        glass = try c.decodeIfPresent(OverlayGlass.self, forKey: .glass)
    }
}

/// Glass under a motion-graphics scene, as a pane of real glass: where the mask's frames are (the glass's shape, frame for
/// frame with the scene and moved with it), the picture under the scene is blurred, made a little brighter and richer,
/// and bent near the shape's edge as thick glass bends it (`Glass`); the scene's own frame goes on top.
public struct OverlayGlass: Codable, Equatable, Sendable {
    /// Folder of PNG frames like the scene's: alpha = where the glass is.
    public var mask: String
    /// Blur radius, px on a 1080-wide frame.
    public var blur = 30.0
    /// How much the picture bends at the edge: 1 = 25 px at the rim, nothing ~35 px in; 0 = flat glass.
    public var refraction = 1.0

    public init(mask: String, blur: Double = 30, refraction: Double = 1) { self.mask = mask; self.blur = blur; self.refraction = refraction }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mask = try c.decode(String.self, forKey: .mask)
        blur = try c.value(.blur, 30.0)
        refraction = try c.value(.refraction, 1.0)
    }
}

// MARK: - Captions and titles

public struct CaptionTrack: Codable, Equatable, Sendable {
    /// "s1"…"s13" — the caption styles (see CaptionStyle). Anything else uses the app's own look.
    public var style = "s5"
    public var chunks: [Chunk] = []
    /// The app's own caption look for the classic presets, kept as it saves it.
    public var legacy: JSONValue?
    /// Every caption in capitals / in italic, whatever the style.
    public var uppercase = false
    public var italic = false
    /// The accent words drawn in the style's accent; off, every word looks the same.
    public var accents = true
    /// How the plain captions (s11, s12) come in; nil = the pop.
    public var entrance: CaptionEntrance?
    /// The step between a caption's lines, × the style's own (1 = as designed).
    public var lineSpacing = 1.0

    enum CodingKeys: String, CodingKey { case style, chunks, legacy, uppercase, italic, accents, entrance, lineSpacing }

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.value(.style, "s5")
        chunks = try c.value(.chunks, [])
        legacy = try c.decodeIfPresent(JSONValue.self, forKey: .legacy)
        uppercase = try c.value(.uppercase, false)
        italic = try c.value(.italic, false)
        accents = try c.value(.accents, true)
        entrance = try c.decodeIfPresent(String.self, forKey: .entrance).flatMap(CaptionEntrance.init(rawValue:))
        lineSpacing = try c.value(.lineSpacing, 1.0)
        Project.fillIDs(&chunks, "c")
    }

    /// The settings are written only when set, so a file without them keeps its bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(chunks, forKey: .chunks)
        try c.encodeIfPresent(legacy, forKey: .legacy)
        if uppercase { try c.encode(true, forKey: .uppercase) }
        if italic { try c.encode(true, forKey: .italic) }
        if !accents { try c.encode(false, forKey: .accents) }
        if let entrance { try c.encode(entrance.rawValue, forKey: .entrance) }
        if lineSpacing != 1 { try c.encode(lineSpacing, forKey: .lineSpacing) }
    }

    public var options: CaptionOptions {
        CaptionOptions(uppercase: uppercase, italic: italic, accents: accents, entrance: entrance ?? .pop, lineSpacing: lineSpacing)
    }
}

/// What is on screen at once: 2–3 words, or a whole sentence for the two-line styles.
public struct Chunk: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var words: [ChunkWord]
    /// Starts a new paragraph. Paragraphs group captions by sentence or thought, and regrouping for
    /// another style keeps words inside their paragraph. With no chunk marked, every sentence is a
    /// paragraph (`CaptionGrouping.startsParagraph`).
    public var paragraph = false
    /// Classic styles: the whole caption drawn with the accent font, tilt and colour.
    public var emphasis = false
    /// Moved by hand on the picture: stage px (1080 wide, y down) from the style's place.
    public var x: Double?
    public var y: Double?

    enum CodingKeys: String, CodingKey { case id, start, end, words, paragraph, emphasis, x, y }

    public init(id: String, start: Double, end: Double, words: [ChunkWord], paragraph: Bool = false, emphasis: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.words = words; self.paragraph = paragraph; self.emphasis = emphasis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        words = try c.value(.words, [])
        paragraph = try c.value(.paragraph, false)
        emphasis = try c.value(.emphasis, false)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
    }

    /// `paragraph` and `emphasis` are written only when set, so a file without them keeps its bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(words, forKey: .words)
        if paragraph { try c.encode(true, forKey: .paragraph) }
        if emphasis { try c.encode(true, forKey: .emphasis) }
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(y, forKey: .y)
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// A word appears at `start`; `end` is when the voice finishes it.
public struct ChunkWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var accent = false
    /// Where the voice says the word (see `VoiceAnchor`).
    public var voice: VoiceAnchor?
    /// A film caption's line break after this word, set by hand where the automatic one would split a phrase.
    public var br: Bool?

    public init(text: String, start: Double, end: Double, accent: Bool = false, voice: VoiceAnchor? = nil) {
        self.text = text; self.start = start; self.end = end; self.accent = accent; self.voice = voice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.value(.end, start)
        accent = try c.value(.accent, false)
        voice = try c.decodeIfPresent(VoiceAnchor.self, forKey: .voice)
        br = try c.decodeIfPresent(Bool.self, forKey: .br)
    }
}

/// A caption word's place in its voice: the voice clip's file and the stretch of it (the file's own seconds), taken
/// while the word still sat on its voice. A ripple trim squeezes the word but leaves this alone, so «Пересчитать
/// по словам» can put the word back where that stretch of the file plays now.
public struct VoiceAnchor: Codable, Equatable, Sendable {
    public var src: String
    public var from: Double
    public var to: Double

    public init(src: String, from: Double, to: Double) {
        self.src = src; self.from = from; self.to = to
    }
}

public struct TitleItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "T1"…"T10" — see TitleStyle.
    public var style = "T1"
    /// "|" starts a second line.
    public var text: String
    /// Small line under the headline.
    public var kicker: String?
    public var start: Double
    public var duration = 3.6
    /// Blur the picture behind the title while it is on screen.
    public var blur = true
    /// A picture the title shows — the reviewer's photo on a Trustpilot card (T8).
    public var image: String?
    /// The reviews of a review collage (T9) or slider (T10), photos as full paths.
    public var reviews: [Review]?
    /// Moved by hand on the picture: stage px (1080 wide, y down) from its own place.
    public var x: Double?
    public var y: Double?
    /// Emoji placed on the title by hand; they appear and move with it.
    public var stickers: [Sticker]?

    public init(id: String, style: String, text: String, kicker: String? = nil,
                start: Double, duration: Double = 3.6, blur: Bool = true, image: String? = nil) {
        self.id = id; self.style = style; self.text = text; self.kicker = kicker
        self.start = start; self.duration = duration; self.blur = blur; self.image = image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        style = try c.value(.style, "T1")
        text = try c.decode(String.self, forKey: .text)
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.value(.duration, 3.6)
        blur = try c.value(.blur, true)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        reviews = try c.decodeIfPresent([Review].self, forKey: .reviews)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        stickers = try c.decodeIfPresent([Sticker].self, forKey: .stickers)
    }

    public var end: Double { start + duration }
}

/// An emoji on a title — animated when the project's emoji pack has it. Its centre is in stage px from the
/// frame's centre (540, 960), before the title's own move; it turns clockwise by `rotation` degrees.
public struct Sticker: Codable, Equatable, Sendable {
    public var emoji: String
    public var x = 0.0
    public var y = -170.0
    /// Width and height of the emoji, stage px.
    public var size = 150.0
    public var rotation = 0.0

    public init(emoji: String, x: Double = 0, y: Double = -170, size: Double = 150, rotation: Double = 0) {
        self.emoji = emoji; self.x = x; self.y = y; self.size = size; self.rotation = rotation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try c.decode(String.self, forKey: .emoji)
        x = try c.value(.x, 0.0)
        y = try c.value(.y, -170.0)
        size = try c.value(.size, 150.0)
        rotation = try c.value(.rotation, 0.0)
    }
}

/// Final loudness of the mix.
public struct MasterBus: Codable, Equatable, Sendable {
    public var loudness = -14.0
    public var truePeak = -1.5
    /// Leveller, compressor and limiter on every voice clip; nil = off.
    public var voice: VoiceChain?

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loudness = try c.value(.loudness, -14.0)
        truePeak = try c.value(.truePeak, -1.5)
        voice = try c.decodeIfPresent(VoiceChain.self, forKey: .voice)
    }
}

// MARK: - Helpers

extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when the key is missing — hand-written files may skip defaults.
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension Project {
    /// Short random id with a type prefix ("s3f9a1c") — readable in the JSON, unique enough per project.
    public static func newID(_ prefix: String) -> String {
        prefix + String(UInt32.random(in: 0...UInt32.max), radix: 16)
    }
}

/// Free-form JSON, for data one side stores and the other only carries along.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
