import AVFoundation
import CoreImage
import ImageIO

/// A shot's colour brought to another's: the reference as it looks with its own grade, the target graded until its
/// picture has the same overall cast and brightness (per-channel gain), the same spread of light (contrast) and the
/// same amount of colour (saturation) — measured on a few frames of each. The project look comes on top of both.
public enum ColourMatch {
    /// The target's grade that matches `reference`; nil when either clip can't be read.
    public static func grade(for target: Shot, like reference: Shot, projectURL: URL?) async -> Grade? {
        guard let ref = await frames(reference, projectURL: projectURL), let tgt = await frames(target, projectURL: projectURL),
              !ref.isEmpty, !tgt.isEmpty else { return nil }
        let own = reference.grade ?? Grade()
        let want = stats(ref.map { own.on ? graded($0, own) : $0.rgba })

        var g = Grade()
        g.match = 1
        // first the cast and brightness of the midtones (per-channel gain), then the amount of colour around that
        // cast (saturation) with the gain kept in step, last a touch of contrast — the spread of light depends on
        // what is in the frame (a pale close-up against one full of shadows), so only part of it is taken
        for _ in 0..<5 { fitGain(&g, tgt, want) }
        for _ in 0..<4 {
            let now = stats(tgt.map { graded($0, g) })
            if now.colour > 0.002 { g.saturation = clamp(g.saturation * pow(want.colour / now.colour, 0.7), 0.6, 1.4) }
            fitGain(&g, tgt, want)
        }
        let now = stats(tgt.map { graded($0, g) })
        if now.light > 0.005 { g.contrast = clamp(pow(want.light / now.light, 0.5), 0.85, 1.2) }
        fitGain(&g, tgt, want)
        g.gain = g.gain.map { ($0 * 1000).rounded() / 1000 }
        g.contrast = (g.contrast * 1000).rounded() / 1000
        g.saturation = (g.saturation * 1000).rounded() / 1000
        g.scene = reference.label.map { "как \($0)" } ?? "как эталон"
        return g
    }

    /// The cast by the channels' share (whatever the brightness), then the brightness by the mean light.
    private static func fitGain(_ g: inout Grade, _ frames: [Frame], _ want: Stats) {
        let now = stats(frames.map { graded($0, g) })
        guard now.luma > 0.01 else { return }
        let light = want.luma / now.luma
        for c in 0..<3 where now.cast[c] > 0.01 {
            g.gain[c] = clamp(g.gain[c] * pow(want.cast[c] / now.cast[c] * light, 0.8), 0.6, 1.6)
        }
    }

    /// Of everything neither near black nor blown out: the cast (each channel's share of r + g + b), the mean light,
    /// and how far colours spread around that cast; of the whole picture, the spread of the light (std of luma).
    /// The share, not the channel means: two framings put different things in the midtones (shadows under a nose
    /// against the skin itself), and the means then disagree about the cast.
    struct Stats { var cast: [Double]; var luma: Double; var light: Double; var colour: Double }

    static func stats(_ images: [[UInt8]]) -> Stats {
        var share = [0.0, 0.0, 0.0], luma = 0.0, n = 0.0
        var chroma: [(Double, Double)] = [], lumaAll: [Double] = []
        for px in images {
            var i = 0
            while i + 3 < px.count {
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                i += 4
                if max(r, g, b) > 0.985 || max(r, g, b) < 0.015 { continue }      // clipped pixels say nothing
                let y = 0.2125 * r + 0.7154 * g + 0.0721 * b
                lumaAll.append(y)
                guard y > 0.08 else { continue }
                let sum = r + g + b
                share[0] += r / sum; share[1] += g / sum; share[2] += b / sum
                luma += y; n += 1
                chroma.append((r / sum, b / sum))
            }
        }
        guard n > 50 else { return Stats(cast: [1 / 3, 1 / 3, 1 / 3], luma: 0.5, light: 0.2, colour: 0.05) }
        let cast = share.map { $0 / n }
        let cr = chroma.reduce(0) { $0 + $1.0 } / n, cb = chroma.reduce(0) { $0 + $1.1 } / n
        let colour = (chroma.reduce(0) { $0 + ($1.0 - cr) * ($1.0 - cr) + ($1.1 - cb) * ($1.1 - cb) } / n).squareRoot()
        let my = lumaAll.reduce(0, +) / Double(lumaAll.count)
        let light = (lumaAll.reduce(0) { $0 + ($1 - my) * ($1 - my) } / Double(lumaAll.count)).squareRoot()
        return Stats(cast: cast, luma: luma / n, light: light, colour: colour)
    }

    // MARK: Frames

    /// A small frame's RGBA bytes, as decoded.
    struct Frame { let width: Int; let height: Int; let rgba: [UInt8] }

    /// Five frames across the shot as the compositor sees them (decoded values, oriented, small).
    static func frames(_ shot: Shot, projectURL: URL?) async -> [Frame]? {
        let url = Project.resolve(shot.src, relativeTo: projectURL)
        if Project.stillTypes.contains(url.pathExtension.lowercased()) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                             kCGImageSourceThumbnailMaxPixelSize: 200,
                                                                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return nil }
            return [frame(image)]
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        var out: [Frame] = []
        for f in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let t = CMTime(seconds: shot.inPoint + f * shot.footage, preferredTimescale: 600)
            if let image = try? await generator.image(at: t).image { out.append(frame(image)) }
        }
        return out
    }

    static func frame(_ image: CGImage) -> Frame { Frame(width: image.width, height: image.height, rgba: pixels(image)) }

    /// The frame with `grade` on it, rendered as the compositor renders it (values taken as they are, no conversion).
    static func graded(_ frame: Frame, _ grade: Grade) -> [UInt8] {
        let size = CGSize(width: frame.width, height: frame.height)
        let input = CIImage(bitmapData: Data(frame.rgba), bytesPerRow: frame.width * 4, size: size, format: .RGBA8, colorSpace: nil)
        var out = [UInt8](repeating: 0, count: frame.rgba.count)
        context.render(grade.applied(to: input), toBitmap: &out, rowBytes: frame.width * 4, bounds: CGRect(origin: .zero, size: size),
                       format: .RGBA8, colorSpace: nil)
        return out
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// RGBA8 bytes of the image without any colour conversion.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { raw in
            guard let cg = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
}
