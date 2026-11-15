import AppKit
import Foundation

/// One character placed relative to the caption's centre.
struct Glyph {
    let text: String
    let dx: Double
    let dy: Double
}

/// Everything the ASS writer needs to place a caption and its parts.
struct CaptionLayout {
    let centre: CGPoint
    let box: CGSize
    /// Width of the text itself, without the backplate padding.
    let textWidth: Double
    let glyphs: [Glyph]
    let size: Double
}

/// Builds the .ass script that ffmpeg burns in.
///
/// Layout is anchored with `\an5\pos(...)`: libass centres both the text and the backplate
/// drawing on that point, so they scale and rotate as one. The backplate is a `\p1` rounded
/// rectangle rather than BorderStyle=3, because an opaque box has square corners.
extension Job {

    // MARK: Script

    func makeASS() -> String {
        var script = assHeader()
        for cue in exportCues {
            let body = displayText(cue.text)
            guard !body.isEmpty else { continue }
            script += dialogues(for: cue, body: body).joined(separator: "\n") + "\n"
        }
        return script
    }

    func displayText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return look.uppercase ? trimmed.uppercased() : trimmed
    }

    private func assHeader() -> String {
        let playW = Int(videoSize.width.rounded())
        let playH = Int(videoSize.height.rounded())
        let text = look.textColor.assColor ?? "&H00FFFFFF"
        let outline = look.outlineOn ? (look.outlineColor.assColor ?? "&H00000000") : "&H00000000"
        let shadow = look.shadowColor.assColor ?? "&H00000000"
        let fill = look.fillColor.assColor ?? text
        let bord = look.outlineOn ? look.outlineWidth * fontSize : 0
        let shad = look.shadowOn ? look.shadowDepth * fontSize : 0
        let plateShad = look.fillShadow ? look.shadowDepth * fontSize : 0
        let spacing = look.tracking * fontSize
        let accentText = (look.accentColorOn ? look.accentColor.assColor : nil) ?? text

        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(playW)
        PlayResY: \(playH)
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        YCbCr Matrix: None

        [V4+ Styles]
        Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
        Style: Text,\(look.font),\(Int(fontSize)),\(text),\(text),\(outline),\(shadow),\(look.bold ? -1 : 0),\(look.italic ? -1 : 0),0,0,100,100,\(fmt(spacing)),0,1,\(fmt(bord)),\(fmt(shad)),5,0,0,0,1
        Style: Accent,\(look.accentFont),\(Int(fontSize(accent: true))),\(accentText),\(accentText),\(outline),\(shadow),\(look.bold ? -1 : 0),\(look.italic ? -1 : 0),0,0,100,100,\(fmt(spacing * look.accentScale)),0,1,\(fmt(bord * look.accentScale)),\(fmt(shad * look.accentScale)),5,0,0,0,1
        Style: Plate,\(look.font),\(Int(fontSize)),\(fill),\(fill),\(fill),\(shadow),0,0,0,0,100,100,0,0,1,0,\(fmt(plateShad)),5,0,0,0,1

        [Events]
        Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text

        """
    }

    // MARK: Dialogue emission

    /// A cue becomes an entrance-and-hold event plus, when an exit is chosen, a second event
    /// over its tail. Two events rather than one is what allows any entrance to pair with any
    /// exit: `\move` may appear only once per event.
    private func dialogues(for cue: Cue, body: String) -> [String] {
        let layout = layout(for: body, accent: cue.accent)
        let duration = max(0.05, cue.end - cue.start)

        guard look.animationsOn else { return staticLines(cue: cue, layout: layout, body: body) }

        let exit = outro.length(of: duration)
        let holdEnd = cue.end - exit
        let holdLength = max(0.05, holdEnd - cue.start)
        // With a dedicated exit event the entrance must not fade out on its own.
        let fadeOut = exit > 0 ? 0 : Int(min(120, max(40, duration * 1000 * 0.18)))

        var lines: [String] = []
        if let plate = plateShape(layout) {
            lines.append(event(layer: 0, cue: cue, style: "Plate",
                               override: "\\an5" + accentTag(cue.accent) + animation.plateMotion(
                                   centre: layout.centre, layout: layout,
                                   duration: holdLength, job: self, fadeOut: fadeOut) + "\\p1",
                               body: plate, end: holdEnd))
        }
        lines += animation.textLines(cue: cue, layout: layout, duration: holdLength, job: self,
                                     end: holdEnd, fadeOut: fadeOut)

        guard exit > 0 else { return lines }

        let ms = Int(exit * 1000)
        if let plate = plateShape(layout) {
            lines.append(event(layer: 0, cue: cue, style: "Plate",
                               override: "\\an5" + accentTag(cue.accent) + outro.plateMotion(
                                   centre: layout.centre, layout: layout,
                                   milliseconds: ms, job: self) + "\\p1",
                               body: plate, start: holdEnd))
        }
        lines += outro.textLines(cue: cue, layout: layout, seconds: exit, job: self, start: holdEnd)
        return lines
    }

    /// Master switch off: the caption is simply on screen for its whole cue.
    private func staticLines(cue: Cue, layout: CaptionLayout, body: String) -> [String] {
        let accent = accentTag(cue.accent)
        let glow = look.glow > 0 ? "\\blur\(fmt(look.glow))" : ""
        let anchorX = look.alignment.anchorX(centre: layout.centre.x, width: layout.textWidth)
        var lines: [String] = []
        if let plate = plateShape(layout) {
            lines.append(event(layer: 0, cue: cue, style: "Plate",
                               override: "\\an5\\pos(\(fmt(layout.centre.x)),\(fmt(layout.centre.y)))\\p1",
                               body: plate))
        }
        lines.append(event(layer: 1, cue: cue, style: styleName(accent: cue.accent),
                           override: "\\an\(look.alignment.assAnchor)" + accent
                               + "\\pos(\(fmt(anchorX)),\(fmt(layout.centre.y)))" + glow,
                           body: Job.escapeASS(body)))
        return lines
    }

    private func plateShape(_ layout: CaptionLayout) -> String? {
        guard look.fillOn, look.fillColor.assColor != nil else { return nil }
        return Self.roundedRect(width: layout.box.width, height: layout.box.height,
                                radius: layout.size * Plate.radius) + "{\\p0}"
    }

    func event(layer: Int, cue: Cue, style: String, override: String, body: String,
               start: Double? = nil, end: Double? = nil) -> String {
        "Dialogue: \(layer),\(stamp(start ?? cue.start)),\(stamp(end ?? cue.end)),\(style),,0,0,0,,{\(override)}\(body)"
    }

    // MARK: Layout

    /// Measures the caption with the same font the burn-in uses, and records where every
    /// character sits so per-character presets can address them individually.
    func layout(for text: String, accent: Bool = false) -> CaptionLayout {
        let font = nsFont(accent: accent)
        let size = fontSize(accent: accent)
        let spacing = look.tracking * size
        let lines = text.components(separatedBy: "\n")
        let lineHeight = font.ascender - font.descender

        var widths: [Double] = []
        var perLine: [[(String, Double)]] = []
        for line in lines {
            var cursor = 0.0
            var glyphs: [(String, Double)] = []
            let characters = Array(line)
            for index in characters.indices {
                let prefix = String(characters[0...index])
                let previous = index == 0 ? 0 : Self.width(String(characters[0..<index]), font: font)
                let advance = Self.width(prefix, font: font) - previous
                glyphs.append((String(characters[index]), cursor + advance / 2))
                cursor += advance + spacing
            }
            widths.append(cursor)
            perLine.append(glyphs)
        }

        let textWidth = widths.max() ?? 0
        let textHeight = lineHeight * Double(max(1, lines.count))
        let box = CGSize(width: textWidth + size * Plate.padX * 2,
                         height: textHeight + size * Plate.padY * 2)

        var glyphs: [Glyph] = []
        for (row, line) in perLine.enumerated() {
            let lineWidth = widths[row]
            let originX = -lineWidth / 2
            let originY = lineHeight * (Double(row) - Double(perLine.count - 1) / 2)
            for (character, dx) in line where !character.trimmingCharacters(in: .whitespaces).isEmpty {
                glyphs.append(Glyph(text: character, dx: originX + dx, dy: originY))
            }
        }

        return CaptionLayout(centre: centre(box: box), box: box, textWidth: textWidth,
                             glyphs: glyphs, size: size)
    }

    /// The user's anchor is the bottom-left / bottom-centre / bottom-right of the caption;
    /// `\an5` needs the centre. EditorView mirrors this maths for the preview.
    private func centre(box: CGSize) -> CGPoint {
        let anchorX = look.posX * videoSize.width
        let anchorY = look.posY * videoSize.height
        let dx: Double
        switch look.alignment {
        case .left: dx = box.width / 2
        case .center: dx = 0
        case .right: dx = -box.width / 2
        }
        return CGPoint(x: anchorX + dx, y: anchorY - box.height / 2)
    }

    /// libass takes an integer Fontsize, so everything measured here must use the same value.
    var fontSize: Double { look.size.rounded() }

    func fontSize(accent: Bool) -> Double {
        (accent ? look.size * look.accentScale : look.size).rounded()
    }

    /// ASS style name for a cue — emphasis gets its own style block.
    func styleName(accent: Bool) -> String { accent ? "Accent" : "Text" }

    /// The static tilt that marks an emphasised caption. Placed before the animation tags so a
    /// preset that animates rotation (SHAKE) still owns `\frz`.
    func accentTag(_ accent: Bool) -> String {
        accent && look.accentAngle != 0 ? "\\frz\(fmt(look.accentAngle))" : ""
    }

    func nsFont(accent: Bool = false) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if look.bold { traits.insert(.bold) }
        if look.italic { traits.insert(.italic) }
        let size = fontSize(accent: accent)
        let family = accent ? look.accentFont : look.font
        let base = NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func width(_ text: String, font: NSFont) -> Double {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Drawing + escaping

    /// Rounded rectangle in ASS drawing commands. Coordinates must be non-negative — libass
    /// derives a drawing's bounding box from the origin, so a path using negative values ends
    /// up anchored by its far corner instead of its centre.
    static func roundedRect(width: Double, height: Double, radius: Double) -> String {
        let w = max(2, width), h = max(2, height)
        let r = max(0, min(radius, min(w, h) / 2))
        func n(_ value: Double) -> String { String(format: "%.1f", value) }
        return [
            "m \(n(r)) 0", "l \(n(w - r)) 0",
            "b \(n(w)) 0 \(n(w)) 0 \(n(w)) \(n(r))",
            "l \(n(w)) \(n(h - r))",
            "b \(n(w)) \(n(h)) \(n(w)) \(n(h)) \(n(w - r)) \(n(h))",
            "l \(n(r)) \(n(h))",
            "b 0 \(n(h)) 0 \(n(h)) 0 \(n(h - r))",
            "l 0 \(n(r))",
            "b 0 0 0 0 \(n(r)) 0",
        ].joined(separator: " ")
    }

    /// `{` would open an override block, so it has to be escaped; newlines become hard breaks.
    static func escapeASS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\u{200B}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }
}

func fmt(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}

/// ASS override colour literal: `&HBBGGRR&` — reversed from RGB, and no alpha byte.
func assOverrideColor(_ hex: String) -> String {
    guard let (r, g, b) = hex.rgb255 else { return "&HFFFFFF&" }
    return String(format: "&H%02X%02X%02X&", b, g, r)
}

/// Small deterministic hash so "random" scatter is stable between preview and export,
/// and between two exports of the same project.
func stableNoise(_ seed: Int) -> Double {
    var x = UInt64(bitPattern: Int64(seed &* 2_654_435_761))
    x ^= x >> 33; x = x &* 0xFF51_AFD7_ED55_8CCD
    x ^= x >> 33; x = x &* 0xC4CE_B9FE_1A85_EC53
    x ^= x >> 33
    return Double(x % 10_000) / 10_000
}
