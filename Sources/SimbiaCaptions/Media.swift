import AppKit
import AVFoundation
import ImageIO
import SimbiaCore

/// CGImage across the actor boundary — it is immutable once made.
private struct Frozen: @unchecked Sendable { let image: CGImage? }

/// Shot thumbnails and sound outlines for the timeline, made in the background and kept for the
/// session. Views ask; the first ask starts the work and returns nil, the result republishes.
@MainActor final class MediaCache: ObservableObject {
    static let shared = MediaCache()

    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var envelopes: [String: [Float]] = [:]
    @Published private(set) var duck: [String: [Float]] = [:]
    private var lastDuck: [String: [Float]] = [:]
    private var duckWanted: [String: (key: String, project: Project, clip: AudioClip, projectURL: URL?)] = [:]
    private var duckRunning: String?
    @Published private(set) var tempos: [String: Tempo.Found] = [:]
    private var pending: Set<String> = []
    /// Thumbnails that could not be made (a missing clip): not tried again on every redraw.
    private var failed: Set<String> = []

    // MARK: Thumbnails

    func thumbnail(_ shot: Shot, projectURL: URL?) -> CGImage? {
        let url = Project.resolve(shot.src, relativeTo: projectURL)
        let time = shot.inPoint + min(shot.duration / 2, 1.0) * shot.speed
        let key = "\(url.path)#\(Int(time * 10))"
        if let image = thumbnails[key] { return image }
        guard !failed.contains(key), pending.insert(key).inserted else { return nil }
        Task.detached(priority: .utility) {
            let made = Frozen(image: await Self.makeThumbnail(url: url, at: time))
            await MainActor.run {
                self.pending.remove(key)
                if let image = made.image { self.thumbnails[key] = image } else { self.failed.insert(key) }
            }
        }
        return nil
    }

    nonisolated private static func makeThumbnail(url: URL, at time: Double) async -> CGImage? {
        if Project.stillTypes.contains(url.pathExtension.lowercased()) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            return try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        } catch {
            NSLog("Simbia thumbnail failed for %@ at %.2f: %@", url.path, time, error.localizedDescription)
            return nil
        }
    }

    // MARK: Sound

    /// RMS outline of a clip's whole source, 50 values per second from the start of the file (not of the clip).
    /// The file is read once at 0 dB; the gain is applied here and the drawing picks the clip's stretch, so
    /// dragging the volume, or trimming and moving the clip, never decodes the track again.
    func envelope(_ clip: AudioClip, projectURL: URL?) -> [Float]? {
        let key = Project.resolve(clip.src, relativeTo: projectURL).path
        if let values = envelopes[key] { return clip.gain == 1 ? values : values.map { $0 * Float(clip.gain) } }
        guard pending.insert(key).inserted else { return nil }
        let unit = AudioClip(id: clip.id, role: clip.role, src: clip.src)
        Task.detached(priority: .utility) { [unit] in
            let values = (try? await Project.envelope(of: unit, projectURL: projectURL, rate: 50)) ?? []
            await MainActor.run { self.pending.remove(key); self.envelopes[key] = values }
        }
        return nil
    }

    /// How long the clip's source is, once its outline has been read.
    func length(_ clip: AudioClip, projectURL: URL?) -> Double? {
        envelopes[Project.resolve(clip.src, relativeTo: projectURL).path].map { Double($0.count) / 50 }
    }

    /// The tempo and first downbeat of a music file, found once per file.
    func tempo(_ clip: AudioClip, projectURL: URL?) -> Tempo.Found? {
        let url = Project.resolve(clip.src, relativeTo: projectURL)
        let key = "tempo:" + url.path
        if let found = tempos[url.path] { return found }
        guard !failed.contains(key), pending.insert(key).inserted else { return nil }
        Task.detached(priority: .utility) {
            let found = (try? await Tempo.detect(url)) ?? nil
            await MainActor.run {
                self.pending.remove(key)
                if let found { self.tempos[url.path] = found } else { self.failed.insert(key) }
            }
        }
        return nil
    }

    /// How far a music clip dips under the voice, 100 values per second on the edit's clock. One analysis at a time,
    /// the newest wanted state per clip next: a drag on the sound changes the voice many times a second, and an
    /// analysis for every step used to pile up. Until the new curve is ready the clip's last one is shown.
    func duckCurve(_ project: Project, clip: AudioClip, projectURL: URL?) -> [Float]? {
        let key = project.audio.filter { $0.role == .voice }.map { "\($0.src)#\($0.start)#\($0.inPoint)#\($0.gain)#\($0.speed)" }.joined(separator: "|")
            + (clip.sidechain.map { "|sc \($0.depth),\($0.attack),\($0.release)" } ?? "")
        if let values = duck[key] { lastDuck[clip.id] = values; return values }
        if duckRunning != key { duckWanted[clip.id] = (key, project, clip, projectURL) }
        nextDuck()
        return lastDuck[clip.id]
    }

    private func nextDuck() {
        guard duckRunning == nil, let (id, job) = duckWanted.first else { return }
        duckWanted[id] = nil
        duckRunning = job.key
        Task.detached(priority: .utility) {
            let values = (try? await job.project.duckCurve(for: job.clip, projectURL: job.projectURL)) ?? []
            await MainActor.run {
                if self.duck.count > 24 { self.duck.removeAll() }
                self.duck[job.key] = values
                self.duckRunning = nil
                self.nextDuck()
            }
        }
    }
}
