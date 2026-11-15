import CoreGraphics
import Foundation
import ImageIO

/// Captions and titles of a project, drawn natively for any moment — the same picture the web
/// reference draws. The app uses one for the live preview, the compositor one for export.
public final class OverlayRenderer {
    public let project: Project
    public let style: CaptionStyle?
    private let chunks: [Chunk]
    private var layouts: [String: CaptionPainter.Layout] = [:]
    private let lock = NSLock()
    private let projectURL: URL?

    public init(project: Project, style: String? = nil, projectURL: URL? = nil) {
        self.project = project
        self.style = CaptionStyle(id: style ?? project.captions.style)
        self.projectURL = projectURL
        chunks = project.captions.chunks.sorted { $0.start < $1.start }
    }

    /// The canvas the overlay is designed for: 1080 px wide, height in proportion.
    public static let stage = CGSize(width: 1080, height: 1920)

    /// Draws at `time` into `ctx`, whose user space must be the 1080-wide stage with y pointing down.
    public func draw(in ctx: CGContext, time: Double) {
        TitlePainter.draw(project.titles, in: ctx, time: time, pack: pack)
        guard let style, let chunk = chunk(at: time) else { return }
        let layout = layout(chunk, style)
        let shift = shift(chunk, layout, time: time)
        ctx.saveGState()
        ctx.translateBy(x: shift.x, y: shift.y)
        CaptionPainter.draw(layout, in: ctx, time: time)
        ctx.restoreGState()
    }

    // MARK: Moving things on the picture

    /// How far a caption is moved by hand from its style's place (Bogdan places them himself — no automatic lift).
    func shift(_ chunk: Chunk, _ layout: CaptionPainter.Layout, time: Double) -> CGPoint {
        CGPoint(x: chunk.x ?? 0, y: chunk.y ?? 0)
    }

    /// What can be moved on the picture.
    public enum Piece: Equatable, Sendable {
        case caption(String), title(String), overlay(String)
        /// A video on the overlay track that is cut out or made smaller (`Shot.cutout`): its `transform` moves.
        case layer(String)
        /// An emoji on a title: the title's id and the sticker's place in its list.
        case sticker(String, Int)
    }

    /// The emoji pack the titles' emoji play from.
    public var pack: String { project.emojiPack ?? AnimatedEmoji.defaultPack }

    /// The topmost thing drawn at `point` (stage px) at `time`: the caption, then the titles and graphics (the last
    /// drawn first), then the kit's scenes, then the cut-out videos of the overlay track (by their box).
    public func piece(at point: CGPoint, time: Double) -> Piece? {
        if let style, let chunk = chunk(at: time) {
            let layout = layout(chunk, style)
            let shift = shift(chunk, layout, time: time)
            if layout.words.contains(where: { $0.box.insetBy(dx: -0.2 * $0.size, dy: -0.2 * $0.size).offsetBy(dx: shift.x, dy: shift.y).contains(point) }) {
                return .caption(chunk.id)
            }
        }
        for title in project.titles.reversed() where time >= title.start && time <= title.end {
            // the emoji first: they sit on top, and a turned one is hit inside its own square
            for (k, s) in (title.stickers ?? []).enumerated().reversed() {
                let c = CGPoint(x: 540 + s.x + (title.x ?? 0), y: 960 + s.y + (title.y ?? 0))
                let a = -s.rotation * .pi / 180, dx = point.x - c.x, dy = point.y - c.y
                let local = CGPoint(x: dx * cos(a) - dy * sin(a), y: dx * sin(a) + dy * cos(a))
                if abs(local.x) <= s.size / 2 && abs(local.y) <= s.size / 2 { return .sticker(title.id, k) }
            }
            if Self.touches(point, { TitlePainter.draw([title], in: $0, time: time, pack: pack) }) { return .title(title.id) }
        }
        for clip in project.overlays.reversed() {
            guard let image = frame(clip, time: time) else { continue }
            if Self.touches(point, { Self.drawFrame(image, clip, in: $0) }) { return .overlay(clip.id) }
        }
        for layer in project.layers.reversed() where layer.cutout && time >= layer.start && time < layer.end {
            if (layer.transform ?? LayerTransform()).contains(point, stageHeight: stageHeight) { return .layer(layer.id) }
        }
        return nil
    }

    /// The stage's height: 1080 wide, in the canvas's proportion.
    private var stageHeight: Double { 1080 * Double(project.canvas.height) / Double(max(project.canvas.width, 1)) }

    /// Where a cut-out video of the overlay track is drawn, stage px: the whole frame, moved by its transform (before it
    /// is turned).
    private func layerBox(_ layer: Shot) -> CGRect { (layer.transform ?? LayerTransform()).box(stageHeight: stageHeight) }

    /// Where a piece is drawn now (stage px), as the outline to show while it is dragged.
    public func bounds(of piece: Piece, time: Double) -> CGRect? {
        switch piece {
        case .caption(let id):
            guard let style, let chunk = chunks.first(where: { $0.id == id }) else { return nil }
            let layout = layout(chunk, style), shift = shift(chunk, layout, time: time)
            return layout.words.reduce(CGRect.null) { $0.union($1.box) }.offsetBy(dx: shift.x, dy: shift.y)
        case .title(let id):
            guard let title = project.titles.first(where: { $0.id == id }) else { return nil }
            return Self.opaque { TitlePainter.draw([title], in: $0, time: time, pack: pack) }
        case .sticker(let id, let k):
            guard let title = project.titles.first(where: { $0.id == id }), let s = title.stickers, s.indices.contains(k) else { return nil }
            return TitlePainter.stickerBox(s[k]).offsetBy(dx: title.x ?? 0, dy: title.y ?? 0)
        case .overlay(let id):
            guard let clip = project.overlays.first(where: { $0.id == id }), let image = frame(clip, time: time) else { return nil }
            return Self.opaque { Self.drawFrame(image, clip, in: $0) }
        case .layer(let id):
            return project.layers.first { $0.id == id }.map(layerBox)
        }
    }

    /// The scene's frame at `time`, if it is on screen.
    private func frame(_ clip: OverlayClip, time: Double) -> CGImage? {
        let folder = Project.resolve(clip.src, relativeTo: projectURL)
        let n = MotionLibrary.frames(in: folder)
        guard let index = MotionLibrary.frameIndex(at: time - clip.start, length: MotionLibrary.duration(clip, projectURL: projectURL),
                                                   fps: clip.fps, frames: n, hold: MotionLibrary.holdFrame(in: folder)) else { return nil }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("._") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard index < names.count, let source = CGImageSourceCreateWithURL(folder.appending(path: names[index]) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func drawFrame(_ image: CGImage, _ clip: OverlayClip, in ctx: CGContext) {
        let rect = CGRect(x: clip.x ?? 0, y: clip.y ?? 0, width: 1080, height: 1080 * Double(image.height) / Double(max(image.width, 1)))
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Whether `draw` (stage px, y down) paints anything within 8 px of `point`.
    private static func touches(_ point: CGPoint, _ draw: (CGContext) -> Void) -> Bool {
        let n = 16
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: Paint.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(n))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -(point.x - Double(n) / 2), y: -(point.y - Double(n) / 2))
        draw(ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return (0..<(n * n)).contains { data[$0 * 4 + 3] > 24 }
    }

    /// The box around everything `draw` paints, found on an eighth-size copy of the stage.
    private static func opaque(_ draw: (CGContext) -> Void) -> CGRect? {
        let k = 0.125, w = Int(1080 * k), h = Int(1920 * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Paint.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: k, y: -k)
        draw(ctx)
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var box = CGRect.null
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 24 { box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) } }
        return box.isNull ? nil : CGRect(x: box.minX / k, y: box.minY / k, width: box.width / k, height: box.height / k)
    }

    /// Draws into a context of any size covering the whole frame (top-left origin set up here).
    /// The 9:16 stage is fitted into the frame: a 9:16 frame gets it exactly, a wider one (4:5, 1:1,
    /// 16:9) gets it centred at full height so captions and titles stay inside the picture; a frame
    /// taller than 9:16 keeps the stage at the top, like the web page does.
    public func draw(in ctx: CGContext, size: CGSize, time: Double, flipped: Bool = true) {
        ctx.saveGState()
        if flipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let scale = min(size.width / Self.stage.width, size.height / Self.stage.height)
        guard scale > 0 else { ctx.restoreGState(); return }
        ctx.translateBy(x: (size.width - Self.stage.width * scale) / 2, y: 0)
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, time: time)
        ctx.restoreGState()
    }

    /// The caption on screen at `time`: a binary search over captions in time order, and — for a file
    /// whose captions overlap — the first one that covers the time, as the web reference picks it.
    func chunk(at time: Double) -> Chunk? {
        var lo = 0, hi = chunks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if time < chunks[mid].start { hi = mid - 1 }
            else if time >= chunks[mid].end { lo = mid + 1 }
            else { return chunks.first { time >= $0.start && time < $0.end } ?? chunks[mid] }
        }
        return chunks.first { time >= $0.start && time < $0.end }
    }

    /// Layouts carry the words' start times, so they are kept per chunk start and timing; the sprite key
    /// only needs what the picture depends on — the style and the words with their accents.
    func layout(_ chunk: Chunk, _ style: CaptionStyle) -> CaptionPainter.Layout {
        let words = chunk.words.map { ($0.accent ? "A" : "a") + $0.text }.joined(separator: "\u{1F}")
        let options = project.captions.options
        let key = "\(options.entrance.rawValue)|\(options.lineSpacing)|\(chunk.start)|" + chunk.words.map { "\($0.start)" }.joined(separator: ",") + "|" + words
        lock.lock(); defer { lock.unlock() }
        if let l = layouts[key] { return l }
        var l = CaptionPainter.layout(chunk, style: style, options: options)
        l.key = style.id + "|" + options.look + "|" + words
        layouts[key] = l
        return l
    }

    /// The caption's word boxes at `time`, for comparing with the web layout.
    public func wordBoxes(at time: Double) -> [(text: String, box: CGRect, size: Double)] {
        guard let style, let chunk = chunk(at: time) else { return [] }
        return layout(chunk, style).words.map { ($0.text, $0.box, $0.size) }
    }
}
