import AVFoundation
import CoreImage

/// Cuts a screen out of a video (`ChromaKey`, the steps of Final Cut's Keyer) and frames and places it (`LayerTransform`).
/// The key works on the video's own pixels, before it is scaled — cheap, and its matte tools count the footage's pixels,
/// as the reference Python keyer did. Per-pixel steps are Core Image kernels compiled from Metal source the first time they are needed;
/// the matte tools are Core Image's own morphology and convolution.
enum Keyer {
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    // how much a colour is the screen: its screen channel minus the larger of the other two
    inline float excess(float3 c, float3 pick) {
        float3 rest = c * (1.0 - pick);
        return dot(c, pick) - max(max(rest.r, rest.g), rest.b);
    }
    // the key colour from an average (rgb · n, n) of the screen's pixels; a plain screen colour when none was found
    inline float3 screen(float4 k, float3 pick) { return k.a > 0.0001 ? k.rgb / k.a : 0.2 + 0.5 * pick; }
    // clearly the screen: averaged for the key colour of a still (a video's is measured once, `measure`)
    [[ stitchable ]] float4 simbiaKeyScreen(sample_t s, float3 pick) {
        float3 c = s.rgb / max(s.a, 0.0001);
        float n = s.a > 0.5 && excess(c, pick) > 0.12 ? 1.0 : 0.0;
        return float4(c * n, n);
    }
    // what stays: 1 − smoothstep(low, high, how much of the key colour's own excess the pixel has)
    [[ stitchable ]] float4 simbiaKeyMatte(sample_t s, sample_t k, float3 pick, float low, float high) {
        float3 c = s.rgb / max(s.a, 0.0001);
        float d = excess(c, pick) / max(excess(screen(k, pick), pick), 0.02);
        float t = clamp((d - low) / max(high - low, 0.001), 0.0, 1.0);
        float a = 1.0 - t * t * (3.0 - 2.0 * t);
        return float4(a, a, a, 1.0);
    }
    // the screen mixed into the edges taken out, then the screen's cast off the whole person
    [[ stitchable ]] float4 simbiaKeyClean(sample_t s, sample_t m, sample_t k, float3 pick, float spill) {
        float3 c = clamp(s.rgb / max(s.a, 0.0001) - 0.6 * (1.0 - m.r) * screen(k, pick), 0.0, 1.0);
        float own = dot(c, pick), rest = (c.r + c.g + c.b - own) * 0.5;
        c -= pick * (spill * max(0.0, own - rest));
        return float4(c, 1.0) * s.a;
    }
    // the picture (premultiplied, as Core Image hands it over) with the matte taken into its alpha
    [[ stitchable ]] float4 simbiaKeyMask(sample_t c, sample_t m) {
        return c * clamp(m.r, 0.0, 1.0);
    }
    // the matte to look at (Final Cut's View: Matte): white where the picture stays
    [[ stitchable ]] float4 simbiaKeyShow(sample_t m) {
        float a = clamp(m.r * m.a, 0.0, 1.0);
        return float4(a, a, a, 1.0);
    }
    }}
    """

    private struct Kernels: @unchecked Sendable { let screen, matte, clean, mask, show: CIColorKernel }

    private static let kernels: Kernels? = {
        do {
            let all = try CIKernel.kernels(withMetalString: source)
            func named(_ n: String) -> CIColorKernel? { all.first { $0.name == n } as? CIColorKernel }
            guard let screen = named("simbiaKeyScreen"), let matte = named("simbiaKeyMatte"), let clean = named("simbiaKeyClean"),
                  let mask = named("simbiaKeyMask"), let show = named("simbiaKeyShow") else {
                SimbiaCompositor.report?("chroma key: kernels missing")
                return nil
            }
            return Kernels(screen: screen, matte: matte, clean: clean, mask: mask, show: show)
        } catch {
            SimbiaCompositor.report?("chroma key: \(error)")
            return nil
        }
    }()

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The frame cleaned of the screen's colour (still opaque), and the matte — white where the picture stays — both at the
    /// frame's own size. The colour then works on the first; `masked` puts the two together at the end. `screen` = the
    /// clip's measured key colour (0…1); nil = the pipette's, else this frame's average (a still). nil = no key built.
    static func key(_ image: CIImage, _ key: ChromaKey, screen measured: SIMD3<Float>?) -> (picture: CIImage, matte: CIImage)? {
        guard let k = kernels else { return nil }
        let e = image.extent
        let pick = CIVector(x: key.channel == 0 ? 1 : 0, y: key.channel == 1 ? 1 : 0, z: key.channel == 2 ? 1 : 0)
        // 1. the key colour
        let screen: CIImage
        if let c = key.rgb ?? measured.map({ (r: Double($0.x), g: Double($0.y), b: Double($0.z)) }),
           let colour = CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1, colorSpace: srgb) {
            screen = CIImage(color: colour)
        } else {
            guard let pixels = k.screen.apply(extent: e, arguments: [image, pick]) else { return nil }
            screen = pixels.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: e)]).clampedToExtent()
        }
        // 2–3. the matte, shrunk (or grown) and softened — the frame's edge carried outward, as numpy's edge padding
        let (low, high) = key.thresholds
        guard var matte = k.matte.apply(extent: e, arguments: [image, screen, pick, low, high]) else { return nil }
        let shrink = Int(min(3, max(-3, key.shrink)).rounded()), soften = Int(min(3, max(0, key.soften)).rounded())
        if shrink != 0 {
            let side = 2 * abs(shrink) + 1
            matte = matte.clampedToExtent().applyingFilter(shrink > 0 ? "CIMorphologyRectangleMinimum" : "CIMorphologyRectangleMaximum",
                                                           parameters: ["inputWidth": side, "inputHeight": side]).cropped(to: e)
        }
        if soften > 0 {
            let side = 2 * soften + 1
            let box = CIVector(values: Array(repeating: CGFloat(1) / CGFloat(side * side), count: side * side), count: side * side)
            matte = matte.clampedToExtent().applyingFilter("CIConvolution\(side)X\(side)", parameters: [kCIInputWeightsKey: box, kCIInputBiasKey: 0])
                .cropped(to: e)
        }
        // 4–5. edges and spill
        guard let picture = k.clean.apply(extent: e, arguments: [image, matte, screen, pick, min(1, max(0, key.spill))]) else { return nil }
        return (picture, matte)
    }

    /// The picture cut out by its matte: transparent where the screen was.
    static func masked(_ picture: CIImage, _ matte: CIImage) -> CIImage {
        guard let k = kernels else { return picture }
        return k.mask.apply(extent: picture.extent.intersection(matte.extent), arguments: [picture, matte]) ?? picture
    }

    /// The matte as a black-and-white picture.
    static func shown(_ matte: CIImage) -> CIImage {
        kernels?.show.apply(extent: matte.extent, arguments: [matte]) ?? matte
    }

    /// The video framed as a shot fills the canvas (`zoom`, `pan` −1…1, mirrored) and then placed by its transform —
    /// in one scale, so the picture is resampled once (and once more when it is turned). Its box starts on a whole pixel.
    static func frame(_ image: CIImage, canvas size: CGSize, zoom: Double, pan: CGPoint, mirror: Bool, place t: LayerTransform?) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return image }
        let W = size.width, H = size.height
        let fill = max(W / e.width, H / e.height) * zoom
        let s = max(0.01, t?.scale ?? 1), k = W / 1080
        let dx = (W * (1 - s) / 2 + (t?.x ?? 0) * k).rounded(), dy = (H * (1 - s) / 2 - (t?.y ?? 0) * k).rounded()   // CI's y points up
        var out = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if mirror { out = out.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.width, ty: 0)) }
        out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: fill * s, kCIInputAspectRatioKey: 1.0])
        let w = e.width * fill, h = e.height * fill
        let px = min(1, max(-1, pan.x)), py = min(1, max(-1, pan.y))
        // whole pixels: a fractional move would resample (soften) the picture once more
        out = out.transformed(by: CGAffineTransform(translationX: (s * (W - w) * (1 + px) / 2).rounded() + dx,
                                                    y: (s * (H - h) * (1 - py) / 2).rounded() + dy))
        let box = CGRect(x: dx, y: dy, width: (W * s).rounded(), height: (H * s).rounded())
        out = out.cropped(to: box)
        guard let degrees = t?.rotation, abs(degrees) > 0.01 else { return out }
        // turned about the middle of its box, clockwise as seen (CI's y points up)
        return out.transformed(by: CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
    }

    /// A green screen's key colour, as the reference keyer found it: per channel the median of the pixels clearly the screen (green
    /// 0.25 above red and blue; 0.12 when under 1 % of them are — AVFoundation reads some takes less green than ffmpeg) in
    /// every 24th frame of the first 15 s, decoded as the compositor gets them (BGRA). nil = no picture or no screen.
    static func measure(_ url: URL) async -> SIMD3<Float>? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange), let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, CMTime(seconds: 15, preferredTimescale: 600)))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        // histograms of r, g, b over the clear screen (≥ 0.25) and the looser one (≥ 0.12)
        var clear = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3), loose = clear
        var clearCount = 0, looseCount = 0, seen = 0, index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % 24 == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { continue }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<h {
                let line = base + y * row
                for x in 0..<w {
                    let b = Int(line[4 * x]), g = Int(line[4 * x + 1]), r = Int(line[4 * x + 2])
                    let excess = g - max(r, b)
                    guard excess > 30 else { continue }                       // 0.12 of 255
                    loose[0][r] += 1; loose[1][g] += 1; loose[2][b] += 1; looseCount += 1
                    if excess > 63 { clear[0][r] += 1; clear[1][g] += 1; clear[2][b] += 1; clearCount += 1 }   // 0.25
                }
            }
            seen += w * h
        }
        let (histogram, count) = clearCount * 100 >= seen && clearCount > 0 ? (clear, clearCount) : (loose, looseCount)
        guard count > 0 else { return nil }
        func median(_ bins: [Int]) -> Float {
            var sum = 0
            for (v, n) in bins.enumerated() { sum += n; if sum * 2 >= count { return Float(v) / 255 } }
            return 1
        }
        return SIMD3(median(histogram[0]), median(histogram[1]), median(histogram[2]))
    }
}
