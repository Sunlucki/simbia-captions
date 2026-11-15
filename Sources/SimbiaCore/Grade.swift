import CoreImage
import Foundation

/// The colour of one shot: an automatic match to its scene (per-channel gain and offset, written by Claude
/// to bring the shot to the scene's reference frame) plus the editor's own adjustments. Values work on the
/// picture as decoded (gamma-encoded RGB, 0…1), like everything else the compositor does.
public struct Grade: Codable, Equatable, Sendable {
    /// Off = the footage as it is: no match, no adjustments, no project look.
    public var on = true
    /// The match: out = in × gain + offset, per channel (r, g, b).
    public var gain: [Double] = [1, 1, 1]
    public var offset: [Double] = [0, 0, 0]
    /// How much of the match is used, 0…1.
    public var match = 1.0
    /// −1…1: darker…brighter (±41 %).
    public var exposure = 0.0
    /// Multipliers, 1 = unchanged.
    public var contrast = 1.0
    public var saturation = 1.0
    /// −1…1: cooler…warmer, green…magenta.
    public var warmth = 0.0
    public var tint = 0.0
    /// Scene the match was made for (shown in the shot window), e.g. "garage night".
    public var scene: String?
    /// Lipstick, for a take whose lips came out paler than the story needs: 0 = off … 1 = the colour fully
    /// (the lips are found on every frame, see `Lips`).
    public var lips = 0.0
    /// The lipstick colour, "#RRGGBB" — only its hue and saturation count, the lips keep their own light.
    public var lipColour = "#C85A68"
    /// 0…1: how soft the edge of the lips is.
    public var lipSoftness = 0.5
    /// 0…1: how much of the near-white is kept off (teeth): higher spares greyer whites too, at 1 the palest lip edges go as well.
    public var lipTeeth = 0.6
    /// A split-face take: the lipstick on one half of the mouth only, "left" or "right" of the picture, cut at the
    /// face's middle line; nil = the whole mouth.
    public var lipSide: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Grade()
        on = try c.value(.on, d.on)
        gain = try c.value(.gain, d.gain)
        offset = try c.value(.offset, d.offset)
        match = try c.value(.match, d.match)
        exposure = try c.value(.exposure, d.exposure)
        contrast = try c.value(.contrast, d.contrast)
        saturation = try c.value(.saturation, d.saturation)
        warmth = try c.value(.warmth, d.warmth)
        tint = try c.value(.tint, d.tint)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        lips = try c.value(.lips, d.lips)
        lipColour = try c.value(.lipColour, d.lipColour)
        lipSoftness = try c.value(.lipSoftness, d.lipSoftness)
        lipTeeth = try c.value(.lipTeeth, d.lipTeeth)
        lipSide = try c.decodeIfPresent(String.self, forKey: .lipSide)
    }

    /// Has a match from Claude (not just hand adjustments).
    public var hasMatch: Bool { gain != [1, 1, 1] || offset != [0, 0, 0] }

    /// The hand adjustments are all at their defaults.
    public var untouched: Bool { exposure == 0 && contrast == 1 && saturation == 1 && warmth == 0 && tint == 0 && lips == 0 }

    func applied(to image: CIImage) -> CIImage {
        func channel(_ k: Int) -> Double { 1 + ((gain[safe: k] ?? 1) - 1) * match }
        let light = pow(2, exposure * 0.5)
        let r = channel(0) * light * (1 + 0.08 * warmth) * (1 + 0.03 * tint)
        let g = channel(1) * light * (1 - 0.06 * tint)
        let b = channel(2) * light * (1 - 0.08 * warmth) * (1 + 0.03 * tint)
        var out = image
        if r != 1 || g != 1 || b != 1 || hasMatch {
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: (offset[safe: 0] ?? 0) * match, y: (offset[safe: 1] ?? 0) * match,
                                            z: (offset[safe: 2] ?? 0) * match, w: 0),
            ])
        }
        if contrast != 1 || saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation, kCIInputContrastKey: contrast, kCIInputBrightnessKey: 0.0])
        }
        return out
    }
}

/// The look of the whole project, laid over every shot whose colour is on: one curve, one warmth, teal
/// shadows / warm highlights, lifted blacks, vignette and film grain — what makes footage from different
/// generators read as one film.
public struct ColourLook: Codable, Equatable, Sendable {
    public var on = true
    /// 0…1: how strong the S-curve is.
    public var contrast = 0.3
    /// Multiplier, 1 = unchanged.
    public var saturation = 0.92
    /// −1…1: cooler…warmer, green…magenta.
    public var warmth = 0.1
    public var tint = 0.0
    /// 0…1: teal in the shadows, warm in the highlights.
    public var split = 0.3
    /// 0…1: blacks lifted (a soft, filmic floor).
    public var fade = 0.2
    /// 0…1.
    public var vignette = 0.18
    /// 0…1: film grain, a new pattern every frame.
    public var grain = 0.2
    /// 0…1: the shutter angle of the motion blur as a share of a full turn (0.5 = 180°, like a film camera).
    public var motionBlur = 0.5
    /// The blur goes across the cuts: a shot that ends moving fast carries its smear into the next one (fading over
    /// ~6 frames), and a shot that starts with a whip builds it up over the last 3 frames before it.
    public var cutBlur = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ColourLook()
        on = try c.value(.on, d.on)
        contrast = try c.value(.contrast, d.contrast)
        saturation = try c.value(.saturation, d.saturation)
        warmth = try c.value(.warmth, d.warmth)
        tint = try c.value(.tint, d.tint)
        split = try c.value(.split, d.split)
        fade = try c.value(.fade, d.fade)
        vignette = try c.value(.vignette, d.vignette)
        grain = try c.value(.grain, d.grain)
        motionBlur = try c.value(.motionBlur, d.motionBlur)
        cutBlur = try c.value(.cutBlur, d.cutBlur)
    }

    static let cubeSize = 33

    /// The curve, warmth, split toning, fade and saturation as one 3D lookup table (RGBA floats).
    func cube() -> Data {
        let n = Self.cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let s = contrast * 0.7
        let wr = 1 + 0.08 * warmth + 0.03 * tint, wg = 1 - 0.06 * tint, wb = 1 - 0.08 * warmth + 0.03 * tint
        let floor = fade * 0.09
        func curve(_ x: Double) -> Double {
            let x = min(1, max(0, x))
            return (1 - s) * x + s * x * x * (3 - 2 * x)                     // blend toward smoothstep: an S around 0.5
        }
        var k = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = Double(ri) / Double(n - 1) * wr, g = Double(gi) / Double(n - 1) * wg, b = Double(bi) / Double(n - 1) * wb
                    r = curve(r); g = curve(g); b = curve(b)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let shadow = (1 - luma) * (1 - luma) * split * 0.06, light = luma * luma * split * 0.05
                    r += -0.6 * shadow + 0.6 * light
                    g += 0.15 * shadow + 0.15 * light
                    b += 0.6 * shadow - 0.6 * light
                    r = luma + (r - luma) * saturation; g = luma + (g - luma) * saturation; b = luma + (b - luma) * saturation
                    r = floor + r * (1 - floor); g = floor + g * (1 - floor); b = floor + b * (1 - floor)
                    values[k] = Float(min(1, max(0, r))); values[k + 1] = Float(min(1, max(0, g)))
                    values[k + 2] = Float(min(1, max(0, b))); values[k + 3] = 1
                    k += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func applied(to image: CIImage, size: CGSize, frame: Int, cube: Data) -> CIImage {
        var out = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": cube])
        if vignette > 0.001 {
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2),
                kCIInputRadiusKey: hypot(size.width, size.height) * 0.42,
                kCIInputIntensityKey: vignette * 0.85,
                "inputFalloff": 0.65,
            ]).cropped(to: CGRect(origin: .zero, size: size))
        }
        if grain > 0.001, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            // a different stretch of the endless noise every frame, slightly enlarged so it clumps like film
            var seed = UInt64(truncatingIfNeeded: frame &* 2654435761) ^ 0x9E3779B97F4A7C15
            // offsets kept small: far out in its plane the generator's noise breaks into sparse white specks
            func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) % 2048) }
            let amp = grain * 0.9
            let canvas = CGRect(origin: .zero, size: size)
            // the generator's alpha is random too: made opaque first, or un-premultiplying blows a few pixels up to white
            let gray = noise.transformed(by: CGAffineTransform(translationX: -next(), y: -next()))
                .transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6))
                .cropped(to: canvas).settingAlphaOne(in: canvas)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: amp, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: amp, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - amp / 2, y: 0.5 - amp / 2, z: 0.5 - amp / 2, w: 1),
                ])
                .cropped(to: CGRect(origin: .zero, size: size))
            out = gray.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: out])
        }
        return out
    }
}

/// A filter over a stretch of the edit — an adjustment layer: its colour adjustments go over every shot
/// under it (after the shot's own colour, before the project look).
public struct FilterClip: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var duration: Double
    /// Shown on the filter track.
    public var label: String?
    /// on + exposure / contrast / saturation / warmth / tint (no match).
    public var grade = Grade()

    public var end: Double { start + duration }

    public init(id: String, start: Double, duration: Double, label: String? = nil) {
        self.id = id; self.start = start; self.duration = duration; self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        start = try c.value(.start, 0.0)
        duration = try c.value(.duration, 1.0)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        grade = try c.value(.grade, Grade())
    }
}

/// What the compositor does with colour: the shot's grade, the filters over it, then the project's look.
enum Colour {
    static func apply(_ image: CIImage, grade: Grade?, filters: [FilterClip], look: ColourLook?, size: CGSize, frame: Int,
                      cube: (ColourLook) -> Data) -> CIImage {
        if let grade, !grade.on { return image }
        var out = image
        if let grade { out = grade.applied(to: out) }
        for filter in filters where filter.grade.on { out = filter.grade.applied(to: out) }
        if let look, look.on { out = look.applied(to: out, size: size, frame: frame, cube: cube(look)) }
        return out
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
