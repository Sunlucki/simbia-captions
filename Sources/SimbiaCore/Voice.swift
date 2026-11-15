import Foundation

/// Where the voice is actually heard: its loudness every 10 ms on the edit's clock, and the level above
/// which it counts as speaking. Caption edges snap to it, and pause removal leaves anything it hears alone.
public struct VoiceActivity: Sendable {
    public static let rate = 100.0
    /// RMS level of each 10 ms, in dB (−120 for silence).
    public let levels: [Float]
    /// Well under the voice's usual level and clear of the room's noise.
    public let threshold: Float

    public init(levels: [Float]) {
        self.levels = levels
        let heard = levels.filter { $0 > -100 }.sorted()
        func percentile(_ p: Double) -> Float { heard.isEmpty ? -120 : heard[Int(Double(heard.count - 1) * p)] }
        threshold = max(percentile(0.10) + 8, percentile(0.95) - 28)
    }

    private func frame(_ time: Double) -> Int { Int((time * Self.rate).rounded()) }
    private func loud(_ i: Int) -> Bool { levels.indices.contains(i) && levels[i] >= threshold }
    /// Speaking for 30 ms from frame i.
    private func speech(from i: Int) -> Bool { (i..<i + 3).allSatisfy(loud) }
    /// Quiet for `frames` frames before frame i.
    private func quiet(before i: Int, _ frames: Int) -> Bool { (i - frames..<i).allSatisfy { !loud($0) } }

    public func speaking(at time: Double) -> Bool { loud(frame(time)) }

    /// Where the voice starts after a silence of at least 0.12 s, closest to `time` within `reach`.
    public func onset(near time: Double, reach: Double) -> Double? {
        let candidates = (frame(time - reach)...frame(time + reach)).filter { quiet(before: $0, 12) && speech(from: $0) }
        return candidates.min { abs($0 - frame(time)) < abs($1 - frame(time)) }.map { Double($0) / Self.rate }
    }

    /// Where the voice falls silent for at least 0.15 s, closest to `time` within `reach`.
    public func offset(near time: Double, reach: Double) -> Double? {
        let candidates = (frame(time - reach)...frame(time + reach)).filter { i in
            (i - 3..<i).allSatisfy(loud) && (i..<i + 15).allSatisfy { !loud($0) }
        }
        return candidates.min { abs($0 - frame(time)) < abs($1 - frame(time)) }.map { Double($0) / Self.rate }
    }

    /// The first moment in `from…to` where the voice starts speaking.
    public func start(after from: Double, before to: Double) -> Double? {
        guard to > from else { return nil }
        return (frame(from)...frame(to)).first { !loud($0 - 1) && speech(from: $0) }.map { Double($0) / Self.rate }
    }

    /// Where the voice last stops in `from…to` — not counting a start right at `to` (the next words).
    public func stop(before to: Double, after from: Double) -> Double? {
        guard to > from else { return nil }
        return (frame(from)...max(frame(from), frame(to) - 2)).last(where: loud).map { Double($0 + 1) / Self.rate }
    }

    /// Stretches where the voice says nothing for longer than `minimum` seconds, the very start and end included.
    public func silences(longer minimum: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = [], from: Int?
        for i in 0...levels.count {
            if i < levels.count, !loud(i) { if from == nil { from = i }; continue }
            if let f = from, Double(i - f) / Self.rate > minimum { out.append(Double(f) / Self.rate...Double(i) / Self.rate) }
            from = nil
        }
        return out
    }

    /// The project's voice clips, summed on the edit's clock. nil without a voice.
    public static func of(_ project: Project, projectURL: URL?) async -> VoiceActivity? {
        let clips = project.audio.filter { $0.role == .voice }
        guard !clips.isEmpty else { return nil }
        let key = clips.map { clip -> String in
            let url = Project.resolve(clip.src, relativeTo: projectURL)
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(stamp)|\(clip.start)|\(clip.inPoint)|\(clip.duration ?? -1)|\(clip.gain)|\(clip.speed)"
        }.joined(separator: ";") + "|\(project.duration)"
        if let hit = cacheLock.withLock({ cache[key] }) { return hit }

        let sampleRate = DuckEnvelope.sampleRate
        let hop = Int(sampleRate / rate)
        var sum = [Float](repeating: 0, count: Int(max(0, project.duration) * sampleRate) + hop)
        for clip in clips {
            guard let samples = try? await DuckEnvelope.decodeMono(clip, projectURL: projectURL) else { continue }
            let offset = Int((clip.start * sampleRate).rounded())
            let from = max(0, -offset), to = min(samples.count, sum.count - offset)
            guard to > from else { continue }
            for i in from..<to { sum[offset + i] += samples[i] * Float(clip.gain) }
        }
        var levels: [Float] = []
        levels.reserveCapacity(sum.count / hop + 1)
        var i = 0
        while i + hop <= sum.count {
            var energy: Float = 0
            for k in i..<i + hop { energy += sum[k] * sum[k] }
            let rms = (energy / Float(hop)).squareRoot()
            levels.append(rms > 1e-6 ? 20 * log10(rms) : -120)
            i += hop
        }
        let made = VoiceActivity(levels: levels)
        cacheLock.withLock {
            if cache.count >= 4 { cache.removeAll() }
            cache[key] = made
        }
        return made
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: VoiceActivity] = [:]
}
