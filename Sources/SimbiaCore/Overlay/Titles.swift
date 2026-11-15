import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The lipstick titles T1–T5, drawn as Reference/overlay_ref.html draws them (every keyframe percentage is of the
/// title's own duration; colours develop from pale to full over ~3.3 s), the plain T6–T7 of the earlier ads, and
/// T8, a Trustpilot review card.
enum TitlePainter {
    static func draw(_ titles: [TitleItem], in ctx: CGContext, time t: Double, pack: String = AnimatedEmoji.defaultPack) {
        for title in titles where t >= title.start && t <= title.start + title.duration {
            let dt = t - title.start
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.translateBy(x: title.x ?? 0, y: title.y ?? 0)          // moved by hand on the picture
            switch TitleStyle(id: title.style)?.number ?? 1 {
            case 1: t1(title, ctx, dt)
            case 2: t2(title, ctx, dt)
            case 3: t3(title, ctx, dt)
            case 4: t4(title, ctx, dt)
            case 6: t6(title, ctx, dt, pack)
            case 7: t7(title, ctx, dt, pack)
            case 8: t8(title, ctx, dt)
            case 9: t9(title, ctx, dt)
            case 10: t10(title, ctx, dt)
            case 11: t11(title, ctx, dt)
            case 12: t12(title, ctx, dt)
            case 13: t13(title, ctx, dt)
            default: t5(title, ctx, dt)
            }
            if let stickers = title.stickers, !stickers.isEmpty {
                let m = pop(dt, title.duration)
                for s in stickers { sticker(s, ctx, dt: dt, m: m, pack: pack) }
            }
        }
    }

    /// An emoji placed on the title by hand: it pops in and out with the title, its animation starts with it.
    static func sticker(_ s: Sticker, _ ctx: CGContext, dt: Double, m: Motion, pack: String) {
        guard m.opacity > 0.001 else { return }
        ctx.saveGState()
        ctx.translateBy(x: 540 + s.x, y: 960 + s.y)
        ctx.rotate(by: s.rotation * .pi / 180)
        ctx.scaleBy(x: m.scale, y: m.scale)
        ctx.setAlpha(m.opacity)
        AnimatedEmoji.draw(s.emoji, pack: pack, at: dt, side: s.size, in: ctx)
        ctx.restoreGState()
    }

    /// Where a sticker sits (stage px, before the title's own move): its centre and the square it fills, unturned.
    public static func stickerBox(_ s: Sticker) -> CGRect {
        CGRect(x: 540 + s.x - s.size / 2, y: 960 + s.y - s.size / 2, width: s.size, height: s.size)
    }

    // MARK: Colour

    /// 0…1: how far the lipstick colour has developed `dt` seconds into a title of length `d`.
    static func developed(_ dt: Double, _ d: Double) -> Double {
        let k = max(0, min(1, (dt - 0.3) / max(1, min(3.3, d - 0.9))))
        return 1 - pow(1 - k, 2)
    }

    /// A colour on its way from pale pink (82% toward #f8e2e2) to itself; rounded like the web's rgb().
    static func develop(_ hex: String, _ e: Double) -> CGColor {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        let c = [Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255)]
        let pale = [248.0, 226, 226]
        let from = c.indices.map { c[$0] + (pale[$0] - c[$0]) * 0.82 }
        let mixed = c.indices.map { (from[$0] + (c[$0] - from[$0]) * e).rounded() }
        return Paint.rgba(mixed[0], mixed[1], mixed[2])
    }

    static func gradient(_ stops: [(String, Double)], _ e: Double) -> CGGradient {
        CGGradient(colorsSpace: Paint.srgb, colors: stops.map { develop($0.0, e) } as CFArray, locations: stops.map { CGFloat($0.1) })!
    }

    static let lipRed: [(String, Double)] = [("#e46a79", 0), ("#c1324a", 0.45), ("#d9566a", 0.55), ("#8e1b2c", 1)]
    static let lipStroke: [(String, Double)] = [("#d63a52", 0), ("#b3213a", 0.5), ("#861627", 1)]

    // MARK: Caching

    /// An element whose only change over time is its colour developing (pale -> full). Every step from colour
    /// to pixels — gradient, displacement, opacity, shadow — is linear in it, so a frame is exactly
    /// (1 - e)·pale + e·full: both ends are rendered once, each frame blends them.
    /// `scale`: the sprites' resolution when the element is drawn under an animated transform — taken
    /// from the frame, not from the transform, so a scaling element does not render new sprites every frame.
    static func developing(_ ctx: CGContext, key: String, bounds: CGRect, e: Double, opacity: Double = 1,
                           scale: Double? = nil, _ draw: (CGContext, Double) -> Void) {
        let scale = scale ?? Paint.deviceScale(ctx)
        guard opacity > 0.001,
              let pale = SpriteCache.shared.sprite(key + "|pale", scale: scale, bounds: bounds, { draw($0, 0) }),
              let full = SpriteCache.shared.sprite(key + "|full", scale: scale, bounds: bounds, { draw($0, 1) }) else { return }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        SpriteCache.draw(pale, in: ctx, opacity: 1 - e)
        ctx.setBlendMode(.plusLighter)
        SpriteCache.draw(full, in: ctx, opacity: e)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// A headline (text + its shadow) as a sprite, drawn scaled about its centre with opacity and blur.
    static func headline(_ ctx: CGContext, key: String, _ l: Line, color: CGColor, shadow: Shadow?,
                         scale: Double = 1, opacity: Double, blur: Double = 0, dy: Double = 0) {
        let size = l.box.height
        guard opacity > 0.001,
              let sprite = SpriteCache.shared.sprite(key, scale: Paint.deviceScale(ctx), bounds: l.box.insetBy(dx: -size * 0.5, dy: -size * 0.5),
                                                     { fill($0, l, color: color, shadow: shadow) }) else { return }
        ctx.saveGState()
        ctx.concatenate(Motion(scale: scale).transform(origin: CGPoint(x: l.box.midX, y: l.box.midY)))
        SpriteCache.draw(sprite, in: ctx, opacity: opacity, blur: blur, offset: CGPoint(x: 0, y: dy))
        ctx.restoreGState()
    }

    /// The filter region of `#wax` on an element (x −10%, y −40%, 120% × 180% of its box), on the stage.
    static func waxRegion(_ bbox: CGRect, _ svg: CGAffineTransform) -> CGRect {
        CGRect(x: bbox.minX - 0.1 * bbox.width, y: bbox.minY - 0.4 * bbox.height, width: bbox.width * 1.2, height: bbox.height * 1.8)
            .applying(svg).insetBy(dx: -2, dy: -2)
    }

    // MARK: Strokes

    /// Draws the part [from, to] (user units along the path) of a stroked path whose user space maps
    /// to the stage by `svg`, filled with a vertical gradient over the path's own bounding box.
    static func stroke(_ ctx: CGContext, path: CGPath, from: Double, to: Double, width: Double, svg: CGAffineTransform,
                       gradient: CGGradient, alpha: Double) {
        guard to > from else { return }
        let piece = Paths.segment(path, from: from, to: to)
        let outline = piece.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        var m = svg
        guard let shape = outline.copy(using: &m) else { return }
        let box = path.boundingBoxOfPath
        let top = CGPoint(x: box.midX, y: box.minY).applying(svg), bottom = CGPoint(x: box.midX, y: box.maxY).applying(svg)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: top, end: bottom, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// `filter: url(#wax)` on an element whose user space maps to the stage by `svg`: draw it into a
    /// layer, displace it by the turbulence, clip to the filter region (x −10%, y −40%, 120% × 180% of the
    /// element's bounding box, as SVG defines it).
    static func waxed(_ ctx: CGContext, svg: CGAffineTransform, bbox: CGRect, displacement: Double = 7,
                      _ draw: (CGContext) -> Void) {
        var region = CGRect(x: bbox.minX - 0.1 * bbox.width, y: bbox.minY - 0.4 * bbox.height,
                            width: bbox.width * 1.2, height: bbox.height * 1.8)
        // A dead-straight horizontal stroke has a zero-height box, so its filter region is a sliver:
        // Chromium shows it as a hairline (the bars of "#" in T2). Keep that one device pixel.
        let pixel = 1 / max(Paint.deviceScale(ctx) * abs(svg.d), 1e-6)
        if region.height < pixel { region = region.insetBy(dx: 0, dy: (region.height - pixel) / 2) }
        let onStage = region.applying(svg)
        LipstickFilter.apply(ctx, bounds: onStage, user: svg.inverted(), filter: { LipstickFilter.displace($0, scale: displacement) }) { c in
            c.saveGState()
            c.addPath(CGPath(rect: region, transform: [svg]))
            c.clip()
            draw(c)
            c.restoreGState()
        }
    }

    // MARK: Text

    /// A line of title text: centred in the stage, its box top at `top`, line-height 1.
    struct Line {
        let run: TextRun
        let box: CGRect
        let baseline: Double
    }

    static func line(_ text: String, face: FontLibrary.Face, size: Double, top: Double, uppercase: Bool = false,
                     letterSpacing: Double = 0, center: Double = 540) -> Line {
        let run = TextRun(uppercase ? text.uppercased() : text, font: FontLibrary.font(face, size: size), letterSpacing: letterSpacing * size)
        let ascent = run.ascent.rounded(), descent = run.descent.rounded()
        let half = (size - (ascent + descent)) / 2
        let box = CGRect(x: center - run.width / 2, y: top, width: run.width, height: size)
        return Line(run: run, box: box, baseline: top + half + ascent)
    }

    static func fill(_ ctx: CGContext, _ l: Line, color: CGColor, shadow: Shadow?) {
        var m = CGAffineTransform(translationX: l.box.minX, y: l.baseline)
        guard let path = l.run.path.copy(using: &m) else { return }
        let paint: (CGContext) -> Void = { c in
            c.addPath(path); c.setFillColor(color); c.fillPath()
            l.run.drawColorGlyphs(c, at: CGPoint(x: l.box.minX, y: l.baseline))
        }
        if let shadow { Paint.dropShadow(ctx, shadow, paint) } else { paint(ctx) }
    }

    /// The optional small line under a headline (DM Sans caps), with its own fade.
    static func kicker(_ ctx: CGContext, _ title: TitleItem, top: Double, dt: Double, late: Bool = false) {
        guard let text = title.kicker, !text.isEmpty else { return }
        let size = 1080 * 0.031
        let clock = Clock(duration: title.duration, easing: .easeOut)
        let opacity = clock.value(late ? Track([(0, 0), (0.44, 0), (0.52, 1), (0.78, 1), (0.88, 0), (1, 0)])
                                       : Track([(0, 0), (0.20, 0), (0.28, 1), (0.78, 1), (0.88, 0), (1, 0)]), dt)
        let rise = clock.value(late ? Track([(0, 0.6), (0.44, 0.6), (0.52, 0), (1, 0)]) : Track([(0, 0.6), (0.20, 0.6), (0.28, 0), (1, 0)]), dt) * size
        let run = TextRun(text.uppercased(), font: FontLibrary.font(.dmSans700, size: size), letterSpacing: 0.16 * size)
        let lineHeight = 1.2 * size
        let ascent = run.ascent.rounded(), descent = run.descent.rounded()
        let baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent + rise
        var m = CGAffineTransform(translationX: 540 - run.width / 2, y: baseline)
        guard opacity > 0, let path = run.path.copy(using: &m) else { return }
        Paint.layer(ctx, opacity: opacity) { c in
            Paint.dropShadow(c, Shadow(dx: 0, dy: 0.1 * size, blur: 0.4 * size, color: Paint.rgba(0, 0, 0, 0.55))) { cc in
                cc.addPath(path); cc.setFillColor(Paint.hex("#fff7ef")); cc.fillPath()
            }
        }
    }

    // MARK: T1 · swipe & blur

    static let t1Path: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 12, y: 52))
        p.addCurve(to: CGPoint(x: 230, y: 34), control1: CGPoint(x: 90, y: 30), control2: CGPoint(x: 170, y: 46))
        p.addCurve(to: CGPoint(x: 390, y: 30), control1: CGPoint(x: 290, y: 22), control2: CGPoint(x: 340, y: 22))   // S reflects (170,46)
        return p
    }()

    private static func t1(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, e = developed(dt, d)
        // the stroke: an SVG 112% wide and 22% tall at 49%, viewBox 400×80 stretched to fit
        let svg = CGAffineTransform(a: 1080 * 1.12 / 400, b: 0, c: 0, d: 1920 * 0.22 / 80, tx: -1080 * 0.06, ty: 1920 * 0.49)
        let offset = Clock(duration: d, easing: CubicBezier(0.6, 0, 0.2, 1))
            .value(Track([(0, 520), (0.03, 520), (0.15, 0), (0.78, 0), (0.90, -520), (1, -520)]), dt)
        let length = Paths.length(Paths.polylines(t1Path).first ?? [])
        let from = max(0, -offset), to = min(length, 520 - offset)
        // the path's opacity (.7 → 1) applies after its filter, so it stays outside the colour blend
        let paint: (CGContext, Double) -> Void = { c, e in
            waxed(c, svg: svg, bbox: t1Path.boundingBoxOfPath) { l in
                stroke(l, path: t1Path, from: from, to: to, width: 38, svg: svg, gradient: gradient(lipRed, e), alpha: 1)
            }
        }
        if from <= 0.001, to >= length - 0.001 {
            developing(ctx, key: "T1.stroke", bounds: waxRegion(t1Path.boundingBoxOfPath, svg), e: e, opacity: 0.7 + 0.3 * e, paint)
        } else if to > from {
            Paint.layer(ctx, opacity: 0.7 + 0.3 * e) { paint($0, e) }
        }

        // the headline lands on the stroke
        let clock = Clock(duration: d, easing: CubicBezier(0.2, 0.9, 0.3, 1.2))
        let opacity = clock.value(Track([(0, 0), (0.12, 0), (0.20, 1), (0.78, 1), (0.88, 0), (1, 0)]), dt)
        let scale = clock.value(Track([(0, 0.7), (0.12, 0.7), (0.20, 1), (0.78, 1), (0.88, 1.06), (1, 1.06)]), dt)
        let blur = clock.value(Track([(0, 8), (0.12, 8), (0.20, 0), (0.78, 0), (0.88, 6), (1, 6)]), dt)
        guard opacity > 0.001 else { return }
        let size = 1080 * 0.135
        let text = title.text.replacingOccurrences(of: "|", with: " ")
        let l = line(text, face: .playfairItalic800, size: size, top: 960)
        headline(ctx, key: "T1.text|" + text, l, color: Paint.hex("#fff4ea"),
                 shadow: Shadow(dx: 0, dy: 0.04 * size, blur: 0.2 * size, color: Paint.rgba(90, 10, 20, 0.55)),
                 scale: scale, opacity: opacity, blur: blur)
        kicker(ctx, title, top: 960 + size + 14.4, dt: dt)
    }

    // MARK: T6 · plain text, T7 · pill — the earlier ads' "7 REASONS", "#1 REASON", "BUY 1 GET 1 FREE"

    /// In like the earlier ads' graphics — a quick pop, 70% → 108% → 100% with the blur clearing — and out with a fade.
    private static func pop(_ dt: Double, _ d: Double, delay: Double = 0) -> Motion {
        let e = dt - delay
        var m = Motion()
        guard e > 0 else { m.opacity = 0; return m }
        m.opacity = min(1, e / 0.12) * max(0, min(1, (d - dt) / 0.3))
        m.scale = e < 0.22 ? 0.7 + 0.38 * e / 0.22 : e < 0.36 ? 1.08 - 0.08 * (e - 0.22) / 0.14 : 1
        m.blur = max(0, 8 * (1 - e / 0.2))
        return m
    }

    /// The title's lines ("|" breaks a line), in capitals as the earlier graphics set them.
    private static func plainLines(_ title: TitleItem) -> [String] {
        title.text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    /// A line of emoji only (no letters or digits), e.g. the "😴" above a numbered title.
    static func emojiOnly(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F } && !s.contains { $0.isLetter || $0.isNumber }
    }

    /// A line of emoji only: its animated version looping from the title's start when the library has one
    /// (AnimatedEmoji), else the still glyph with a soft shadow.
    private static func emojiLine(_ ctx: CGContext, _ text: String, size: Double, top: Double, dt: Double, m: Motion, pack: String) {
        if AnimatedEmoji.clip(text, pack: pack) != nil {
            guard m.opacity > 0.001 else { return }
            ctx.saveGState()
            ctx.translateBy(x: 540, y: top + size / 2)
            ctx.scaleBy(x: m.scale, y: m.scale)
            ctx.setAlpha(m.opacity)
            AnimatedEmoji.draw(text, pack: pack, at: dt, side: size * 1.1, in: ctx)
            ctx.restoreGState()
            return
        }
        headline(ctx, key: "Te|\(Int(size))|" + text, line(text, face: .montserrat800, size: size, top: top), color: Paint.rgba(255, 255, 255),
                 shadow: Shadow(dx: 0, dy: 0.04 * size, blur: 0.2 * size, color: Paint.rgba(0, 0, 0, 0.35)),
                 scale: m.scale, opacity: m.opacity, blur: m.blur)
    }

    /// White Montserrat ExtraBold capitals in the middle of the frame, the line underneath smaller.
    private static func t6(_ title: TitleItem, _ ctx: CGContext, _ dt: Double, _ pack: String) {
        let lines = plainLines(title)
        guard !lines.isEmpty else { return }
        var size = 1080 * 0.12
        let widest = lines.map { TextRun($0, font: FontLibrary.font(.montserrat800, size: size)).width }.max() ?? 0
        if widest > 1080 * 0.86 { size *= 1080 * 0.86 / widest }
        let kicker = title.kicker.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let small = max(30, size * 0.34)
        var top = 960 - (Double(lines.count) * size * 1.02 + (kicker.isEmpty ? 0 : small * 1.6)) / 2
        let m = pop(dt, title.duration)
        let shadow = Shadow(dx: 0, dy: 0.04 * size, blur: 0.18 * size, color: Paint.rgba(0, 0, 0, 0.5))
        for text in lines {
            if emojiOnly(text) { emojiLine(ctx, text, size: size, top: top, dt: dt, m: m, pack: pack); top += size * 1.02; continue }
            headline(ctx, key: "T6|\(Int(size))|" + text, line(text, face: .montserrat800, size: size, top: top), color: Paint.rgba(255, 255, 255),
                     shadow: shadow, scale: m.scale, opacity: m.opacity, blur: m.blur)
            top += size * 1.02
        }
        guard !kicker.isEmpty else { return }
        let k = pop(dt, title.duration, delay: 0.15)
        headline(ctx, key: "T6k|\(Int(small))|" + kicker, line(kicker, face: .montserrat800, size: small, top: top + small * 0.3),
                 color: Paint.rgba(255, 255, 255), shadow: Shadow(dx: 0, dy: 0.05 * small, blur: 0.25 * small, color: Paint.rgba(0, 0, 0, 0.55)),
                 scale: k.scale, opacity: k.opacity, blur: k.blur)
    }

    /// Each line in black capitals on a white pill with a soft shadow, the line underneath in white.
    private static func t7(_ title: TitleItem, _ ctx: CGContext, _ dt: Double, _ pack: String) {
        let lines = plainLines(title)
        guard !lines.isEmpty else { return }
        var size = 1080 * 0.058
        let widest = lines.map { TextRun($0, font: FontLibrary.font(.montserrat800, size: size)).width }.max() ?? 0
        if widest + 1.5 * size > 1080 * 0.9 { size *= 1080 * 0.9 / (widest + 1.5 * size) }
        let padX = 0.75 * size, padY = 0.42 * size, height = size + 2 * padY, gap = 0.3 * size
        let emoji = 2.0 * size                                     // a line of emoji only: as it is, bigger, no pill
        let heights = lines.map { emojiOnly($0) ? emoji : height }
        let kicker = title.kicker.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var top = 960 - (heights.reduce(0, +) + gap * Double(lines.count - 1) + (kicker.isEmpty ? 0 : size * 1.4)) / 2
        let m = pop(dt, title.duration)
        let scale = Paint.deviceScale(ctx)
        for text in lines {
            if emojiOnly(text) {
                emojiLine(ctx, text, size: emoji, top: top, dt: dt, m: m, pack: pack)
                top += emoji + gap
                continue
            }
            let l = line(text, face: .montserrat800, size: size, top: top + padY)
            let pill = CGRect(x: l.box.minX - padX, y: top, width: l.box.width + 2 * padX, height: height)
            if m.opacity > 0.001, let sprite = SpriteCache.shared.sprite("T7|\(Int(size))|" + text, scale: scale,
                                                                        bounds: pill.insetBy(dx: -size * 0.6, dy: -size * 0.6), { c in
                Paint.dropShadow(c, Shadow(dx: 0, dy: 0.08 * size, blur: 0.35 * size, color: Paint.rgba(0, 0, 0, 0.35))) { cc in
                    cc.addPath(Paint.roundedRect(pill, radius: height / 2)); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
                fill(c, l, color: Paint.hex("#111111"), shadow: nil)
            }) {
                ctx.saveGState()
                ctx.concatenate(Motion(scale: m.scale).transform(origin: CGPoint(x: pill.midX, y: pill.midY)))
                SpriteCache.draw(sprite, in: ctx, opacity: m.opacity, blur: m.blur)
                ctx.restoreGState()
            }
            top += height + gap
        }
        guard !kicker.isEmpty else { return }
        let k = pop(dt, title.duration, delay: 0.15)
        let small = size * 0.8
        headline(ctx, key: "T7k|\(Int(small))|" + kicker, line(kicker.uppercased(), face: .montserrat800, size: small, top: top + size * 0.2),
                 color: Paint.rgba(255, 255, 255), shadow: Shadow(dx: 0, dy: 0.05 * small, blur: 0.25 * small, color: Paint.rgba(0, 0, 0, 0.55)),
                 scale: k.scale, opacity: k.opacity, blur: k.blur)
    }

    // MARK: T11 · TikTok's own text, T12 · TikTok's "reply to comment" bubble

    /// The title's lines: "|" breaks a line, else broken at spaces to fit `width` as TikTok does. Case kept as typed.
    private static func tiktokLines(_ s: String, _ face: FontLibrary.Face, _ size: Double, width: Double) -> [String] {
        let parts = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count > 1 ? parts : wrap(parts.first ?? "", face, size, width: width, limit: 6)
    }

    /// Black text on a white plate per line, the plates touching — TikTok's in-app text with a background, as creators burn
    /// it into their videos (Michelle V7's "The Christmas gift your girls will ACTUALLY use 🎁"). Shown at once, no
    /// animation, like the burned-in one; the block's top at 176 px, where V7's sits (x/y move it).
    private static func t11(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let size = 1080 * 0.0643, padX = 0.3 * size, row = 1.3 * size              // measured on V7's title
        let lines = tiktokLines(title.text, .inter600, size, width: 1080 * 0.8)
        guard !lines.isEmpty else { return }
        let placed = lines.enumerated().map { i, text in line(text, face: .inter600, size: size, top: 176 + Double(i) * row + (row - size) / 2) }
        let bounds = placed.reduce(CGRect.null) { $0.union($1.box.insetBy(dx: -padX, dy: -(row - size) / 2)) }
        guard let sprite = SpriteCache.shared.sprite("T11|" + lines.joined(separator: "|"), scale: Paint.deviceScale(ctx),
                                                     bounds: bounds.insetBy(dx: -size * 0.3, dy: -size * 0.3), { c in
            for l in placed {
                let plate = l.box.insetBy(dx: -padX, dy: -(row - size) / 2)
                c.addPath(Paint.roundedRect(plate, radius: 0.28 * size)); c.setFillColor(Paint.rgba(255, 255, 255)); c.fillPath()
            }
            for l in placed { fill(c, l, color: Paint.rgba(0, 0, 0), shadow: nil) }
        }) else { return }
        SpriteCache.draw(sprite, in: ctx, opacity: 1, blur: 0)
    }

    /// The bubble TikTok puts on a video made in reply to a comment: a white card, "Reply to <kicker>'s comment" in small
    /// grey beside a round avatar (`image`, else a grey circle), the comment in black underneath, a little tail at the
    /// bottom left. Pops in like T6/T7, fades out; its top at 30 % of the frame (x/y move it).
    private static func t12(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let body = 46.0, small = 31.0, pad = 30.0, avatarSide = 52.0, gap = 14.0
        let lines = wrap(title.text, .inter700, body, width: 1080 * 0.74, limit: 4)
        guard !lines.isEmpty else { return }
        let who = (title.kicker?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let header = who.map { "Reply to \($0)'s comment" } ?? "Reply to comment"                 // no username given: no invented one
        let font = FontLibrary.font(.inter700, size: body), smallFont = FontLibrary.font(.inter600, size: small)
        let widest = max(lines.map { TextRun($0, font: font).width }.max() ?? 0, avatarSide + 14 + TextRun(header, font: smallFont).width)
        let lineHeight = body * 1.22
        let card = CGRect(x: 540 - (widest + 2 * pad) / 2, y: 1920 * 0.3, width: widest + 2 * pad,
                          height: pad + avatarSide + gap + Double(lines.count) * lineHeight + pad * 0.8)
        let m = pop(dt, title.duration)
        guard m.opacity > 0.001, let sprite = SpriteCache.shared.sprite("T12|\(who ?? "")|" + lines.joined(separator: "|") + "|\(title.image ?? "")",
                                                                        scale: Paint.deviceScale(ctx), bounds: card.insetBy(dx: -40, dy: -40), { c in
            let r = 28.0, tail = CGMutablePath()
            tail.move(to: CGPoint(x: card.minX + 34, y: card.maxY - 2)); tail.addLine(to: CGPoint(x: card.minX + 30, y: card.maxY + 26))
            tail.addLine(to: CGPoint(x: card.minX + 68, y: card.maxY - 2)); tail.closeSubpath()
            Paint.dropShadow(c, Shadow(dx: 0, dy: 6, blur: 22, color: Paint.rgba(0, 0, 0, 0.22))) { cc in
                cc.addPath(Paint.roundedRect(card, radius: r)); cc.addPath(tail); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
            let avatar = CGRect(x: card.minX + pad, y: card.minY + pad, width: avatarSide, height: avatarSide)
            c.saveGState(); c.addEllipse(in: avatar); c.clip()
            if let path = title.image, let img = photo(path) {                       // cover-fit, flipped into the y-down stage
                let k = max(avatarSide / Double(img.width), avatarSide / Double(img.height))
                let w = Double(img.width) * k, h = Double(img.height) * k
                c.interpolationQuality = .high
                c.translateBy(x: avatar.midX - w / 2, y: avatar.midY + h / 2); c.scaleBy(x: 1, y: -1)
                c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            } else { c.setFillColor(Paint.hex("#C9CBD1")); c.fill(avatar) }
            c.restoreGState()
            c.addPath(text(header, .inter600, small, x: avatar.maxX + 14, top: avatar.minY, lineHeight: avatarSide).path)
            c.setFillColor(Paint.hex("#8A8B91")); c.fillPath()
            for (i, s) in lines.enumerated() {
                c.addPath(text(s, .inter700, body, x: card.minX + pad, top: avatar.maxY + gap + Double(i) * lineHeight, lineHeight: lineHeight).path)
            }
            c.setFillColor(Paint.hex("#161823")); c.fillPath()
        }) else { return }
        ctx.saveGState()
        ctx.concatenate(Motion(scale: m.scale).transform(origin: CGPoint(x: card.midX, y: card.midY)))
        SpriteCache.draw(sprite, in: ctx, opacity: m.opacity, blur: m.blur)
        ctx.restoreGState()
    }

    // MARK: T13 · a pile of TikTok comments

    /// Where each comment rests (top-left, tilt): two staggered columns from the top down to above the captions.
    private static let commentPlaces: [(Double, Double, Double)] = [(70, 200, -4), (350, 325, 3), (60, 450, -2), (340, 575, 4),
                                                                     (80, 700, -3), (330, 825, 2), (60, 950, -4), (340, 1075, 3)]
    private static let commentColours = ["#E0607E", "#7A6CE0", "#2BA59A", "#E39A3B", "#4C8BE0", "#C45FB0", "#5BAF5B", "#D9534F"]
    private static let commentLikes = ["1.2K", "864", "2.4K", "531", "1.7K", "398", "1.1K", "2.9K"]

    /// "linda.m58" → "LM": the first letters of the handle's first two words.
    private static func initials(_ handle: String) -> String {
        let words = handle.split { !$0.isLetter }.map(String.init)
        let s = words.count > 1 ? String(words[0].prefix(1)) + String(words[1].prefix(1)) : String((words.first ?? "?").prefix(2))
        return s.uppercased()
    }

    /// TikTok's outlined heart (viewBox 24), drawn `side` px.
    private static func heart(_ side: Double, at o: CGPoint) -> CGPath {
        let k = side / 24, p = CGMutablePath()
        func q(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: o.x + x * k, y: o.y + y * k) }
        p.move(to: q(12, 20))
        p.addCurve(to: q(2.8, 11.4), control1: q(12, 20), control2: q(5, 15.6))
        p.addCurve(to: q(6.6, 4.8), control1: q(1.2, 8.2), control2: q(3.1, 4.8))
        p.addCurve(to: q(12, 8), control1: q(8.7, 4.8), control2: q(10.2, 6))
        p.addCurve(to: q(17.4, 4.8), control1: q(13.8, 6), control2: q(15.3, 4.8))
        p.addCurve(to: q(21.2, 11.4), control1: q(20.9, 4.8), control2: q(22.8, 8.2))
        p.addCurve(to: q(12, 20), control1: q(19, 15.6), control2: q(12, 20))
        p.closeSubpath()
        return p
    }

    /// One comment as TikTok shows it, on a white card: round avatar (photo, else initials on a colour), "handle · when"
    /// in grey, the comment, "Reply"; the heart and its count on the right. Laid out at the stage origin.
    private static func commentSprite(_ r: Review, _ k: Int, _ ctx: CGContext) -> (SpriteCache.Sprite, CGSize)? {
        let w = 660.0, pad = 22.0, av = 66.0, gap = 18.0, side = 56.0, size = 29.0, lh = size * 1.32
        let textX = pad + av + gap, textW = w - textX - side - 24
        // emoji are not in Inter's outlines: the words wrap without them, the emoji follow the last line in colour
        let isEmoji: (Character) -> Bool = { ch in !ch.isLetter && !ch.isNumber && ch.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F } }
        let emoji = r.text.filter(isEmoji).map(String.init)
        let plain = String(r.text.filter { !isEmoji($0) }).trimmingCharacters(in: .whitespaces)
        let lines = wrap(plain, .inter600, size, width: textW - Double(emoji.count) * size * 1.15, limit: 3)
        let h = pad + 30 + Double(lines.count) * lh + 8 + 26 + 18
        let card = CGRect(x: 0, y: 0, width: w, height: h)
        let likes = commentLikes[k % commentLikes.count]
        guard let sprite = SpriteCache.shared.sprite("T13|\(k)|\(r.name)|\(r.date)|\(r.text)|\(r.avatar ?? "")", scale: Paint.deviceScale(ctx),
                                                     bounds: card.insetBy(dx: -40, dy: -40), { c in
            Paint.dropShadow(c, Shadow(dx: 0, dy: 12, blur: 30, color: Paint.rgba(0, 0, 0, 0.26))) { cc in
                cc.addPath(Paint.roundedRect(card, radius: 30)); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
            }
            let a = CGRect(x: pad, y: pad, width: av, height: av)
            c.saveGState(); c.addEllipse(in: a); c.clip()
            if let path = r.avatar, let img = photo(path) {
                let s = max(av / Double(img.width), av / Double(img.height)), iw = Double(img.width) * s, ih = Double(img.height) * s
                c.interpolationQuality = .high
                c.translateBy(x: a.midX - iw / 2, y: a.midY + ih / 2); c.scaleBy(x: 1, y: -1)
                c.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            } else {
                c.setFillColor(Paint.hex(commentColours[k % commentColours.count])); c.fill(a)
            }
            c.restoreGState()
            if r.avatar == nil {
                let t = text(initials(r.name), .inter700, 27, x: 0, top: a.minY, lineHeight: av)
                c.addPath(text(initials(r.name), .inter700, 27, x: a.midX - t.width / 2, top: a.minY, lineHeight: av).path)
                c.setFillColor(Paint.rgba(255, 255, 255)); c.fillPath()
            }
            let grey = Paint.hex("#8A8B91")
            c.addPath(text(r.date.isEmpty ? r.name : r.name + " · " + r.date, .inter600, 24, x: textX, top: pad, lineHeight: 30).path)
            c.addPath(text("Reply", .inter400, 22, x: textX, top: pad + 30 + Double(lines.count) * lh + 8, lineHeight: 26).path)
            c.setFillColor(grey); c.fillPath()
            var lastWidth = 0.0
            for (i, s) in lines.enumerated() {
                let t = text(s, .inter600, size, x: textX, top: pad + 30 + Double(i) * lh, lineHeight: lh); c.addPath(t.path); lastWidth = t.width
            }
            c.setFillColor(Paint.hex("#161823")); c.fillPath()
            for (j, e) in emoji.enumerated() {
                c.saveGState()
                c.translateBy(x: textX + lastWidth + 10 + size * 0.55 + Double(j) * size * 1.1, y: pad + 30 + Double(max(0, lines.count - 1)) * lh + lh / 2)
                AnimatedEmoji.draw(e, pack: "", at: 0, side: size * 1.05, in: c)
                c.restoreGState()
            }
            let hx = w - 24 - side / 2
            c.addPath(heart(34, at: CGPoint(x: hx - 17, y: pad + 4))); c.setStrokeColor(grey); c.setLineWidth(1.8 * 34 / 24); c.strokePath()
            let n = text(likes, .inter400, 21, x: 0, top: 0, lineHeight: 26)
            c.addPath(text(likes, .inter400, 21, x: hx - n.width / 2, top: pad + 42, lineHeight: 26).path); c.setFillColor(grey); c.fillPath()
        }) else { return nil }
        return (sprite, card.size)
    }

    /// Up to eight comments dropping in one after another (0.2 s apart), fanned like the review collage; once in, each one
    /// floats on its own — its own period, phase and reach — for as long as the graphic lasts, and all fade in the last 0.3 s.
    private static func t13(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, fade = clamp01((d - dt) / 0.3)
        let comments = Array((title.reviews ?? []).prefix(commentPlaces.count))
        guard fade > 0, !comments.isEmpty else { return }
        ctx.saveGState()
        ctx.concatenate(Motion(scale: 1 + 0.04 * easeOut3(clamp01((dt - 0.2) / max(0.2, d - 0.2)))).transform(origin: CGPoint(x: 540, y: 1920 * 0.4)))
        for (k, r) in comments.enumerated() {
            let (x, y, rest) = commentPlaces[k], t0 = 0.05 + Double(k) * 0.2, side = k % 2 == 1 ? 1.0 : -1.0
            let a = clamp01((dt - t0) / 0.32), opacity = min(1, a * 3) * fade
            guard opacity > 0.001, let (sprite, size) = commentSprite(r, k, ctx) else { continue }
            let f = easeOut3(clamp01((dt - t0 - 0.25) / 0.45))
            let period = 1.5 + 0.8 * Double((k * 5) % 8) / 7, w = 2 * Double.pi * (dt - t0) / period, phase = Double(k) * 1.7
            var m = Motion()
            m.dx = side * (1 - easeOut3(a)) * 240 + f * (7 + Double(k % 3) * 3) * sin(w + phase)
            m.dy = (1 - easeOut3(a)) * 90 + f * (9 + Double(k % 4) * 2.5) * sin(w * 0.83 + phase * 1.3)
            m.rotate = rest + f * 0.7 * sin(w * 0.61 + phase) + (1 - backOut(a)) * 12 * side
            m.scale = 0.72 + 0.28 * backOut(a)
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.concatenate(m.transform(origin: CGPoint(x: size.width / 2, y: size.height / 2)))
            SpriteCache.draw(sprite, in: ctx, opacity: opacity, blur: (1 - min(1, a * 1.6)) * 9)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: T8 · a Trustpilot review — the card of the earlier motion kit

    /// The kit's card is 640 px wide among others; alone on screen it is drawn larger.
    private static let card = 1.2

    /// CSS's `normal` line height of a face at `size`: its ascent plus descent.
    private static func normal(_ face: FontLibrary.Face, _ size: Double) -> Double {
        let font = FontLibrary.font(face, size: size)
        return CTFontGetAscent(font) + CTFontGetDescent(font)
    }

    /// One line of text from `x`, centred in a line box of `lineHeight` from `top`.
    private static func text(_ s: String, _ face: FontLibrary.Face, _ size: Double, x: Double, top: Double, lineHeight: Double,
                             letterSpacing: Double = 0) -> (path: CGPath, width: Double) {
        let run = TextRun(s, font: FontLibrary.font(face, size: size), letterSpacing: letterSpacing)
        var m = CGAffineTransform(translationX: x, y: top + (lineHeight - (run.ascent + run.descent)) / 2 + run.ascent)
        return (run.path.copy(using: &m) ?? run.path, run.width)
    }

    /// Lines broken at spaces to fit `width`; past `limit` lines the last one is cut and ends in "…" (line-clamp).
    private static func wrap(_ s: String, _ face: FontLibrary.Face, _ size: Double, width: Double, limit: Int) -> [String] {
        let font = FontLibrary.font(face, size: size)
        func fits(_ t: String) -> Bool { TextRun(t, font: font).width <= width }
        var lines: [String] = [], current = ""
        for word in s.split(whereSeparator: \.isWhitespace).map(String.init) {
            let longer = current.isEmpty ? word : current + " " + word
            if current.isEmpty || fits(longer) { current = longer } else { lines.append(current); current = word }
        }
        if !current.isEmpty { lines.append(current) }
        guard lines.count > limit else { return lines }
        var last = lines[limit - 1] + " " + lines[limit]
        while !last.isEmpty, !fits(last + "…") { last.removeLast() }
        return Array(lines.prefix(limit - 1)) + [last.trimmingCharacters(in: .whitespaces) + "…"]
    }

    private static let photoLock = NSLock()
    nonisolated(unsafe) private static var photos: [String: CGImage] = [:]

    /// The reviewer's photo, read once per file.
    private static func photo(_ path: String) -> CGImage? {
        photoLock.lock(); defer { photoLock.unlock() }
        if let image = photos[path] { return image }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        photos[path] = image
        return image
    }

    /// What a card shows: the reviewer, the date, the review and her photo (a path; none = initials).
    struct CardReview: Hashable {
        var name: String, date: String, text: String, image: String?
        init(name: String, date: String, text: String, image: String?) { self.name = name; self.date = date; self.text = text; self.image = image }
        init(_ r: Review) { self.init(name: r.name, date: r.date, text: r.text, image: r.avatar) }
    }

    /// A laid-out card: its size (top-left at the origin), its star squares, and how to draw it there.
    private struct ReviewCard {
        var size: CGSize
        var stars: [CGRect]
        var draw: (CGContext) -> Void
        var key: String
    }

    private static let cardLock = NSLock()
    nonisolated(unsafe) private static var cards: [String: ReviewCard] = [:]

    /// The card laid out once per review and look (its line breaks measure every word). `height`: at least this tall
    /// (the slider's cards are all as tall as the tallest), the extra space at the bottom.
    private static func reviewCard(_ r: CardReview, scale k: Double, height: Double = 0, shadow: Bool = true) -> ReviewCard {
        let key = "card|\(k)|\(Int(height))|\(shadow)|\(r.image ?? "")|\(r.name)|\(r.date)|\(r.text)"
        cardLock.lock(); defer { cardLock.unlock() }
        if let made = cards[key] { return made }
        if cards.count > 96 { cards.removeAll() }            // every edit of a text makes a new one
        let made = layoutCard(r, k: k, minHeight: height, shadow: shadow, key: key)
        cards[key] = made
        return made
    }

    private static func layoutCard(_ r: CardReview, k: Double, minHeight: Double, shadow: Bool, key: String) -> ReviewCard {
        let name = r.name, date = r.date
        let width = 640 * k, border = 2 * k, pad = 36 * k
        let x0 = border + pad, inner = width - 2 * border - 2 * pad
        let lines = wrap(r.text.replacingOccurrences(of: "|", with: " "), .inter400, 31 * k, width: inner, limit: 5)
        // heights from the card's top, as the kit's CSS stacks them
        let header = border + pad, side = 92 * k
        let starsTop = header + side + 26 * k, star = 36 * k
        let textTop = starsTop + star + 18 * k, lineHeight = 31 * 1.45 * k
        let moreTop = textTop + Double(lines.count) * lineHeight + 4 * k, moreHeight = normal(.inter400, 31 * k)
        let repliedTop = moreTop + moreHeight + 26 * k, repliedHeight = max(normal(.inter400, 28 * k), 22 * k)
        let footTop = repliedTop + repliedHeight + 34 * k, footHeight = max(30 * k, normal(.inter400, 28 * k))
        let height = max(minHeight, footTop + footHeight + 30 * k + border)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let top = 0.0
        let stars = (0..<5).map { CGRect(x: x0 + Double($0) * (star + 3 * k), y: starsTop, width: star, height: star) }

        let draw: (CGContext) -> Void = { c in
            let shape = Paint.roundedRect(rect, radius: 30 * k)
            if shadow {
                Paint.dropShadow(c, Shadow(dx: 0, dy: 18 * k, blur: 50 * k, color: Paint.rgba(0, 0, 0, 0.22))) { cc in
                    cc.addPath(shape); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
            } else {
                c.addPath(shape); c.setFillColor(Paint.rgba(255, 255, 255)); c.fillPath()
            }
            c.addPath(Paint.roundedRect(rect.insetBy(dx: border / 2, dy: border / 2), radius: 30 * k - border / 2))
            c.setStrokeColor(Paint.hex("#E3E3DD")); c.setLineWidth(border); c.strokePath()
            // photo, or her initials on a pastel circle
            let avatar = CGRect(x: x0, y: top + header, width: side, height: side)
            c.saveGState()
            c.addEllipse(in: avatar); c.clip()
            if let path = r.image, let image = photo(path) {
                let s = max(side / Double(image.width), side / Double(image.height))
                let w = Double(image.width) * s, h = Double(image.height) * s
                c.interpolationQuality = .high
                c.translateBy(x: avatar.midX - w / 2, y: avatar.midY + h / 2)
                c.scaleBy(x: 1, y: -1)
                c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                let pastel = ["#F7D9C4", "#DCE8F7", "#E3F1DA", "#F5DCE6", "#FFF1C4"]
                c.setFillColor(Paint.hex(pastel[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % pastel.count]))
                c.fill(avatar)
                let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
                let size = 34 * k
                let probe = text(initials, .inter600, size, x: 0, top: 0, lineHeight: size)
                let label = text(initials, .inter600, size, x: avatar.midX - probe.width / 2, top: avatar.midY - size / 2, lineHeight: size)
                c.addPath(label.path); c.setFillColor(Paint.hex("#3A3A3A")); c.fillPath()
            }
            c.restoreGState()

            // name and date beside it
            let nameHeight = 34 * 1.15 * k, dateHeight = normal(.inter400, 29 * k)
            let block = top + header + (side - (nameHeight + 6 * k + dateHeight)) / 2
            let nx = x0 + side + 22 * k
            c.addPath(text(name, .inter600, 34 * k, x: nx, top: block, lineHeight: nameHeight, letterSpacing: -0.2 * k).path)
            c.setFillColor(Paint.hex("#191919")); c.fillPath()
            c.addPath(text(date, .inter400, 29 * k, x: nx, top: block + nameHeight + 6 * k, lineHeight: dateHeight).path)
            c.setFillColor(Paint.hex("#6C6C85")); c.fillPath()

            // the review
            for (i, line) in lines.enumerated() {
                c.addPath(text(line, .inter400, 31 * k, x: x0, top: top + textTop + Double(i) * lineHeight, lineHeight: lineHeight).path)
            }
            c.setFillColor(Paint.hex("#191919")); c.fillPath()
            c.addPath(text("See more", .inter400, 31 * k, x: x0, top: top + moreTop, lineHeight: moreHeight).path)
            c.setFillColor(Paint.hex("#1C5FE0")); c.fillPath()

            // ↳ Company replied
            let hook = CGMutablePath(), hx = x0 + border / 2, hy = top + repliedTop + repliedHeight / 2 - 11 * k - 5 * k
            hook.move(to: CGPoint(x: hx, y: hy))
            hook.addLine(to: CGPoint(x: hx, y: hy + 22 * k - 14 * k))
            hook.addQuadCurve(to: CGPoint(x: hx + 14 * k, y: hy + 22 * k - border / 2), control: CGPoint(x: hx, y: hy + 22 * k - border / 2))
            hook.addLine(to: CGPoint(x: hx + 22 * k, y: hy + 22 * k - border / 2))
            c.addPath(hook); c.setStrokeColor(Paint.hex("#C9C9C9")); c.setLineWidth(border); c.strokePath()
            c.addPath(text("Company replied", .inter400, 28 * k, x: x0 + 36 * k, top: top + repliedTop, lineHeight: repliedHeight).path)
            c.setFillColor(Paint.hex("#6C6C85")); c.fillPath()

            // 👍 Useful   ⤴ Share   ⚑
            let icon = 30 * k, iconTop = top + footTop + (footHeight - icon) / 2
            var x = x0
            for (glyph, label) in [(thumbIcon, "Useful"), (shareIcon, "Share"), (flagIcon, "")] {
                var place = CGAffineTransform(a: icon / 24, b: 0, c: 0, d: icon / 24, tx: x, ty: iconTop)
                if let path = glyph.copy(using: &place) {
                    c.addPath(path); c.setStrokeColor(Paint.hex("#3A3A3A")); c.setLineWidth(1.6 * icon / 24)
                    c.setLineJoin(.round); c.setLineCap(.round); c.strokePath()
                }
                x += icon
                if !label.isEmpty {
                    let t = text(label, .inter400, 28 * k, x: x + 12 * k, top: top + footTop, lineHeight: footHeight)
                    c.addPath(t.path); c.setFillColor(Paint.hex("#3A3A3A")); c.fillPath()
                    x += 12 * k + t.width
                }
                x += 44 * k
            }
        }
        return ReviewCard(size: rect.size, stars: stars, draw: draw, key: key)
    }

    /// A card's picture (shadow and all), top-left at the origin.
    private static func cardSprite(_ card: ReviewCard, _ ctx: CGContext) -> SpriteCache.Sprite? {
        SpriteCache.shared.sprite(card.key, scale: Paint.deviceScale(ctx) * 1.1,
                                  bounds: CGRect(origin: .zero, size: card.size).insetBy(dx: -150, dy: -150), card.draw)
    }

    /// The kit's footer icons, in their 24 × 24 boxes (arcs as quadratic curves).
    private static let thumbIcon: CGPath = {
        let p = CGMutablePath()
        p.addRect(CGRect(x: 4, y: 10, width: 3, height: 10))
        p.move(to: CGPoint(x: 7, y: 10))
        p.addLine(to: CGPoint(x: 11, y: 3))
        p.addCurve(to: CGPoint(x: 13.2, y: 5.6), control1: CGPoint(x: 12.5, y: 3), control2: CGPoint(x: 13.5, y: 4))
        p.addLine(to: CGPoint(x: 12.6, y: 9))
        p.addLine(to: CGPoint(x: 19, y: 9))
        p.addQuadCurve(to: CGPoint(x: 21, y: 11.3), control: CGPoint(x: 21.2, y: 9.2))
        p.addLine(to: CGPoint(x: 19.8, y: 18.3))
        p.addQuadCurve(to: CGPoint(x: 17.8, y: 20), control: CGPoint(x: 19.5, y: 20))
        p.addLine(to: CGPoint(x: 7, y: 20))
        return p
    }()

    private static let shareIcon: CGPath = {
        let p = CGMutablePath()
        for (x, y) in [(18.0, 5.0), (6.0, 12.0), (18.0, 19.0)] { p.addEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)) }
        p.move(to: CGPoint(x: 8.2, y: 10.8)); p.addLine(to: CGPoint(x: 15.8, y: 6.4))
        p.move(to: CGPoint(x: 8.2, y: 13.2)); p.addLine(to: CGPoint(x: 15.8, y: 17.6))
        return p
    }()

    private static let flagIcon: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 5, y: 21)); p.addLine(to: CGPoint(x: 5, y: 4)); p.addLine(to: CGPoint(x: 16, y: 4))
        p.addLine(to: CGPoint(x: 14, y: 8)); p.addLine(to: CGPoint(x: 16, y: 12)); p.addLine(to: CGPoint(x: 5, y: 12))
        return p
    }()

    /// Trustpilot's star, white on its green square (viewBox 24, drawn 27 of 36).
    private static let starPath: CGPath = {
        let pts: [(Double, Double)] = [(12, 2.5), (14.8, 8.8), (21.7, 9.4), (16.5, 14), (18.1, 20.8), (12, 17.2),
                                       (5.9, 20.8), (7.5, 14), (2.3, 9.4), (9.2, 8.8)]
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
        p.closeSubpath()
        return p
    }()

    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
    private static func easeOut3(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func backOut(_ x: Double) -> Double { 1 + 2.70158 * pow(x - 1, 3) + 1.70158 * pow(x - 1, 2) }

    /// Trustpilot's green squares with their white stars, each at its own scale (0 = not there yet).
    private static func drawStars(_ c: CGContext, _ stars: [CGRect], scales: [Double]) {
        for (box, scale) in zip(stars, scales) where scale > 0.001 {
            c.saveGState()
            c.concatenate(Motion(scale: scale).transform(origin: CGPoint(x: box.midX, y: box.minY + 0.6 * box.height)))
            c.setFillColor(Paint.hex("#00B67A")); c.fill(box)
            let s = box.width * 27 / 36 / 24
            var place = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: box.midX - 12 * s, ty: box.midY - 12 * s)
            if let star = starPath.copy(using: &place) { c.addPath(star); c.setFillColor(Paint.rgba(255, 255, 255)); c.fillPath() }
            c.restoreGState()
        }
    }

    /// A card dropping in as the kit's comment cards do: from the side `side` (−1 left, 1 right) and below, turning
    /// in to its resting tilt, 70% → overshoot → 100%, the blur clearing; then its stars pop in one after another.
    /// `origin`: its top-left on the stage; `t0`: when it starts, `dt`: the time into the graphic.
    private static func dropCard(_ card: ReviewCard, _ ctx: CGContext, origin: CGPoint, rest: Double, side: Double,
                                 t0: Double, length: Double, dt: Double, fade: Double) {
        let a = clamp01((dt - t0) / length)
        let opacity = min(1, a * 3) * fade
        guard opacity > 0.001, let sprite = cardSprite(card, ctx) else { return }
        var m = Motion()
        m.dx = side * (1 - easeOut3(a)) * 260
        m.dy = (1 - easeOut3(a)) * 120
        m.rotate = rest + (1 - backOut(a)) * 14 * side
        m.scale = 0.7 + 0.3 * backOut(a)
        let blur = (1 - min(1, a * 1.6)) * 10
        let pops = (0..<5).map { i -> Double in
            let q = clamp01((dt - (t0 + 0.18 + Double(i) * 0.05)) / 0.14)
            return q > 0 ? 0.4 + 0.6 * backOut(q) : 0
        }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.concatenate(m.transform(origin: CGPoint(x: card.size.width / 2, y: card.size.height / 2)))
        Paint.layer(ctx, opacity: opacity) { c in
            SpriteCache.draw(sprite, in: c, blur: blur)
            drawStars(c, card.stars, scales: pops)
        }
        ctx.restoreGState()
    }

    /// T8: one card, larger, centred above the captions; a slow push-in while it is read, a fade out.
    private static func t8(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, fade = clamp01((d - dt) / 0.3)
        guard fade > 0 else { return }
        let who = title.reviewer
        let card = reviewCard(CardReview(name: who.name, date: who.date, text: title.text, image: title.image), scale: card)
        let left = 540 - card.size.width / 2
        let top = min(960 - card.size.height / 2, 1920 * 0.66 - 45 - card.size.height)     // clear of the captions
        let push = 1 + 0.04 * easeOut3(clamp01((dt - 0.5) / max(0.5, d - 0.5)))
        ctx.saveGState()
        ctx.concatenate(Motion(scale: push).transform(origin: CGPoint(x: 540, y: top + card.size.height / 2)))
        dropCard(card, ctx, origin: CGPoint(x: left, y: top), rest: -1.5, side: -1, t0: 0.08, length: 0.45, dt: dt, fade: fade)
        ctx.restoreGState()
    }

    // MARK: T9 · a collage of reviews, T10 · the review slider — the kit's "comments" and "reviews_carousel" scenes

    /// The kit's places for four cards, 640 px wide: top-left and resting tilt.
    private static let collage: [(Double, Double, Double)] = [(80, 300, -5), (360, 470, 4), (70, 700, -3), (380, 880, 5)]

    /// Up to four cards dropping in one after another (0.42 s apart), fanned, the whole collage slowly pushing in.
    private static func t9(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, fade = clamp01((d - dt) / 0.3)
        let reviews = Array((title.reviews ?? []).prefix(collage.count))
        guard fade > 0, !reviews.isEmpty else { return }
        ctx.saveGState()
        ctx.concatenate(Motion(scale: 1 + 0.05 * easeOut3(clamp01((dt - 0.3) / max(0.3, d - 0.3)))).transform(origin: CGPoint(x: 540, y: 1920 * 0.45)))
        for (k, review) in reviews.enumerated() {
            let (x, y, rest) = collage[k]
            dropCard(reviewCard(CardReview(review), scale: 1), ctx, origin: CGPoint(x: x, y: y), rest: rest, side: k % 2 == 1 ? 1 : -1,
                     t0: 0.08 + Double(k) * 0.42, length: 0.38, dt: dt, fade: fade)
        }
        ctx.restoreGState()
    }

    /// The white "Reviews shaping this summary" panel rising in; its cards (as tall as the tallest) slide one card
    /// to the left every 0.9 s from 0.9 s, each slide after a press on the arrow — as many as the cards and time allow.
    private static func t10(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration
        let reviews = title.reviews ?? []
        let a = clamp01(dt / 0.35), out = clamp01((dt - (d - 0.3)) / 0.3)
        let opacity = min(1, a * 2) * (1 - out)
        guard opacity > 0.001, !reviews.isEmpty else { return }
        let h = reviews.map { reviewCard(CardReview($0), scale: 1, shadow: false).size.height }.max() ?? 0
        let cards = reviews.map { reviewCard(CardReview($0), scale: 1, height: h, shadow: false) }
        let panel = CGRect(x: 40, y: 960 - (170 + h) / 2, width: 1000, height: 130 + h + 40)
        let snaps = min(reviews.count - 1, max(0, Int((d - 1.55) / 0.9) + 1))
        let times = (0..<snaps).map { 0.9 + Double($0) * 0.9 }
        let slid = times.reduce(0) { $0 + 674 * easeOut3(clamp01((dt - $1) / 0.35)) }
        let press = times.map { sin(clamp01((dt - ($0 - 0.15)) / 0.25) * .pi) }.max() ?? 0
        var m = Motion()
        m.dy = (1 - easeOut3(a)) * 160
        m.scale = 0.9 + 0.1 * backOut(a)
        let heading = title.text.trimmingCharacters(in: .whitespaces).isEmpty ? "Reviews shaping this summary" : title.text
        ctx.saveGState()
        ctx.concatenate(m.transform(origin: CGPoint(x: panel.midX, y: panel.midY)))
        Paint.layer(ctx, opacity: opacity) { c in
            if let sprite = SpriteCache.shared.sprite("T10.panel|\(Int(h))|" + heading, scale: Paint.deviceScale(c) * 1.1,
                                                      bounds: panel.insetBy(dx: -150, dy: -150), { pc in
                Paint.dropShadow(pc, Shadow(dx: 0, dy: 20, blur: 60, color: Paint.rgba(0, 0, 0, 0.25))) { cc in
                    cc.addPath(Paint.roundedRect(panel, radius: 34)); cc.setFillColor(Paint.rgba(255, 255, 255)); cc.fillPath()
                }
                pc.addPath(text(heading, .inter700, 44, x: panel.minX + 40, top: panel.minY + 44, lineHeight: normal(.inter700, 44),
                                letterSpacing: -0.3).path)
                pc.setFillColor(Paint.hex("#191919")); pc.fillPath()
            }) { SpriteCache.draw(sprite, in: c) }
            // the cards slide inside the panel
            c.saveGState()
            c.addPath(Paint.roundedRect(panel, radius: 34)); c.clip()
            for (i, card) in cards.enumerated() {
                let left = panel.minX + 40 + Double(i) * 674 - slid
                guard left < panel.maxX, left + card.size.width > panel.minX, let sprite = cardSprite(card, c) else { continue }
                c.saveGState()
                c.translateBy(x: left, y: panel.minY + 130)
                SpriteCache.draw(sprite, in: c)
                drawStars(c, card.stars, scales: [1, 1, 1, 1, 1])
                c.restoreGState()
            }
            c.restoreGState()
            // the arrow
            let ring = CGRect(x: panel.maxX - 30 - 78, y: panel.midY - 39, width: 78, height: 78)
            c.saveGState()
            c.concatenate(Motion(scale: 1 - 0.14 * press).transform(origin: CGPoint(x: ring.midX, y: ring.midY)))
            Paint.dropShadow(c, Shadow(dx: 0, dy: 4, blur: 14, color: Paint.rgba(0, 0, 0, 0.12))) { cc in
                cc.addEllipse(in: ring); cc.setFillColor(Paint.hex(press > 0.3 ? "#EEF0FF" : "#FFFFFF")); cc.fillPath()
            }
            c.addEllipse(in: ring.insetBy(dx: 1.5, dy: 1.5)); c.setStrokeColor(Paint.hex("#3C4FC4")); c.setLineWidth(3); c.strokePath()
            let s = 34.0 / 24, ox = ring.midX - 17, oy = ring.midY - 17
            c.move(to: CGPoint(x: ox + 9 * s, y: oy + 5 * s))
            c.addLine(to: CGPoint(x: ox + 16 * s, y: oy + 12 * s))
            c.addLine(to: CGPoint(x: ox + 9 * s, y: oy + 19 * s))
            c.setLineWidth(2 * s); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
            c.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: T2 · the lipstick writes

    private static let tube: CGImage? = {
        guard let url = FontLibrary.directory?.deletingLastPathComponent().appending(path: "Brand/tube.webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    private static func t2(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, e = developed(dt, d)
        // no glyphs to write (empty, "|" alone, letters the script lacks): the line underneath still shows
        guard let script = Handwriting.paths(for: title.text) else { kicker(ctx, title, top: 1920 * 0.55 + 60, dt: dt, late: true); return }
        let wide = script.height > 1500 || script.width > 4500
        let boxX = 1080 * (wide ? 0.06 : 0.12), boxW = 1080 * (wide ? 0.88 : 0.76), boxY = 1920 * (wide ? 0.53 : 0.55)
        let s = boxW / script.width
        let svg = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: boxX, ty: boxY)
        let strokeWidth = 92 * script.width / 3983
        let write = title.text.contains("|") ? 2.4 : 1.6
        let w0 = 0.2, w1 = w0 + write
        let p = max(0, min(1, (dt - w0) / write))
        let ease = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        let lines = script.paths.map { Paths.polylines($0) }
        let lengths = lines.map { $0.reduce(0) { $0 + Paths.length($1) } }
        var left = ease * lengths.reduce(0, +)
        var pen: CGPoint?
        let boxOpacity = dt < d - 0.6 ? 1 : max(0, 1 - (dt - (d - 0.6)) / 0.6)

        // each stroke carries its own wax filter, its region cut from its own bounding box; the svg casts one shadow
        let paint: (CGContext, Double, Double) -> Void = { c, e, budget in
            var left = budget
            Paint.dropShadow(c, Shadow(dx: 0, dy: 1080 * 0.0025, blur: 1080 * 0.005, color: Paint.rgba(40, 0, 10, 0.55))) { cc in
                for (i, path) in script.paths.enumerated() {
                    let drawn = max(0, min(lengths[i], left))
                    left -= lengths[i]
                    guard drawn > 0 else { continue }
                    waxed(cc, svg: svg, bbox: path.boundingBoxOfPath) { l in
                        stroke(l, path: path, from: 0, to: drawn, width: strokeWidth, svg: svg,
                               gradient: gradient(lipStroke, e), alpha: 0.7 + 0.3 * e)
                    }
                }
            }
        }
        let total = lengths.reduce(0, +)
        for (i, _) in script.paths.enumerated() {                 // where the pen is now
            let drawn = max(0, min(lengths[i], left))
            left -= lengths[i]
            if drawn > 0 { pen = Paths.point(along: lines[i], at: drawn).map { $0.applying(svg) } }
        }
        let budget = ease * total
        if budget >= total - 0.01 {
            let all = script.paths.reduce(CGRect.null) { $0.union(waxRegion($1.boundingBoxOfPath, svg)) }.insetBy(dx: -20, dy: -20)
            developing(ctx, key: "T2|" + title.text, bounds: all, e: e, opacity: boxOpacity) { c, e in paint(c, e, total) }
        } else {
            Paint.layer(ctx, opacity: boxOpacity) { paint($0, e, budget) }
        }
        kicker(ctx, title, top: boxY + script.height * s + 0.35 * 1080 * 0.031, dt: dt, late: true)

        // the real tube rides on the pen point, then lifts off up and to the right
        guard let pen, dt < w1 + 0.35, let tube else { return }
        let lift = max(0, dt - w1) / 0.35
        let width = 1080 * 0.075, height = width * 684 / 170
        let opacity = dt < w0 ? dt / w0 : 1 - lift
        guard opacity > 0 else { return }
        let origin = CGPoint(x: pen.x + lift * 40, y: pen.y - lift * 60)
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.rotate(by: -62 * .pi / 180)
        Paint.layer(ctx, opacity: opacity) { c in
            Paint.dropShadow(c, Shadow(dx: 0, dy: 1080 * 0.012, blur: 1080 * 0.016, color: Paint.rgba(0, 0, 0, 0.45))) { cc in
                cc.translateBy(x: 0, y: height)
                cc.scaleBy(x: 1, y: -1)
                cc.draw(tube, in: CGRect(x: -width / 2, y: 0, width: width, height: height))
            }
        }
        ctx.restoreGState()
    }

    // MARK: T3 · smear band

    private static func t3(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, e = developed(dt, d)
        let band = CGRect(x: 1080 * 0.07, y: 960, width: 1080 * 0.86, height: 1920 * 0.21)
        let clock = Clock(duration: d, easing: CubicBezier(0.7, 0, 0.2, 1))
        let hidden = clock.value(Track([(0, 1), (0.03, 1), (0.16, 0), (0.78, 0), (0.90, 0), (1, 1)]), dt)   // clip-path inset right
        let blur = clock.value(Track([(0, 0), (0.03, 0), (0.16, 0), (0.78, 0), (0.90, 14), (1, 14)]), dt)
        let opacity = clock.value(Track([(0, 1), (0.03, 1), (0.16, 1), (0.78, 1), (0.90, 0), (1, 0)]), dt)
        guard opacity > 0.001, hidden < 1 else { kicker(ctx, title, top: 1920 * 0.75, dt: dt); return }

        ctx.saveGState()
        ctx.translateBy(x: band.midX, y: band.midY)
        ctx.rotate(by: -4 * .pi / 180)
        ctx.translateBy(x: -band.midX, y: -band.midY)
        ctx.clip(to: CGRect(x: band.minX, y: band.minY, width: band.width * (1 - hidden), height: band.height))
        let local = CGAffineTransform(translationX: band.minX, y: band.minY)
        let shape = smearShape(CGSize(width: band.width, height: band.height))
        let size = 1080 * 0.125
        let text = title.text.replacingOccurrences(of: "|", with: " ")
        let label = line(text, face: .archivoBlack, size: size, top: band.midY - size / 2, uppercase: true, letterSpacing: 0.01, center: band.midX)
        let smear: (CGContext, Double) -> Void = { c, e in
            // the smear: a waxy 100° gradient with uneven corners
            waxed(c, svg: local, bbox: CGRect(origin: .zero, size: band.size)) { l in
                l.saveGState()
                var place = local
                l.addPath(shape.copy(using: &place) ?? shape)
                l.clip()
                let stops: [(String, Double)] = [("#9e2236", 0), ("#d24c5e", 0.45), ("#e98a93", 0.6), ("#b02c40", 1)]
                let angle = 100.0 * .pi / 180
                let dir = CGPoint(x: sin(angle), y: -cos(angle))
                let length = abs(band.width * sin(angle)) + abs(band.height * cos(angle))
                l.drawLinearGradient(gradient(stops, e),
                                     start: CGPoint(x: band.midX - dir.x * length / 2, y: band.midY - dir.y * length / 2),
                                     end: CGPoint(x: band.midX + dir.x * length / 2, y: band.midY + dir.y * length / 2),
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                l.restoreGState()
            }
        }
        let whole: (CGContext) -> Void = { c in
            developing(c, key: "T3.band", bounds: waxRegion(CGRect(origin: .zero, size: band.size), local), e: e, opacity: 0.7 + 0.3 * e, smear)
            headline(c, key: "T3.text|" + text, label, color: Paint.rgba(255, 255, 255), shadow: nil, opacity: 1)
        }
        if blur > 0.05 {
            Paint.blurred(ctx, sigma: blur, bounds: band.insetBy(dx: -20, dy: -20), opacity: opacity, whole)   // the melt
        } else {
            Paint.layer(ctx, opacity: opacity, whole)
        }
        ctx.restoreGState()
        kicker(ctx, title, top: 1920 * 0.75, dt: dt)
    }

    /// `border-radius: 30% 8% 25% 12%` on a w×h box.
    static func smearShape(_ size: CGSize) -> CGPath {
        let w = size.width, h = size.height
        let tl = (0.30 * w, 0.30 * h), tr = (0.08 * w, 0.08 * h), br = (0.25 * w, 0.25 * h), bl = (0.12 * w, 0.12 * h)
        let k = 0.5522847498
        let p = CGMutablePath()
        p.move(to: CGPoint(x: tl.0, y: 0))
        p.addLine(to: CGPoint(x: w - tr.0, y: 0))
        p.addCurve(to: CGPoint(x: w, y: tr.1), control1: CGPoint(x: w - tr.0 + tr.0 * k, y: 0), control2: CGPoint(x: w, y: tr.1 - tr.1 * k))
        p.addLine(to: CGPoint(x: w, y: h - br.1))
        p.addCurve(to: CGPoint(x: w - br.0, y: h), control1: CGPoint(x: w, y: h - br.1 + br.1 * k), control2: CGPoint(x: w - br.0 + br.0 * k, y: h))
        p.addLine(to: CGPoint(x: bl.0, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - bl.1), control1: CGPoint(x: bl.0 - bl.0 * k, y: h), control2: CGPoint(x: 0, y: h - bl.1 + bl.1 * k))
        p.addLine(to: CGPoint(x: 0, y: tl.1))
        p.addCurve(to: CGPoint(x: tl.0, y: 0), control1: CGPoint(x: 0, y: tl.1 - tl.1 * k), control2: CGPoint(x: tl.0 - tl.0 * k, y: 0))
        p.closeSubpath()
        return p
    }

    // MARK: T4 · kiss stamp

    static let lips: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 58))
        p.addCurve(to: CGPoint(x: 100, y: 40), control1: CGPoint(x: 38, y: 30), control2: CGPoint(x: 70, y: 18))
        p.addCurve(to: CGPoint(x: 192, y: 58), control1: CGPoint(x: 130, y: 18), control2: CGPoint(x: 162, y: 30))
        p.addCurve(to: CGPoint(x: 100, y: 61), control1: CGPoint(x: 150, y: 60), control2: CGPoint(x: 122, y: 54))
        p.addCurve(to: CGPoint(x: 8, y: 58), control1: CGPoint(x: 78, y: 54), control2: CGPoint(x: 50, y: 60))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8, y: 62))
        p.addCurve(to: CGPoint(x: 100, y: 69), control1: CGPoint(x: 50, y: 66), control2: CGPoint(x: 80, y: 64))
        p.addCurve(to: CGPoint(x: 192, y: 62), control1: CGPoint(x: 120, y: 64), control2: CGPoint(x: 150, y: 66))
        p.addCurve(to: CGPoint(x: 100, y: 116), control1: CGPoint(x: 162, y: 104), control2: CGPoint(x: 132, y: 116))
        p.addCurve(to: CGPoint(x: 8, y: 62), control1: CGPoint(x: 68, y: 116), control2: CGPoint(x: 38, y: 104))
        p.closeSubpath()
        return p
    }()

    private static func t4(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, e = developed(dt, d)
        // ring
        let ring = Clock(duration: d, easing: .easeOut)
        let ringOpacity = ring.value(Track([(0, 0), (0.09, 0), (0.10, 0.9), (0.24, 0), (1, 0)]), dt)
        let ringScale = ring.value(Track([(0, 0.4), (0.09, 0.4), (0.10, 0.5), (0.24, 1.9), (1, 1.9)]), dt)
        if ringOpacity > 0.001 {
            let side = 1080 * 0.30, border = 1080 * 0.006
            let r = CGRect(x: 540 - side / 2, y: 1920 * 0.45 - side / 2, width: side, height: side)
            ctx.saveGState()
            ctx.concatenate(Motion(scale: ringScale).transform(origin: CGPoint(x: r.midX, y: r.midY)))
            ctx.setAlpha(ringOpacity)
            ctx.addEllipse(in: r.insetBy(dx: border / 2, dy: border / 2))
            ctx.setLineWidth(border)
            ctx.setStrokeColor(Paint.rgba(232, 163, 169, 0.8))
            ctx.strokePath()
            ctx.restoreGState()
        }
        // lips: an SVG 40% × 14% at (30%, 38%), viewBox 200×120 fitted (xMidYMid meet)
        let stamp = Clock(duration: d, easing: CubicBezier(0.3, 0, 0.3, 1))
        let opacity = stamp.value(Track([(0, 0), (0.03, 0), (0.10, 1), (0.78, 1), (0.90, 0), (1, 0)]), dt)
        let scale = stamp.value(Track([(0, 2.4), (0.03, 2.4), (0.10, 0.88), (0.14, 1.06), (0.18, 1), (0.78, 1), (0.90, 0.96), (1, 0.96)]), dt)
        let rotate = stamp.value(Track([(0, -14), (0.03, -14), (0.10, -8), (0.14, -10), (0.18, -9), (0.78, -9), (0.90, -9), (1, -9)]), dt)
        if opacity > 0.001 {
            let box = CGRect(x: 1080 * 0.30, y: 1920 * 0.38, width: 1080 * 0.40, height: 1920 * 0.14)
            let s = min(box.width / 200, box.height / 120)
            let svg = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: box.minX + (box.width - 200 * s) / 2, ty: box.minY + (box.height - 120 * s) / 2)
            let resolution = Paint.deviceScale(ctx) * 2.4          // enough for the stamp's largest moment
            ctx.saveGState()
            var m = Motion(scale: scale); m.rotate = rotate
            ctx.concatenate(m.transform(origin: CGPoint(x: box.midX, y: box.midY)))
            let region = lips.boundingBoxOfPath
            let filterBox = CGRect(x: region.minX - 0.1 * region.width, y: region.minY - 0.1 * region.height,
                                   width: region.width * 1.2, height: region.height * 1.2).applying(svg)
            developing(ctx, key: "T4.lips", bounds: filterBox.insetBy(dx: -2, dy: -2), e: e, opacity: opacity * (0.7 + 0.3 * e),
                       scale: resolution) { cc, e in
                LipstickFilter.apply(cc, bounds: filterBox, user: svg.inverted(), opacity: 1,
                                     filter: LipstickFilter.printMask) { c in
                    c.saveGState()
                    var place = svg
                    c.addPath(lips.copy(using: &place) ?? lips)
                    c.clip()
                    let top = CGPoint(x: 0, y: region.minY).applying(svg), bottom = CGPoint(x: 0, y: region.maxY).applying(svg)
                    c.drawLinearGradient(gradient(lipRed, e), start: top, end: bottom, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    c.restoreGState()
                }
            }
            ctx.restoreGState()
        }
        // headline rises under it
        let main = Clock(duration: d, easing: CubicBezier(0.2, 0.9, 0.3, 1.15))
        let textOpacity = main.value(Track([(0, 0), (0.14, 0), (0.24, 1), (0.78, 1), (0.88, 0), (1, 0)]), dt)
        let size = 1080 * 0.13
        let rise = main.value(Track([(0, 0.5), (0.14, 0.5), (0.24, 0), (1, 0)]), dt) * size
        if textOpacity > 0.001 {
            let text = title.text.replacingOccurrences(of: "|", with: " ")
            let l = line(text, face: .frauncesItalic700, size: size, top: 1920 * 0.55)
            headline(ctx, key: "T4.text|" + text, l, color: Paint.hex("#fff4ea"),
                     shadow: Shadow(dx: 0, dy: 0.05 * size, blur: 0.25 * size, color: Paint.rgba(0, 0, 0, 0.5)), opacity: textOpacity, dy: rise)
        }
        kicker(ctx, title, top: 1920 * 0.55 + size + 4.8, dt: dt)
    }

    // MARK: T5 · swatch stack

    static let swatches: [CGPath] = [
        ((20, 40), (120, 20), (260, 30), (380, 18)),
        ((14, 66), (130, 50), (250, 60), (386, 44)),
        ((24, 92), (140, 80), (260, 88), (378, 72)),
    ].map { a, b, c, e in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: a.0, y: a.1))
        p.addCurve(to: CGPoint(x: e.0, y: e.1), control1: CGPoint(x: b.0, y: b.1), control2: CGPoint(x: c.0, y: c.1))
        return p
    }

    private static func t5(_ title: TitleItem, _ ctx: CGContext, _ dt: Double) {
        let d = title.duration, e = developed(dt, d)
        let svg = CGAffineTransform(a: 1080 * 0.92 / 400, b: 0, c: 0, d: 1920 * 0.30 / 120, tx: 1080 * 0.04, ty: 1920 * 0.44)
        let clock = Clock(duration: d, easing: CubicBezier(0.6, 0, 0.2, 1))
        let colors = ["#c99a7a", "#d76b78", "#8e2a45"]
        let starts = [(0.02, 0.10), (0.06, 0.14), (0.10, 0.18)]
        let reach = swatches.map { min(Paths.length(Paths.polylines($0).first ?? []), 460 - clock.value(
            Track([(0, 460), (starts[swatches.firstIndex(of: $0)!].0, 460), (starts[swatches.firstIndex(of: $0)!].1, 0), (0.78, 0), (0.90, 460), (1, 460)]), dt)) }
        let paint: (CGContext, Double) -> Void = { c, e in
            for (i, path) in swatches.enumerated() where reach[i] > 0 {
                let color = develop(colors[i], e)
                waxed(c, svg: svg, bbox: path.boundingBoxOfPath) { l in
                    let grad = CGGradient(colorsSpace: Paint.srgb, colors: [color, color] as CFArray, locations: [0, 1])!
                    stroke(l, path: path, from: 0, to: reach[i], width: 26, svg: svg, gradient: grad, alpha: 1)
                }
            }
        }
        let full = zip(swatches, reach).allSatisfy { $1 >= Paths.length(Paths.polylines($0).first ?? []) - 0.001 }
        if full {
            let all = swatches.reduce(CGRect.null) { $0.union(waxRegion($1.boundingBoxOfPath, svg)) }
            developing(ctx, key: "T5.swatches", bounds: all, e: e, opacity: 0.7 + 0.3 * e, paint)
        } else {
            Paint.layer(ctx, opacity: 0.7 + 0.3 * e) { paint($0, e) }
        }
        // letters drop in one by one (each its own inline-block, 45 ms apart)
        let size = 1080 * 0.15
        let text = Array(title.text.replacingOccurrences(of: "|", with: " "))
        let font = FontLibrary.font(.dmSerifItalic, size: size)
        let runs = text.map { TextRun($0 == " " ? "\u{00A0}" : String($0), font: font) }
        let total = runs.reduce(0) { $0 + $1.width }
        let ascent = (runs.first?.ascent ?? size).rounded(), descent = (runs.first?.descent ?? 0).rounded()
        let baseline = 960 + (size - (ascent + descent)) / 2 + ascent
        var x = 540 - total / 2
        let letters = Clock(duration: d, easing: CubicBezier(0.2, 0.9, 0.3, 1.3))
        for (i, run) in runs.enumerated() {
            defer { x += run.width }
            let local = dt - Double(i) * 0.045
            let opacity = letters.value(Track([(0, 0), (0.18, 0), (0.25, 1), (0.78, 1), (0.88, 0), (1, 0)]), local)
            guard opacity > 0.001 else { continue }
            var m = Motion()
            m.dy = letters.value(Track([(0, -0.6), (0.18, -0.6), (0.25, 0), (1, 0)]), local) * size
            m.rotate = letters.value(Track([(0, -8), (0.18, -8), (0.25, 0), (1, 0)]), local)
            let box = CGRect(x: x, y: 960, width: run.width, height: size)
            var place = CGAffineTransform(translationX: x, y: baseline)
            guard let path = run.path.copy(using: &place),
                  let sprite = SpriteCache.shared.sprite("T5.letter|\(title.text)|\(i)", scale: Paint.deviceScale(ctx),
                                                         bounds: box.insetBy(dx: -size * 0.4, dy: -size * 0.4), { c in
                Paint.dropShadow(c, Shadow(dx: 0, dy: 0.04 * size, blur: 0.22 * size, color: Paint.rgba(60, 8, 20, 0.6))) { cc in
                    cc.addPath(path); cc.setFillColor(Paint.hex("#fff8f0")); cc.fillPath()
                }
            }) else { continue }
            ctx.saveGState()
            ctx.concatenate(m.transform(origin: CGPoint(x: box.midX, y: box.midY)))
            SpriteCache.draw(sprite, in: ctx, opacity: opacity)
            ctx.restoreGState()
        }
        kicker(ctx, title, top: 960 + size + 4.8 + 1080 * 0.07, dt: dt)
    }
}

extension Motion {
    init(scale: Double) { self.init(); self.scale = scale }
}

// MARK: - Handwriting

/// EMS Allure (SIL OFL), a single-line script: each glyph is a set of polylines the pen follows. The
/// title text becomes smoothed strokes in font units, lines 1000 units apart — as the V5 renderer did.
enum Handwriting {
    struct Script { let paths: [CGPath]; let width: Double; let height: Double }

    private static let glyphs: [String: (Double, String)] = {
        guard let url = FontLibrary.allureURL, let svg = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let pattern = #"<glyph unicode="([^"]*)"[^>]*?horiz-adv-x="([\d.]+)"(?:[^>]*?d="([^"]*)")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var out: [String: (Double, String)] = [:]
        let ns = svg as NSString
        for m in regex.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let key = unescape(ns.substring(with: m.range(at: 1)))
            let adv = Double(ns.substring(with: m.range(at: 2))) ?? 378
            let d = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
            out[key] = (adv, d)
        }
        return out
    }()

    /// XML character references as the font file writes them: named, and numeric (`&#xe9;`, `&#233;`) —
    /// accented letters, curly quotes and dashes are stored that way.
    private static func unescape(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&"), let semi = rest[amp...].firstIndex(of: ";") {
            out += rest[..<amp]
            let name = rest[rest.index(after: amp)..<semi]
            let named = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "amp": "&"]
            if let plain = named[String(name)] {
                out += plain
            } else if name.hasPrefix("#"), let value = name.hasPrefix("#x") || name.hasPrefix("#X")
                        ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
            } else {
                out += rest[amp...semi]
            }
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Script] = [:]

    static func paths(for text: String) -> Script? {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[text] { return s }
        let number = try! NSRegularExpression(pattern: #"(-?[\d.]+)\s+(-?[\d.]+)"#)
        var lines: [[[CGPoint]]] = []
        for line in text.split(separator: "|", omittingEmptySubsequences: false) {
            var pen = 0.0
            var strokes: [[CGPoint]] = []
            for ch in line {
                let (adv, d) = glyphs[String(ch)] ?? (378, "")
                for seg in d.components(separatedBy: "M") where !seg.isEmpty {
                    let ns = seg as NSString
                    let pts = number.matches(in: seg, range: NSRange(location: 0, length: ns.length)).compactMap { m -> CGPoint? in
                        guard let x = Double(ns.substring(with: m.range(at: 1))), let y = Double(ns.substring(with: m.range(at: 2))) else { return nil }
                        return CGPoint(x: x + pen, y: 800 - y)
                    }
                    if !pts.isEmpty { strokes.append(pts) }
                }
                pen += adv
            }
            lines.append(strokes)
        }
        let widths = lines.map { l -> Double in
            let xs = l.flatMap { $0.map(\.x) }
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        guard let widest = widths.max(), widest > 0 else { return nil }
        let w = widest + 120
        var paths: [CGPath] = []
        var y0 = 0.0
        for (l, lw) in zip(lines, widths) {
            let x0 = l.flatMap { $0.map(\.x) }.min() ?? 0, ymin = l.flatMap { $0.map(\.y) }.min() ?? 0
            let dx = (w - lw) / 2 - x0, dy = 60 + y0 - ymin
            for stroke in l { paths.append(smooth(stroke.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })) }
            y0 += 1000
        }
        let script = Script(paths: paths, width: w.rounded(), height: (y0 + 150).rounded())
        if cache.count > 64 { cache.removeAll() }            // every string typed while editing a title lands here
        cache[text] = script
        return script
    }

    /// Catmull-Rom through the points as cubic Béziers, coordinates rounded to 0.1 like the path text the
    /// web version parses.
    private static func smooth(_ pts: [CGPoint]) -> CGPath {
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func R(_ p: CGPoint) -> CGPoint { CGPoint(x: r(p.x), y: r(p.y)) }
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: R(first))
        if pts.count < 3 { pts.dropFirst().forEach { path.addLine(to: R($0)) }; return path }
        let p = [pts[0]] + pts + [pts[pts.count - 1]]
        for i in 1..<(p.count - 2) {
            let p0 = p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = p[i + 2]
            path.addCurve(to: R(p2),
                          control1: R(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)),
                          control2: R(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)))
        }
        return path
    }
}
