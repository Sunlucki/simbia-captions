import Foundation

/// The footage library's index — `_ASSETS/_index`, one JSON per clip saying what happens when and what each
/// moment is good for — and the moments it suggests for what is said over a shot: the closest match first,
/// real ambassadors before AI, moments no delivered video has used yet (`usage.json`), never one with
/// burned-in captions or marked "avoid".
public struct FootageIndex: Sendable {
    public struct Clip: Decodable, Sendable {
        public struct Person: Decodable, Sendable { public var name: String? }
        public struct Span: Decodable, Sendable { public var from: Double; public var to: Double }
        public struct Segment: Decodable, Sendable {
            public var from: Double, to: Double
            public var description: String?
            public var usable: String?
            public var action: String?
            public var product: String?
            /// The product stick's tip on screen: white, pink or not_visible (indexed from 2026-10-13).
            public var tip: String?
            public var whyAvoid: String?
        }
        /// Our own generations (`add_ours.py`): the prompt the take was made from and a sentence or two of it.
        public struct Source: Decodable, Sendable {
            public var prompt: String?
            public var summary: String?
            public var model: String?
        }
        public struct Moment: Decodable, Sendable {
            public var from: Double, to: Double
            public var tag: String
            public var note: String?
        }
        public var id: String
        public var path: String
        public var kind: String
        public var duration: Double?
        public var person: Person?
        public var character: String?
        public var aiRealism: String?
        public var burnedInText: [Span]?
        public var segments: [Segment]?
        public var bestFor: [Moment]?
        /// When it was filmed (its own metadata or a date in its name) and when it appeared in the shared library.
        public var recorded: String?
        public var added: String?
        public var source: Source?
    }

    /// Our generations by the real file they point to (links resolved): they are linked into the task folders'
    /// «Генерации», so the project's video window can show what each take was prompted to be.
    public func generationsByFile() -> [String: Clip] {
        let assets = folder.deletingLastPathComponent()
        var out: [String: Clip] = [:]
        for clip in clips where clip.source != nil { out[assets.appending(path: clip.path).resolvingSymlinksInPath().path] = clip }
        return out
    }

    struct Use: Decodable, Sendable { var video: String; var id: String; var from: Double; var to: Double }

    /// A stretch taken out of the library by hand (`hidden.json` beside the clips): a pink tip, a bad frame.
    public struct Hidden: Codable, Sendable {
        public var id: String
        public var from: Double
        public var to: Double
        public var why: String
    }

    public struct Suggestion: Identifiable, Sendable {
        public var id: String { "\(clip)@\(from)" }
        public let clip: String
        public let file: URL
        public let from: Double
        public let to: Double
        public let tag: String
        public let note: String
        /// The ambassador's name, or the AI face's description.
        public let who: String
        public let real: Bool
        /// Delivered videos that already used this moment.
        public let usedIn: [String]
    }

    /// The `_index` folder.
    public let folder: URL
    public let clips: [Clip]
    let usage: [Use]
    public private(set) var hidden: [Hidden] = []

    /// The workspace's footage index, else `_ASSETS/_index` in the project's folder or any folder above it.
    public static func find(near projectURL: URL?) -> URL? {
        if let w = Workspace.find(near: projectURL) ?? Workspace.active,
           FileManager.default.fileExists(atPath: w.footageIndex.appending(path: "clips").path) { return w.footageIndex }
        var folder = projectURL?.deletingLastPathComponent()
        while let dir = folder, dir.path != "/" {
            for candidate in [dir.appending(path: "_ASSETS/_index"), dir.appending(path: "_index")]
            where FileManager.default.fileExists(atPath: candidate.appending(path: "clips").path) {
                return candidate
            }
            folder = dir.deletingLastPathComponent()
        }
        return nil
    }

    public static func load(_ folder: URL) throws -> FootageIndex {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let files = try FileManager.default.contentsOfDirectory(at: folder.appending(path: "clips"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
        let clips = files.compactMap { try? decoder.decode(Clip.self, from: Data(contentsOf: $0)) }
        let usage = (try? decoder.decode([Use].self, from: Data(contentsOf: folder.appending(path: "usage.json")))) ?? []
        var index = FootageIndex(folder: folder, clips: clips, usage: usage)
        index.hidden = (try? JSONDecoder().decode([Hidden].self, from: Data(contentsOf: folder.appending(path: "hidden.json")))) ?? []
        return index
    }

    /// The best `count` moments for `text` over a shot of `length` seconds, one per clip, none from a file in `taken`.
    public func suggest(for text: String, length: Double, taken: Set<String>, count: Int = 3) -> [Suggestion] {
        let said = Self.tokens(text)
        let wanted = Self.tags(for: said)
        let assets = folder.deletingLastPathComponent()
        var best: [String: (score: Double, suggestion: Suggestion)] = [:]
        for clip in clips where Self.usableKinds.contains(clip.kind) {
            let file = assets.appending(path: clip.path)
            guard !taken.contains(file.path) else { continue }
            guard Self.allowed(clip.path) else { continue }
            for m in clip.bestFor ?? [] {
                guard !(clip.burnedInText ?? []).contains(where: { $0.from < m.to && $0.to > m.from }) else { continue }
                let segments = (clip.segments ?? []).filter { $0.from < m.to && $0.to > m.from }
                guard !segments.contains(where: { $0.usable == "avoid" || Self.pinkTip($0) }), !isHidden(clip.id, m.from, m.to) else { continue }
                let described = Self.tokens(([m.note ?? ""] + segments.map { $0.description ?? "" }).joined(separator: " "))
                let shared = Double(said.filter { $0.count > 3 && described.contains($0) }.count)
                let tag = wanted[m.tag] ?? 0
                guard tag > 0 || shared > 0 else { continue }
                let used = Array(Set(usage.filter { $0.id == clip.id && $0.from < m.to && $0.to > m.from }.map(\.video))).sorted()
                var score = tag * 10 + shared * 2 + Double(segments.filter { $0.usable == "great" }.count)
                score -= Double(used.count) * 4
                if clip.kind != "real_ambassador" { score -= 5 }          // real people before AI
                score -= clip.aiRealism == "low" ? 6 : clip.aiRealism == "medium" ? 1 : 0
                if (clip.duration ?? m.to) - m.from < length { score -= 4 }          // too short: it would be slowed down
                guard score > (best[clip.id]?.score ?? -.infinity) else { continue }
                best[clip.id] = (score, Suggestion(clip: clip.id, file: file, from: m.from, to: m.to, tag: m.tag, note: m.note ?? "",
                                                   who: clip.person?.name ?? clip.character ?? "", real: clip.kind == "real_ambassador",
                                                   usedIn: used))
            }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(count).map(\.suggestion)
    }

    static let usableKinds: Set<String> = ["real_ambassador", "ai_generated", "stock", "product_still"]

    /// Not another creator's TikTok, nothing set aside.
    static func allowed(_ path: String) -> Bool {
        let p = path.lowercased()
        return !p.contains("do not use") && !p.contains("ssstik")
    }

    /// House rule: the product stick is shown with its white (clear) tip only — never a pink one.
    static func pinkTip(_ segment: Clip.Segment) -> Bool {
        if segment.tip == "pink" { return true }
        guard let text = segment.description?.lowercased() else { return false }
        return ["pink tint", "pinkish stick", "pink stick", "pink-tinted stick", "clear/pink stick", "pink tip", "pink bullet", "stick is pink"]
            .contains { text.contains($0) } && (segment.product ?? Brand.current.key) == Brand.current.key   // not someone's own pink lipstick
    }

    // MARK: The gallery

    /// What a moment shows, as the gallery groups them.
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case applying, tube, lips, smile, talking, pain, otherBrands, product, broll
        public var id: String { rawValue }

        static func of(_ action: String?) -> Category {
            switch action ?? "" {
            case "applying_lipstick", Brand.current.applyingTag: return .applying
            case "showing_tube_to_camera", "holding_two_tubes", "two_tubes_bogo", "unboxing": return .tube
            case "lips_closeup", "color_change_reveal", "color_develops_on_lips", "before_after", "kiss_or_blot_test", "swatch": return .lips
            case "smiling_result": return .smile
            case "talking": return .talking
            case "dry_or_cracked_lips", "frustrated", "pain_transfer_smear": return .pain
            case "drawer_or_many_lipsticks", "other_brand_lipstick": return .otherBrands
            case "product_only": return .product
            default: return .broll
            }
        }
    }

    /// The gallery's category for what is said: the strongest of the index's tags the words point to.
    public static func category(for text: String) -> Category {
        let wanted = tags(for: tokens(text))
        guard let tag = wanted.max(by: { $0.value < $1.value })?.key else { return .tube }
        switch tag {
        case "lips_closeup_result", "color_develops_on_lips", "no_transfer_test", "long_lasting_proof", "hydration_soft_lips": return .lips
        case "pain_drawer_full", "pain_wrong_shade", "shopping_store": return .otherBrands
        case let t where t.hasPrefix("pain_"): return .pain
        case Brand.current.applyingTag: return .applying
        case "happy_result_smile", "mature_woman_confident", "lifestyle_brunch_date", "mirror_check": return .smile
        case "product_hero", "ingredients": return .product
        case "skeptic_before", "phone_scrolling_reviews": return .talking
        default: return .tube
        }
    }

    /// One stretch of a clip for the gallery.
    public struct Moment: Identifiable, Sendable {
        public var id: String { "\(clip)@\(from)" }
        public let clip: String
        public let file: URL
        public let from: Double
        public let to: Double
        public let category: Category
        public let description: String
        /// The ambassador's name, or the AI face's description.
        public let who: String
        /// real_ambassador, ai_generated, stock, product_still.
        public let kind: String
        public let great: Bool
        /// Delivered videos that already used this moment.
        public let usedIn: [String]
        /// How recent the footage is: filmed, else put on the Drive (yyyy-mm-dd).
        public let date: String?
    }

    func isHidden(_ clip: String, _ from: Double, _ to: Double) -> Bool {
        hidden.contains { $0.id == clip && $0.from < to && $0.to > from }
    }

    /// Takes a moment out of the library for good (written to `hidden.json`).
    public mutating func hide(_ moment: Moment, why: String) throws {
        hidden.append(Hidden(id: moment.clip, from: moment.from, to: moment.to, why: why))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(hidden).write(to: folder.appending(path: "hidden.json"), options: .atomic)
    }

    /// Every usable moment of the library: not marked "avoid", no burned-in text, no pink tip, nothing set aside —
    /// the best first within each clip's order.
    public func moments() -> [Moment] {
        let assets = folder.deletingLastPathComponent()
        var out: [Moment] = []
        // a library may keep a file in two folders: show one copy, the «No Caption» one (no burnt-in captions)
        var seen = Set<String>()
        let ordered = clips.sorted { ($0.path.contains("No Caption") ? 0 : 1, $0.path) < ($1.path.contains("No Caption") ? 0 : 1, $1.path) }
        for clip in ordered where Self.usableKinds.contains(clip.kind) && Self.allowed(clip.path) {
            guard seen.insert((clip.path as NSString).lastPathComponent + "|\(Int((clip.duration ?? 0) * 10))").inserted else { continue }
            let file = assets.appending(path: clip.path)
            for s in clip.segments ?? [] where s.usable != "avoid" && !Self.pinkTip(s) && s.to - s.from >= 0.8 && !isHidden(clip.id, s.from, s.to) {
                guard !(clip.burnedInText ?? []).contains(where: { $0.from < s.to && $0.to > s.from }) else { continue }
                let used = Array(Set(usage.filter { $0.id == clip.id && $0.from < s.to && $0.to > s.from }.map(\.video))).sorted()
                out.append(Moment(clip: clip.id, file: file, from: s.from, to: s.to, category: Category.of(s.action),
                                  description: s.description ?? "", who: clip.person?.name ?? clip.character ?? "", kind: clip.kind,
                                  great: s.usable == "great", usedIn: used, date: clip.recorded ?? clip.added))
            }
        }
        return out
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// What is said, as the index's tags: the words that point to each kind of moment, English and Russian.
    /// A stem matches the start of a word; one ending in "." only the whole word.
    static func tags(for words: Set<String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for (stems, tag, weight) in rules where words.contains(where: { w in
            stems.contains { $0.hasSuffix(".") ? w == String($0.dropLast()) : w.hasPrefix($0) }
        }) {
            out[tag] = max(out[tag] ?? 0, weight)
        }
        return out
    }

    static let rules: [(stems: [String], tag: String, weight: Double)] = [
        // "until I found it": a close-up of beautiful lips once the lipstick is on
        (["found", "find", "discover", "finally", "нашл", "нашёл", "нашел", "наконец"], "lips_closeup_result", 1),
        (["found", "find", "discover"], "color_develops_on_lips", 0.6),
        (["lips.", "lip."], "lips_closeup_result", 0.6),
        (["губ"], "lips_closeup_result", 0.8),
        (["dry", "crack", "flaky", "peel", "chapped", "сух", "трескал", "шелуш"], "pain_dry_cracked_lips", 1),
        (["bleed", "feather", "line", "wrinkl", "creas", "settl", "морщин", "растека"], "pain_bleeding_lines", 1),
        (["orange", "wrong", "clash", "washed"], "pain_wrong_shade", 0.8),
        (["drawer", "collection", "dozens", "tried", "bought", "ящик", "коллекц", "перепробова"], "pain_drawer_full", 1),
        (["smear", "transfer", "cup.", "cups.", "mask", "смаз", "отпечат", "чашк"], "pain_transfer_smear", 0.8),
        (["transfer", "cup.", "kiss", "budge", "поцелу"], "no_transfer_test", 0.6),
        (["reappl", "touch", "fade", "wore.", "подкраш", "стира"], "pain_reapplying", 0.8),
        (["hours", "lasting", "lasts", "stays", "all-day", "часов", "держит"], "long_lasting_proof", 0.8),
        // in these ads "your shade" is what the lipstick finds, not a pain
        (["color", "colour", "shade", "change", "adapt", "react", "custom", "unique", "цвет", "оттен", "меняе", "подстра"], "color_develops_on_lips", 1),
        (["apply", "applie", "swipe", "glide", "нанос", "нанес"], Brand.current.applyingTag, 0.7),
        (["tube", "stick.", "flake", "gold", "lipstick", "помад", "тюбик", "золот"] + (Brand.current.name.isEmpty ? [] : [Brand.current.name.lowercased()]),
         Brand.current.tubeTag, 0.6),
        (["two.", "bogo", "free.", "second", "deal.", "deals.", "две.", "бесплат", "втор"], "two_tubes_bogo", 1),
        (["box.", "package", "arriv", "unbox", "mail.", "order", "коробк", "посылк", "заказ"], "unboxing_package", 1),
        (["hydrat", "moistur", "soft", "balm", "smooth", "nourish", "plump", "увлаж", "мягк", "бальзам"], "hydration_soft_lips", 1),
        (["confiden", "age.", "older", "mature", "years", "50s", "60s", "уверен", "возраст"], "mature_woman_confident", 0.8),
        (["smile", "smiling", "love", "happy", "compliment", "obsess", "beautiful", "gorgeous", "улыб", "люблю", "счаст", "комплимент", "красив"], "happy_result_smile", 0.8),
        (["mirror", "зеркал"], "mirror_check", 1),
        (["store", "shop", "aisle", "sephora", "магазин"], "shopping_store", 1),
        (["review", "scroll", "online", "tiktok", "comment", "отзыв", "листа"], "phone_scrolling_reviews", 1),
        (["ingredient", "natural", "wax.", "oil.", "oils.", "vitamin", "состав", "натурал", "масл"], "ingredients", 1),
        (["brunch", "date.", "dates.", "dinner", "party", "wedding", "свидан", "ужин", "вечерин"], "lifestyle_brunch_date", 1),
        (["skeptic", "doubt", "believe", "thought", "figured", "hype", "gimmick", "scam", "honestly", "сомнева", "думала"], "skeptic_before", 0.8),
        (["product", "signature"], "product_hero", 0.6),
    ]
}
