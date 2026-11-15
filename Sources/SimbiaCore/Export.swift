import AVFoundation
import Foundation

/// Renders a project to a finished MP4: the composition with captions and titles drawn in, the mix,
/// then loudness brought to the project's target (−14 LUFS) by ffmpeg's loudnorm, video copied.
public enum Exporter {
    public struct Settings: Sendable {
        public var videoBitrate = 10_000_000
        public var audioBitrate = 192_000
        /// The first ffmpeg found; the app passes the one it has checked actually runs.
        public var ffmpeg = Exporter.ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? Exporter.ffmpegCandidates[0]
        public init() {}
    }

    public static let ffmpegCandidates = ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg",
                                          "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    public enum Failure: LocalizedError {
        case writer(String), reader(String), loudness(String)
        public var errorDescription: String? {
            switch self {
            case .writer(let s): return "Export: \(s)"
            case .reader(let s): return "Export: \(s)"
            case .loudness(let s): return "Loudness pass: \(s)"
            }
        }
    }

    /// `progress` gets 0…1 (the render is ~95%, the loudness pass the rest).
    public static func export(_ project: Project, projectURL: URL?, to out: URL, settings: Settings = Settings(),
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let built = try await project.composition(projectURL: projectURL, overlay: true)
        // the preview shows a missing clip as black; a finished video must not
        guard built.missing.isEmpty else { throw CompositionError.missing(built.missing) }
        await built.context.prepareEdges()                                 // the blur across every cut, before the render
        let renderer = OverlayRenderer(project: project, projectURL: projectURL)
        let canvas = CGSize(width: project.canvas.width, height: project.canvas.height)
        built.context.overlay = { cg, t in renderer.draw(in: cg, size: canvas, time: t, flipped: false) }

        let raw = out.deletingPathExtension().appendingPathExtension("render.mov")
        try? FileManager.default.removeItem(at: raw)
        defer { if ProcessInfo.processInfo.environment["SIMBIA_KEEP_RAW"] == nil { try? FileManager.default.removeItem(at: raw) } }
        try await render(built, duration: project.duration, fps: project.canvas.fps, size: canvas,
                         to: raw, settings: settings) { progress($0 * 0.95) }
        try loudness(raw, to: out, master: project.master, duration: project.duration, settings: settings)
        progress(1)
    }

    private static func render(_ built: BuiltComposition, duration: Double, fps: Double, size: CGSize, to url: URL,
                               settings: Settings, progress: @escaping (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.asset)
        let end = CMTime(seconds: duration, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: .zero, end: end)

        let videoTracks = try await built.asset.loadTracks(withMediaType: .video)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = built.video
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw Failure.reader("cannot read the composition") }
        reader.add(videoOut)

        let audioTracks = try await built.asset.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
            o.audioMix = built.audio
            o.audioTimePitchAlgorithm = .spectral         // sound at another speed keeps its pitch
            if reader.canAdd(o) { reader.add(o); audioOut = o }
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw Failure.writer("cannot add video") }
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); audioIn = a }
        }

        guard reader.startReading() else { throw Failure.reader(reader.error?.localizedDescription ?? "start") }
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "simbia.export")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(videoOut, into: videoIn, on: queue) { time in progress(min(1, time / max(duration, 0.01))) }
            }
            if let audioOut, let audioIn {
                group.addTask { await pump(audioOut, into: audioIn, on: queue) { _ in } }
            }
        }
        if reader.status == .failed { throw Failure.reader(reader.error?.localizedDescription ?? "read failed") }
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writer(writer.error?.localizedDescription ?? "write failed") }
    }

    /// Moves samples from a reader output to a writer input as fast as the input accepts them.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, on queue: DispatchQueue,
                             progress: @escaping (Double) -> Void) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                    progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    if !input.append(sample) {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    /// EBU R128 loudness to the target with a true-peak ceiling (ffmpeg loudnorm, as the renders used, then a limiter),
    /// AAC 192k, the video stream copied untouched; faststart for the web.
    private static func loudness(_ source: URL, to out: URL, master: MasterBus, duration: Double, settings: Settings) throws {
        // loudnorm lets a loud first syllable through before its own limiter catches up (seen: +0.8 dBTP at 0.15 s)
        // and the AAC encode adds up to half a dB more: a limiter on its 192 kHz output, a dB under the ceiling, holds both.
        let ceiling = min(1, max(0.0625, pow(10, (master.truePeak - 1) / 20)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.ffmpeg)
        process.arguments = ["-y", "-nostdin", "-loglevel", "error", "-i", source.path,
                             "-map", "0:v", "-map", "0:a?", "-c:v", "copy",
                             // loudnorm flushes its 3 s look-ahead with a jump in timestamps; renumber the samples.
                             // Sound that ends before the picture is padded with silence to the full length.
                             "-af", "loudnorm=I=\(master.loudness):TP=\(master.truePeak):LRA=11,"
                                 + "alimiter=limit=\(String(format: "%.4f", ceiling)):attack=1:release=50:level=false,"
                                 + "aresample=48000,asetpts=N/SR/TB,"
                                 + "apad=whole_dur=\(String(format: "%.3f", duration))",
                             "-c:a", "aac", "-b:a", "\(settings.audioBitrate / 1000)k", "-ar", "48000",
                             "-movflags", "+faststart", out.path]
        // errors go to a file: a pipe nobody reads while ffmpeg runs would stall it once it fills up
        let log = FileManager.default.temporaryDirectory.appending(path: "simbia-loudness-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        try? errors.close()
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Failure.loudness(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
