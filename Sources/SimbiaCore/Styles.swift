import Foundation

/// The caption looks: the five shared with the web versions (caption_styles/index.html), plain captions, and film
/// subtitles, regular and bold.
public enum CaptionLook: Int, CaseIterable, Sendable {
    case goldScript = 1, highlighter, editorial, handwritten, cleanBox, plain, film, filmBold

    /// Film subtitles either weight: small, the whole sentence at once, no animation.
    public var isFilm: Bool { self == .film || self == .filmBold }
}

/// One of the fourteen caption styles: the five web looks as 2–3-word chunks (s1–s5) or as a whole sentence on
/// two balanced lines (s6–s10), plain captions the same two ways (s11, s12), and film subtitles (s13, bold s14) —
/// small, the whole sentence at once, no animation, as a streaming service shows a film.
public struct CaptionStyle: Equatable, Identifiable, Sendable {
    public let number: Int
    public var id: String { "s\(number)" }
    public var look: CaptionLook { number == 14 ? .filmBold : number == 13 ? .film : number > 10 ? .plain : CaptionLook(rawValue: (number - 1) % 5 + 1)! }
    public var twoLine: Bool { number > 10 ? number >= 12 : number > 5 }

    public var name: String {
        guard !look.isFilm else { return look == .filmBold ? "Film Bold" : "Film" }
        let base = ["Gold Script", "Highlighter", "Editorial", "Handwritten Note", "Clean Box", "Plain"][look.rawValue - 1]
        return twoLine ? base + " · 2" : base
    }

    public var fonts: String {
        ["Montserrat + Playfair Display", "Archivo Black", "DM Sans + DM Serif Display",
         "Poppins + Caveat", "Inter Tight + Playfair Display", "Montserrat", "Inter", "Inter Bold"][look.rawValue - 1]
    }

    public init?(id: String) {
        guard id.hasPrefix("s"), let n = Int(id.dropFirst()), (1...14).contains(n) else { return nil }
        number = n
    }

    public init(number: Int) { self.number = number }

    public static let all = (1...14).map { CaptionStyle(number: $0) }
}

/// How the plain captions (s11, s12) come in: the earlier ads' pop, the same pop word by word as each is
/// said, rising from below, a plain fade, or karaoke — the whole caption pops up dimmed, the word being said
/// grows and glows, the words already said stay plain white.
public enum CaptionEntrance: String, CaseIterable, Sendable { case pop, words, rise, fade, karaoke }

/// What applies to every caption whatever the style: all capitals, italic, accent words on or off, and how
/// plain captions come in.
public struct CaptionOptions: Equatable, Sendable {
    public var uppercase = false
    public var italic = false
    public var accents = true
    public var entrance = CaptionEntrance.pop
    /// The step from one line of a caption to the next, × the style's own (two-line styles and film subtitles).
    public var lineSpacing = 1.0

    public init(uppercase: Bool = false, italic: Bool = false, accents: Bool = true, entrance: CaptionEntrance = .pop, lineSpacing: Double = 1) {
        self.uppercase = uppercase; self.italic = italic; self.accents = accents; self.entrance = entrance; self.lineSpacing = lineSpacing
    }

    /// What the words' pictures depend on (the entrance only moves them).
    public var look: String { (uppercase ? "U" : "") + (italic ? "I" : "") + (accents ? "" : "N") }
}

/// Title overlays: the lipstick ones T1–T5, T6–T7 as plain text, like the earlier ads' graphics, and the Trustpilot graphics:
/// T8 one review, T9 a collage of reviews, T10 the review slider; T11 TikTok's own text on white plates, T12 TikTok's
/// "reply to comment" bubble, T13 a pile of TikTok comments.
public struct TitleStyle: Equatable, Identifiable, Sendable {
    public let number: Int
    public var id: String { "T\(number)" }

    public var name: String {
        ["Swipe & Blur", "Lipstick Writes", "Smear Band", "Kiss Stamp", "Swatch Stack", "Plain Text", "Pill", "Trustpilot Review", "Review Collage", "Review Slider", "TikTok Text", "Comment Reply", "Comments"][number - 1]
    }

    public init?(id: String) {
        guard id.uppercased().hasPrefix("T"), let n = Int(id.dropFirst()), (1...13).contains(n) else { return nil }
        number = n
    }

    public init(number: Int) { self.number = number }

    public static let all = (1...13).map { TitleStyle(number: $0) }
}
