import CoreGraphics
import Foundation

/// CSS `cubic-bezier(x1, y1, x2, y2)`: y for a given x, solved the way browsers do (Newton, then bisection).
struct CubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2 }

    static let linear = CubicBezier(0, 0, 1, 1)
    static let ease = CubicBezier(0.25, 0.1, 0.25, 1)
    static let easeIn = CubicBezier(0.42, 0, 1, 1)
    static let easeOut = CubicBezier(0, 0, 0.58, 1)
    static let easeInOut = CubicBezier(0.42, 0, 0.58, 1)

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let err = sample(t, x1, x2) - x
            if abs(err) < 1e-7 { return sample(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = sample(t, x1, x2)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }
}

/// One animated number (opacity, a translation in em, a blur radius…) as CSS keyframes: the
/// keyframes that name this property, each interval eased on its own with the animation's timing
/// function.
struct Track {
    var stops: [(Double, Double)]

    init(_ stops: [(Double, Double)]) { self.stops = stops.sorted { $0.0 < $1.0 } }

    /// The same value all the way (a property the animation does not touch).
    static func constant(_ v: Double) -> Track { Track([(0, v), (1, v)]) }

    func value(_ progress: Double, _ easing: CubicBezier) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if progress <= first.0 { return first.1 }
        if progress >= last.0 { return last.1 }
        for i in 0..<(stops.count - 1) where progress >= stops[i].0 && progress <= stops[i + 1].0 {
            let (a, va) = stops[i], (b, vb) = stops[i + 1]
            guard b > a else { return vb }
            let local = easing((progress - a) / (b - a))
            return va + (vb - va) * local
        }
        return last.1
    }
}

/// A CSS animation's clock: duration, delay and `animation-fill-mode: both` — before it starts it
/// holds the first keyframe, after it ends the last.
struct Clock {
    let duration: Double
    var delay = 0.0
    let easing: CubicBezier

    /// 0…1 through the animation at `elapsed` seconds after the element appeared.
    func progress(_ elapsed: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, (elapsed - delay) / duration))
    }

    func value(_ track: Track, _ elapsed: Double) -> Double { track.value(progress(elapsed), easing) }
}

/// The animated state of one element at one moment.
struct Motion {
    var opacity = 1.0
    var dx = 0.0, dy = 0.0          // translate, px
    var scale = 1.0
    var scaleX = 1.0
    var rotate = 0.0                // degrees
    var blur = 0.0                  // filter: blur(σ px)

    /// CSS `transform: translate(dx, dy) scale(s) rotate(r)` about `origin`, as one matrix in the
    /// element's coordinate space (y down).
    func transform(origin: CGPoint) -> CGAffineTransform {
        var m = CGAffineTransform(translationX: origin.x, y: origin.y)
        m = m.translatedBy(x: dx, y: dy)
        m = m.scaledBy(x: scale * scaleX, y: scale)
        m = m.rotated(by: rotate * .pi / 180)
        return m.translatedBy(x: -origin.x, y: -origin.y)
    }
}
