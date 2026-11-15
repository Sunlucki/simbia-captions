import AVFoundation
import SimbiaCore

/// `simbia playtap <project> <out.wav> [from] [seconds]`: what the app's preview player really plays — the project
/// built as the preview builds it (`live`: the levels put on every sample by `LevelTap`), played muted by an AVPlayer
/// in real time, each sound track caught as its tap lets it through, the tracks summed on the edit's clock into a mono
/// WAV. For comparing with `simbia audio`, which reads the export's mix offline.
/// `retarget`: at that point of the edit, the levels of another project handed to the playing taps — as a level edit in
/// the app does.
func playTap(_ project: Project, url: URL, out: URL, from: Double, seconds: Double, retarget: (Project, Double)? = nil) async throws {
    let built = try await project.composition(projectURL: url, overlay: false, live: true)
    for tap in built.taps.values { tap.record = true }
    let item = built.playerItem()
    let player = AVPlayer(playerItem: item)
    player.volume = 0                                      // (isMuted: the player stopped feeding sound after ~5 s)
    for _ in 0..<100 where item.status == .unknown { try await Task.sleep(nanoseconds: 50_000_000) }
    await player.seek(to: CMTime(seconds: from, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    player.play()
    let started = Date()                                   // until the player itself is there (it starts late)
    var next: BuiltComposition?
    if let retarget { next = try await retarget.0.composition(projectURL: url, overlay: false, live: true) }
    var handed = false
    while player.currentTime().seconds < from + seconds, Date().timeIntervalSince(started) < seconds * 2 + 5 {
        if let next, let at = retarget?.1, !handed, player.currentTime().seconds >= at {
            for (id, tap) in next.taps { built.taps[id]?.retarget(tap.levels) }
            handed = true
            print(String(format: "levels handed over at %.3f s", player.currentTime().seconds))
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    player.pause()
    let rate = built.taps.values.first?.sampleRate ?? 48_000
    var sum = [Float](repeating: 0, count: Int((from + seconds + 1) * rate))
    var buffers = 0
    if ProcessInfo.processInfo.environment["TAPTIMES"] != nil, let tap = built.taps.values.first {
        print(tap.takeRecorded().map { String(format: "%.3f", $0.start) }.joined(separator: " "))
    }
    for tap in built.taps.values {
        for c in tap.takeRecorded() {
            buffers += 1
            let at = Int((c.start * rate).rounded())
            for (i, v) in c.samples.enumerated() where at + i >= 0 && at + i < sum.count { sum[at + i] += v }
        }
    }
    var pcm = Data()
    for v in sum { var s = Int16(max(-1, min(1, v)) * 32767).littleEndian; pcm.append(Data(bytes: &s, count: 2)) }
    var header = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header += $0 } }
    header += "RIFF".data(using: .ascii)!; u32(UInt32(36 + pcm.count)); header += "WAVEfmt ".data(using: .ascii)!
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
    header += "data".data(using: .ascii)!; u32(UInt32(pcm.count))
    try (header + pcm).write(to: out)
    print("\(out.path): \(built.taps.count) tracks, \(buffers) buffers at \(Int(rate)) Hz")
}
