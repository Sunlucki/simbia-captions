import AVFoundation
import CoreImage
import ImageIO

/// What every frame of one build shares: the project, decoded stills and motion-graphics frames,
/// the title blur windows and the Core Image context.
///
/// Blending happens in gamma-encoded sRGB, like a browser and like ffmpeg's overlay — compositing
/// in linear light would make soft shadows and semi-transparent edges look different from the web.
public final class RenderContext: @unchecked Sendable {
    public let project: Project
    public let projectURL: URL?
    public let drawsOverlay: Bool
    public let size: CGSize
    let ci: CIContext
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let blurs: [BlurWindow]
    let sequences: [FrameSequence]
    /// The overlay track's videos (set by the build before anything is drawn).
    var layers: [ShotInstruction] = []
    /// Draws captions and titles into a frame. Set before rendering when `drawsOverlay` is on.
    public var overlay: ((CGContext, Double) -> Void)?

    private let lock = NSLock()
    private var stills: [String: CIImage] = [:]
    /// Colour by shot id and the project look. Kept here, not only in `project`, so the app can change them
    /// while the preview plays — no rebuild, the next frame drawn already has them.
    private var grades: [String: Grade]
    /// The key and the transform by shot id — live like the colour, so the sliders and a drag on the picture need no rebuild.
    private var cutouts: [String: Cutout]
    private var look: ColourLook?
    private var filters: [FilterClip]
    private var cubeCache: (look: ColourLook, data: Data)?
    /// Shots in time order, and how each one's picture moves at its end / its start (for the blur across cuts).
    let ordered: [Shot]
    /// Cuts with a transition (by the shot before them): no blur carried across those.
    let transitionAfter: Set<String>
    /// Edge motion, measured once per clip edge and kept across rebuilds (an edit elsewhere doesn't measure it again).
    nonisolated(unsafe) private static var edges: [String: EdgeMotion?] = [:]
    nonisolated(unsafe) private static var measuring: Set<String> = []
    private static let edgeLock = NSLock()

    /// A shot's motion field at an edge and how to scale its vectors to canvas px.
    struct EdgeMotion: @unchecked Sendable { let flow: CVPixelBuffer; let scale: Double }

    init(project: Project, projectURL: URL?, drawsOverlay: Bool) {
        self.project = project
        self.projectURL = projectURL
        self.drawsOverlay = drawsOverlay
        size = CGSize(width: project.canvas.width, height: project.canvas.height)
        ci = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .cacheIntermediates: false])
        blurs = project.titles.filter(\.blur).map(BlurWindow.init)
        sequences = project.overlays.compactMap { FrameSequence(clip: $0, projectURL: projectURL) }
        grades = Self.grades(of: project)
        cutouts = Self.cutouts(of: project)
        look = project.look
        filters = project.filters
        ordered = project.shots.sorted { $0.start < $1.start }
        transitionAfter = Set(project.transitions.map(\.after))
    }

    /// How the picture moves over a shot's last two source frames (`exit`) or its first two — the whole motion
    /// field, so a pan, a push or a pull each carry their own kind of smear. Measured once per shot edge, never on
    /// the compositor's own threads: a frame asked for before its edge is measured is drawn without the blur across
    /// the cut and the measuring starts in the background. (Waiting for it there held every render thread after an
    /// edit — the preview froze on one frame while the sound played on.) Export measures every edge first.
    func edgeMotion(_ shot: Shot, exit: Bool) -> EdgeMotion? {
        let key = Self.edgeKey(shot, exit: exit)
        let (known, start) = Self.edgeLock.withLock { () -> (EdgeMotion??, Bool) in
            if let v = Self.edges[key] { return (v, false) }
            return (nil, Self.measuring.insert(key).inserted)
        }
        if let known { return known }
        if start {
            let url = projectURL, canvas = size
            Task.detached(priority: .utility) { await Self.measure(shot, exit: exit, key: key, projectURL: url, canvas: canvas) }
        }
        return nil
    }

    /// Every edge the blur across cuts can use, measured before a render that must have them all (export, stills) — and
    /// every keyed video's key colour.
    public func prepareEdges() async {
        await prepareKeys()
        guard let look = lock.withLock({ self.look }), look.on, look.motionBlur > 0.001, look.cutBlur else { return }
        var todo: [(Shot, Bool)] = []
        for (i, shot) in ordered.enumerated() {
            if i + 1 < ordered.count, !transitionAfter.contains(shot.id) { todo.append((shot, true)); todo.append((ordered[i + 1], false)) }
        }
        todo = todo.filter { item in Self.edgeLock.withLock { Self.edges[Self.edgeKey(item.0, exit: item.1)] == nil } }
        let url = projectURL, canvas = size
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (shot, exit) in todo {
                if running == 4 { await group.next(); running -= 1 }      // a few at once: decoders are shared
                group.addTask { await Self.measure(shot, exit: exit, key: Self.edgeKey(shot, exit: exit), projectURL: url, canvas: canvas) }
                running += 1
            }
        }
    }

    private static func edgeKey(_ shot: Shot, exit: Bool) -> String { "\(shot.src)|\(shot.inPoint)|\(shot.footage)|\(exit)" }

    private static func measure(_ shot: Shot, exit: Bool, key: String, projectURL: URL?, canvas: CGSize) async {
        if edgeLock.withLock({ edges[key] != nil }) { return }
        let v = await measureEdge(shot, exit: exit, projectURL: projectURL, canvas: canvas)
        edgeLock.withLock {
            if edges.count > 600 { edges.removeAll() }
            edges[key] = .some(v); measuring.remove(key)
        }
    }

    private static func measureEdge(_ shot: Shot, exit: Bool, projectURL: URL?, canvas: CGSize) async -> EdgeMotion? {
        guard !Project.stillTypes.contains((shot.src as NSString).pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: Project.resolve(shot.src, relativeTo: projectURL))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let rate = try? await track.load(.nominalFrameRate) else { return nil }
        let step = rate > 1 ? 1 / Double(rate) : 1 / 30
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 270, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // three frames at the edge: the last (or first) pair that differs — a repeated frame shows no motion
        let edge = exit ? shot.inPoint + shot.footage - step * 0.5 : shot.inPoint + step * 0.5
        func at(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 600) }
        var images: [CGImage] = []
        for k in 0..<3 {
            if let image = try? await generator.image(at: at(exit ? edge - Double(2 - k) * step : edge + Double(k) * step)).image {
                images.append(image)
            }
        }
        guard images.count == 3 else { return nil }
        let (a, b) = exit ? (MotionBlur.same(images[1], images[2]) ? (images[0], images[1]) : (images[1], images[2]))
                          : (MotionBlur.same(images[0], images[1]) ? (images[1], images[2]) : (images[0], images[1]))
        guard let flow = MotionBlur.flow(a, b) else { return nil }
        // image px → canvas px (the picture fills the canvas: the larger of the two scales)
        return EdgeMotion(flow: flow, scale: Double(max(canvas.width / CGFloat(a.width), canvas.height / CGFloat(a.height))))
    }

    static func grades(of project: Project) -> [String: Grade] {
        Dictionary((project.shots + project.layers).compactMap { s in s.grade.map { (s.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A shot's key and transform (`Shot.chromaKey`, `Shot.transform`), and its file.
    struct Cutout: Equatable {
        let key: ChromaKey?
        let transform: LayerTransform?
        let src: String
        /// Laid over the picture under it, not covering it — as `Shot.cutout`.
        var active: Bool { (key?.on ?? false) || !(transform?.isIdentity ?? true) }
    }

    static func cutouts(of project: Project) -> [String: Cutout] {
        Dictionary((project.shots + project.layers).compactMap { s in
            s.chromaKey == nil && s.transform == nil ? nil : (s.id, Cutout(key: s.chromaKey, transform: s.transform, src: s.src))
        }, uniquingKeysWith: { a, _ in a })
    }

    func cutout(_ shotID: String) -> Cutout? { lock.withLock { cutouts[shotID] } }

    /// The video whose matte the preview shows instead of the picture (Final Cut's View: Matte); never set for an export.
    private var matteShown: String?

    /// Shows a video's matte (nil = the picture again). Returns whether anything changed.
    @discardableResult public func showMatte(_ shotID: String?) -> Bool {
        lock.withLock { defer { matteShown = shotID }; return matteShown != shotID }
    }

    func showsMatte(_ shotID: String) -> Bool { lock.withLock { matteShown == shotID } }

    /// Each keyed video's key colour (`Keyer.measure`), by file: measured once, kept across rebuilds.
    nonisolated(unsafe) private static var screens: [String: SIMD3<Float>?] = [:]
    nonisolated(unsafe) private static var measuringScreens: Set<String> = []

    /// The clip's key colour for a shot keyed without a pipette colour; nil while it is measured (started in the background —
    /// the compositor never waits; the frame meanwhile uses its own screen's average) and for stills.
    func screen(_ src: String) -> SIMD3<Float>? {
        guard !Project.stillTypes.contains((src as NSString).pathExtension.lowercased()) else { return nil }
        let url = Project.resolve(src, relativeTo: projectURL)
        let (known, start) = Self.edgeLock.withLock { () -> (SIMD3<Float>??, Bool) in
            if let v = Self.screens[url.path] { return (v, false) }
            return (nil, Self.measuringScreens.insert(url.path).inserted)
        }
        if let known { return known }
        if start { Task.detached(priority: .userInitiated) { await Self.measureScreen(url) } }
        return nil
    }

    private static func measureScreen(_ url: URL) async {
        let v = await Keyer.measure(url)
        edgeLock.withLock { screens[url.path] = .some(v); measuringScreens.remove(url.path) }
    }

    /// Every keyed video's key colour measured, before a render that must have it (export, stills) or for the preview to
    /// draw again. Returns whether anything was measured.
    @discardableResult public func prepareKeys() async -> Bool {
        let files = lock.withLock { cutouts.values.filter { ($0.key?.on ?? false) && $0.key?.rgb == nil }.map(\.src) }
        var measured = false
        for src in Set(files) where !Project.stillTypes.contains((src as NSString).pathExtension.lowercased()) {
            let url = Project.resolve(src, relativeTo: projectURL)
            if Self.edgeLock.withLock({ Self.screens[url.path] != nil }) { continue }
            await Self.measureScreen(url)
            measured = true
        }
        return measured
    }

    /// The project's colour (and the keys and transforms) as they are now. Returns whether anything changed (then the
    /// shown frame needs redrawing).
    @discardableResult public func setColour(of project: Project) -> Bool {
        let g = Self.grades(of: project), c = Self.cutouts(of: project)
        lock.lock(); defer { lock.unlock() }
        guard g != grades || c != cutouts || project.look != look || project.filters != filters else { return false }
        grades = g; cutouts = c; look = project.look; filters = project.filters
        return true
    }

    /// A shot's colour at `time`: its grade, the filters over that moment and the look.
    func colour(_ shotID: String, at time: Double) -> (grade: Grade?, filters: [FilterClip], look: ColourLook?) {
        lock.lock(); defer { lock.unlock() }
        return (grades[shotID], filters.filter { time >= $0.start && time < $0.end }, look)
    }

    /// The look's lookup table, built once per look.
    func cube(_ look: ColourLook) -> Data {
        lock.lock()
        if let cached = cubeCache, cached.look == look { lock.unlock(); return cached.data }
        lock.unlock()
        let data = look.cube()
        lock.lock(); cubeCache = (look, data); lock.unlock()
        return data
    }

    func still(_ shot: Shot) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let image = stills[shot.src] { return image }
        let url = Project.resolve(shot.src, relativeTo: projectURL)
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        stills[shot.src] = image
        return image
    }

    /// 0…1: how far the picture is blurred behind the titles at `time`.
    func blurWeight(_ time: Double) -> Double {
        blurs.map { $0.weight(time) }.max() ?? 0
    }
}

/// The picture behind a title blurs in and out with it. Same windows as the web renderer used:
/// T1 fades the blur over 12% of the title at 4% and 90%; the T2 handwriting stays readable to
/// its own fade-out, so the blur covers the whole title with 0.4 s ramps.
struct BlurWindow {
    let from: Double, to: Double, ramp: Double

    init(_ title: TitleItem) {
        let d = title.duration
        if TitleStyle(id: title.style)?.number == 2 {
            from = title.start; to = title.start + d; ramp = 0.4
        } else if let n = TitleStyle(id: title.style)?.number, n >= 6 {
            from = title.start; to = title.start + d; ramp = min(0.3, d / 4)        // the plain titles pop in and fade out
        } else {
            from = title.start + 0.04 * d; to = title.start + 0.90 * d; ramp = 0.12 * d
        }
    }

    func weight(_ t: Double) -> Double {
        guard t >= from, t <= to else { return 0 }
        return min(1, (t - from) / ramp) * min(1, (to - t) / ramp)
    }
}

/// A motion-graphics scene: numbered PNG frames with alpha, laid over the picture from `start`.
struct FrameSequence {
    let start: Double
    let fps: Double
    let frames: [URL]
    /// Moved by hand: stage px, y down.
    let offset: CGPoint

    init?(clip: OverlayClip, projectURL: URL?) {
        let folder = Project.resolve(clip.src, relativeTo: projectURL)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        frames = names.filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("._") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }          // frame2 before frame10
            .map { folder.appending(path: $0) }
        guard !frames.isEmpty else { return nil }
        start = clip.start
        fps = clip.fps
        offset = CGPoint(x: clip.x ?? 0, y: clip.y ?? 0)
        length = clip.duration ?? Double(frames.count) / clip.fps
        hold = MotionLibrary.holdFrame(in: folder)
        glass = clip.glass.flatMap { g in
            let folder = Project.resolve(g.mask, relativeTo: projectURL)
            let masks = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("._") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { folder.appending(path: $0) }
            return masks.isEmpty ? nil : (masks, g.blur, g.refraction)
        }
    }

    /// How long it is on screen (see OverlayClip.duration), and the frame it waits on when lengthened.
    let length: Double
    let hold: Int
    /// The glass under it: its mask's frames (taken frame for frame with the scene's), blur and refraction.
    let glass: (masks: [URL], blur: Double, refraction: Double)?

    func index(at time: Double) -> Int? {
        MotionLibrary.frameIndex(at: time - start, length: length, fps: fps, frames: frames.count, hold: hold)
    }

    func frame(at time: Double) -> URL? { index(at: time).map { frames[$0] } }
}

// MARK: - Compositor

/// Draws each frame of the edit. Created by AVFoundation; all state arrives on the instruction.
public final class SimbiaCompositor: NSObject, AVVideoCompositing {
    private static let attributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: any Sendable],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    public var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attributes }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attributes }

    /// Frames are independent of each other, so several are drawn at once (AVFoundation orders them by time).
    private let queue = DispatchQueue(label: "simbia.compositor", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var cancelling = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    /// Told about a frame that could not be drawn (the app writes it to its log; the player would only show black).
    nonisolated(unsafe) public static var report: ((String) -> Void)?
    /// Frames drawn so far by every compositor — the app's watch for a preview that plays on without new pictures.
    public static var framesDrawn: Int { countLock.withLock { drawn } }
    nonisolated(unsafe) private static var drawn = 0
    private static let countLock = NSLock()

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if lock.withLock({ cancelling }) { request.finishCancelledRequest(); return }
            autoreleasepool {
                do {
                    request.finish(withComposedVideoFrame: try Self.render(request))
                    Self.countLock.withLock { Self.drawn += 1 }
                }
                catch {
                    Self.report?("frame at \(String(format: "%.2f", request.compositionTime.seconds)) s: \(error.localizedDescription)")
                    request.finish(with: error)
                }
            }
        }
    }

    /// Seeking or swapping the item: frames already queued finish as cancelled instead of being drawn,
    /// and once the queue has drained new requests render again.
    public func cancelAllPendingVideoCompositionRequests() {
        lock.withLock { cancelling = true }
        queue.async(flags: .barrier) { [self] in lock.withLock { cancelling = false } }
    }

    static func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "Simbia", code: 20, userInfo: [NSLocalizedDescriptionKey: "compositor: no buffer"])
        }
        let t = request.compositionTime.seconds
        func frame(_ track: CMPersistentTrackID) -> CVPixelBuffer? {
            track == kCMPersistentTrackID_Invalid ? nil : request.sourceFrame(byTrackID: track)
        }
        // a video on the overlay track covers the picture while it plays (a later one over an earlier one); one cut out
        // or made smaller is laid over it instead
        func layered(_ picture: CIImage, _ context: RenderContext) -> CIImage {
            var image = picture
            for layer in context.layers where layer.timeRange.containsTime(request.compositionTime) {
                let source = frame(layer.track)
                guard source != nil || layer.track == kCMPersistentTrackID_Invalid else { continue }
                let drawn = Frame.shot(layer, source: source, previous: nil, time: t, inTransition: true)
                image = context.cutout(layer.shot.id)?.active == true ? drawn.composited(over: image) : drawn
            }
            return image
        }
        let context: RenderContext, image: CIImage
        if let transition = request.videoCompositionInstruction as? TransitionInstruction {
            context = transition.context
            let span = transition.timeRange
            let p = min(1, max(0, (t - span.start.seconds) / max(span.duration.seconds, 0.001)))
            let a = Frame.shot(transition.from, source: frame(transition.from.track), previous: nil, time: t, inTransition: true)
            let b = Frame.shot(transition.to, source: frame(transition.to.track), previous: nil, time: t, inTransition: true)
            image = Frame.finish(layered(TransitionRender.blend(a, b, transition.clip, progress: p, size: context.size), context), context: context, time: t)
        } else if let instruction = request.videoCompositionInstruction as? ShotInstruction {
            context = instruction.context
            image = Frame.finish(layered(Frame.shot(instruction, source: frame(instruction.track), previous: frame(instruction.previous),
                                                    next: frame(instruction.next), time: t), context), context: context, time: t)
        } else {
            throw NSError(domain: "Simbia", code: 20, userInfo: [NSLocalizedDescriptionKey: "compositor: no instruction"])
        }
        let canvas = CGRect(origin: .zero, size: context.size)
        context.ci.render(image.cropped(to: canvas), to: output, bounds: canvas, colorSpace: context.srgb)
        if context.drawsOverlay, let draw = context.overlay {
            Frame.drawOverlay(into: output, size: context.size, colorSpace: context.srgb) { draw($0, t) }
        }
        return output
    }
}

/// A shot turned by hand (`Shot.rotation`): the footage turned about its centre, then cut to the largest frame
/// with the canvas's proportions inside it — no black corners, zoomed in no more than the tilt needs; a quarter
/// turn keeps the whole turned picture. The crop window shows the same picture, so its box frames exactly what
/// the edit gets.
public enum Rotation {
    public static func apply(_ image: CIImage, degrees: Double, aspect canvas: Double) -> CIImage {
        let e = image.extent
        guard abs(degrees.truncatingRemainder(dividingBy: 360)) > 0.001, e.width > 0, e.height > 0, e.width.isFinite else { return image }
        let a = -degrees * .pi / 180                                    // clockwise as seen; CI's y points up
        let c = abs(cos(a)), s = abs(sin(a)), W = e.width, H = e.height
        let turned = image.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY).concatenating(CGAffineTransform(rotationAngle: a)))
        let quarter = abs(degrees / 90 - (degrees / 90).rounded()) < 0.0005
        let aspect = quarter ? (W * c + H * s) / (W * s + H * c) : canvas
        let w = min(W / (c + s / aspect), H / (s + c / aspect)), h = w / aspect
        return turned.cropped(to: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    }
}

/// The picture for one frame, as Core Image steps. Kept apart from the compositor so stills can
/// be rendered without AVFoundation in the loop.
enum Frame {
    /// One shot's own picture at `t`: lipstick, fill and push, motion blur, colour, dimming. In a transition the blur across
    /// the cut is left out — the transition is what crosses it.
    static func shot(_ instruction: ShotInstruction, source: CVPixelBuffer?, previous: CVPixelBuffer?, next: CVPixelBuffer? = nil,
                     time t: Double, inTransition: Bool = false) -> CIImage {
        let context = instruction.context
        let shot = instruction.shot
        let size = context.size
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))

        /// The source frame at timeline time `at` with its covered zones painted over and lipstick — the shot's own,
        /// else a filter's over that moment.
        func lipped(_ frame: CIImage, _ at: Double) -> CIImage {
            let covered = Covers.apply(frame, shot.covers)
            let colour = context.colour(shot.id, at: at)
            guard colour.grade?.on ?? true,
                  let lips = ([colour.grade].compactMap { $0 } + colour.filters.map(\.grade)).first(where: { $0.on && $0.lips > 0.001 })
            else { return covered }
            let ms = Int((shot.source(at: at) * 1000).rounded())
            return Lips.apply(covered, grade: lips, key: "\(shot.src)|\(ms)", shot: shot.id, ms: ms)
        }

        var image: CIImage
        if var source {
            // slowed down: the moment between this source frame and the next drawn from the optical flow, not the frame
            // shown again (export at full quality, the preview quicker)
            if let tween = instruction.tween, let next, let f = tween.fraction(at: t),
               let drawn = Tween.draw(source, next, at: f, fine: context.drawsOverlay) { source = drawn }
            // Take the decoded values as they are, like ffmpeg and browsers do: colour-managing BT.709 into
            // sRGB lifts the midtones and the picture no longer matches the web renders.
            image = lipped(Rotation.apply(oriented(CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()]), instruction.orientation),
                                          degrees: shot.rotation, aspect: size.width / size.height), t)
        } else if instruction.track == kCMPersistentTrackID_Invalid, let still = context.still(shot) {
            image = lipped(Rotation.apply(still, degrees: shot.rotation, aspect: size.width / size.height), t)
        } else {
            image = black
        }

        // Push: frame k of n is at zoom z0 + (z1 - z0) * k / (n - 1), the same curve ffmpeg's zoompan drew.
        let frames = max(1, (shot.duration * context.project.canvas.fps).rounded())
        let k = ((t - shot.start) * context.project.canvas.fps).rounded()
        let progress = frames > 1 ? min(1, max(0, k / (frames - 1))) : 0
        let (z0, z1) = shot.zoom.scales
        /// The push at `p` times the hand reframing at `at` (its keys, when it has them).
        func framing(_ p: Double, at: Double) -> (zoom: Double, pan: CGPoint) {
            let f = shot.framing(at: at)
            return ((z0 + (z1 - z0) * p) * f.scale, framed(shot, f.panX, f.panY))
        }
        let now = framing(progress, at: t)
        if let cutout = context.cutout(shot.id), cutout.active {
            return cut(image, instruction, cutout, zoom: now.zoom, pan: CGPoint(x: shot.flip ? -now.pan.x : now.pan.x, y: now.pan.y), time: t)
        }
        image = mirrored(fill(image, size: size, zoom: now.zoom, pan: now.pan), shot, size)

        let colour = context.colour(shot.id, at: t)
        // motion blur: how every pixel moved since the source frame before, blurred along that motion
        if let previous, let look = colour.look, look.on, look.motionBlur > 0.001, colour.grade?.on ?? true {
            let kb = ((t - instruction.step - shot.start) * context.project.canvas.fps).rounded()
            let before = framing(frames > 1 ? min(1, max(0, kb / (frames - 1))) : 0, at: t - instruction.step)
            let earlier = mirrored(fill(lipped(Rotation.apply(oriented(CIImage(cvPixelBuffer: previous, options: [.colorSpace: NSNull()]), instruction.orientation),
                                                              degrees: shot.rotation, aspect: size.width / size.height), t - instruction.step),
                                        size: size, zoom: before.zoom, pan: before.pan), shot, size)
            let ka = ((t + instruction.step - shot.start) * context.project.canvas.fps).rounded()
            let after = framing(frames > 1 ? min(1, max(0, ka / (frames - 1))) : 0, at: t + instruction.step)
            let later = next.map { mirrored(fill(lipped(Rotation.apply(oriented(CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]), instruction.orientation),
                                                                       degrees: shot.rotation, aspect: size.width / size.height), t + instruction.step),
                                                 size: size, zoom: after.zoom, pan: after.pan), shot, size) }
            image = MotionBlur.apply(image, previous: earlier, next: later, size: size, shutter: look.motionBlur)
        }
        // across the cut: the smear of a shot that ended moving fast fades out over the next one's first frames,
        // and a shot that starts with a whip builds its smear up over the last frames before it
        if !inTransition, let look = colour.look, look.on, look.motionBlur > 0.001, look.cutBlur, colour.grade?.on ?? true,
           let i = context.ordered.firstIndex(where: { $0.id == shot.id }) {
            let fps = context.project.canvas.fps
            let since = (t - shot.start) * fps, until = (shot.end - t) * fps
            var edge: RenderContext.EdgeMotion?, w = 0.0
            // (the motion is measured one source frame apart; at another speed a frame shows `speed` times that)
            if i > 0, since < 6, !context.transitionAfter.contains(context.ordered[i - 1].id) {
                edge = context.edgeMotion(context.ordered[i - 1], exit: true); w = pow(1 - since / 6, 1.5) * context.ordered[i - 1].speed
            } else if i + 1 < context.ordered.count, until < 3, !context.transitionAfter.contains(shot.id) {
                edge = context.edgeMotion(context.ordered[i + 1], exit: false); w = pow(1 - until / 3, 1.5) * context.ordered[i + 1].speed
            }
            if let edge, w > 0.02 {
                image = MotionBlur.apply(image, flow: edge.flow, scale: edge.scale * look.motionBlur * w, size: size)
            }
        }
        image = Colour.apply(image, grade: colour.grade, filters: colour.filters, look: colour.look, size: size,
                             frame: Int((t * context.project.canvas.fps).rounded()), cube: context.cube)

        if shot.dim {
            image = gaussian(image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.10, kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.0]), radius: 2.5, size: size)
        }
        return image.composited(over: black)
    }

    /// A shot cut out or made smaller (a video of the overlay track, `Shot.cutout`): keyed on its own pixels, before any
    /// scaling; framed and placed in one scale (the picture and its matte alike); then its colour and dimming, and the
    /// matte put on — transparent around it and where the screen was. No motion blur (the overlay track has none).
    private static func cut(_ source: CIImage, _ instruction: ShotInstruction, _ cutout: RenderContext.Cutout, zoom: Double, pan: CGPoint,
                            time t: Double) -> CIImage {
        let context = instruction.context, shot = instruction.shot, size = context.size
        var picture = source, matte: CIImage?
        if let key = cutout.key, key.on,
           let keyed = Keyer.key(source, key, screen: key.rgb == nil ? context.screen(shot.src) : nil) {
            picture = keyed.picture; matte = keyed.matte
        }
        func framed(_ image: CIImage) -> CIImage {
            Keyer.frame(image, canvas: size, zoom: zoom, pan: pan, mirror: shot.flip, place: cutout.transform)
        }
        if context.showsMatte(shot.id) {                // the matte alone, white on black, over the whole frame
            let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            return framed(matte.map(Keyer.shown) ?? CIImage(color: .white).cropped(to: source.extent)).composited(over: black)
        }
        picture = framed(picture)
        let box = picture.extent
        let colour = context.colour(shot.id, at: t)
        picture = Colour.apply(picture, grade: colour.grade, filters: colour.filters, look: colour.look, size: size,
                               frame: Int((t * context.project.canvas.fps).rounded()), cube: context.cube)
        if shot.dim {
            picture = gaussian(picture.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.10, kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.0]), radius: 2.5, size: size)
        }
        picture = picture.cropped(to: box)
        return matte.map { Keyer.masked(picture, framed($0)) } ?? picture
    }

    /// What goes over the whole frame whatever the shot: the blur behind titles and the motion-graphics scenes.
    static func finish(_ picture: CIImage, context: RenderContext, time t: Double) -> CIImage {
        let size = context.size
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var image = picture
        let weight = context.blurWeight(t)
        if weight > 0.001 {
            let blurred = gaussian(image, radius: 15, size: size).applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.06, kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.0])
            image = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: blurred, kCIInputTimeKey: weight])
        }

        for sequence in context.sequences {
            guard let k = sequence.index(at: t),
                  let layer = CIImage(contentsOf: sequence.frames[k]) else { continue }
            let s = size.width / 1080                                       // stage px to canvas px; CI's y points up
            let moved = CGAffineTransform(translationX: sequence.offset.x * s, y: -sequence.offset.y * s)
            // glass: what is drawn so far, seen through it where its mask is
            if let glass = sequence.glass, let mask = CIImage(contentsOf: glass.masks[min(k, glass.masks.count - 1)]) {
                image = Glass.apply(under: image, mask: mask.transformed(by: moved), blur: glass.blur * s, refraction: glass.refraction,
                                    scale: s, size: size)
            }
            image = layer.transformed(by: moved).composited(over: image)
        }
        return image.composited(over: black)
    }

    /// A shot marked `flip` is shown mirrored left to right (about the canvas centre).
    static func mirrored(_ image: CIImage, _ shot: Shot, _ size: CGSize) -> CIImage {
        guard shot.flip else { return image }
        return image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
    }

    /// Phone footage stores its rotation as a transform; apply it as an orientation.
    static func oriented(_ image: CIImage, _ transform: CGAffineTransform) -> CIImage {
        guard transform != .identity else { return image }
        let quarter = (atan2(transform.b, transform.a) / (.pi / 2)).rounded()
        let orientation: CGImagePropertyOrientation
        switch Int(quarter) {
        case 1: orientation = .right
        case -1, 3: orientation = .left
        case 2, -2: orientation = .down
        default: orientation = .up
        }
        return image.oriented(orientation)
    }

    /// Where a reframed shot's frame sits in its enlarged picture; a mirrored shot pans the other way before it is
    /// turned round, so the frame lands where the editor put it.
    static func framed(_ shot: Shot, _ panX: Double, _ panY: Double) -> CGPoint { CGPoint(x: shot.flip ? -panX : panX, y: panY) }

    /// Scale to cover the canvas, times `zoom`; `pan` moves the frame within the picture, −1…1 from its left / top
    /// edge to its right / bottom one (0 = a centre crop).
    static func fill(_ image: CIImage, size: CGSize, zoom: Double, pan: CGPoint = .zero) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite else { return image }
        let scale = max(size.width / e.width, size.height / e.height) * zoom
        var out = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        let w = e.width * scale, h = e.height * scale
        let px = min(1, max(-1, pan.x)), py = min(1, max(-1, pan.y))           // CI's y points up
        out = out.transformed(by: CGAffineTransform(translationX: (size.width - w) * (1 + px) / 2, y: (size.height - h) * (1 - py) / 2))
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Radii are fitted to ffmpeg's `gblur` the renders used (one-step recursive filter, sharper core than a
    /// true Gaussian): sigma 18 ≈ radius 15, sigma 3 ≈ radius 2.5, RMS error under 1.6/255 on real frames.
    static func gaussian(_ image: CIImage, radius: Double, size: CGSize) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Lets Core Graphics paint captions and titles straight onto the finished frame, top-left origin.
    static func drawOverlay(into buffer: CVPixelBuffer, size: CGSize, colorSpace: CGColorSpace, _ draw: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let cg = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                 bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        cg.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(buffer)))
        cg.scaleBy(x: CGFloat(CVPixelBufferGetWidth(buffer)) / size.width, y: -CGFloat(CVPixelBufferGetHeight(buffer)) / size.height)
        draw(cg)
    }
}
