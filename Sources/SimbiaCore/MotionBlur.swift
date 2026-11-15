import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// Real motion blur, the way After Effects' Pixel Motion Blur and CapCut do it, computed on this Mac: the optical
/// flow between the source frame before and this one (Apple Vision) gives every pixel its motion, and the pixel
/// is averaged along that motion over the shutter — 180° = half of a frame's travel. What stands still stays sharp.
/// The kernel is Metal compiled at run time (no Metal toolchain needed to build the app).
enum MotionBlur {
    /// The flow is computed this small (width; the height follows the canvas) — plenty for motion, ~6 ms a frame.
    static let flowWidth = 270

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let ci: CIContext? = device.map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
    }
    static let cache: CVMetalTextureCache? = device.flatMap { d in
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, d, nil, &c)
        return c
    }
    private static let pipeline: MTLComputePipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: kernelSource, options: nil),
              let function = library.makeFunction(name: "motionBlur") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()
    private static let lock = NSLock()
    private static var pools: [String: CVPixelBufferPool] = [:]

    /// `current` and `previous` are the filled canvas pictures of the same shot, one source frame apart.
    /// `shutter` is the shutter angle as a fraction of a full turn (0.5 = 180°). Returns `current` when it can't blur.
    /// `next` (one source frame after) is used when `previous` turns out to be a copy of this frame.
    static func apply(_ current: CIImage, previous: CIImage, next: CIImage? = nil, size: CGSize, shutter: Double) -> CIImage {
        guard shutter > 0.001, let ci, let queue, let pipeline, let cache else { return current }
        let w = Int(size.width), h = Int(size.height)
        let fw = flowWidth, fh = max(2, Int((Double(flowWidth) * size.height / size.width).rounded()))
        let small = CGAffineTransform(scaleX: CGFloat(fw) / size.width, y: CGFloat(fh) / size.height)
        let canvas = CGRect(origin: .zero, size: size), flowRect = CGRect(x: 0, y: 0, width: fw, height: fh)

        // 1. the motion of every pixel, previous → current
        guard let a = buffer(fw, fh), let b = buffer(fw, fh) else { return current }
        ci.render(previous.cropped(to: canvas).transformed(by: small), to: a, bounds: flowRect, colorSpace: srgb)
        ci.render(current.cropped(to: canvas).transformed(by: small), to: b, bounds: flowRect, colorSpace: srgb)
        var (from, to) = (a, b)
        if let next, same(a, b), let c = buffer(fw, fh) {       // a repeated frame: measure towards the next one
            ci.render(next.cropped(to: canvas).transformed(by: small), to: c, bounds: flowRect, colorSpace: srgb)
            (from, to) = (b, c)
        }
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: to, options: [:])
        request.revision = VNGenerateOpticalFlowRequestRevision1
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        guard (try? VNImageRequestHandler(cvPixelBuffer: from, options: [:]).perform([request])) != nil,
              let flow = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return current }
        return apply(current, flow: flow, scale: Double(w) / Double(fw) * shutter, size: size)
    }

    /// Blurs `current` along a motion field `flow` (2 × Float32, covering the whole canvas, top-left), its vectors
    /// times `scale` in canvas px — the frame's own motion, or the motion a cut carries over from the shot before.
    static func apply(_ current: CIImage, flow: CVPixelBuffer, scale: Double, size: CGSize) -> CIImage {
        guard scale > 0.001, let ci, let queue, let pipeline, let cache else { return current }
        let w = Int(size.width), h = Int(size.height)
        let canvas = CGRect(origin: .zero, size: size)

        // 2. the picture as it is, and a buffer for the blurred one (both top-left like the flow)
        guard let source = buffer(w, h), let output = buffer(w, h) else { return current }
        ci.render(current.cropped(to: canvas), to: source, bounds: canvas, colorSpace: srgb)
        // the CVMetalTextures are kept until the GPU is done with them
        guard let srcT = texture(source, .bgra8Unorm, cache), let dstT = texture(output, .bgra8Unorm, cache),
              let vecT = texture(flow, .rg32Float, cache),
              let src = CVMetalTextureGetTexture(srcT), let dst = CVMetalTextureGetTexture(dstT), let vec = CVMetalTextureGetTexture(vecT),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return current }

        // 3. average along the motion: flow px → canvas px, times the shutter
        var params = SIMD4<Float>(Float(scale), 32, 0.6, 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src, index: 0); encoder.setTexture(vec, index: 1); encoder.setTexture(dst, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((srcT, dstT, vecT)) {}
        return CIImage(cvPixelBuffer: output, options: [.colorSpace: srgb])
    }

    /// A radial blur centred on the canvas that doesn't push the picture outwards (Core Image's zoom blur does):
    /// every pixel is averaged along the line to the centre, `strength` of its distance from it each way.
    static func radial(_ image: CIImage, strength: Double, size: CGSize) -> CIImage {
        guard strength > 0.002, let field = radialField(size) else { return image }
        return apply(image, flow: field.buffer, scale: Double(size.width) / Double(field.width) * strength, size: size)
    }

    private static var radialCache: (key: String, buffer: CVPixelBuffer, width: Int)?

    /// Vectors from the centre to every pixel (flow px), for `radial`.
    private static func radialField(_ size: CGSize) -> (buffer: CVPixelBuffer, width: Int)? {
        let w = flowWidth, h = max(2, Int((Double(flowWidth) * size.height / size.width).rounded()))
        let key = "\(w)x\(h)"
        lock.lock()
        if let c = radialCache, c.key == key { lock.unlock(); return (c.buffer, c.width) }
        lock.unlock()
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_TwoComponent32Float,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let row = CVPixelBufferGetBytesPerRow(out)
            for y in 0..<h {
                let p = (base + y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { p[2 * x] = Float(x) + 0.5 - Float(w) / 2; p[2 * x + 1] = Float(y) + 0.5 - Float(h) / 2 }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        lock.lock(); radialCache = (key, out, w); lock.unlock()
        return (out, w)
    }

    /// Two small frames that are (nearly) the same picture — a generator's repeated frame.
    static func same(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else { return false }
        return difference(pa, pb, CVPixelBufferGetWidth(a), CVPixelBufferGetHeight(a),
                          CVPixelBufferGetBytesPerRow(a), CVPixelBufferGetBytesPerRow(b)) < 0.6
    }

    static func same(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db), a.bitsPerPixel == 32, b.bitsPerPixel == 32 else { return false }
        return difference(UnsafeRawPointer(pa), UnsafeRawPointer(pb), a.width, a.height, a.bytesPerRow, b.bytesPerRow) < 0.6
    }

    /// Mean absolute difference of the first byte of every 4th pixel of every 4th row (0…255).
    private static func difference(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ w: Int, _ h: Int, _ rowA: Int, _ rowB: Int) -> Double {
        var sum = 0, n = 0
        for y in stride(from: 0, to: h, by: 4) {
            let ra = a.advanced(by: y * rowA).assumingMemoryBound(to: UInt8.self), rb = b.advanced(by: y * rowB).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: 4) { for c in 0..<3 { sum += abs(Int(ra[x * 4 + c]) - Int(rb[x * 4 + c])) }; n += 3 }
        }
        return n > 0 ? Double(sum) / Double(n) : 0
    }

    /// The motion field from `a` to `b` (2 × Float32 per pixel of these images, y down), nil when it can't be had.
    static func flow(_ a: CGImage, _ b: CGImage) -> CVPixelBuffer? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        request.revision = VNGenerateOpticalFlowRequestRevision1
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        guard (try? VNImageRequestHandler(cgImage: a, options: [:]).perform([request])) != nil else { return nil }
        return (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer
    }

    static func buffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(w)x\(h)"
        if pools[key] == nil {
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                             kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    static func texture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat, _ cache: CVMetalTextureCache) -> CVMetalTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, CVPixelBufferGetWidth(buffer),
                                                  CVPixelBufferGetHeight(buffer), 0, &t)
        return t
    }

    /// p.x: flow → canvas px × shutter, p.y: most samples, p.z: shorter motion than this (px) is left sharp.
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void motionBlur(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::sample> flow [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float4 &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (gid.x >= w || gid.y >= h) return;
        constexpr sampler img(coord::pixel, address::clamp_to_edge, filter::linear);
        constexpr sampler fl(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 pos = float2(gid) + 0.5;
        float2 v = flow.sample(fl, pos / float2(w, h)).xy * p.x;
        float len = length(v);
        if (len < p.z) { dst.write(src.sample(img, pos), gid); return; }
        int n = clamp(int(ceil(len)), 2, int(p.y));
        float4 acc = 0.0;
        for (int i = 0; i < n; i++) {
            float t = float(i) / float(n - 1) - 0.5;
            acc += src.sample(img, pos + v * t);
        }
        dst.write(acc / float(n), gid);
    }
    """
}
