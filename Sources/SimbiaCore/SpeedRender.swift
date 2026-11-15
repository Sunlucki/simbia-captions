import AVFoundation
import CryptoKit

/// Sound clips at another speed (`AudioClip.speed`), rendered once into a cache the mix plays instead: the clip's
/// stretch of its source (`duration · speed` from `inPoint`) played `speed` times as fast with its pitch kept (Apple's
/// time-pitch unit, offline), so the composition lays the file in as it is. (Scaling the sound in the composition and
/// letting the reader keep the pitch came out now and then with a clip silent, the mix cut short or the read hung.)
enum SpeedRender {
    static let rate = 48_000.0

    /// The clips with every one at another speed pointing at its rendered sound (from its first sample, speed 1). One
    /// that can't be rendered stays as it is — the composition then scales it itself.
    static func sped(_ clips: [AudioClip], projectURL: URL?) async -> [AudioClip] {
        var out = clips
        for (i, clip) in clips.enumerated() where clip.speed != 1 {
            guard let url = await file(for: clip, projectURL: projectURL) else { continue }
            out[i].src = url.path; out[i].inPoint = 0; out[i].speed = 1
        }
        return out
    }

    static var cache: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SimbiaCaptions/speed", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The clip's sound at its speed, rendered if it is not in the cache yet; nil if the source can't be read.
    static func file(for clip: AudioClip, projectURL: URL?) async -> URL? {
        let src = Project.resolve(clip.src, relativeTo: projectURL)
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let stamp = "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs?[.size] as? Int) ?? 0)"
        let length = clip.duration.map { $0 * clip.speed }
        let key = "s1|\(src.path)|\(stamp)|\(clip.inPoint)|\(length ?? -1)|\(clip.speed)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = cache.appending(path: name + ".caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let input = try? await read(src, from: clip.inPoint, length: length), input.frameLength > 0,
              let output = try? stretch(input, speed: clip.speed) else { return nil }
        let part = cache.appending(path: name + "-" + UUID().uuidString + ".part.caf")
        do {
            let file = try AVAudioFile(forWriting: part, settings: output.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: output)
        } catch { return nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: part, to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Stereo float samples at 48 kHz of a stretch of any audio or video file (a mono source on both sides).
    static func read(_ url: URL, from: Double, length: Double?) async throws -> AVAudioPCMBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, from), preferredTimescale: 48_000),
                                       duration: length.map { CMTime(seconds: $0, preferredTimescale: 48_000) } ?? .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var x: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            x += chunk
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var frames = x.count / 2
        if let length { frames = min(frames, Int((length * rate).rounded())) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { out.floatChannelData![0][i] = x[2 * i]; out.floatChannelData![1][i] = x[2 * i + 1] }
        return out
    }

    /// The samples played `speed` times as fast, pitch kept: `frames / speed` of them, the time-pitch unit's delay
    /// taken off the front.
    static func stretch(_ input: AVAudioPCMBuffer, speed: Double) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(min(32, max(1.0 / 32, speed)))
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: input.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: input.format)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: input.format, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input)
        player.play()
        let delay = Int((pitch.latency * rate).rounded())
        let want = Int((Double(input.frameLength) / speed).rounded())
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(max(1, want))),
              let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else { throw CocoaError(.fileWriteUnknown) }
        var made = 0
        while made < delay + want {
            guard try engine.renderOffline(AVAudioFrameCount(min(Int(block), delay + want - made)), to: chunk) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
            let n = Int(chunk.frameLength)
            let skip = max(0, min(n, delay - made))
            let keep = min(n - skip, want - Int(out.frameLength))
            if keep > 0 {
                for c in 0..<Int(out.format.channelCount) {
                    (out.floatChannelData![c] + Int(out.frameLength)).update(from: chunk.floatChannelData![c] + skip, count: keep)
                }
                out.frameLength += AVAudioFrameCount(keep)
            }
            made += n
        }
        return out
    }
}
