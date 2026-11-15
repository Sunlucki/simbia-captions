import AVFoundation
import CryptoKit

/// Every voice clip through one chain before the mix («Обработка голоса» in the sound window), modelled on the
/// FabFilter voice-over setup: each clip brought to one loudness (EBU R128), then Pro-C 2's «Pro Voice Over»
/// (transparent feed-forward compression, soft knee, 2 ms lookahead, a low cut in the detector, release that is
/// quick after a short peak and slow after long compression, 70 % wet), the level set back to the target, and a
/// Pro-L 2-style true-peak limiter (lookahead, instant attack, smooth release). nil on the master = off.
public struct VoiceChain: Codable, Equatable, Sendable {
    public var on = true
    /// Integrated loudness every voice clip is brought to, LUFS.
    public var target = -16.0
    /// 0 = gentle (2:1 from 4 dB under the target), 1 = firm (6:1 from 10 dB under).
    public var squeeze = 0.5
    /// The limiter's ceiling, dBTP.
    public var ceiling = -1.5

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.value(.on, true)
        target = try c.value(.target, -16.0)
        squeeze = try c.value(.squeeze, 0.5)
        ceiling = try c.value(.ceiling, -1.5)
    }

    var ratio: Double { 2 + 4 * min(1, max(0, squeeze)) }
    var threshold: Double { target - (4 + 6 * min(1, max(0, squeeze))) }
}

/// Renders processed voice clips into a cache the mix plays instead of the sources (one file per clip, made again
/// only when the clip's piece of sound or the chain changes).
public enum VoiceRender {
    static let rate = 48_000.0

    /// The clips with every voice clip pointing at its processed sound (from its first sample).
    public static func processed(_ clips: [AudioClip], chain: VoiceChain, projectURL: URL?) async -> [AudioClip] {
        guard chain.on else { return clips }
        var out = clips
        await withTaskGroup(of: (Int, URL?).self) { group in
            var running = 0
            for (i, clip) in clips.enumerated() where clip.role == .voice {
                if running == 6 { if let (k, url) = await group.next(), let url { out[k] = moved(out[k], url) }; running -= 1 }
                group.addTask { (i, await file(for: clip, chain: chain, projectURL: projectURL)) }
                running += 1
            }
            for await (k, url) in group { if let url { out[k] = moved(out[k], url) } }
        }
        return out
    }

    /// Loudness of every voice clip before and after the chain (LUFS) and its true-ish peak after (dBFS) — for the CLI.
    public static func report(_ project: Project, projectURL: URL?) async -> [(label: String, start: Double, before: Double?, after: Double?, peak: Double)] {
        let chain = project.master.voice ?? VoiceChain()
        var rows: [(label: String, start: Double, before: Double?, after: Double?, peak: Double)] = []
        for clip in project.audio where clip.role == .voice {
            let src = Project.resolve(clip.src, relativeTo: projectURL)
            let x = (try? await read(src, from: clip.inPoint, duration: clip.duration.map { $0 * clip.speed })) ?? []
            guard let url = await file(for: clip, chain: chain, projectURL: projectURL) else { continue }
            let y = (try? await read(url, from: 0, duration: nil)) ?? []
            let g = 20 * log10(max(clip.gain, 1e-6))
            rows.append(((clip.label ?? src.lastPathComponent), clip.start, Dynamics.loudness(x).map { $0 + g }, Dynamics.loudness(y).map { $0 + g },
                         20 * log10(Double(y.map { abs($0) }.max() ?? 0) + 1e-9) + g))
        }
        return rows.sorted { $0.start < $1.start }
    }

    private static func moved(_ clip: AudioClip, _ url: URL) -> AudioClip {
        var c = clip; c.src = url.path; c.inPoint = 0; return c
    }

    static var cache: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SimbiaCaptions/voice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The processed sound of one clip, rendered if it is not in the cache yet; nil if the source can't be read.
    static func file(for clip: AudioClip, chain: VoiceChain, projectURL: URL?) async -> URL? {
        let src = Project.resolve(clip.src, relativeTo: projectURL)
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let stamp = "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs?[.size] as? Int) ?? 0)"
        let key = "v1|\(src.path)|\(stamp)|\(clip.inPoint)|\((clip.duration ?? -1) * clip.speed)|\(chain.target)|\(chain.squeeze)|\(chain.ceiling)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = cache.appending(path: name + ".caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // the clip's stretch of its source (at another speed `duration · speed` of it; the edit squeezes the file)
        guard var x = try? await read(src, from: clip.inPoint, duration: clip.duration.map { $0 * clip.speed }), !x.isEmpty else { return nil }
        Dynamics.process(&x, chain: chain)
        let part = url.deletingPathExtension().appendingPathExtension("part.caf")
        guard (try? write(x, to: part)) != nil else { return nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: part, to: url)
        return url
    }

    /// Mono float samples at 48 kHz of a stretch of any audio or video file.
    static func read(_ url: URL, from: Double, duration: Double?) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: max(0, from), preferredTimescale: 48_000)
        reader.timeRange = CMTimeRange(start: start, duration: duration.map { CMTime(seconds: $0, preferredTimescale: 48_000) } ?? .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var out: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            out += chunk
        }
        if let duration { out = Array(out.prefix(Int((duration * rate).rounded()))) }
        return out
    }

    static func write(_ x: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        try file.write(from: buffer)
    }
}

/// The chain's signal processing, on mono samples at 48 kHz.
enum Dynamics {
    static let fs = 48_000.0

    static func process(_ x: inout [Float], chain: VoiceChain) {
        // 1. one loudness for every clip
        if let l = loudness(x) { scale(&x, by: db(min(20, max(-15, chain.target - l)))) }
        // 2. compression, then 3. back to the target (the compressor took some level away)
        compress(&x, threshold: chain.threshold, ratio: chain.ratio)
        if let l = loudness(x) { scale(&x, by: db(min(12, max(-12, chain.target - l)))) }
        // 4. true-peak limiting
        limit(&x, ceiling: Float(db(chain.ceiling)))
    }

    static func db(_ v: Double) -> Double { pow(10, v / 20) }
    static func scale(_ x: inout [Float], by g: Double) { let g = Float(g); for i in x.indices { x[i] *= g } }

    /// A biquad run over the samples (direct form I).
    static func biquad(_ x: [Float], _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let x0 = Double(x[i]); let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            y[i] = Float(y0); x2 = x1; x1 = x0; y2 = y1; y1 = y0
        }
        return y
    }

    /// 2nd-order Butterworth high-pass.
    static func highpass(_ x: [Float], _ f: Double) -> [Float] {
        let w = 2 * Double.pi * f / fs, q = 1 / 2.0.squareRoot(), al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        return biquad(x, (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    /// Integrated loudness (ITU-R BS.1770-4: K-weighting, 400 ms blocks with 75 % overlap, absolute −70 LUFS and
    /// relative −10 LU gates); a clip shorter than one block is measured as one block. nil = silence.
    static func loudness(_ x: [Float]) -> Double? {
        var k = biquad(x, 1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
        k = biquad(k, 1, -2, 1, -1.99004745483398, 0.99007225036621)
        let block = Int(0.4 * fs), hop = block / 4
        var z: [Double] = []
        if k.count < block {
            z = [k.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, k.count))]
        } else {
            var i = 0
            while i + block <= k.count {
                var s = 0.0
                for j in i..<(i + block) { s += Double(k[j] * k[j]) }
                z.append(s / Double(block)); i += hop
            }
        }
        func lufs(_ v: Double) -> Double { -0.691 + 10 * log10(max(v, 1e-12)) }
        let abs = z.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return nil }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        return lufs(gated.reduce(0, +) / Double(max(1, gated.count)))
    }

    /// Feed-forward compression in the manner of Pro-C 2 «Pro Voice Over»: the detector hears the voice through a
    /// 100 Hz low cut, 5 ms RMS; soft 16 dB knee; 2 ms lookahead; a fast (2 ms / 60 ms) and a slow (40 ms / 450 ms)
    /// gain-reduction stage — the larger one wins, so a short peak lets go quickly and long squeezing slowly;
    /// 70 % compressed + 30 % dry.
    static func compress(_ x: inout [Float], threshold: Double, ratio: Double) {
        let n = x.count; guard n > 0 else { return }
        let sc = highpass(x, 100)
        let knee = 16.0, look = Int(0.002 * fs), win = Int(0.005 * fs), mix: Float = 0.7
        func coef(_ t: Double) -> Double { exp(-1 / (t * fs)) }
        let fa = coef(0.002), fr = coef(0.060), sa = coef(0.040), sr = coef(0.450)
        var gr = [Float](repeating: 0, count: n)
        var acc = 0.0, fast = 0.0, slow = 0.0
        for i in 0..<n {
            acc += Double(sc[i] * sc[i]); if i >= win { acc -= Double(sc[i - win] * sc[i - win]) }
            let level = 10 * log10(max(acc / Double(min(i + 1, win)), 1e-12))
            // gain computer with a soft knee: dB of reduction wanted
            let over = level - threshold
            let want: Double
            if 2 * over < -knee { want = 0 }
            else if 2 * abs(over) <= knee { want = (1 - 1 / ratio) * pow(over + knee / 2, 2) / (2 * knee) }
            else { want = (1 - 1 / ratio) * over }
            fast = want > fast ? fa * fast + (1 - fa) * want : fr * fast + (1 - fr) * want
            slow = want > slow ? sa * slow + (1 - sa) * want : sr * slow + (1 - sr) * want
            gr[i] = Float(max(fast, slow))
        }
        // the reduction leads the sound by the lookahead
        let dry = x
        for i in 0..<n {
            let g = Float(db(-Double(gr[min(n - 1, i + look)])))
            x[i] = dry[i] * (mix * g + (1 - mix))
        }
    }

    /// Peak limiting in the manner of Pro-L 2 with true-peak detection: inter-sample peaks estimated at 4x by a
    /// windowed-sinc interpolator; the gain needed is held low over a 1.5 ms lookahead and faded in over it
    /// (no attack overshoot, no clicks), then let go over 120 ms; a last safety clip at the ceiling.
    static func limit(_ x: inout [Float], ceiling: Float) {
        let n = x.count; guard n > 0 else { return }
        let look = Int(0.0015 * fs)
        // windowed sinc (8 taps, Hann) at the 1/4, 2/4, 3/4 positions between samples
        let taps = 8
        let phases: [[Float]] = [0.25, 0.5, 0.75].map { f in
            (0..<taps).map { k in
                let t = Double(k - taps / 2 + 1) - f
                let s = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
                let w = 0.5 + 0.5 * cos(Double.pi * t / Double(taps / 2))
                return Float(s * w)
            }
        }
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            var peak = abs(x[i])
            for ph in phases {
                var v: Float = 0
                for k in 0..<taps { let j = i + k - taps / 2 + 1; if j >= 0 && j < n { v += x[j] * ph[k] } }
                peak = max(peak, abs(v))
            }
            if peak > ceiling { need[i] = ceiling / peak }
        }
        // the lowest gain needed anywhere in the next `look` samples (monotonic deque)
        var hold = [Float](repeating: 1, count: n)
        var dq: [Int] = []; var head = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            while dq.count > head, need[dq[dq.count - 1]] >= need[i] { dq.removeLast() }
            dq.append(i)
            while dq.count > head, dq[head] > i + look { head += 1 }
            hold[i] = need[dq[head]]
            if head > 4096 { dq.removeFirst(head); head = 0 }
        }
        // faded in over the lookahead (moving average of the held gain), released smoothly
        let rel = Float(exp(-1 / (0.120 * fs)))
        var sum: Float = 0, g: Float = 1
        for i in 0..<n {
            sum += hold[i]; if i >= look { sum -= hold[i - look] }
            let target = sum / Float(min(i + 1, look))          // ≤ the gain any peak inside the window needs
            g = target < g ? target : rel * g + (1 - rel) * target
            x[i] = max(-ceiling, min(ceiling, x[i] * g))
        }
    }
}
