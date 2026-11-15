import AVFoundation
import Foundation

/// Cuts inside a source clip — an edited UGC video, a jump cut in a talking head. A shot taken from a stretch
/// with one in it flashes another picture for a moment, which reads as a glitch in the ad. Found by comparing
/// each frame with the one before: its brightness on a coarse grid (what moves) and its brightness histogram
/// (what the picture is made of) — a cut changes both at once, a moving camera mostly the first.
public enum SourceCuts {
    /// One frame boiled down: mean brightness on a 24 × 24 grid and a 32-bin histogram.
    struct Signature {
        var grid: [Float]
        var histogram: [Float]

        init?(_ image: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let planar = CVPixelBufferIsPlanar(image)
            guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image) else { return nil }
            let width = planar ? CVPixelBufferGetWidthOfPlane(image, 0) : CVPixelBufferGetWidth(image)
            let height = planar ? CVPixelBufferGetHeightOfPlane(image, 0) : CVPixelBufferGetHeight(image)
            let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let cells = 24, taps = 3
            grid = [Float](repeating: 0, count: cells * cells)
            histogram = [Float](repeating: 0, count: 32)
            for cy in 0..<cells {
                for cx in 0..<cells {
                    var sum: Float = 0
                    for ty in 0..<taps {
                        for tx in 0..<taps {
                            let x = ((cx * taps + tx) * 2 + 1) * width / (cells * taps * 2)
                            let y = ((cy * taps + ty) * 2 + 1) * height / (cells * taps * 2)
                            let v = luma[y * row + x]
                            sum += Float(v)
                            histogram[Int(v) >> 3] += 1
                        }
                    }
                    grid[cy * cells + cx] = sum / Float(taps * taps)
                }
            }
            let total = Float(cells * cells * taps * taps)
            for i in histogram.indices { histogram[i] /= total }
        }

        /// How unlike the frame before: mean grid change (0…1) and histogram distance (0…2).
        func change(from other: Signature) -> (grid: Float, histogram: Float) {
            var g: Float = 0, h: Float = 0
            for i in grid.indices { g += abs(grid[i] - other.grid[i]) }
            for i in histogram.indices { h += abs(histogram[i] - other.histogram[i]) }
            return (g / Float(grid.count) / 255, h)
        }
    }

    /// The frames that cut to another picture: a single-frame jump — much of the picture changes, more than twice
    /// as much as just before and just after (a moving camera or light changes several frames in a row), and its
    /// brightness histogram moves too.
    public static func cuts(_ frames: [(Double, Float, Float)]) -> [Double] {
        frames.indices.filter { i in
            let (_, grid, histogram) = frames[i]
            let around = max(i > 0 ? frames[i - 1].1 : 0, i + 1 < frames.count ? frames[i + 1].1 : 0, 0.02)
            return grid >= 0.12 && grid >= 2.5 * around && histogram >= 0.2
        }.map { frames[$0].0 }
    }

    /// Every frame's change from the one before in `range` of the clip: (time, grid, histogram).
    public static func changes(in url: URL, range: ClosedRange<Double>) async -> (frames: [(Double, Float, Float)], length: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let length = (try? await asset.load(.duration))?.seconds ?? 0
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, range.lowerBound), preferredTimescale: 600),
                                       end: CMTime(seconds: min(range.upperBound, length), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var previous: Signature?
        var frames: [(Double, Float, Float)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(buffer), let signature = Signature(image) else { continue }
            if let previous {
                let c = signature.change(from: previous)
                frames.append((CMSampleBufferGetPresentationTimeStamp(buffer).seconds, c.grid, c.histogram))
            }
            previous = signature
        }
        return (frames, length)
    }

    /// The times (in the clip) where `range` of it cuts to another picture, and the clip's length.
    public static func find(in url: URL, range: ClosedRange<Double>) async -> (cuts: [Double], length: Double)? {
        guard let scan = await changes(in: url, range: range) else { return nil }
        return (cuts(scan.frames), scan.length)
    }

    // MARK: The shots of an edit

    /// What a look at one stretch found: its cuts (clip time) and the clip's length.
    public struct Found: Codable, Sendable {
        public var cuts: [Double]
        public var length: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scanned: [String: Found] = [:]
    nonisolated(unsafe) private static var loaded = false

    /// Kept between launches (and shared with `simbia`): a stretch is looked at again only when its file changes.
    private static var store: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Simbia Captions/source-cuts.json")
    }

    private static func loadStore() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: store), let saved = try? JSONDecoder().decode([String: Found].self, from: data) { scanned = saved }
    }

    /// The shot's stretch of its clip, as the file is on disk now.
    private static func key(_ shot: Shot, projectURL: URL?) -> String? {
        let url = Project.resolve(shot.src, relativeTo: projectURL)
        guard !Project.stillTypes.contains(url.pathExtension.lowercased()),
              let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return String(format: "%@|%.0f|%.3f|%.3f", url.path, stamp.timeIntervalSince1970, shot.inPoint, shot.footage)
    }

    /// The cuts in the shot's stretch of its clip, and the clip's length — nil until `scan` has looked.
    public static func known(for shot: Shot, projectURL: URL?) -> Found? {
        guard let key = key(shot, projectURL: projectURL) else { return nil }
        return lock.withLock { loadStore(); return scanned[key] }
    }

    /// The whole clip's cuts — looked at once a shot's stretch of it turned out to have one, to find a clean
    /// stretch to move to.
    public static func wholeClip(of shot: Shot, projectURL: URL?) -> Found? {
        guard let key = wholeKey(shot, projectURL: projectURL) else { return nil }
        return lock.withLock { loadStore(); return scanned[key] }
    }

    private static func wholeKey(_ shot: Shot, projectURL: URL?) -> String? {
        key(Shot(id: "", start: 0, end: 0, src: shot.src), projectURL: projectURL).map { $0 + "|whole" }
    }

    /// Looks at every shot's stretch not looked at yet, four at a time — not the speaker's own picture, whose
    /// cuts are hers — then at the whole clip of every stretch with a cut inside. True when anything was added.
    @discardableResult public static func scan(_ project: Project, projectURL: URL?) async -> Bool {
        let shots = project.shots.filter { !project.speaker($0) }
        let stretches = await look(shots.compactMap { shot in
            key(shot, projectURL: projectURL).map { ($0, Project.resolve(shot.src, relativeTo: projectURL), shot.inPoint...(shot.inPoint + shot.footage)) }
        })
        let frame = 1 / max(project.canvas.fps, 1)
        let clips = await look(shots.compactMap { shot in
            guard let found = known(for: shot, projectURL: projectURL),
                  found.cuts.contains(where: { $0 > shot.inPoint + 2 * frame && $0 < shot.inPoint + shot.footage - 2 * frame }),
                  let key = wholeKey(shot, projectURL: projectURL) else { return nil }
            return (key, Project.resolve(shot.src, relativeTo: projectURL), 0...found.length)
        })
        return stretches || clips
    }

    /// Looks at each stretch not looked at yet, four at a time, and keeps what it finds. True when anything was added.
    private static func look(_ jobs: [(String, URL, ClosedRange<Double>)]) async -> Bool {
        var seen = Set<String>()
        let todo = jobs.filter { job in seen.insert(job.0).inserted && lock.withLock { loadStore(); return scanned[job.0] == nil } }
            .map { (key: $0.0, url: $0.1, range: $0.2) }
        guard !todo.isEmpty else { return false }
        await withTaskGroup(of: (String, Found?).self) { group in
            var next = 0
            func add() {
                guard next < todo.count else { return }
                let job = todo[next]
                next += 1
                group.addTask { (job.key, await find(in: job.url, range: job.range).map { Found(cuts: $0.cuts, length: $0.length) }) }
            }
            for _ in 0..<4 { add() }
            while let (key, found) = await group.next() {
                if let found { lock.withLock { scanned[key] = found } }
                add()
            }
        }
        let snapshot = lock.withLock { scanned.count > 20_000 ? [:] : scanned }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: store, options: .atomic)
        return true
    }
}
