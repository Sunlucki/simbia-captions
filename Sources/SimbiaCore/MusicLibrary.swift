import AVFoundation
import Foundation

/// The music library: every track under `_ASSETS/MUSIC` (its subfolders too), what each sounds like — length, loudness, a
/// small outline — and which projects already have it as their music. What «Аудиобиблиотека» shows, and what putting a
/// track in as a project's music bed needs: the new track gets the old one's place, length, fade and ducking, and a gain
/// that keeps the bed as loud as it was — `gain · 10^((LUFS old − LUFS new) / 20)`, the loudness of the whole file by
/// ffmpeg's ebur128 (as the 11-11 batch script measured it).
public enum MusicLibrary {
    public struct Track: Identifiable, Hashable, Sendable {
        public let url: URL
        /// The subfolder it is in, "" for the library's own folder.
        public let folder: String
        public var id: String { url.path }
        /// The file's name without its extension: what the project's clip is labelled ("Upbeat Pop 17 a").
        public var name: String { url.deletingPathExtension().lastPathComponent }
        /// On the card: the name without the generator's id in brackets.
        public var title: String { name.replacingOccurrences(of: #"\s*\([0-9a-f]{6,}\)$"#, with: "", options: .regularExpression) }
    }

    /// A track as heard: seconds, integrated loudness (LUFS; nil when ffmpeg could not tell) and 120 peaks for drawing.
    public struct Sound: Codable, Sendable {
        public let duration: Double
        public let lufs: Double?
        public let bars: [Float]
    }

    static let types: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac", "aac"]

    /// The workspace's music folder, else `_ASSETS/MUSIC` in a folder above the project.
    public static func find(near projectURL: URL?) -> URL? {
        if let w = Workspace.find(near: projectURL) ?? Workspace.active,
           FileManager.default.fileExists(atPath: w.music.path) { return w.music.resolvingSymlinksInPath() }
        var folder = projectURL?.deletingLastPathComponent()
        while let dir = folder, dir.path != "/" {
            let here = dir.appending(path: "_ASSETS/MUSIC", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: here.path) { return here.resolvingSymlinksInPath() }
            folder = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every sound file under `root`, by folder (the library's own first) and name.
    public static func tracks(in root: URL) -> [Track] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path
        var out: [Track] = []
        for case let url as URL in walk where types.contains(url.pathExtension.lowercased()) {
            let dir = url.deletingLastPathComponent().standardizedFileURL.path
            out.append(Track(url: url, folder: dir.hasPrefix(base) ? String(dir.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""))
        }
        return out.sorted { a, b in
            a.folder != b.folder ? (a.folder.isEmpty || (!b.folder.isEmpty && a.folder.localizedStandardCompare(b.folder) == .orderedAscending))
                                 : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: How it sounds

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Sound]?
    private static var cacheFile: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "SimbiaCaptions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "music.json")
    }

    private static func key(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(Int(date))|\((attrs?[.size] as? Int) ?? 0)"
    }

    /// Already worked out for the file as it is on disk (nil = not yet).
    public static func known(_ url: URL) -> Sound? {
        let k = key(url)
        return lock.withLock {
            if known == nil { known = (try? JSONDecoder().decode([String: Sound].self, from: Data(contentsOf: cacheFile))) ?? [:] }
            return known?[k]
        }
    }

    /// Its length, loudness and outline: worked out once per file as it is on disk, kept in the app's cache.
    public static func sound(of url: URL, ffmpeg: String) async -> Sound? {
        if let hit = known(url), hit.lufs != nil { return hit }
        let k = key(url)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let bars = (try? await outline(asset, count: 120)) ?? []
        let lufs = await loudness(url, ffmpeg: ffmpeg)
        let made = Sound(duration: duration, lufs: lufs, bars: bars)
        lock.withLock {
            known?[k] = made
            if let all = known, let data = try? JSONEncoder().encode(all) { try? data.write(to: cacheFile, options: .atomic) }
        }
        return made
    }

    /// Peaks of `count` equal stretches, 0…1, read at 8 kHz mono (the reader takes no lower rate).
    static func outline(_ asset: AVURLAsset, count: Int) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        var x: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            x += chunk
        }
        guard !x.isEmpty else { return [] }
        let step = max(1, x.count / count)
        let peaks = stride(from: 0, to: x.count, by: step).map { i in x[i..<min(x.count, i + step)].reduce(0) { max($0, abs($1)) } }
        let top = max(peaks.max() ?? 1, 0.0001)
        return peaks.prefix(count).map { $0 / top }
    }

    /// Integrated loudness of the whole file, LUFS — ffmpeg's ebur128, the last «I:» it prints.
    static func loudness(_ url: URL, ffmpeg: String) async -> Double? {
        await Task.detached(priority: .utility) { () -> Double? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostats", "-hide_banner", "-i", url.path, "-af", "ebur128=framelog=quiet", "-f", "null", "-"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let line = lines.last(where: { $0.hasPrefix("I:") }) else { return nil }
            return Double(line.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
        }.value
    }

    /// The gain that keeps a music bed as loud as it was with another track: `gain · 10^((old − new) / 20)`, to 4 places.
    public static func matched(gain: Double, from old: Double, to new: Double) -> Double {
        (gain * pow(10, (old - new) / 20) * 10_000).rounded() / 10_000
    }

    // MARK: Where it is used

    /// Which projects in `folder` have each track as their music: the file's path → their short names («504», else the
    /// project's name), in name order.
    public static func usage(projectsIn folder: URL) -> [String: [String]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".simbia") && !$0.hasPrefix("._") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var out: [String: [String]] = [:]
        for name in names {
            let file = folder.appending(path: name)
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audio = json["audio"] as? [[String: Any]] else { continue }
            let short = shortName(name)
            for clip in audio where (clip["role"] as? String) == "music" {
                guard let src = clip["src"] as? String else { continue }
                let path = Project.resolve(src, relativeTo: file).standardizedFileURL.path
                if out[path]?.contains(short) != true { out[path, default: []].append(short) }
            }
        }
        return out
    }

    /// «VD 12 DEMO AD - HOOK.simbia» → «12»; any other name without its extension.
    public static func shortName(_ file: String) -> String {
        if let r = file.range(of: #"^VD\s*(\d+)"#, options: .regularExpression) {
            return String(file[r].drop { !$0.isNumber })
        }
        return (file as NSString).deletingPathExtension
    }
}
