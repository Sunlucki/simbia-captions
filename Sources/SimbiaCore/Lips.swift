import CoreImage
import Foundation
import Vision

/// Lipstick on footage whose lips came out paler than the story needs (an AI take that "forgot" the colour after
/// the application). The lips are found on every source frame with Apple Vision's face landmarks — the outer
/// outline minus the open mouth, so teeth and tongue stay — and take the colour's hue and saturation over their
/// own light and texture, through a soft edge.
enum Lips {
    /// Outer and inner lip outlines and the face's middle line per source frame, in the image's own coordinates (y up);
    /// empty = no face.
    private static var outlines: [String: [Face]] = [:]
    private typealias Face = (outer: [CGPoint], inner: [CGPoint], median: [CGPoint])
    private static let lock = NSLock()
    /// The last lips found in each shot and when (ms in its clip): a frame where Vision loses the face (the cup over the
    /// mouth, a blur) keeps them for a moment instead of the lipstick flickering off.
    private static var last: [String: (ms: Int, faces: [Face])] = [:]

    /// `image` = the shot's source frame (before framing); `key` names that frame (clip + time in the clip), `ms` that time.
    static func apply(_ image: CIImage, grade: Grade?, key: String, shot: String = "", ms: Int = 0) -> CIImage {
        guard let grade, grade.on, grade.lips > 0.001, let (r, g, b) = rgb(grade.lipColour) else { return image }
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return image }
        var faces = outlines(of: image, key: key)
        lock.lock()
        if !faces.isEmpty { last[shot] = (ms, faces) } else if let held = last[shot], abs(ms - held.ms) <= 300 { faces = held.faces }
        lock.unlock()
        guard !faces.isEmpty else { return image }

        // the mask: lips white, the mouth opening black, drawn at half size and scaled up soft
        let k = 0.5, w = Int(e.width * k), h = Int(e.height * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        for face in faces {
            ctx.setFillColor(gray: 1, alpha: 1); ctx.addPath(smooth(face.outer, k)); ctx.fillPath()
            if let side = grade.lipSide {                                 // split face: the other half of the mouth stays as it is
                let (top, bottom) = middle(face)
                func x(_ y: Double) -> Double { abs(top.y - bottom.y) < 1 ? top.x : top.x + (y - top.y) * (bottom.x - top.x) / (bottom.y - top.y) }
                let far = side == "right" ? 0 : e.width
                let half = CGMutablePath()
                half.addLines(between: [CGPoint(x: far * k, y: 0), CGPoint(x: x(0) * k, y: 0),
                                        CGPoint(x: x(e.height) * k, y: e.height * k), CGPoint(x: far * k, y: e.height * k)])
                half.closeSubpath()
                ctx.setFillColor(gray: 0, alpha: 1); ctx.addPath(half); ctx.fillPath()
            }
            guard face.inner.count > 2 else { continue }
            ctx.setFillColor(gray: 0, alpha: 1); ctx.addPath(smooth(face.inner, k)); ctx.fillPath()
            let open = abs(zip(face.inner, face.inner.dropFirst() + [face.inner[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
            if open > 400 {                                               // open mouth: keep the colour off the teeth's edge
                ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setLineWidth(3); ctx.addPath(smooth(face.inner, k)); ctx.strokePath()
            }
        }
        guard let drawn = ctx.makeImage() else { return image }
        let soft = 1 + grade.lipSoftness * 7                              // edge blur in frame pixels
        let mask = CIImage(cgImage: drawn)
            .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: soft]).cropped(to: e)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: grade.lips, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: grade.lips, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: grade.lips, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let lo = 0.06 + 0.12 * grade.lipTeeth                              // chroma below this is white (teeth)
        let lipsOnly = coloured?.apply(extent: e, arguments: [image, lo, lo + 0.05]).map {
            mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: $0])
        } ?? mask
        let colour = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: e)
        let painted = colour.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return painted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: lipsOnly])
    }

    /// 1 where the picture has colour (lips, skin), 0 on the white of the teeth — Vision's mouth opening is coarse at
    /// the corners, so the lipstick would otherwise catch the side teeth. Chroma (max − min channel) rather than
    /// saturation, so teeth in shadow count as white too: teeth ≈ 0.05–0.16, lips and skin ≈ 0.18–0.25.
    private static let coloured = CIColorKernel(source: """
        kernel vec4 coloured(__sample s, float lo, float hi) {
            float c = max(s.r, max(s.g, s.b)) - min(s.r, min(s.g, s.b));
            float w = smoothstep(lo, hi, c);
            return vec4(w, w, w, 1.0);
        }
        """)

    /// The face's middle line (top and bottom point): Vision's median line, else straight up through the middle of the mouth.
    private static func middle(_ face: Face) -> (CGPoint, CGPoint) {
        if face.median.count > 1, let top = face.median.max(by: { $0.y < $1.y }), let bottom = face.median.min(by: { $0.y < $1.y }) {
            return (top, bottom)
        }
        let xs = face.outer.map(\.x), mid = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        return (CGPoint(x: mid, y: 1), CGPoint(x: mid, y: 0))
    }

    private static func outlines(of image: CIImage, key: String) -> [Face] {
        lock.lock(); if let known = outlines[key] { lock.unlock(); return known }; lock.unlock()
        let e = image.extent
        let frame = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var found = detect(frame, e.size)
        if found.isEmpty {
            // a second look at the frame shrunk to half inside a grey canvas: a face cut by the frame's edge or half
            // behind a cup is found that way more often; its points go back to the frame's own coordinates
            let place = CGAffineTransform(scaleX: 0.5, y: 0.5).concatenating(CGAffineTransform(translationX: e.width / 4, y: e.height / 4))
            let canvas = frame.transformed(by: place).composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: e.size)))
            let back = place.inverted()
            found = detect(canvas, e.size).map { f in (f.outer.map { $0.applying(back) }, f.inner.map { $0.applying(back) }, f.median.map { $0.applying(back) }) }
        }
        lock.lock()
        if outlines.count > 4000 { outlines.removeAll() }
        outlines[key] = found
        lock.unlock()
        return found
    }

    private static func detect(_ image: CIImage, _ size: CGSize) -> [Face] {
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { face in
            guard let outer = face.landmarks?.outerLips?.pointsInImage(imageSize: size), outer.count > 2 else { return nil }
            return (outer, face.landmarks?.innerLips?.pointsInImage(imageSize: size) ?? [], face.landmarks?.medianLine?.pointsInImage(imageSize: size) ?? [])
        }
    }

    /// A closed Catmull-Rom curve through the landmark points (Vision gives 14 round the lips, 6 inside), scaled by `k`.
    private static func smooth(_ points: [CGPoint], _ k: Double) -> CGPath {
        let p = points.map { CGPoint(x: $0.x * k, y: $0.y * k) }, n = p.count
        let path = CGMutablePath()
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
