import CoreGraphics
import Foundation
import ImageIO

/// The motion-graphics scenes of the earlier ads — `RENDER_KIT/motion/frames/<scene>/0000.png …`, 30 fps with alpha —
/// laid over the edit as `overlays`.
public enum MotionLibrary {
    public struct Scene: Identifiable, Sendable {
        public let folder: URL
        public let frames: Int
        public var id: String { folder.path }
        public var name: String { folder.lastPathComponent }
        public var duration: Double { Double(frames) / 30 }
        /// A frame from the scene's middle, to show what it is.
        public var still: URL { folder.appending(path: String(format: "%04d.png", frames * 3 / 5)) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var holds: [String: Int] = [:]

    /// How many frames a scene folder holds (read once).
    public static func frames(in folder: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let n = counts[folder.path] { return n }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let n = names.filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("._") }.count
        counts[folder.path] = n
        return n
    }

    /// The last full frame before the scene fades out — where a lengthened scene waits (the last frame if it never fades).
    public static func holdFrame(in folder: URL) -> Int {
        if let h = lock.withLock({ holds[folder.path] }) { return h }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("._") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tail = Array(max(0, names.count - 30)..<names.count)
        let cover = tail.map { opacity(folder.appending(path: names[$0])) }
        let peak = cover.max() ?? 0
        let h = tail.isEmpty ? 0 : tail[cover.lastIndex { $0 >= 0.97 * peak } ?? tail.count - 1]
        lock.withLock { holds[folder.path] = h }
        return h
    }

    /// How much of a frame is painted (summed alpha of a small thumbnail).
    private static func opacity(_ url: URL) -> Double {
        let n = 48
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: n,
                                                                          kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        return (0..<(n * n)).reduce(0.0) { $0 + Double(bytes[$1 * 4 + 3]) }
    }

    /// Which frame of a scene is on screen `t` seconds after its start (nil when it is not). The scene comes in as made,
    /// waits on its hold frame as long as its length asks, and always ends with its own fade-out — sooner when shortened.
    public static func frameIndex(at t: Double, length: Double, fps: Double, frames n: Int, hold h: Int) -> Int? {
        guard n > 0, t >= -1e-6, t < length - 1e-6 else { return nil }
        let outroStart = length - Double(n - 1 - h) / fps
        if t < outroStart - 1e-6 { return min(Int((max(t, 0) * fps + 1e-6).rounded(.down)), h) }
        return min(h + 1 + Int(((t - outroStart) * fps + 1e-6).rounded(.down)), n - 1)
    }

    /// How long the scene itself runs.
    public static func sceneDuration(_ clip: OverlayClip, projectURL: URL?) -> Double {
        Double(frames(in: Project.resolve(clip.src, relativeTo: projectURL))) / max(clip.fps, 1)
    }

    /// How long an overlay stays on screen: the length set by hand, or the scene's own.
    public static func duration(_ clip: OverlayClip, projectURL: URL?) -> Double {
        clip.duration ?? sceneDuration(clip, projectURL: projectURL)
    }

    /// The kit's `frames` folder: where the project's overlays come from, or `*/RENDER_KIT/motion/frames` in a folder
    /// above the project.
    public static func find(near projectURL: URL?, project: Project?) -> URL? {
        let fm = FileManager.default
        for clip in project?.overlays ?? [] {
            let parent = Project.resolve(clip.src, relativeTo: projectURL).deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) { return parent }
        }
        var folder = projectURL?.deletingLastPathComponent()
        while let dir = folder, dir.path != "/" {
            let here = dir.appending(path: "RENDER_KIT/motion/frames")
            if fm.fileExists(atPath: here.path) { return here }
            for sub in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !sub.hasPrefix(".") {
                let kit = dir.appending(path: sub).appending(path: "RENDER_KIT/motion/frames")
                if fm.fileExists(atPath: kit.path) { return kit }
            }
            folder = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every scene in a `frames` folder, in name order — not the glass shapes (`<scene>_mask`), which are no scenes.
    public static func scenes(in folder: URL) -> [Scene] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix("_mask") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            let url = folder.appending(path: name)
            let n = frames(in: url)
            return n > 0 ? Scene(folder: url, frames: n) : nil
        }
    }
}
