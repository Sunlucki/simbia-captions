import CoreGraphics
import Foundation

/// SVG `feTurbulence` (fractalNoise), ported from the reference code in the SVG 1.1 specification —
/// the algorithm Chromium's Skia implements — so the waxy lipstick edges come out the same.
final class Turbulence {
    private static let bSize = 0x100, bm = 0xff, perlinN = 0x1000
    private var lattice = [Int](repeating: 0, count: 0x100 + 0x100 + 2)
    private var gradient = [[(Double, Double)]](repeating: [(Double, Double)](repeating: (0, 0), count: 0x100 + 0x100 + 2), count: 4)
    let baseX: Double, baseY: Double, octaves: Int

    init(baseFrequency: (Double, Double), octaves: Int, seed: Double) {
        baseX = baseFrequency.0; baseY = baseFrequency.1; self.octaves = octaves
        let m = 2147483647, a = 16807, q = 127773, r = 2836
        var s = Int(seed.rounded())
        if s <= 0 { s = -(s % (m - 1)) + 1 }
        if s > m - 1 { s = m - 1 }
        func random() -> Int {
            var result = a * (s % q) - r * (s / q)
            if result <= 0 { result += m }
            s = result
            return result
        }
        let b = Self.bSize
        for k in 0..<4 {
            for i in 0..<b {
                lattice[i] = i
                var g = (0.0, 0.0)
                g.0 = Double((random() % (b + b)) - b) / Double(b)
                g.1 = Double((random() % (b + b)) - b) / Double(b)
                let len = (g.0 * g.0 + g.1 * g.1).squareRoot()
                gradient[k][i] = len > 0 ? (g.0 / len, g.1 / len) : (0, 0)
            }
        }
        var i = b - 1
        while i > 0 {
            let k = lattice[i]
            let j = random() % b
            lattice[i] = lattice[j]
            lattice[j] = k
            i -= 1
        }
        for i in 0..<(b + 2) {
            lattice[b + i] = lattice[i]
            for k in 0..<4 { gradient[k][b + i] = gradient[k][i] }
        }
    }

    private func noise2(_ channel: Int, _ x: Double, _ y: Double) -> Double {
        let bm = Self.bm
        var t = x + Double(Self.perlinN)
        let bx0 = Int(t) & bm, bx1 = (bx0 + 1) & bm
        let rx0 = t - Double(Int(t)), rx1 = rx0 - 1
        t = y + Double(Self.perlinN)
        let by0 = Int(t) & bm, by1 = (by0 + 1) & bm
        let ry0 = t - Double(Int(t)), ry1 = ry0 - 1
        let i = lattice[bx0], j = lattice[bx1]
        let b00 = lattice[i + by0], b10 = lattice[j + by0], b01 = lattice[i + by1], b11 = lattice[j + by1]
        let sx = rx0 * rx0 * (3 - 2 * rx0), sy = ry0 * ry0 * (3 - 2 * ry0)
        let g = gradient[channel]
        var u = rx0 * g[b00].0 + ry0 * g[b00].1
        var v = rx1 * g[b10].0 + ry0 * g[b10].1
        let a = u + sx * (v - u)
        u = rx0 * g[b01].0 + ry1 * g[b01].1
        v = rx1 * g[b11].0 + ry1 * g[b11].1
        let bb = u + sx * (v - u)
        return a + sy * (bb - a)
    }

    /// The channel's fractal-noise value at a user-space point, 0…1 (as feTurbulence writes it).
    func value(_ channel: Int, _ x: Double, _ y: Double) -> Double {
        var sum = 0.0, ratio = 1.0
        var vx = x * baseX, vy = y * baseY
        for _ in 0..<octaves {
            sum += noise2(channel, vx, vy) / ratio
            vx *= 2; vy *= 2; ratio *= 2
        }
        return min(1, max(0, (sum + 1) / 2))
    }
}

/// The two SVG filters the lipstick titles use, applied to a rendered layer.
enum LipstickFilter {
    /// `#wax`: turbulence (.035 .9, 2 octaves, seed 4) displacing the layer by 7 user units through its
    /// alpha channel — the streaky edge of a lipstick swipe.
    static let wax = Turbulence(baseFrequency: (0.035, 0.9), octaves: 2, seed: 4)
    /// `#print`: turbulence (.9 .08, 2 octaves, seed 2) whose alpha, through −1.6·A + 1.25, masks the shape —
    /// the creases of a lip print.
    static let print = Turbulence(baseFrequency: (0.9, 0.08), octaves: 2, seed: 2)

    /// A premultiplied RGBA bitmap and the map from its pixels to the filter's user space.
    struct Layer {
        var pixels: [UInt8]
        let width: Int, height: Int
        /// pixel (x, y) -> user-space point
        let toUser: CGAffineTransform
        /// user-space vector (1, 1) in pixels, per axis
        let pixelsPerUnit: (Double, Double)
    }

    /// feDisplacementMap(in2 = turbulence, scale, channels A/A): every pixel takes its colour from
    /// the source `scale·(A − 0.5)` user units away, on both axes.
    /// The noise is sampled at pixel centres (measured closer to Chromium than corners).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fields: [String: [Float]] = [:]

    /// The turbulence's alpha for every pixel of a layer. It depends only on where the layer sits in
    /// user space, so it is made once per title layout and scale and reused every frame.
    static func field(_ layer: Layer, _ noise: Turbulence) -> [Float] {
        let m = layer.toUser
        let key = "\(ObjectIdentifier(noise))|\(layer.width)x\(layer.height)|\(m.a),\(m.b),\(m.c),\(m.d),\(m.tx),\(m.ty)"
        lock.lock()
        if let f = fields[key] { lock.unlock(); return f }
        lock.unlock()
        var f = [Float](repeating: 0, count: layer.width * layer.height)
        for y in 0..<layer.height {
            for x in 0..<layer.width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(m)
                f[y * layer.width + x] = Float(noise.value(3, p.x, p.y))
            }
        }
        lock.lock()
        if fields.count > 64 { fields.removeAll() }
        fields[key] = f
        lock.unlock()
        return f
    }

    static func displace(_ layer: Layer, scale: Double, noise: Turbulence = wax) -> [UInt8] {
        let w = layer.width, h = layer.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let src = layer.pixels
        let kx = scale * layer.pixelsPerUnit.0, ky = scale * layer.pixelsPerUnit.1
        let field = field(layer, noise)
        for y in 0..<h {
            for x in 0..<w {
                let a = Double(field[y * w + x]) - 0.5
                let sx = Double(x) + kx * a, sy = Double(y) + ky * a
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let fx = sx - Double(x0), fy = sy - Double(y0)
                var acc = (0.0, 0.0, 0.0, 0.0)
                for (dx, dy, wgt) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] where wgt > 0 {
                    let xx = x0 + dx, yy = y0 + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let i = (yy * w + xx) * 4
                    acc.0 += Double(src[i]) * wgt; acc.1 += Double(src[i + 1]) * wgt
                    acc.2 += Double(src[i + 2]) * wgt; acc.3 += Double(src[i + 3]) * wgt
                }
                let o = (y * w + x) * 4
                out[o] = UInt8(min(255, acc.0.rounded())); out[o + 1] = UInt8(min(255, acc.1.rounded()))
                out[o + 2] = UInt8(min(255, acc.2.rounded())); out[o + 3] = UInt8(min(255, acc.3.rounded()))
            }
        }
        return out
    }

    /// feColorMatrix (alpha = −1.6·A + 1.25) + feComposite in: the shape kept where the print mask is.
    static func printMask(_ layer: Layer) -> [UInt8] {
        let w = layer.width, h = layer.height
        var out = layer.pixels
        let field = field(layer, print)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                guard out[o + 3] > 0 else { continue }
                let m = min(1, max(0, -1.6 * Double(field[y * w + x]) + 1.25))
                for c in 0..<4 { out[o + c] = UInt8((Double(out[o + c]) * m).rounded()) }
            }
        }
        return out
    }

    /// Renders `draw` (stage coordinates) into a bitmap over `bounds`, runs `filter` on it and paints
    /// the result back. `user` maps stage points to the filter's user space.
    static func apply(_ ctx: CGContext, bounds: CGRect, user: CGAffineTransform, opacity: Double = 1,
                      filter: (Layer) -> [UInt8], _ draw: (CGContext) -> Void) {
        let scale = Paint.deviceScale(ctx)
        let area = bounds.integral
        let w = Int((area.width * scale).rounded(.up)), h = Int((area.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h < 30_000_000,
              let off = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Paint.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        off.translateBy(x: 0, y: CGFloat(h))
        off.scaleBy(x: scale, y: -scale)
        off.translateBy(x: -area.minX, y: -area.minY)
        draw(off)
        guard let data = off.data else { return }
        let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        // pixel -> stage -> user
        let toStage = CGAffineTransform(a: 1 / scale, b: 0, c: 0, d: 1 / scale, tx: area.minX, ty: area.minY)
        let toUser = toStage.concatenating(user)
        let unit = CGSize(width: 1, height: 1).applying(user.inverted())
        let layer = Layer(pixels: pixels, width: w, height: h, toUser: toUser,
                          pixelsPerUnit: (abs(unit.width) * scale, abs(unit.height) * scale))
        var result = filter(layer)
        guard let provider = CGDataProvider(data: Data(bytes: &result, count: result.count) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: Paint.srgb,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.translateBy(x: area.minX, y: area.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: area.width, height: area.height))
        ctx.restoreGState()
    }
}
