import AVFoundation

/// The tempo and the bars of a piece of music, found in its sound: where the beats fall (the onsets repeat at one
/// period), and which beat of four starts a bar (the music changes on the first beat of a bar — sections, phrases).
public enum Tempo {
    public struct Found: Equatable, Sendable {
        public let bpm: Double
        /// The first downbeat, seconds into the file.
        public let downbeat: Double
    }

    /// Frames of the onset curve per second.
    static let fps = 100.0
    private static let rate = 12_000.0

    public static func detect(_ url: URL) async throws -> Found? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let found = analyse(try await decode(url))
        lock.withLock { cache[key] = found }
        return found
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Found?] = [:]

    static func analyse(_ x: [Float]) -> Found? {
        let hop = Int(rate / fps)
        let n = x.count / hop
        guard n > Int(fps * 8) else { return nil }
        // loudness of the whole sound and of its top end (hats, attacks), dB per 10 ms
        var low = [Double](repeating: 0, count: n), high = [Double](repeating: 0, count: n)
        for f in 0..<n {
            var a: Float = 0, b: Float = 0
            for i in f * hop..<(f + 1) * hop {
                a += x[i] * x[i]
                let d = i > 0 ? x[i] - x[i - 1] : 0
                b += d * d
            }
            low[f] = 10 * log10(Double(a) / Double(hop) + 1e-10)
            high[f] = 10 * log10(Double(b) / Double(hop) + 1e-10)
        }
        // onset strength: how much louder each frame got, less its neighbourhood's average
        var onset = [Double](repeating: 0, count: n)
        for f in 1..<n { onset[f] = max(0, low[f] - low[f - 1]) + max(0, high[f] - high[f - 1]) }
        let span = Int(fps / 2)
        var prefix = [0.0]
        for v in onset { prefix.append(prefix.last! + v) }
        onset = (0..<n).map { f in
            let a = max(0, f - span), b = min(n, f + span)
            return max(0, onset[f] - (prefix[b] - prefix[a]) / Double(b - a))
        }

        // the period: autocorrelation of the onsets softened over a few frames (a beat seldom falls on a whole
        // frame: sharp onsets a fraction of a frame apart miss each other, and 1.5 beats then beats 1), leaning
        // towards 120 bpm between a tempo and its double or half, then read between whole frames
        let kernel = [1.0, 2, 3, 2, 1].map { $0 / 9 }
        let soft = (0..<n).map { f in (-2...2).reduce(0.0) { s, d in f + d >= 0 && f + d < n ? s + onset[f + d] * kernel[d + 2] : s } }
        let lags = Int(fps * 60 / 200)...Int(fps * 60 / 60)
        var r = [Double](repeating: 0, count: lags.upperBound + 2)
        for lag in lags.lowerBound - 1...lags.upperBound + 1 {
            var acc = 0.0
            for f in 0..<(n - lag) { acc += soft[f] * soft[f + lag] }
            r[lag] = acc / Double(n - lag)
        }
        var best = (lag: 0, score: -Double.infinity)
        for lag in lags {
            let lean = exp(-0.5 * pow(log2(60 * fps / Double(lag) / 120) / 0.9, 2))
            if r[lag] * lean > best.score { best = (lag, r[lag] * lean) }
        }
        guard best.lag > 0 else { return nil }
        let (a0, b0, c0) = (r[best.lag - 1], r[best.lag], r[best.lag + 1])
        let curve = a0 - 2 * b0 + c0
        var period = Double(best.lag) + (curve < 0 ? 0.5 * (a0 - c0) / curve : 0)

        // tempo to a hundredth of a bpm and the beat's place: the comb of beats that catches the most onsets over
        // the whole track. Generated music is seldom at the whole tempo its name says (a "129 bpm" track runs at
        // 129.22, and a 129 grid is a third of a second off by the end), so the tempo is measured, not rounded.
        func comb(_ phase: Double, _ period: Double) -> Double {
            var s = 0.0, t = phase
            while t < Double(n - 1) { s += interpolate(soft, t); t += period }
            return s
        }
        let rough = 60 * fps / period
        var found = (score: -Double.infinity, bpm: rough, phase: 0.0)
        var bpm = (rough * 0.985 * 100).rounded() / 100
        while bpm <= rough * 1.015 {
            let p = 60 * fps / bpm
            var ph = 0.0
            while ph < p {
                let s = comb(ph, p)
                if s > found.score { found = (s, bpm, ph) }
                ph += 1
            }
            bpm += 0.01
        }
        bpm = (found.bpm * 100).rounded() / 100
        period = 60 * fps / bpm
        var phase = stride(from: found.phase - 1, through: found.phase + 1, by: 0.125).max { comb($0, period) < comb($1, period) } ?? found.phase
        phase = phase.truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }

        // the downbeat: the music changes most on the first beat of a bar
        var level: [Double] = []
        var t = phase
        while t + period < Double(n) {
            let a = Int(t), b = Int(t + period)
            level.append(low[a..<b].reduce(0, +) / Double(b - a))
            t += period
        }
        var change = [Double](repeating: 0, count: 4)
        for k in 1..<max(1, level.count) { change[k % 4] += abs(level[k] - level[k - 1]) }
        let first = change.indices.max { change[$0] < change[$1] } ?? 0
        let downbeat = (phase + Double(first) * period) / fps
        return Found(bpm: bpm, downbeat: downbeat.truncatingRemainder(dividingBy: 4 * 60 / bpm))
    }

    private static func interpolate(_ v: [Double], _ t: Double) -> Double {
        guard t >= 0 else { return 0 }
        let i = Int(t), f = t - Double(i)
        guard i + 1 < v.count else { return v[min(max(i, 0), v.count - 1)] }
        return v[i] * (1 - f) + v[i + 1] * f
    }

    /// The file as mono floats at 12 kHz — plenty for where the beats are.
    private static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Simbia", code: 31) }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: bytes / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
}

/// A stretch of the edit and the bars of the music playing there.
public struct GridSpan: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var grid: BeatGrid

    public init(from: Double, to: Double, grid: BeatGrid) { self.from = from; self.to = to; self.grid = grid }
}

extension Project {
    /// The music the bars come from: the earliest music clip.
    public var beatSource: AudioClip? {
        audio.filter { $0.role == .music }.min { $0.start < $1.start }
    }

    /// The beat grid of the project's music, on the edit's clock: its tempo, and its first downbeat at or after 0.
    public func detectGrid(projectURL: URL?) async throws -> BeatGrid? {
        guard let clip = beatSource,
              let found = try await Tempo.detect(Project.resolve(clip.src, relativeTo: projectURL)) else { return nil }
        return Self.grid(found, for: clip)
    }

    /// The music's grid where `clip` puts that music on the edit: the bars move with the clip.
    public static func grid(_ found: Tempo.Found, for clip: AudioClip) -> BeatGrid {
        let bar = 4 * 60 / found.bpm
        var offset = (clip.start - clip.inPoint + found.downbeat).truncatingRemainder(dividingBy: bar)
        if offset < 0 { offset += bar }
        return BeatGrid(bpm: found.bpm, offset: offset, source: beatSignature(clip))
    }

    /// The bars of the music on the edit, piece by piece: each music clip lays its own from its start until the next
    /// one starts (the first also before it, the last on to the end) — move or trim a piece and its bars go with it.
    public func gridSpans(_ found: (AudioClip) -> Tempo.Found?) -> [GridSpan] {
        var spans: [GridSpan] = []
        for clip in audio.filter({ $0.role == .music }).sorted(by: { $0.start < $1.start }) {
            guard let f = found(clip) else { continue }
            spans.append(GridSpan(from: spans.isEmpty ? -.infinity : clip.start, to: .infinity, grid: Self.grid(f, for: clip)))
        }
        for i in spans.indices.dropLast() { spans[i].to = spans[i + 1].from }
        return spans
    }

    /// What the grid was found from: the music file and where it sits — when that changes, the bars are found again.
    public static func beatSignature(_ clip: AudioClip) -> String { "\(clip.src)|\(clip.start)|\(clip.inPoint)" }
}
