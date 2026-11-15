import CoreImage
import Foundation

/// A transition on a cut: the shot before it and the one after play over each other for `duration`, centred on
/// the cut (each side uses footage its file has past the cut — less footage, a shorter transition).
public struct TransitionClip: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// cross dissolve · through black · white flash · whip pan with motion blur · zoom in through a radial blur
        /// · zoom out (the camera pulls back across the cut) · through a blur · push
        case dissolve, black, white, whip, zoom, zoomOut, blur, slide
    }
    /// Which way the picture moves in a whip or a push.
    public enum Direction: String, Codable, CaseIterable, Sendable { case left, right, up, down }

    public var id: String
    /// The shot before the cut.
    public var after: String
    public var kind: Kind = .dissolve
    public var duration = 0.4
    public var direction: Direction = .left

    public init(id: String, after: String, kind: Kind = .dissolve, duration: Double = 0.4) {
        self.id = id; self.after = after; self.kind = kind; self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        after = try c.value(.after, "")
        kind = try c.value(.kind, Kind.dissolve)
        duration = try c.value(.duration, 0.4)
        direction = try c.value(.direction, Direction.left)
    }
}

/// How the two pictures of a transition are put together at `p` (0 = all the shot before, 1 = all the one after).
enum TransitionRender {
    static func blend(_ a: CIImage, _ b: CIImage, _ clip: TransitionClip, progress p: Double, size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: canvas)
        let e = p * p * (3 - 2 * p)                                          // ease in and out
        switch clip.kind {
        case .dissolve:
            return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: e])
        case .black:
            // down to black over the first half, up from it over the second
            return p < 0.5 ? scaled(a, by: 1 - smooth(p * 2)) : scaled(b, by: smooth(p * 2 - 1))
        case .white:
            // a flash: white peaks at the cut
            let white = CIImage(color: .white).cropped(to: canvas)
            let f = 1 - abs(2 * p - 1)
            return (p < 0.5 ? a : b).applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: white,
                                                                                      kCIInputTimeKey: smooth(f)])
        case .slide, .whip:
            // the picture after pushes the one before out; a whip is faster through the middle and smeared along the move
            let travel = clip.kind == .whip ? whipCurve(p) : e
            let (dx, dy, span) = vector(clip.direction, size)
            // the shot before moves the way of `direction`, the next comes in behind it from the other side
            let outA = a.transformed(by: CGAffineTransform(translationX: dx * span * travel, y: dy * span * travel))
            let inB = b.transformed(by: CGAffineTransform(translationX: -dx * span * (1 - travel), y: -dy * span * (1 - travel)))
            var both = inB.composited(over: outA).cropped(to: canvas)
            if clip.kind == .whip {
                let radius = 0.09 * span * sin(.pi * p)
                if radius > 0.5 {
                    both = both.clampedToExtent()
                        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(dy, dx)])
                        .cropped(to: canvas)
                }
            }
            return both.composited(over: black)
        case .zoom:
            // into the shot before (growing, a radial blur), out of the one after (shrinking back to size)
            let centre = CIVector(x: size.width / 2, y: size.height / 2)
            let blur = 26 * sin(.pi * p)
            let image = p < 0.5 ? zoomed(a, 1 + 0.6 * smooth(p * 2), size) : zoomed(b, 1 + 0.6 * (1 - smooth(p * 2 - 1)), size)
            let out = blur > 0.5
                ? image.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: centre, kCIInputAmountKey: blur]).cropped(to: canvas)
                : image
            return out.composited(over: black)
        case .zoomOut:
            // the shot before shrinks away (its edges carried out under the blur), the next one arrives close and
            // settles back to size — one pull-back across the cut
            let image = p < 0.5 ? zoomed(a.clampedToExtent(), 1 - 0.3 * smooth(p * 2), size)
                                : zoomed(b, 1 + 0.6 * (1 - smooth(p * 2 - 1)), size)
            return MotionBlur.radial(image.composited(over: black), strength: 0.19 * sin(.pi * p), size: size)
        case .blur:
            let ra = 34 * e, rb = 34 * (1 - e)
            let ba = ra > 0.3 ? a.clampedToExtent().applyingGaussianBlur(sigma: ra).cropped(to: canvas) : a
            let bb = rb > 0.3 ? b.clampedToExtent().applyingGaussianBlur(sigma: rb).cropped(to: canvas) : b
            return ba.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: bb, kCIInputTimeKey: e])
        }
    }

    private static func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }

    /// Slow out of the shot, fast across the cut, slow into the next — like a camera whipped round.
    private static func whipCurve(_ p: Double) -> Double {
        let x = min(1, max(0, p))
        return x < 0.5 ? 0.5 * pow(2 * x, 3) : 1 - 0.5 * pow(2 - 2 * x, 3)
    }

    /// Unit step and how far: CI's y points up, so "up" is +y.
    private static func vector(_ d: TransitionClip.Direction, _ size: CGSize) -> (Double, Double, Double) {
        switch d {
        case .left: return (-1, 0, size.width)
        case .right: return (1, 0, size.width)
        case .up: return (0, 1, size.height)
        case .down: return (0, -1, size.height)
        }
    }

    private static func scaled(_ image: CIImage, by k: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    private static func zoomed(_ image: CIImage, _ s: Double, _ size: CGSize) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: s, y: s)
            .translatedBy(x: -size.width / 2, y: -size.height / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
