import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Text as outlines, laid out the way a browser lays out one inline run: kerning on, letter-spacing
/// added after every character (the last one too), baseline at y = 0, y growing downwards.
struct TextRun {
    let path: CGPath
    let width: Double
    let ascent: Double
    let descent: Double
    let font: CTFont
    /// Colour glyphs (emoji) have no outline: they are kept as glyphs and drawn as they are (`drawColorGlyphs`).
    let colorGlyphs: [(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint])]

    init(_ text: String, font: CTFont, letterSpacing: Double = 0) {
        self.font = font
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if letterSpacing != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing
            // browsers drop optional ligatures (fi, fl) once letter-spacing is set; "fifties" must not narrow here alone
            attributes[NSAttributedString.Key(kCTLigatureAttributeName as String)] = 0
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)

        let out = CGMutablePath()
        var colour: [(font: CTFont, glyphs: [CGGlyph], positions: [CGPoint])] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runFont = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont?) ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { colour.append((runFont, glyphs, positions)); continue }
            for i in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // glyph outlines are y-up; flip into the y-down stage
                let m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: -positions[i].y)
                out.addPath(glyph, transform: m)
            }
        }
        path = out
        colorGlyphs = colour
    }

    /// The colour glyphs, the line's baseline start at `origin` on the y-down stage.
    func drawColorGlyphs(_ ctx: CGContext, at origin: CGPoint) {
        guard !colorGlyphs.isEmpty else { return }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        for g in colorGlyphs { CTFontDrawGlyphs(g.font, g.glyphs, g.positions, g.glyphs.count, ctx) }
        ctx.restoreGState()
    }
}

/// A CSS text-shadow / box-shadow: offset and blur radius in px (σ = radius / 2), colour with alpha.
struct Shadow {
    var dx = 0.0, dy = 0.0, blur = 0.0
    var color: CGColor
}

enum Paint {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
    }

    static func hex(_ h: String, _ a: Double = 1) -> CGColor {
        let v = Int(h.dropFirst(), radix: 16) ?? 0
        return rgba(Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255), a)
    }


    static var shadowBlurScale = 2.0

    /// The device scale of the current transform (shadows are given in device space).
    static func deviceScale(_ ctx: CGContext) -> Double {
        let m = ctx.ctm
        return Double(hypot(m.a, m.b))
    }

    /// A vector in the current user space, as the device-space size Core Graphics wants for shadows
    /// (shadows ignore the transform, so rotation, scale and the y-flip are applied here).
    static func deviceVector(_ ctx: CGContext, _ dx: Double, _ dy: Double) -> CGSize {
        let m = ctx.ctm
        return CGSize(width: m.a * dx + m.c * dy, height: m.b * dx + m.d * dy)
    }

    /// CSS `filter: drop-shadow()` — and a single text-shadow or box-shadow: the shadow of everything
    /// `draw` paints, beneath it. Nest calls for a filter chain (drop-shadow(a) drop-shadow(b)).
    static func dropShadow(_ ctx: CGContext, _ s: Shadow, _ draw: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: deviceVector(ctx, s.dx, s.dy), blur: s.blur * deviceScale(ctx) * shadowBlurScale, color: s.color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Draws `draw` (stage coordinates, inside `bounds`) into a bitmap at `scale` device pixels per point and
    /// paints it back scaled up — for wide glows, which are blurs anyway, so a lower resolution loses nothing.
    static func lowResolution(_ ctx: CGContext, scale low: Double, bounds: CGRect, _ draw: (CGContext) -> Void) {
        let area = bounds.integral
        let w = Int((area.width * low).rounded(.up)), h = Int((area.height * low).rounded(.up))
        guard w > 0, h > 0,
              let off = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { draw(ctx); return }
        off.translateBy(x: 0, y: CGFloat(h))
        off.scaleBy(x: low, y: -low)
        off.translateBy(x: -area.minX, y: -area.minY)
        draw(off)
        guard let image = off.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: area.minX, y: area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: Double(w) / low, height: Double(h) / low))
        ctx.restoreGState()
    }

    /// Paints `shadows` under `draw` the way CSS does — every shadow cast by the content alone, the
    /// first listed on top — then the content. With several shadows the content is drawn far to the
    /// side with each shadow pulled back into view, so only the shadows land.
    static func withShadows(_ ctx: CGContext, _ shadows: [Shadow], _ draw: (CGContext) -> Void) {
        let visible = shadows.filter { $0.color.alpha > 0 }
        if visible.isEmpty { draw(ctx); return }
        if visible.count == 1 { dropShadow(ctx, visible[0], draw); return }
        let far = 100_000.0
        let away = deviceVector(ctx, far, 0)
        for s in visible.reversed() {
            ctx.saveGState()
            let offset = deviceVector(ctx, s.dx, s.dy)
            ctx.setShadow(offset: CGSize(width: offset.width - away.width, height: offset.height - away.height),
                          blur: s.blur * deviceScale(ctx) * shadowBlurScale, color: s.color)
            ctx.translateBy(x: far, y: 0)
            draw(ctx)
            ctx.restoreGState()
        }
        draw(ctx)
    }

    /// Draws into a transparency layer, so overlapping parts (stroke under fill) count as one shape
    /// for opacity and shadows.
    static func layer(_ ctx: CGContext, opacity: Double = 1, _ draw: (CGContext) -> Void) {
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func roundedRect(_ r: CGRect, radius: Double) -> CGPath {
        let rad = max(0, min(radius, min(r.width, r.height) / 2))
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    // MARK: Blur (CSS filter: blur(σ))

    private static let ci = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])

    /// Renders `draw` (in stage coordinates, inside `bounds`) to an offscreen bitmap, blurs it with
    /// a Gaussian of standard deviation `sigma` px and paints the result back. Used for CSS
    /// `filter: blur()`; without blur the content is drawn directly.
    static func blurred(_ ctx: CGContext, sigma: Double, bounds: CGRect, opacity: Double = 1, _ draw: (CGContext) -> Void) {
        guard sigma > 0.05 else { layer(ctx, opacity: opacity, draw); return }
        let scale = deviceScale(ctx)
        let pad = sigma * 3
        let area = bounds.insetBy(dx: -pad, dy: -pad).integral
        let w = Int((area.width * scale).rounded(.up)), h = Int((area.height * scale).rounded(.up))
        guard w > 0, h > 0, w < 8000, h < 8000,
              let off = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        off.translateBy(x: 0, y: CGFloat(h))
        off.scaleBy(x: scale, y: -scale)
        off.translateBy(x: -area.minX, y: -area.minY)
        draw(off)
        guard let image = off.makeImage() else { return }
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma * scale])
            .cropped(to: input.extent)
        // clampedToExtent smears edge pixels outwards; the padding keeps them transparent
        guard let result = ci.createCGImage(output, from: input.extent) else { return }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.translateBy(x: area.minX, y: area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(result, in: CGRect(x: 0, y: 0, width: area.width, height: area.height))
        ctx.restoreGState()
    }
}
