import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Animated emoji packs: Application Support/Simbia Captions/Emoji/<pack>/<code points>.webp|.gif|.png (looping; png = APNG), plus the
/// pack's index.json (code points, emoji, name, category) for the picker. 😴 is 1f634.webp, 😮‍💨 1f62e_200d_1f4a8.webp.
/// An emoji the pack lacks is drawn as the still glyph. SIMBIA_EMOJI_DIR points the packs elsewhere (tests).
public enum AnimatedEmoji {
    public static let defaultPack = "noto"

    struct Clip {
        let frames: [CGImage]
        let starts: [Double]
        let length: Double
    }

    /// One emoji of a pack, as its index.json lists it.
    public struct Entry: Codable, Hashable, Sendable {
        public let cp: String
        public let emoji: String
        public let name: String
        public let category: String
    }

    public static let root: URL = {
        if let dir = ProcessInfo.processInfo.environment["SIMBIA_EMOJI_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Simbia Captions/Emoji")
    }()

    /// The packs there are (folders with an index.json), "noto" first.
    public static var packs: [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/index.json").path) }
        return names.sorted { ($0 == defaultPack ? 0 : 1, $0) < ($1 == defaultPack ? 0 : 1, $1) }
    }

    private static var clips: [String: Clip?] = [:]
    private static var indexes: [String: [Entry]] = [:]
    private static let lock = NSLock()

    public static func index(_ pack: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let known = indexes[pack] { return known }
        let url = root.appendingPathComponent("\(pack)/index.json")
        let list = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
        indexes[pack] = list
        return list
    }

    /// "1f634", "1f62e_200d_1f4a8"; packs differ on keeping the variation selector FE0F, so both are tried.
    static func names(_ emoji: String) -> [String] {
        let all = emoji.unicodeScalars.map { String($0.value, radix: 16) }
        let bare = emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }
        return Array(Set([all.joined(separator: "_"), bare.joined(separator: "_")]))
    }

    static func clip(_ emoji: String, pack: String) -> Clip? {
        let key = pack + "/" + emoji
        lock.lock(); defer { lock.unlock() }
        if let known = clips[key] { return known }
        var found: Clip?
        search: for name in names(emoji) {
            for ext in ["webp", "gif", "png"] {
                let url = root.appendingPathComponent("\(pack)/\(name).\(ext)")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                var frames: [CGImage] = [], starts: [Double] = [], t = 0.0
                // decoded at title size (a 512 px, 60-frame clip would hold ~60 MB), whole frames as ImageIO composes them
                let options = [kCGImageSourceThumbnailMaxPixelSize: 360, kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary
                for i in 0..<CGImageSourceGetCount(source) {
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options) else { continue }
                    let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
                    let info = (props[kCGImagePropertyWebPDictionary] ?? props[kCGImagePropertyGIFDictionary]
                                ?? props[kCGImagePropertyPNGDictionary]) as? [CFString: Any] ?? [:]
                    let delay = [kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
                                 kCGImagePropertyWebPDelayTime, kCGImagePropertyGIFDelayTime, kCGImagePropertyAPNGDelayTime]
                        .lazy.compactMap { info[$0] as? Double }.first ?? 0
                    frames.append(image); starts.append(t)
                    t += delay > 0.005 ? delay : 1.0 / 30
                }
                if !frames.isEmpty { found = Clip(frames: frames, starts: starts, length: t); break search }
            }
        }
        clips[key] = found
        return found
    }

    /// The frame shown `t` seconds in, the clip looping.
    static func frame(_ clip: Clip, at t: Double) -> CGImage {
        let local = max(0, t).truncatingRemainder(dividingBy: clip.length)
        var lo = 0, hi = clip.starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if clip.starts[mid] <= local { lo = mid } else { hi = mid - 1 }
        }
        return clip.frames[lo]
    }

    /// The emoji `t` seconds into its life, filling a `side`-px square centred on the origin of the y-down `ctx`:
    /// the pack's animation, or the still glyph.
    static func draw(_ emoji: String, pack: String, at t: Double, side: Double, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let clip = clip(emoji, pack: pack) {
            ctx.interpolationQuality = .high
            ctx.translateBy(x: -side / 2, y: side / 2)
            ctx.scaleBy(x: 1, y: -1)                                // images are drawn y-up
            ctx.draw(frame(clip, at: t), in: CGRect(x: 0, y: 0, width: side, height: side))
            return
        }
        // Apple Color Emoji's square: the glyph box is ~1.17 × the point size wide, centred on its ascent/descent
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, side / 1.17, nil)
        let run = TextRun(emoji, font: font)
        run.drawColorGlyphs(ctx, at: CGPoint(x: -run.width / 2, y: (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2))
    }
}
