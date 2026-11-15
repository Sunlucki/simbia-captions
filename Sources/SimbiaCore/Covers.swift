import AVFoundation
import CoreImage
import Foundation
import Vision

/// A creator's burned-in captions (or a logo) painted over on the footage itself, before the shot is framed — so they
/// stay covered whatever the crop. «fill» draws every pixel of the zone from its four edges, the nearer edge weighing
/// more (ffmpeg's delogo), then lays the footage's own grain back over it;
/// «blur» blurs the zone heavily. Both blend in through a soft edge.
public enum Covers {
    /// `image` = the shot's source frame as turned; the zones are in its frame.
    public static func apply(_ image: CIImage, _ zones: [CoverZone]) -> CIImage {
        let e = image.extent
        guard !zones.isEmpty, e.width > 0, e.height > 0, e.width.isFinite else { return image }
        var out = image
        for zone in zones {
            let r = CGRect(x: e.minX + zone.x * e.width, y: e.minY + (1 - zone.y - zone.h) * e.height,
                           width: zone.w * e.width, height: zone.h * e.height).intersection(e)
            guard r.width >= 2, r.height >= 2 else { continue }
            let painted: CIImage
            if zone.mode == "blur" {
                painted = out.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(r.width, r.height) * 0.12])
                    .cropped(to: e)
            } else {
                // the edges are read from a lightly blurred copy, so one noisy pixel does not streak across the zone
                let edges = out.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5])
                guard let filled = fill?.apply(extent: r, roiCallback: { _, _ in r.insetBy(dx: -8, dy: -8) },
                                               arguments: [edges, CIVector(x: r.minX, y: r.minY, z: r.maxX, w: r.maxY)]) else { continue }
                painted = grain(filled, like: out, in: r).composited(over: out)
            }
            let feather = 2 + zone.soft * 14                              // px of edge, half of it inside the zone
            let mask = CIImage(color: .white).cropped(to: r.insetBy(dx: feather * 0.5, dy: feather * 0.5))
                .composited(over: CIImage(color: .black).cropped(to: e))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: e)
            out = painted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
        }
        return out
    }

    /// Each pixel from the zone's four edges: across from left and right, down from top and bottom, the pair whose
    /// edges are nearer weighing more.
    private static let fill = CIKernel(source: """
        kernel vec4 coverFill(sampler s, vec4 r) {
            vec2 p = destCoord();
            float w = r.z - r.x, h = r.w - r.y;
            float u = clamp((p.x - r.x) / w, 0.0, 1.0), v = clamp((p.y - r.y) / h, 0.0, 1.0);
            vec4 left = sample(s, samplerTransform(s, vec2(r.x - 2.0, p.y)));
            vec4 right = sample(s, samplerTransform(s, vec2(r.z + 2.0, p.y)));
            vec4 bottom = sample(s, samplerTransform(s, vec2(p.x, r.y - 2.0)));
            vec4 top = sample(s, samplerTransform(s, vec2(p.x, r.w + 2.0)));
            vec4 across = mix(left, right, u), down = mix(bottom, top, v);
            float wa = 1.0 / max(min(u, 1.0 - u) * w, 0.5), wd = 1.0 / max(min(v, 1.0 - v) * h, 0.5);
            return (across * wa + down * wd) / (wa + wd);
        }
        """)

    /// The footage's own grain (how far its fine detail strays from a blur of itself, next to the zone) laid over the
    /// smooth fill, so the patch does not read as a flat smear.
    private static func grain(_ filled: CIImage, like source: CIImage, in r: CGRect) -> CIImage {
        // a strip just over the zone (else under it): the zone itself holds the text, whose edges are no grain
        let band = max(8, r.height * 0.25)
        var ring = CGRect(x: r.minX, y: r.maxY + 2, width: r.width, height: band).intersection(source.extent)
        if ring.height < 4 { ring = CGRect(x: r.minX, y: r.minY - 2 - band, width: r.width, height: band).intersection(source.extent) }
        guard ring.width >= 4, ring.height >= 4, let addGrain else { return filled }
        let detail = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: ring)
            .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: source.cropped(to: ring)])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ring)])
        var px = [Float](repeating: 0, count: 4)
        measure.render(detail, toBitmap: &px, rowBytes: 16, bounds: detail.extent, format: .RGBAf, colorSpace: nil)
        // the mean |x − blur| sits well under the grain's reach: ×4 brings the noise to the same look
        let amount = min(0.08, max(0.004, Double(px[0] + px[1] + px[2]) / 3 * 4))
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: r)
        return addGrain.apply(extent: r, arguments: [filled, noise, amount]) ?? filled
    }

    private static let measure = CIContext(options: [.workingColorSpace: NSNull()])

    /// The fill plus grey noise (−½…½ of `amount`), its own alpha kept.
    private static let addGrain = CIColorKernel(source: """
        kernel vec4 addGrain(__sample f, __sample n, float amount) {
            return vec4(f.rgb + (n.r - 0.5) * amount, f.a);
        }
        """)

    /// Where a stretch of footage has text burned in: Vision reads `count` frames across `from…to` (seconds of the
    /// file) turned by `rotation` as the shot shows them, and the text boxes that overlap, from any of those frames,
    /// become one zone each, with a little room round them.
    public static func findText(in url: URL, from: Double, to: Double, rotation: Double, aspect: Double, count: Int = 10) async -> [CoverZone] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var boxes: [CGRect] = []                                          // top-left origin, 0…1
        for k in 0..<count {
            let t = from + (to - from) * (Double(k) + 0.5) / Double(count)
            guard let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            var image = CIImage(cgImage: frame)
            if abs(rotation) > 0.001 {
                image = Rotation.apply(image, degrees: rotation, aspect: aspect)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            guard let turned = context.createCGImage(image, from: image.extent) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: turned, options: [:]).perform([request])
            for o in request.results ?? [] where o.confidence > 0.3 {
                let b = o.boundingBox
                boxes.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
        }
        // overlapping boxes (with room round them) become one zone
        var zones: [CGRect] = []
        for b in boxes.map({ $0.insetBy(dx: -0.035, dy: -0.02) }) {     // room for the letters' outline and shadow, and the soft edge
            var merged = b
            var changed = true
            while changed {
                changed = false
                for (i, z) in zones.enumerated().reversed() where z.intersects(merged) {
                    merged = merged.union(z); zones.remove(at: i); changed = true
                }
            }
            zones.append(merged)
        }
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        return zones.map { $0.intersection(whole) }.filter { $0.width > 0.01 && $0.height > 0.005 }
            .sorted { $0.minY < $1.minY }
            .map { CoverZone(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) }
    }
}
