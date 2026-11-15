import CoreGraphics
import CoreText
import Foundation

/// The caption styles drawn natively, rule for rule as the web versions (Reference/overlay_ref.html):
/// the same fonts, sizes in em, flex layout, keyframes and timing functions.
enum CaptionPainter {
    static let stageWidth = 1080.0
    static let base = stageWidth * 0.072            // 7.2cqw
    static let fill = 0.8, maxScale = 1.7
    static let left = stageWidth * 0.1, room = stageWidth * 0.8

    // MARK: Word looks

    /// How a word is set in a look: font, size in em of the caption size, and box metrics in em of its own size.
    struct Setting {
        var face: FontLibrary.Face
        var em: Double
        var uppercase = false
        var letterSpacing = 0.0
        /// × own size; nil = `normal` — the `font:` shorthand in every look resets line-height to normal.
        var lineHeight: Double? = nil
        var padX = 0.0, padTop = 0.0, padBottom = 0.0
    }

    static func setting(_ look: CaptionLook, accent: Bool) -> Setting {
        switch (look, accent) {
        case (.goldScript, false): return Setting(face: .montserrat800, em: 1)
        case (.goldScript, true): return Setting(face: .playfairItalic800, em: 1.38, letterSpacing: -0.01)
        case (.highlighter, false): return Setting(face: .archivoBlack, em: 0.92, uppercase: true, letterSpacing: 0.01)
        case (.highlighter, true): return Setting(face: .archivoBlack, em: 1.12, uppercase: true, letterSpacing: 0.01, padX: 0.16)
        case (.editorial, false): return Setting(face: .dmSans700, em: 0.96, padBottom: 0.06)
        case (.editorial, true): return Setting(face: .dmSerifItalic, em: 1.42, padX: 0.02, padBottom: 0.06)
        case (.handwritten, false): return Setting(face: .poppins700, em: 0.9)
        case (.handwritten, true): return Setting(face: .caveat700, em: 1.55, lineHeight: 0.9)
        case (.cleanBox, false): return Setting(face: .interTight800, em: 0.9, lineHeight: 1.25, padX: 0.28, padTop: 0.14, padBottom: 0.14)
        case (.cleanBox, true): return Setting(face: .playfairItalic800, em: 1.08, padX: 0.32, padTop: 0.1, padBottom: 0.1)   // its own font: shorthand resets 1.25 to normal
        case (.plain, let accent): return Setting(face: .montserrat800, em: accent ? 1.22 : 1)                            // the accent only a little larger
        case (.film, _): return Setting(face: .inter600, em: 1)                                                          // no accent: every word alike
        case (.filmBold, _): return Setting(face: .inter700, em: 1)
        }
    }

    static func gap(_ look: CaptionLook) -> Double { look == .cleanBox ? 0.14 : 0.26 }
    static func rowGap(_ look: CaptionLook) -> Double { look == .cleanBox ? 0.08 : 0.12 }

    // MARK: Layout

    struct Word {
        let text: String
        let start: Double
        let accent: Bool
        let size: Double             // own font size, px
        let run: TextRun
        let box: CGRect              // border box at rest, stage px
        let baseline: Double         // stage y of the baseline
        let textX: Double            // stage x where the text starts
        let lineHeight: Double       // the word's line box, px
    }

    struct Layout {
        /// How plain captions come in (the other looks keep their own entrances).
        var entrance = CaptionEntrance.pop
        /// When the caption comes up and goes (karaoke shows every word from `appear`, the last one lit until `end`).
        var appear = 0.0, end = Double.infinity
        var words: [Word]
        let size: Double             // the caption's font size (1em)
        let look: CaptionLook
        /// Identity for the sprite cache (set by the renderer).
        var key = ""
    }

    /// The face at `size`, slanted 12° when every caption is set in italic and the face stands upright.
    private static func font(_ s: Setting, size: Double, italic: Bool) -> CTFont {
        let font = FontLibrary.font(s.face, size: size)
        guard italic, !s.face.file.contains("Italic"), s.face != .caveat700 else { return font }
        var slant = CGAffineTransform(a: 1, b: 0, c: tan(12 * .pi / 180), d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, size, &slant, nil)
    }

    /// Width of a word's box at caption size `size`, as the browser lays it out.
    private static func boxWidth(_ text: String, _ s: Setting, size: Double, italic: Bool) -> Double {
        let own = size * s.em
        let run = TextRun(s.uppercase ? text.uppercased() : text, font: font(s, size: own, italic: italic), letterSpacing: s.letterSpacing * own)
        return run.width + 2 * s.padX * own
    }

    /// The caption laid out in its style, with the track's settings: all capitals, italic; the plain captions
    /// come up whole (every word from the caption's start) unless they come in word by word.
    static func layout(_ chunk: Chunk, style: CaptionStyle, options: CaptionOptions = CaptionOptions()) -> Layout {
        let look = style.look, italic = options.italic
        let words = chunk.words.map { w in
            var w = w
            if options.uppercase { w.text = w.text.uppercased() }
            if !options.accents { w.accent = false }
            return w
        }
        // karaoke: every word gets room to grow without touching its neighbours
        let spread = look == .plain && options.entrance == .karaoke ? karaokeGrow : 0
        var made: Layout
        if look.isFilm {
            made = filmLines(words, look: look, italic: italic, spacing: options.lineSpacing)
        } else if style.twoLine {
            made = twoLines(words, look: look, italic: italic, spread: spread, spacing: options.lineSpacing)
        } else {
            // fit(): natural width at the base size (offsetWidth is whole px), then scale to 80% of the frame
            let nat = words.reduce(0.0) { $0 + (boxWidth($1.text, setting(look, accent: $1.accent), size: base, italic: italic) * (1 + spread)).rounded() }
                + gap(look) * base * Double(max(0, words.count - 1))
            let size = nat > 0 ? min(base * maxScale, base * room / nat) : base
            made = Layout(words: row(words, look: look, size: size, top: 1920 * 0.70, italic: italic, spread: spread), size: size, look: look)
        }
        made.entrance = options.entrance
        made.appear = chunk.start; made.end = chunk.end
        // film subtitles are always there whole; word by word and karaoke keep each word's own start
        guard look.isFilm || (look == .plain && options.entrance != .words && options.entrance != .karaoke) else { return made }
        made.words = made.words.map { Word(text: $0.text, start: chunk.start, accent: $0.accent, size: $0.size, run: $0.run, box: $0.box,
                                           baseline: $0.baseline, textX: $0.textX, lineHeight: $0.lineHeight) }
        return made
    }

    /// A flex row with align-items: baseline, centred in the 80% box. `spread` widens each word's slot by that share of
    /// its width (the word centred in it) — room for karaoke's growing word.
    private static func row(_ words: [ChunkWord], look: CaptionLook, size: Double, top: Double, italic: Bool, spread: Double = 0) -> [Word] {
        let gap = gap(look) * size
        struct Item { let w: ChunkWord; let s: Setting; let run: TextRun; let own: Double; let width: Double; let above: Double; let height: Double; let line: Double }
        let items: [Item] = words.map { w in
            let s = setting(look, accent: w.accent)
            let own = size * s.em
            let font = font(s, size: own, italic: italic)
            let run = TextRun(s.uppercase ? w.text.uppercased() : w.text, font: font, letterSpacing: s.letterSpacing * own)
            // Blink rounds the font's ascent, descent and line gap; `normal` is their sum
            let ascent = run.ascent.rounded(), descent = run.descent.rounded()
            let line = s.lineHeight.map { $0 * own } ?? (ascent + descent + CTFontGetLeading(font).rounded())
            let half = (line - (ascent + descent)) / 2
            return Item(w: w, s: s, run: run, own: own, width: run.width + 2 * s.padX * own,
                        above: s.padTop * own + half + ascent,
                        height: (s.padTop + s.padBottom) * own + line, line: line)
        }
        let total = items.reduce(0) { $0 + $1.width * (1 + spread) } + gap * Double(max(0, items.count - 1))
        let maxAbove = items.map(\.above).max() ?? 0
        var x = left + (room - total) / 2
        var out: [Word] = []
        for item in items {
            let boxTop = top + maxAbove - item.above, inset = item.width * spread / 2
            let box = CGRect(x: x + inset, y: boxTop, width: item.width, height: item.height)
            out.append(Word(text: item.w.text, start: item.w.start, accent: item.w.accent, size: item.own, run: item.run,
                            box: box, baseline: top + maxAbove, textX: x + inset + item.s.padX * item.own, lineHeight: item.line))
            x += item.width * (1 + spread) + gap
        }
        return out
    }

    /// The row's height (flex line cross size) for stacking the two lines.
    private static func rowHeight(_ row: [Word], look: CaptionLook) -> Double {
        guard let first = row.first else { return 0 }
        let baseline = first.baseline
        let top = row.map { $0.box.minY }.min() ?? baseline
        let bottom = row.map { $0.box.maxY }.max() ?? baseline
        return bottom - top
    }

    /// Two balanced lines: the break that makes the longer line shortest; one size for both.
    private static func twoLines(_ words: [ChunkWord], look: CaptionLook, italic: Bool, spread: Double = 0, spacing: Double = 1) -> Layout {
        func width(_ ws: ArraySlice<ChunkWord>, _ size: Double) -> Double {
            ws.reduce(0.0) { $0 + boxWidth($1.text, setting(look, accent: $1.accent), size: size, italic: italic) * (1 + spread) } + gap(look) * size * Double(max(0, ws.count - 1))
        }
        var best = (k: words.count, widest: Double.infinity)
        if words.count > 1 {
            for k in 1..<words.count {
                let widest = max(width(words[..<k], base).rounded(), width(words[k...], base).rounded())
                if widest < best.widest - 0.01 { best = (k, widest) }
            }
        } else {
            best = (1, width(words[...], base).rounded())
        }
        let size = best.widest > 0 ? min(base * maxScale, base * room / best.widest) : base
        let lines = words.count > 1 ? [Array(words[..<best.k]), Array(words[best.k...])] : [words]
        var top = 1920 * 0.66
        var out: [Word] = []
        for line in lines where !line.isEmpty {
            let placed = row(line, look: look, size: size, top: top, italic: italic, spread: spread)
            out += placed
            top += (rowHeight(placed, look: look) + rowGap(look) * size) * spacing
        }
        return Layout(words: out, size: size, look: look)
    }

    /// Film subtitles' size, px on the 1080-wide stage — about half the other styles', like a streaming service's.
    static let filmSize = 48.0

    /// Words a subtitle line should not end on (an article, a preposition, a conjunction hangs without its word)…
    private static let clinging: Set<String> = ["a", "an", "the", "my", "your", "her", "his", "their", "our", "its", "this",
        "these", "those", "to", "of", "in", "on", "at", "for", "with", "from", "into", "and", "but", "or", "i", "i'm"]
    /// …and words a second line reads well starting with.
    private static let joining: Set<String> = ["and", "but", "or", "so", "because", "that", "which", "who", "when", "while",
        "if", "with", "to", "in", "on", "at", "of", "for", "from", "like", "into", "over", "after", "before", "as", "than", "until"]
    private static let leading: Set<String> = ["the", "a", "an", "my", "your", "her", "his", "their", "our", "this", "these", "those"]
    /// A number stays with what it counts («the ninety / days» reads badly).
    private static let numbers: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred"]

    /// Film subtitles: one fixed size, the sentence on one line, or on two when it is too wide — broken where a
    /// subtitler would (Netflix): after punctuation, before a joining word, never after an article or a preposition,
    /// the lines as even as that allows. The last line's bottom at 78% of the frame — low like a film's, above the
    /// apps' buttons and text.
    private static func filmLines(_ words: [ChunkWord], look: CaptionLook, italic: Bool, spacing: Double = 1) -> Layout {
        let s = setting(look, accent: false), space = gap(look) * filmSize
        func width(_ ws: ArraySlice<ChunkWord>) -> Double {
            ws.reduce(0.0) { $0 + boxWidth($1.text, s, size: filmSize, italic: italic) } + space * Double(max(0, ws.count - 1))
        }
        func bare(_ text: String) -> String { text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        func cost(_ k: Int) -> Double {
            let a = width(words[..<k]), b = width(words[k...])
            let before = words[k - 1].text, after = bare(words[k].text)
            var c = abs(a - b) / room + max(0, max(a, b) - room) / room * 10
            if let mark = before.last, ".!?".contains(mark) { c -= 0.8 } else if let mark = before.last, ",;:—–".contains(mark) { c -= 0.6 }
            if joining.contains(after) { c -= 0.3 } else if leading.contains(after) { c -= 0.2 }
            if clinging.contains(bare(before)) { c += 0.6 }
            if numbers.contains(bare(before)) || (!bare(before).isEmpty && bare(before).allSatisfy(\.isNumber)) { c += 0.4 }
            // two capitalised words in a row are a name: «Baby / Jane»
            if before.first?.isUppercase == true, words[k].text.first?.isUppercase == true, before.last?.isLetter == true { c += 0.5 }
            return c
        }
        var lines = [words[...]]
        if let k = words.dropLast().firstIndex(where: { $0.br == true }) {      // the editor's own break
            lines = [words[...k], words[(k + 1)...]]
        } else if words.count > 1, width(words[...]) > room {
            let k = (1..<words.count).min { cost($0) < cost($1) }!
            lines = [words[..<k], words[k...]]
        }
        let height = rowHeight(row(Array(lines[0]), look: look, size: filmSize, top: 0, italic: italic), look: look)
        let step = (height + rowGap(look) * filmSize) * spacing
        var top = 1920 * 0.78 - height - step * Double(lines.count - 1)
        var out: [Word] = []
        for line in lines {
            out += row(Array(line), look: look, size: filmSize, top: top, italic: italic)
            top += step
        }
        return Layout(words: out, size: filmSize, look: look)
    }

    // MARK: Drawing

    /// The chunk as it looks `t` seconds into the edit.
    static func draw(_ layout: Layout, in ctx: CGContext, time t: Double) {
        let scale = Paint.deviceScale(ctx)
        if layout.look == .plain, layout.entrance == .karaoke {
            guard t >= layout.appear - 1e-6 else { return }
            for (i, word) in layout.words.enumerated() {
                let next = i + 1 < layout.words.count ? layout.words[i + 1].start : layout.end
                karaoke(word, "\(layout.key)#\(i)", ctx, t: t, appear: layout.appear, next: next, scale)
            }
            return
        }
        for (i, word) in layout.words.enumerated() where t >= word.start - 1e-6 {
            let e = t - word.start
            let key = "\(layout.key)#\(i)"
            switch layout.look {
            case .goldScript: goldScript(word, key, ctx, e, scale)
            case .highlighter: highlighter(word, key, ctx, e, scale)
            case .editorial: editorial(word, key, ctx, e, scale)
            case .handwritten: handwritten(word, key, ctx, e, scale)
            case .cleanBox: cleanBox(word, key, ctx, e, scale)
            case .plain: plain(word, key, ctx, e, scale, layout.entrance)
            case .film, .filmBold: film(word, key, ctx, scale)
            }
        }
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // 6 · Plain: white Montserrat with a thin dark outline and a soft shadow, coming in one of four ways
    private static func plain(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double, _ entrance: CaptionEntrance) {
        var m = Motion()
        switch entrance {
        case .pop, .words:
            // the earlier ads' captions: in over 70 ms, from 70% to 104% with the blur clearing by 110 ms, 100% at 200 ms
            m.opacity = min(1, e / 0.07)
            m.scale = e < 0.11 ? 0.7 + 0.34 * e / 0.11 : e < 0.2 ? 1.04 - 0.04 * (e - 0.11) / 0.09 : 1
            m.blur = e < 0.11 ? 7 - 6.4 * e / 0.11 : e < 0.2 ? 0.6 * (1 - (e - 0.11) / 0.09) : 0
        case .rise:
            let p = Clock(duration: 0.28, easing: CubicBezier(0.2, 0.8, 0.2, 1)).value(Track([(0, 0), (1, 1)]), e)
            m.opacity = p
            m.dy = (1 - p) * 0.35 * w.size
        case .fade:
            m.opacity = Clock(duration: 0.2, easing: .easeOut).value(Track([(0, 0), (1, 1)]), e)
        case .karaoke:
            break                                           // drawn by karaoke()
        }
        let path = glyphs(w)
        sprite(key, w, scale: scale, margin: 0.3, motion: m, origin: center(w.box), ctx) { c in
            Paint.withShadows(c, [Shadow(dx: 0, dy: 0.05 * w.size, blur: 0.14 * w.size, color: Paint.rgba(0, 0, 0, 0.5))]) { cc in
                cc.addPath(path); cc.setLineWidth(0.07 * w.size); cc.setLineJoin(.round)
                cc.setStrokeColor(Paint.rgba(0, 0, 0, 0.85)); cc.strokePath()
                cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
        }
    }

    // 6 · Plain, karaoke (Bogdan 10-26: «активное слово увеличивалось и становилось ярче, а те, что уже сказали, были
    // просто белыми»): the caption pops up whole with every word dimmed; the word being said grows to 115% over 80 ms
    // with a white glow and settles back over 120 ms when the next one starts; words already said stay plain white.
    static let karaokeDim = 0.45, karaokeGrow = 0.15

    private static func karaoke(_ w: Word, _ key: String, _ ctx: CGContext, t: Double, appear: Double, next: Double, _ scale: Double) {
        let e = t - appear
        var m = Motion()                                    // the caption's pop, as `.pop`
        m.opacity = min(1, e / 0.07)
        m.scale = e < 0.11 ? 0.7 + 0.34 * e / 0.11 : e < 0.2 ? 1.04 - 0.04 * (e - 0.11) / 0.09 : 1
        m.blur = e < 0.11 ? 7 - 6.4 * e / 0.11 : e < 0.2 ? 0.6 * (1 - (e - 0.11) / 0.09) : 0
        // 0 before the word, 1 while it is said, back to 0 after; brightness stays once it was said
        let lit = t < w.start ? 0 : t < next ? min(1, (t - w.start) / 0.08) : max(0, 1 - (t - next) / 0.12)
        let said = t >= w.start ? 1.0 : 0.0
        m.opacity *= karaokeDim + (1 - karaokeDim) * max(said, lit)
        m.scale *= 1 + karaokeGrow * lit
        let path = glyphs(w), origin = center(w.box)
        if lit > 0.001 {
            var g = m; g.opacity *= lit
            sprite(key + "~glow", w, scale: scale, margin: 0.7, motion: g, origin: origin, ctx) { c in
                Paint.withShadows(c, [Shadow(dx: 0, dy: 0, blur: 0.42 * w.size, color: Paint.rgba(255, 255, 255, 0.85))]) { cc in
                    cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
            }
        }
        sprite(key, w, scale: scale, margin: 0.3, motion: m, origin: origin, ctx) { c in
            Paint.withShadows(c, [Shadow(dx: 0, dy: 0.05 * w.size, blur: 0.14 * w.size, color: Paint.rgba(0, 0, 0, 0.5))]) { cc in
                cc.addPath(path); cc.setLineWidth(0.07 * w.size); cc.setLineJoin(.round)
                cc.setStrokeColor(Paint.rgba(0, 0, 0, 0.85)); cc.strokePath()
                cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
        }
    }

    // 7 · Film: white Inter with a hairline dark outline and a soft shadow, there from the caption's first frame
    private static func film(_ w: Word, _ key: String, _ ctx: CGContext, _ scale: Double) {
        let path = glyphs(w)
        sprite(key, w, scale: scale, margin: 0.3, motion: Motion(), origin: center(w.box), ctx) { c in
            Paint.withShadows(c, [Shadow(dx: 0, dy: 0.04 * w.size, blur: 0.12 * w.size, color: Paint.rgba(0, 0, 0, 0.75))]) { cc in
                cc.addPath(path); cc.setLineWidth(0.05 * w.size); cc.setLineJoin(.round)
                cc.setStrokeColor(Paint.rgba(0, 0, 0, 0.6)); cc.strokePath()
                cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
        }
    }

    /// The run's glyphs at the word's text position.
    private static func glyphs(_ word: Word) -> CGPath {
        var m = CGAffineTransform(translationX: word.textX, y: word.baseline)
        return word.run.path.copy(using: &m) ?? word.run.path
    }

    /// The word's static look (text, strokes, shadows) as a sprite, drawn under `motion` with
    /// opacity and blur. `margin` (in em of the word) leaves room for shadows and glows.
    private static func sprite(_ key: String, _ w: Word, scale: Double, margin: Double, motion: Motion, origin: CGPoint,
                               _ ctx: CGContext, _ paint: (CGContext) -> Void) {
        guard motion.opacity > 0.001,
              let s = SpriteCache.shared.sprite(key, scale: scale, bounds: w.box.insetBy(dx: -margin * w.size, dy: -margin * w.size), paint)
        else { return }
        ctx.saveGState()
        ctx.concatenate(motion.transform(origin: origin))
        SpriteCache.draw(s, in: ctx, opacity: motion.opacity, blur: motion.blur)
        ctx.restoreGState()
    }

    // 1 · Gold Script
    private static let v1 = CubicBezier(0.2, 0.9, 0.25, 1.15)

    private static func goldScript(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double) {
        let clock = Clock(duration: w.accent ? 0.5 : 0.42, easing: v1)
        var m = Motion()
        m.opacity = clock.value(Track([(0, 0), (0.6, 1), (1, 1)]), e)
        m.blur = clock.value(Track([(0, 8), (0.6, 0), (1, 0)]), e)
        m.dy = clock.value(Track([(0, 0.35), (0.6, 0), (1, 0)]), e) * w.size
        m.scale = clock.value(Track([(0, 0.7), (0.6, 1.05), (1, 1)]), e)
        let path = glyphs(w)

        guard w.accent else {
            sprite(key, w, scale: scale, margin: 0.4, motion: m, origin: center(w.box), ctx) { c in
                Paint.withShadows(c, [Shadow(dx: 0, dy: 0.06 * w.size, blur: 0.18 * w.size, color: Paint.rgba(0, 0, 0, 0.55)),
                                      Shadow(dx: 0, dy: 0, blur: 0.02 * w.size, color: Paint.rgba(0, 0, 0, 1))]) { cc in
                    cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
            }
            return
        }
        // the light sweep runs to 1.35 s; the drop-shadow filter replaces the blur 80% into the entrance
        let accent: (CGContext, Double, Bool) -> Void = { c, position, shadowed in
            Paint.withShadows(c, shadowed ? [Shadow(dx: 0, dy: 0.05 * w.size, blur: 0.12 * w.size, color: Paint.rgba(0, 0, 0, 0.6))] : []) { cc in
                gradientText(cc, path: path, box: w.box, position: position)
            }
        }
        if e >= 1.35 {
            sprite(key + "f", w, scale: scale, margin: 0.4, motion: m, origin: center(w.box), ctx) { accent($0, 0, true) }
            return
        }
        let position = 1 - Clock(duration: 1.1, delay: 0.25, easing: .easeOut).value(Track([(0, 0), (1, 1)]), e)
        ctx.saveGState()
        ctx.concatenate(m.transform(origin: center(w.box)))
        Paint.blurred(ctx, sigma: m.blur, bounds: w.box.insetBy(dx: -w.size * 0.3, dy: -w.size * 0.3), opacity: m.opacity) { c in
            accent(c, position, e >= 0.4)
        }
        ctx.restoreGState()
    }

    /// `linear-gradient(100deg, …)` sized 220% × 100% of the box, shown through the glyphs.
    private static func gradientText(_ ctx: CGContext, path: CGPath, box: CGRect, position: Double) {
        let w = box.width * 2.2, h = box.height
        let originX = box.minX + (box.width - w) * position
        let angle = 100.0 * .pi / 180
        let dir = CGPoint(x: sin(angle), y: -cos(angle))
        let length = abs(w * sin(angle)) + abs(h * cos(angle))
        let c = CGPoint(x: originX + w / 2, y: box.minY + h / 2)
        let start = CGPoint(x: c.x - dir.x * length / 2, y: c.y - dir.y * length / 2)
        let end = CGPoint(x: c.x + dir.x * length / 2, y: c.y + dir.y * length / 2)
        let colors = ["#b8893a", "#f6dc9b", "#fff3d2", "#d9b26a", "#a87a2e"].map { Paint.hex($0) } as CFArray
        guard let gradient = CGGradient(colorsSpace: Paint.srgb, colors: colors, locations: [0, 0.38, 0.5, 0.62, 1]) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // 2 · Highlighter
    private static func highlighter(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double) {
        let clock = Clock(duration: 0.32, easing: CubicBezier(0.3, 1.6, 0.4, 1))
        var m = Motion()
        m.opacity = clock.value(Track([(0, 0), (1, 1)]), e)
        m.scale = clock.value(Track([(0, 0.5), (1, 1)]), e)
        let path = glyphs(w)
        guard w.accent else {
            sprite(key, w, scale: scale, margin: 0.2, motion: m, origin: center(w.box), ctx) { c in
                // Chromium's order: the stroke first, then the fill carrying the text-shadow (over the stroke)
                c.addPath(path); c.setLineWidth(0.045 * w.size); c.setLineJoin(.miter); c.setMiterLimit(4)
                c.setStrokeColor(Paint.hex("#111111")); c.strokePath()
                Paint.dropShadow(c, Shadow(dx: 0, dy: 0.05 * w.size, blur: 0, color: Paint.rgba(0, 0, 0, 0.35))) { cc in
                    cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
            }
            return
        }
        // the rose marker wipes in behind the word: skewX(-6deg) scaleX(0 -> 1) from the left, 0.12–0.46 s
        let wipe = Clock(duration: 0.34, delay: 0.12, easing: CubicBezier(0.6, 0, 0.2, 1)).value(Track([(0, 0), (1, 1)]), e)
        let paint: (CGContext, Double) -> Void = { c, wipe in
            if wipe > 0 {
                let em = w.size
                let r = CGRect(x: w.box.minX - 0.04 * em, y: w.box.minY + 0.02 * em, width: w.box.width + 0.08 * em, height: w.box.height)
                let origin = CGPoint(x: r.minX, y: r.midY)
                let skew = CGAffineTransform(a: 1, b: 0, c: tan(-6 * .pi / 180), d: 1, tx: 0, ty: 0)
                let local = CGAffineTransform(scaleX: wipe, y: 1).concatenating(skew)
                let full = CGAffineTransform(translationX: -origin.x, y: -origin.y).concatenating(local)
                    .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                c.saveGState()
                c.concatenate(full)
                c.addPath(Paint.roundedRect(r, radius: 0.14 * em))
                c.setFillColor(Paint.hex("#e8a3a9"))
                c.fillPath()
                c.restoreGState()
            }
            // white like the other words (Bogdan, 2026-10-13: not dark on the rose)
            c.addPath(path); c.setLineWidth(0.045 * w.size); c.setLineJoin(.miter); c.setMiterLimit(4)
            c.setStrokeColor(Paint.hex("#111111")); c.strokePath()
            Paint.dropShadow(c, Shadow(dx: 0, dy: 0.05 * w.size, blur: 0, color: Paint.rgba(0, 0, 0, 0.35))) { cc in
                cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
        }
        if e >= 0.46 {
            sprite(key + "f", w, scale: scale, margin: 0.2, motion: m, origin: center(w.box), ctx) { paint($0, 1) }
        } else {
            ctx.saveGState()
            ctx.concatenate(m.transform(origin: center(w.box)))
            Paint.layer(ctx, opacity: m.opacity) { paint($0, wipe) }
            ctx.restoreGState()
        }
    }

    // 3 · Editorial
    private static func editorial(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double) {
        let clock = Clock(duration: w.accent ? 0.62 : 0.5, easing: CubicBezier(0.16, 1, 0.3, 1))
        let rise = clock.value(Track([(0, 1.05 * w.lineHeight), (1, 0)]), e)   // the inner span's own height: translateY(105%)
        let opacity = clock.value(Track([(0, 0.2), (1, 1)]), e)
        let path = glyphs(w)
        guard let s = SpriteCache.shared.sprite(key, scale: scale, bounds: w.box.insetBy(dx: -0.5 * w.size, dy: -0.5 * w.size), { c in
            // the accent keeps the words' text-shadow: its rule changes font and colour only
            Paint.withShadows(c, [Shadow(dx: 0, dy: 0.04 * w.size, blur: 0.2 * w.size, color: Paint.rgba(0, 0, 0, 0.6))]) { cc in
                cc.addPath(path); cc.setFillColor(Paint.hex(w.accent ? "#e8a3a9" : "#fffaf4")); cc.fillPath()
            }
        }) else { return }
        ctx.saveGState()
        ctx.clip(to: w.box)                                   // overflow: hidden — the word rises out of its own box
        SpriteCache.draw(s, in: ctx, opacity: opacity, offset: CGPoint(x: 0, y: rise))
        ctx.restoreGState()
    }

    // 4 · Handwritten Note
    private static let underline: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 8))
        p.addCurve(to: CGPoint(x: 98, y: 4), control1: CGPoint(x: 25, y: 2), control2: CGPoint(x: 55, y: 12))
        return p
    }()

    private static func handwritten(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double) {
        let path = glyphs(w)
        var m = Motion()
        guard w.accent else {
            let clock = Clock(duration: 0.4, easing: CubicBezier(0.2, 0.8, 0.2, 1))
            m.opacity = clock.value(Track([(0, 0), (1, 1)]), e)
            m.dx = clock.value(Track([(0, -0.4), (1, 0)]), e) * w.size
            sprite(key, w, scale: scale, margin: 0.4, motion: m, origin: center(w.box), ctx) { c in
                Paint.withShadows(c, [Shadow(dx: 0, dy: 0.05 * w.size, blur: 0.18 * w.size, color: Paint.rgba(0, 0, 0, 0.6))]) { cc in
                    cc.addPath(path); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
            }
            return
        }
        let clock = Clock(duration: 0.55, easing: CubicBezier(0.2, 0.9, 0.3, 1.3))
        m.opacity = clock.value(Track([(0, 0), (1, 1)]), e)
        m.rotate = clock.value(Track([(0, -8), (1, -3)]), e)
        m.scale = clock.value(Track([(0, 0.6), (1, 1)]), e)
        let origin = CGPoint(x: w.box.midX, y: w.box.minY + w.box.height * 0.7)

        let text: (CGContext) -> Void = { c in
            // Chromium's order: the white stroke first, then the fill whose shadow lands on the stroke
            c.addPath(path); c.setLineWidth(0.1 * w.size); c.setLineJoin(.miter); c.setMiterLimit(4)
            c.setStrokeColor(Paint.rgba(255, 255, 255)); c.strokePath()
            Paint.dropShadow(c, Shadow(dx: 0, dy: 0.04 * w.size, blur: 0.14 * w.size, color: Paint.rgba(0, 0, 0, 0.45))) { cc in
                cc.addPath(path); cc.setFillColor(Paint.hex("#e8173f")); cc.fillPath()
            }
        }
        // the drawn underline: an SVG under the word, 108% wide, .32em tall, .2em below; draws 0.3–0.75 s
        let svg = CGRect(x: w.box.minX - 0.04 * w.box.width, y: w.box.maxY + 0.2 * w.size - 0.32 * w.size,
                         width: w.box.width * 1.08, height: 0.32 * w.size)
        let line: (CGContext, Double) -> Void = { c, visible in
            guard visible > 0 else { return }
            let outline = Paths.prefix(underline, length: visible).copy(strokingWithWidth: 3.2, lineCap: .round, lineJoin: .miter, miterLimit: 4)
            var fit = CGAffineTransform(a: svg.width / 100, b: 0, c: 0, d: svg.height / 12, tx: svg.minX, ty: svg.minY)
            let shape = outline.copy(using: &fit) ?? outline
            // drop-shadow(0 0 .06em #fff) works in the SVG's own units, so the viewBox scaling enlarges the glow too
            let svgScale = ((svg.width / 100) * (svg.height / 12)).squareRoot()
            let glow = Shadow(dx: 0, dy: 0, blur: 0.06 * w.size * svgScale, color: Paint.rgba(255, 255, 255))
            let red: (CGContext) -> Void = { c3 in c3.addPath(shape); c3.setFillColor(Paint.hex("#e8173f")); c3.fillPath() }
            // the double glow exactly as the filter chain composes it, at a resolution its blur can't tell from full;
            // the stroke itself is drawn again on top at full resolution
            let device = Paint.deviceScale(c)
            let low = min(device, device * 24 / max(glow.blur * device * Paint.shadowBlurScale, 1))
            Paint.lowResolution(c, scale: low, bounds: shape.boundingBoxOfPath.insetBy(dx: -glow.blur * 3, dy: -glow.blur * 3)) { off in
                Paint.dropShadow(off, glow) { c2 in Paint.dropShadow(c2, glow, red) }
            }
            red(c)
        }
        if e >= 0.75 {
            sprite(key + "f", w, scale: scale, margin: 1.2, motion: m, origin: origin, ctx) { c in text(c); line(c, 120) }
            return
        }
        // while the underline is drawing, the word itself is still a sprite
        ctx.saveGState()
        ctx.concatenate(m.transform(origin: origin))
        Paint.layer(ctx, opacity: m.opacity) { c in
            if let s = SpriteCache.shared.sprite(key, scale: scale, bounds: w.box.insetBy(dx: -0.4 * w.size, dy: -0.4 * w.size), text) {
                SpriteCache.draw(s, in: c)
            }
            line(c, max(0, 120 - Clock(duration: 0.45, delay: 0.3, easing: .easeOut).value(Track([(0, 120), (1, 0)]), e)))
        }
        ctx.restoreGState()
    }

    // 5 · Clean Box
    private static func cleanBox(_ w: Word, _ key: String, _ ctx: CGContext, _ e: Double, _ scale: Double) {
        let clock = Clock(duration: w.accent ? 0.65 : 0.55, easing: CubicBezier(0.3, 0, 0.3, 1))
        var m = Motion()
        m.opacity = clock.value(Track([(0, 0), (0.45, 1), (1, 1)]), e)
        if w.accent {
            m.dy = clock.value(Track([(0, 0.8), (0.45, -0.18), (0.7, 0.05), (0.85, -0.02), (1, 0)]), e) * w.size
            m.scale = clock.value(Track([(0, 0.3), (0.45, 1.18), (0.7, 0.95), (0.85, 1.03), (1, 1)]), e)
            m.rotate = clock.value(Track([(0, -8), (0.45, 3), (0.7, -1), (0.85, 0), (1, 0)]), e)
        } else {
            m.dy = clock.value(Track([(0, 0.7), (0.45, -0.14), (0.7, 0.04), (0.85, -0.02), (1, 0)]), e) * w.size
            m.scale = clock.value(Track([(0, 0.35), (0.45, 1.12), (0.7, 0.96), (0.85, 1.02), (1, 1)]), e)
        }
        let origin = CGPoint(x: w.box.midX, y: w.box.minY + w.box.height * 0.8)
        let path = glyphs(w)
        let radius = (w.accent ? 0.3 : 0.22) * w.size
        let card = Paint.roundedRect(w.box, radius: radius)
        sprite(key, w, scale: scale, margin: 0.5, motion: m, origin: origin, ctx) { c in
            if w.accent {
                Paint.withShadows(c, [Shadow(dx: 0, dy: 0.1 * w.size, blur: 0.25 * w.size, color: Paint.rgba(0, 0, 0, 0.35))]) { cc in
                    let ring = 0.08 * w.size
                    cc.addPath(Paint.roundedRect(w.box.insetBy(dx: -ring, dy: -ring), radius: radius + ring))
                    cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
                c.addPath(card); c.setFillColor(Paint.hex("#1a1514")); c.fillPath()
                c.addPath(path); c.setFillColor(Paint.hex("#d9b26a")); c.fillPath()
            } else {
                Paint.withShadows(c, [Shadow(dx: 0, dy: 0.08 * w.size, blur: 0.2 * w.size, color: Paint.rgba(0, 0, 0, 0.28))]) { cc in
                    cc.addPath(card); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
                c.addPath(path); c.setFillColor(Paint.hex("#141110")); c.fillPath()
            }
        }
    }
}

/// Path measuring: length and the first `length` units of a path (for stroke-dashoffset drawing).
enum Paths {
    /// Flattened polyline of a path, in path order, one array per subpath.
    static func polylines(_ path: CGPath, tolerance: Double = 0.25) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero
        func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) {
            let approx = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p3.x - c2.x, p3.y - c2.y)
            let n = max(4, min(400, Int(approx / tolerance / 4)))
            for i in 1...n {
                let t = Double(i) / Double(n), u = 1 - t
                current.append(CGPoint(x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x,
                                       y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y))
            }
        }
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                if current.count > 1 { out.append(current) }
                current = [p[0]]; last = p[0]
            case .addLineToPoint:
                current.append(p[0]); last = p[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: last.x + 2 / 3 * (p[0].x - last.x), y: last.y + 2 / 3 * (p[0].y - last.y))
                let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
                cubic(last, c1, c2, p[1]); last = p[1]
            case .addCurveToPoint:
                cubic(last, p[0], p[1], p[2]); last = p[2]
            case .closeSubpath:
                if let first = current.first { current.append(first) }
            @unknown default: break
            }
        }
        if current.count > 1 { out.append(current) }
        return out
    }

    static func length(_ line: [CGPoint]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The first `length` units of a single-subpath path, as a polyline path.
    static func prefix(_ path: CGPath, length: Double) -> CGPath {
        let out = CGMutablePath()
        guard let line = polylines(path).first, let first = line.first else { return out }
        out.move(to: first)
        var left = length
        for (a, b) in zip(line, line.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            if left >= d { out.addLine(to: b); left -= d; continue }
            if left > 0, d > 0 { out.addLine(to: CGPoint(x: a.x + (b.x - a.x) * left / d, y: a.y + (b.y - a.y) * left / d)) }
            break
        }
        return out
    }

    /// The stretch [from, to] along a single-subpath path (stroke-dasharray / dashoffset drawing).
    static func segment(_ path: CGPath, from: Double, to: Double) -> CGPath {
        let out = CGMutablePath()
        guard let line = polylines(path).first, line.count > 1 else { return out }
        var walked = 0.0
        var started = false
        for (a, b) in zip(line, line.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            defer { walked += d }
            guard d > 0, walked + d >= from else { continue }
            if walked > to { break }
            let t0 = max(0, (from - walked) / d), t1 = min(1, (to - walked) / d)
            let p0 = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
            let p1 = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
            if !started { out.move(to: p0); started = true }
            out.addLine(to: p1)
            if t1 < 1 { break }
        }
        return out
    }

    /// The point `distance` units along the path's subpaths taken in order, plus the subpath index.
    static func point(along lines: [[CGPoint]], at distance: Double) -> CGPoint? {
        var left = distance
        for line in lines {
            for (a, b) in zip(line, line.dropFirst()) {
                let d = hypot(b.x - a.x, b.y - a.y)
                if left <= d, d > 0 { return CGPoint(x: a.x + (b.x - a.x) * left / d, y: a.y + (b.y - a.y) * left / d) }
                left -= d
            }
        }
        return lines.last?.last
    }
}
