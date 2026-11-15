import CoreImage

/// Glass under a motion-graphics scene (`OverlayGlass`), as a pane of real glass over the picture:
/// 1. the picture under the scene blurred (`blur` px) and made a little brighter and richer, as frosted glass;
/// 2. bent near the shape's edge as thick glass bends it: the mask's alpha softened (`band` px), and each pixel takes the
///    blurred picture from a little further into the glass — `refraction` × 25 px at the rim, fading to nothing ~35 px in
///    (so the middle is blur only and the rim magnifies, like a lens's edge);
/// 3. cut to the mask's alpha; outside it the picture stays sharp.
/// One Core Image kernel (Metal source, compiled the first time it is needed) and Core Image's own blur and colour.
enum Glass {
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    // the blurred picture, taken from `shift` px further into the glass at its rim (where the softened mask is 0.5),
    // less and less further in, not at all where it is 1
    [[ stitchable ]] float4 simbiaGlass(sampler picture, sampler edge, float shift, destination dest) {
        float2 d = dest.coord();
        float e = edge.sample(edge.transform(d)).r;
        float2 g = float2(edge.sample(edge.transform(d + float2(1.0, 0.0))).r - edge.sample(edge.transform(d - float2(1.0, 0.0))).r,
                          edge.sample(edge.transform(d + float2(0.0, 1.0))).r - edge.sample(edge.transform(d - float2(0.0, 1.0))).r);
        float n = length(g);
        float k = clamp(2.0 * (1.0 - e), 0.0, 1.0);
        float2 o = n > 0.00001 ? g / n * shift * k * (2.0 - k) : float2(0.0);
        return picture.sample(picture.transform(d + o));
    }
    }}
    """

    private static let kernel: CIKernel? = { try? CIKernel.kernels(withMetalString: source).first }()

    /// `picture` with glass where `mask`'s alpha is (both on the canvas, CI coordinates); `blur` in canvas px, `scale`
    /// = canvas px per stage px.
    static func apply(under picture: CIImage, mask: CIImage, blur: Double, refraction: Double, scale: Double, size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        // the mask's alpha as grey, softened into the band the rim bends over
        let alpha = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let edge = alpha.composited(over: CIImage(color: .black).cropped(to: canvas)).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24 * scale]).cropped(to: canvas)
        // frosted: blurred, a touch brighter and richer
        let frosted = Frame.gaussian(picture, radius: max(0, blur), size: size)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.04, kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.0])
        let shift = max(0, refraction) * 25 * scale
        var glass = frosted
        if shift > 0.01, let kernel {
            glass = kernel.apply(extent: canvas, roiCallback: { i, r in r.insetBy(dx: -(i == 0 ? shift : 0) - 2, dy: -(i == 0 ? shift : 0) - 2) },
                                 arguments: [frosted.clampedToExtent(), edge.clampedToExtent(), Float(shift)]) ?? frosted
        }
        return glass.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: picture, kCIInputMaskImageKey: mask])
            .cropped(to: canvas)
    }
}
