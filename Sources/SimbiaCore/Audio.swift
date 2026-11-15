import AVFoundation

/// How much the music dips under the voice, moment by moment.
///
/// This is ffmpeg's `sidechaincompress` run over the voice — threshold 0.035, ratio 4, attack
/// 12 ms, release 250 ms, RMS detection, soft knee 2.83 — the same settings the earlier renders
/// used, so the native mix ducks the way those renders did. Applied as volume automation.
struct DuckEnvelope {
    static let sampleRate = 48_000.0
    /// Gain values per second kept from the per-sample curve.
    static let rate = 100.0

    let gains: [Float]
    /// The voice's level, dB RMS over 30 ms, `rate` values per second — what a hand-set sidechain listens to.
    var level: [Float] = []
    /// Which voice it was worked out from (files, times, gains) — what a cached mix depends on.
    var key = ""

    /// The dip under one clip: its own sidechain, or the old compressor.
    func curve(_ clip: AudioClip) -> [Float] {
        clip.sidechain.map { Self.sidechain(level, $0) } ?? gains
    }

    static func value(_ curve: [Float], at time: Double) -> Double {
        guard !curve.isEmpty else { return 1 }
        let x = max(0, time * rate)
        let i = Int(x)
        guard i + 1 < curve.count else { return Double(curve[min(i, curve.count - 1)]) }
        let f = x - Double(i)
        return Double(curve[i]) * (1 - f) + Double(curve[i + 1]) * f
    }

    /// Down by `depth` dB wherever the voice speaks: the voice counts from 22 dB under its own loud parts (so a
    /// quiet voice-over works the same), gaps between words under 0.3 s are bridged, the music is fully
    /// down by the time the voice starts (it looks ahead by `attack`) and comes back over `release` — straight
    /// ramps in dB.
    static func sidechain(_ level: [Float], _ s: Sidechain) -> [Float] {
        let n = level.count
        guard n > 1, s.depth > 0.01 else { return [Float](repeating: 1, count: max(n, 1)) }
        let loud = level.sorted()[Int(Double(n - 1) * 0.95)]
        let threshold = max(loud - 22, -60)
        let hold = Int(0.3 * rate)
        var held = [Bool](repeating: false, count: n)
        var last = -hold - 1
        for i in 0..<n {
            if level[i] > threshold { last = i }
            held[i] = i - last <= hold
        }
        var target = held
        let lead = Int((s.attack * rate).rounded())
        for i in 1..<n where held[i] && !held[i - 1] {
            for j in max(0, i - lead)..<i { target[j] = true }
        }
        let down = s.depth / max(1, s.attack * rate), up = s.depth / max(1, s.release * rate)
        var db = 0.0
        var out = [Float]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let goal = target[i] ? -s.depth : 0
            db = goal < db ? max(goal, db - down) : min(goal, db + up)
            out.append(Float(pow(10, db / 20)))
        }
        return out
    }

    /// The voice clips summed on the edit's clock up to `until`. A clip that cannot be read is left out
    /// (the composition reports it); a clip starting before 0 loses its head.
    static func from(voice clips: [AudioClip], projectURL: URL?, until: Double) async -> DuckEnvelope? {
        guard !clips.isEmpty else { return nil }
        // Every edit of a shot or a title rebuilds the player; the voice has not changed, so its analysis
        // (seconds for a two-minute voice-over) is reused — keyed by the files as they are on disk.
        let key = clips.map { clip -> String in
            let url = Project.resolve(clip.src, relativeTo: projectURL)
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(stamp)|\(clip.start)|\(clip.inPoint)|\(clip.duration ?? -1)|\(clip.gain)|\(clip.speed)"
        }.joined(separator: ";") + "|\(until)"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }
        // the preview build and the timeline's music outlines ask for the same voice at once after a sound edit:
        // one analysis, the others wait for it (three at a time used to load every thread for seconds)
        let task = cacheLock.withLock { () -> Task<DuckEnvelope, Never> in
            if let running = running[key] { return running }
            let made = Task.detached(priority: .userInitiated) { () -> DuckEnvelope in
                var made = await analyse(clips, projectURL: projectURL, until: until)
                made.key = key
                return made
            }
            running[key] = made
            return made
        }
        let made = await task.value
        cacheLock.withLock {
            if cache.count >= 8 { cache.removeAll() }
            cache[key] = made
            running[key] = nil
        }
        return made
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DuckEnvelope] = [:]
    nonisolated(unsafe) private static var running: [String: Task<DuckEnvelope, Never>] = [:]

    private static func analyse(_ clips: [AudioClip], projectURL: URL?, until: Double) async -> DuckEnvelope {
        let limit = Int(max(0, until) * sampleRate)
        var key: [Float] = []
        for clip in clips where clip.start < until {
            guard var samples = try? await decodeMono(clip, projectURL: projectURL) else { continue }
            let law = Float((try? await Volume.panLaw(clip, projectURL: projectURL)) ?? 1)
            if law != 1 { samples = samples.map { $0 * law } }
            let offset = Int(clip.start * sampleRate)
            let from = max(0, -offset), to = min(samples.count, limit - offset)
            guard to > from else { continue }
            if key.count < offset + to { key += [Float](repeating: 0, count: offset + to - key.count) }
            for i in from..<to { key[offset + i] += samples[i] * Float(clip.gain) }
        }
        // a second of silence after the voice lets the compressor release, as ffmpeg's padded sidechain does
        key += [Float](repeating: 0, count: Int(sampleRate))
        return DuckEnvelope(gains: compress(key), level: levels(key))
    }

    /// dB RMS over 30 ms windows, `rate` per second.
    static func levels(_ key: [Float]) -> [Float] {
        let hop = Int(sampleRate / rate)
        var power = [Float]()
        power.reserveCapacity(key.count / hop + 1)
        var i = 0
        while i < key.count {
            let end = min(key.count, i + hop)
            var sum: Float = 0
            for k in i..<end { sum += key[k] * key[k] }
            power.append(sum / Float(end - i))
            i = end
        }
        return power.indices.map { k in
            let a = max(0, k - 1), b = min(power.count - 1, k + 1)
            return 10 * log10(power[a...b].reduce(0, +) / Float(b - a + 1) + 1e-12)
        }
    }

    /// Port of `compressor()` in libavfilter/af_sidechaincompress.c, downward mode.
    static func compress(_ key: [Float], threshold: Double = 0.035, ratio: Double = 4, attack: Double = 12,
                         release: Double = 250, knee: Double = 2.82843, makeup: Double = 1) -> [Float] {
        let thres = log(threshold)
        let linKneeStart = threshold / knee.squareRoot()
        let linKneeStop = threshold * knee.squareRoot()
        let adjKneeStart = linKneeStart * linKneeStart
        let kneeStart = log(linKneeStart), kneeStop = log(linKneeStop)
        let compressedKneeStop = (kneeStop - thres) / ratio + thres
        let attackCoeff = min(1, 1 / (attack * sampleRate / 4000))
        let releaseCoeff = min(1, 1 / (release * sampleRate / 4000))
        let delta = 1 / ratio

        func hermite(_ x: Double, _ x0: Double, _ x1: Double, _ p0: Double, _ p1: Double, _ m0: Double, _ m1: Double) -> Double {
            let width = x1 - x0, t = (x - x0) / width
            let a = m0 * width, b = m1 * width
            let t2 = t * t, t3 = t2 * t
            return (2 * p0 + a - 2 * p1 + b) * t3 + (-3 * p0 - 2 * a + 3 * p1 - b) * t2 + a * t + p0
        }

        let hop = Int(sampleRate / rate)
        var out: [Float] = []
        out.reserveCapacity(key.count / hop + 2)
        var slope = 0.0
        var gain = 1.0
        for (i, sample) in key.enumerated() {
            let level = Double(sample) * Double(sample)                     // RMS detection squares the key
            slope += (level - slope) * (level > slope ? attackCoeff : releaseCoeff)
            gain = 1
            if slope > 0, slope > adjKneeStart {
                let s = log(slope) * 0.5
                var g = (s - thres) / ratio + thres
                if knee > 1, s < kneeStop { g = hermite(s, kneeStart, kneeStop, kneeStart, compressedKneeStop, 1, delta) }
                gain = exp(g - s)
            }
            if i % hop == 0 { out.append(Float(gain * makeup)) }
        }
        return out
    }

    /// The clip's stretch of its source as 48 kHz mono floats — cut from the whole file, which is read once. (A voice
    /// cut into 150 lines was read 150 times for every analysis, and a drag on the sound started several at once:
    /// every Swift worker thread then waited on a file reader, and the preview's video stalled with them.)
    /// At another speed the stretch is `duration · speed` of the source, picked up every `speed` samples so it lies on
    /// the edit's clock (good enough for levels and for where the voice is).
    static func decodeMono(_ clip: AudioClip, projectURL: URL?) async throws -> [Float] {
        let whole = try await SourceAudio.mono(Project.resolve(clip.src, relativeTo: projectURL))
        let a = min(whole.count, max(0, Int((clip.inPoint * sampleRate).rounded())))
        let b = clip.duration.map { min(whole.count, a + Int(($0 * clip.speed * sampleRate).rounded())) } ?? whole.count
        guard a < b else { return [] }
        guard clip.speed != 1 else { return Array(whole[a..<b]) }
        return (0..<Int(Double(b - a) / clip.speed)).map { whole[min(b - 1, a + Int(Double($0) * clip.speed))] }
    }
}

/// Whole sound files as 48 kHz mono floats: read one at a time on their own thread — never on Swift's worker
/// threads, which a blocking reader holds — and kept for the few files an edit uses.
enum SourceAudio {
    private struct Source: @unchecked Sendable { let asset: AVURLAsset; let track: AVAssetTrack }
    private static let queue = DispatchQueue(label: "simbia.audio.read", qos: .userInitiated)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [(key: String, samples: [Float])] = []

    static func mono(_ url: URL) async throws -> [Float] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        if let hit = cached(key) { return hit }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let source = Source(asset: asset, track: track)
        return try await withCheckedThrowingContinuation { done in
            queue.async {
                if let hit = cached(key) { done.resume(returning: hit); return }
                do {
                    let samples = try read(source)
                    lock.withLock {
                        files.removeAll { $0.key.hasPrefix(url.path + "|") }
                        files.append((key, samples))
                        if files.count > 3 { files.removeFirst() }
                    }
                    done.resume(returning: samples)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private static func cached(_ key: String) -> [Float]? {
        lock.withLock {
            guard let i = files.firstIndex(where: { $0.key == key }) else { return nil }
            let file = files.remove(at: i)
            files.append(file)                                  // most recently used last
            return file.samples
        }
    }

    private static func read(_ source: Source) throws -> [Float] {
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: DuckEnvelope.sampleRate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "Simbia", code: 30) }
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

/// Volume automation already laid down for a clip, reused while nothing it depends on changes: a shot or
/// title edit rebuilds the player, and the thousands of ramps under a ducked music bed cost a second or
/// more every time. The audio tracks keep fixed ids, so the same parameters fit the new composition.
enum MixCache {
    private final class Box: @unchecked Sendable {
        let parameters: AVMutableAudioMixInputParameters
        init(_ parameters: AVMutableAudioMixInputParameters) { self.parameters = parameters }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [String: Box] = [:]

    /// One track's volume automation: the clips laid on it (each with the length it plays), in time order.
    static func parameters(track: CMPersistentTrackID, source: String, clips: [(clip: AudioClip, span: Double)],
                           duck: DuckEnvelope?, panLaw: Double) -> AVMutableAudioMixInputParameters {
        let parts = clips.map { c in "\(c.clip.start)|\(c.clip.inPoint)|\(c.clip.gain)|\(c.clip.fadeIn)|\(c.clip.fadeOut)|\(c.clip.fadeInCurve)|\(c.clip.fadeOutCurve)|\(c.clip.duck)|\(c.clip.sidechain.map { "\($0.depth),\($0.attack),\($0.release)" } ?? "-")|\(c.span)" }
        let key = "\(track)|\(source)|\(panLaw)|\(duck?.key ?? "-")|" + parts.joined(separator: ";")
        if let hit = lock.withLock({ items[key] }) { return hit.parameters }
        let made = AVMutableAudioMixInputParameters()
        made.trackID = track
        for (k, c) in clips.enumerated() {
            Volume.automate(made, clip: c.clip, span: c.span, duck: c.clip.duck ? duck : nil, panLaw: panLaw, first: k == 0)
        }
        lock.withLock {
            if items.count >= 32 { items.removeAll() }
            items[key] = Box(made)
        }
        return made
    }
}

enum Volume {
    /// A mono source spread over two channels plays at -3 dB in each (equal-power pan law), which is
    /// what ffmpeg's upmix did in the renders — AVFoundation would otherwise duplicate it at full level.
    static func panLaw(_ track: AVAssetTrack) async throws -> Double {
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return 1 }
        return asbd.pointee.mChannelsPerFrame == 1 ? 0.5.squareRoot() : 1
    }

    static func panLaw(_ clip: AudioClip, projectURL: URL?) async throws -> Double {
        let asset = AVURLAsset(url: Project.resolve(clip.src, relativeTo: projectURL))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 1 }
        return try await panLaw(track)
    }

    /// A clip's level `local` seconds into it: gain (and pan law), its fades with their arcs, its ducking — the curve
    /// the export's ramps follow and the preview's `LevelTap` puts on every sample.
    static func level(_ clip: AudioClip, span: Double, dip: [Float]?, panLaw: Double, at local: Double) -> Float {
        var v = clip.gain * panLaw
        if clip.fadeIn > 0 { v *= Bend.apply(local / clip.fadeIn, clip.fadeInCurve) }
        if clip.fadeOut > 0 { v *= Bend.apply((span - local) / clip.fadeOut, clip.fadeOutCurve) }
        if let dip { v *= DuckEnvelope.value(dip, at: clip.start + local) }
        return Float(v)
    }

    /// Gain, fades and ducking as volume ramps on one track, 20 ms apart. A track can carry several clips:
    /// the first one also sets the level from the track's very start, the others from their own.
    static func automate(_ parameters: AVMutableAudioMixInputParameters, clip: AudioClip, span: Double,
                         duck: DuckEnvelope?, panLaw: Double = 1, first: Bool = true) {
        func at(_ t: Double) -> CMTime { CMTime(seconds: clip.start + t, preferredTimescale: 48_000) }
        guard duck != nil || clip.fadeIn > 0 || clip.fadeOut > 0 else {
            parameters.setVolume(Float(clip.gain * panLaw), at: first ? .zero : at(0))
            return
        }
        let dip = duck?.curve(clip)
        func volume(_ local: Double) -> Float { level(clip, span: span, dip: dip, panLaw: panLaw, at: local) }
        // The curve sampled every 20 ms, then laid down as the fewest straight ramps that stay within
        // 0.002 of it (about 0.02 dB): AVFoundation takes thousands of ramps very slowly, and a
        // two-minute music bed would otherwise hold ~7000 of them and stall every rebuild for seconds.
        let step = 0.02
        var times: [Double] = []
        var t = 0.0
        while t < span - 1e-6 { times.append(t); t += step }
        times.append(span)
        let values = times.map(volume)
        // AVFoundation starts a track's ramps a buffer late (~18 ms at full volume: a click where a cut music clip
        // goes on, a burst at the very start of the music) — so the track begins at the clip's own level.
        parameters.setVolume(values[0], at: first ? .zero : at(0))
        var a = 0
        while a < times.count - 1 {
            var b = a + 1
            while b + 1 < times.count {
                let c = b + 1
                let fits = (a + 1...b).allSatisfy { k in
                    let f = Float((times[k] - times[a]) / (times[c] - times[a]))
                    return abs(values[a] + (values[c] - values[a]) * f - values[k]) <= 0.002
                }
                guard fits else { break }
                b = c
            }
            parameters.setVolumeRamp(fromStartVolume: values[a], toEndVolume: values[b],
                                     timeRange: CMTimeRange(start: at(times[a]), end: at(times[b])))
            a = b
        }
    }
}

// MARK: - Drawing the sound

extension Project {
    /// A clip's loudness outline for drawing: RMS over windows of 1/`rate` s, starting at the
    /// clip's own start on the edit's clock. Gain and pan law included, ducking not.
    public static func envelope(of clip: AudioClip, projectURL: URL?, rate: Double = 50) async throws -> [Float] {
        let samples = try await DuckEnvelope.decodeMono(clip, projectURL: projectURL)
        let law = Float(try await Volume.panLaw(clip, projectURL: projectURL) * clip.gain)
        let hop = max(1, Int(DuckEnvelope.sampleRate / rate))
        var out: [Float] = []
        out.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            out.append((sum / Float(end - i)).squareRoot() * law)
            i = end
        }
        return out
    }

    /// A music clip's ducking gain under the voice, 100 values per second on the edit's clock — what the
    /// sound track draws so the dips are visible.
    public func duckCurve(for clip: AudioClip, projectURL: URL?) async throws -> [Float] {
        await DuckEnvelope.from(voice: audio.filter { $0.role == .voice }, projectURL: projectURL, until: duration)?.curve(clip) ?? []
    }

    public static let duckCurveRate = DuckEnvelope.rate
}
