import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// A slowed-down shot gets its in-between frames drawn from the optical flow (like Premiere's and Resolve's «Optical
/// Flow»), not a source frame shown twice: the compositor gets the shot's frame and the one after it (the track a frame
/// ahead), and draws the moment between them where this frame of the edit falls.
struct Tween: Sendable {
    /// A track's clock onto the footage's: `source + (t - target) · rate` — read back from the built composition, so it
    /// is exactly the mapping AVFoundation picks frames by (its 1/600 s rounding included).
    struct Mapping: Sendable {
        let target: Double, source: Double, rate: Double
        func at(_ t: Double) -> Double { source + (t - target) * rate }
    }
    /// The shot's own track and the one a source frame ahead.
    let own: Mapping, ahead: Mapping
    /// When each frame of the footage starts (presentation order), around the stretch the shot plays.
    let frames: [Double]

    /// How far the edit's moment `t` is between the frame the shot's track shows and the one the track ahead shows
    /// (0…1); nil when there is nothing to draw between them — right on a frame, or both tracks on the same one.
    func fraction(at t: Double) -> Double? {
        let s = own.at(t)
        guard let a = index(s), let b = index(ahead.at(t)), b > a else { return nil }
        let f = (s - frames[a]) / (frames[b] - frames[a])
        return f > 0.002 ? min(1, f) : nil
    }

    /// The frame shown at footage time `s`: the last one starting at or before it.
    private func index(_ s: Double) -> Int? {
        var lo = 0, hi = frames.count
        while lo < hi { let m = (lo + hi) / 2; if frames[m] <= s + 1e-6 { lo = m + 1 } else { hi = m } }
        return lo > 0 ? lo - 1 : nil
    }

    /// The footage's frame times from about `from` to past `to` (seconds), from the file's sample table — nothing
    /// decoded; empty when the file can't give them.
    static func frames(of track: AVAssetTrack, from: Double, to: Double) async -> [Double] {
        guard (try? await track.load(.canProvideSampleCursors)) == true,
              let cursor = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: max(0, from), preferredTimescale: 600)) else { return [] }
        var times = [cursor.presentationTimeStamp.seconds]
        while times.last! <= to, times.count < 100_000, cursor.stepInPresentationOrder(byCount: 1) == 1 {
            times.append(cursor.presentationTimeStamp.seconds)
        }
        return times
    }

    private static let pipeline: MTLComputePipelineState? = {
        guard let device = MotionBlur.device, let library = try? device.makeLibrary(source: kernelSource, options: nil),
              let function = library.makeFunction(name: "tween") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    /// The picture `t` (0…1) of the way from source frame `a` to `b` (same size, as decoded): the motion both ways
    /// (Apple Vision, at `fine` quality for export, quicker for the preview), each frame moved along it to that moment
    /// and the two blended — the nearer one weighs more, and a pixel the other frame can't see (it comes into or out
    /// of view) is taken from the one that sees it. nil when it can't be drawn (the caller shows `a`).
    static func draw(_ a: CVPixelBuffer, _ b: CVPixelBuffer, at t: Double, fine: Bool) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b), w > 1, h > 1,
              let ci = MotionBlur.ci, let queue = MotionBlur.queue, let cache = MotionBlur.cache, let pipeline else { return nil }
        // 1. the motion a → b and b → a, measured on small copies (half the canvas width for export)
        let fw = min(w, fine ? 540 : 270), fh = max(2, Int((Double(fw) * Double(h) / Double(w)).rounded()))
        guard let sa = MotionBlur.buffer(fw, fh), let sb = MotionBlur.buffer(fw, fh) else { return nil }
        let small = CGAffineTransform(scaleX: CGFloat(fw) / CGFloat(w), y: CGFloat(fh) / CGFloat(h))
        let rect = CGRect(x: 0, y: 0, width: fw, height: fh)
        ci.render(CIImage(cvPixelBuffer: a, options: [.colorSpace: NSNull()]).transformed(by: small), to: sa, bounds: rect, colorSpace: MotionBlur.srgb)
        ci.render(CIImage(cvPixelBuffer: b, options: [.colorSpace: NSNull()]).transformed(by: small), to: sb, bounds: rect, colorSpace: MotionBlur.srgb)
        func flow(_ from: CVPixelBuffer, _ to: CVPixelBuffer) -> CVPixelBuffer? {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: to, options: [:])
            request.revision = VNGenerateOpticalFlowRequestRevision1
            request.computationAccuracy = fine ? .high : .medium
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            guard (try? VNImageRequestHandler(cvPixelBuffer: from, options: [:]).perform([request])) != nil else { return nil }
            return (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer
        }
        guard let ab = flow(sa, sb), let ba = flow(sb, sa), let output = MotionBlur.buffer(w, h) else { return nil }

        // 2. both frames moved to the moment and blended, at full size
        guard let aT = MotionBlur.texture(a, .bgra8Unorm, cache), let bT = MotionBlur.texture(b, .bgra8Unorm, cache),
              let abT = MotionBlur.texture(ab, .rg32Float, cache), let baT = MotionBlur.texture(ba, .rg32Float, cache),
              let outT = MotionBlur.texture(output, .bgra8Unorm, cache),
              let ta = CVMetalTextureGetTexture(aT), let tb = CVMetalTextureGetTexture(bT), let tab = CVMetalTextureGetTexture(abT),
              let tba = CVMetalTextureGetTexture(baT), let tout = CVMetalTextureGetTexture(outT),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
        // p.x: the moment, p.y / p.z: flow px → picture px, p.w: how far (picture px) the two ways may disagree and still count
        var params = SIMD4<Float>(Float(t), Float(w) / Float(fw), Float(h) / Float(fh), 1.5 * Float(w) / Float(fw))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(ta, index: 0); encoder.setTexture(tb, index: 1)
        encoder.setTexture(tab, index: 2); encoder.setTexture(tba, index: 3); encoder.setTexture(tout, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((aT, bT, abT, baT, outT)) {}
        return commands.status == .completed ? output : nil
    }

    /// The moment t between frames A and B. `ab` is the motion A → B on A's grid (A(x) ≈ B(x + ab(x))), `ba` B → A on
    /// B's. The motion from the moment back to each frame is approximated from the two (Jiang et al., Super SloMo):
    /// to A  −(1−t)·t·ab + t²·ba,  to B  (1−t)²·ab − t·(1−t)·ba. A sample whose motion there and back doesn't return to
    /// it (it is hidden in the other frame) weighs less.
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void tween(texture2d<float, access::sample> a [[texture(0)]],
                      texture2d<float, access::sample> b [[texture(1)]],
                      texture2d<float, access::sample> ab [[texture(2)]],
                      texture2d<float, access::sample> ba [[texture(3)]],
                      texture2d<float, access::write> dst [[texture(4)]],
                      constant float4 &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;
        constexpr sampler img(coord::pixel, address::clamp_to_edge, filter::linear);
        constexpr sampler fl(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 size = float2(w, h), k = p.yz;
        float t = p.x;
        float2 x = float2(gid) + 0.5;
        float2 f01 = ab.sample(fl, x / size).xy * k, f10 = ba.sample(fl, x / size).xy * k;
        float2 p0 = x + (-(1.0 - t) * t * f01 + t * t * f10);
        float2 p1 = x + ((1.0 - t) * (1.0 - t) * f01 - t * (1.0 - t) * f10);
        float2 g0 = ab.sample(fl, p0 / size).xy * k, g1 = ba.sample(fl, p1 / size).xy * k;
        float e0 = length(g0 + ba.sample(fl, (p0 + g0) / size).xy * k);
        float e1 = length(g1 + ab.sample(fl, (p1 + g1) / size).xy * k);
        float w0 = (1.0 - t) / (1.0 + (e0 * e0) / (p.w * p.w)), w1 = t / (1.0 + (e1 * e1) / (p.w * p.w));
        float4 c = (a.sample(img, p0) * w0 + b.sample(img, p1) * w1) / max(w0 + w1, 1e-6);
        dst.write(c, gid);
    }
    """
}
