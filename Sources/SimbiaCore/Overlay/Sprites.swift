import CoreGraphics
import CoreImage
import Foundation

/// A piece of the overlay rendered once and then drawn every frame — a word at rest, a title's text —
/// so its outlines and shadows cost nothing after the first frame. Animation only moves, scales,
/// fades or blurs the finished image, as a browser's compositor does with a transformed layer.
///
/// Least recently used sprites go first once the images pass `budget` bytes.
final class SpriteCache: @unchecked Sendable {
    struct Sprite {
        let image: CGImage
        /// Where the image sits, in stage coordinates.
        let rect: CGRect
    }

    static let shared = SpriteCache()
    private var items: [String: (sprite: Sprite, bytes: Int, used: Int)] = [:]
    private var bytes = 0
    private var clock = 0
    private let budget = 384 << 20
    private let lock = NSLock()

    /// The sprite for `key` at device `scale`, drawing it over `bounds` (stage coordinates) the first time.
    /// The scale is rounded up to 1/16, so resizing the window does not render every sprite again per pixel.
    func sprite(_ key: String, scale: Double, bounds: CGRect, _ draw: (CGContext) -> Void) -> Sprite? {
        let scale = max(1.0 / 16, (scale * 16).rounded(.up) / 16)
        let k = "\(key)@\(Int(scale * 16))"
        lock.lock()
        if let hit = items[k] {
            clock += 1
            items[k]?.used = clock
            lock.unlock()
            return hit.sprite
        }
        lock.unlock()
        let area = bounds.integral
        let w = Int((area.width * scale).rounded(.up)), h = Int((area.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h < 40_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Paint.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        let sprite = Sprite(image: image, rect: CGRect(x: area.minX, y: area.minY, width: Double(w) / scale, height: Double(h) / scale))
        lock.lock(); defer { lock.unlock() }
        clock += 1
        if let raced = items[k] { items[k]?.used = clock; return raced.sprite }   // another frame drew it meanwhile
        let size = image.bytesPerRow * image.height
        items[k] = (sprite, size, clock)
        bytes += size
        if bytes > budget || items.count > 4000 {
            for (old, item) in items.sorted(by: { $0.value.used < $1.value.used }) {
                if bytes <= budget * 3 / 4, items.count <= 3000 { break }
                if old == k { continue }
                items.removeValue(forKey: old)
                bytes -= item.bytes
            }
        }
        return sprite
    }

    private static let ci = CIContext(options: [.workingColorSpace: Paint.srgb, .outputColorSpace: Paint.srgb, .cacheIntermediates: false])

    /// Draws a sprite with opacity, an offset, and CSS `filter: blur(σ px)` when σ > 0.
    static func draw(_ sprite: Sprite, in ctx: CGContext, opacity: Double = 1, blur: Double = 0, offset: CGPoint = .zero) {
        guard opacity > 0.001 else { return }
        var image = sprite.image
        var rect = sprite.rect.offsetBy(dx: offset.x, dy: offset.y)
        if blur > 0.05 {
            let perPoint = Double(image.width) / rect.width
            let input = CIImage(cgImage: image)
            let output = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * perPoint])
            let pad = (blur * 3 * perPoint).rounded(.up)
            let extent = input.extent.insetBy(dx: -pad, dy: -pad)
            if let made = ci.createCGImage(output.cropped(to: extent), from: extent) {
                image = made
                rect = rect.insetBy(dx: -pad / perPoint, dy: -pad / perPoint)
            }
        }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
