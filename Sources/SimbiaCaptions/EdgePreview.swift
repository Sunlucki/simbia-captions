import AVFoundation
import SimbiaCore
import SwiftUI

/// The frames a trim or a slip on the timeline leaves at a shot's edges, shown over the picture while the drag lasts, as
/// Final Cut shows them: one frame — the shot's new first (its start trimmed) or last (its end trimmed); two side by
/// side — the last frame before a rolled cut and the first after it, or a slipped shot's first and last. The footage's
/// own frames (mirrored with the shot); only the newest asked for is loaded, so a fast drag never queues up.
@MainActor final class EdgePreview: ObservableObject {
    static let shared = EdgePreview()

    struct Edge: Equatable {
        let file: URL
        /// Seconds into the file.
        let time: Double
        let flip: Bool
        let label: String
    }

    /// What is on show: the edges and their frames (nil while one could not be read).
    @Published private(set) var shown: [Edge] = []
    @Published private(set) var images: [CGImage?] = []
    private var wanted: [Edge] = []
    private var loading = false

    func show(_ edges: [Edge]) {
        wanted = edges
        guard !loading, !edges.isEmpty else { return }
        loading = true
        Task { await load() }
    }

    func clear() {
        wanted = []; shown = []; images = []
    }

    private func load() async {
        while !wanted.isEmpty, wanted != shown {
            let now = wanted
            var out: [CGImage?] = []
            for edge in now { out.append(await Self.frame(edge)) }
            guard !wanted.isEmpty else { break }                    // let go meanwhile
            shown = now; images = out
        }
        loading = false
        if wanted.isEmpty { shown = []; images = [] }
    }

    /// The footage's frame at the edge, read off the main thread (a generator per frame: only the newest is asked for).
    nonisolated private static func frame(_ edge: Edge) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: edge.file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1080)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: max(0, edge.time), preferredTimescale: 600)).image
    }
}

extension Job {
    enum EdgeKind { case first, last, both, cut }

    /// The edges of shot (or overlay-track video) `id` to show while it is trimmed or slipped: its `first` frame, its
    /// `last`, `both`, or — `cut`, the cut after it rolled — its last and the next shot's first. A still has none.
    func showEdges(_ kind: EdgeKind, of id: String) {
        guard let s = shot(id) else { return }
        let frame = 1 / max(project?.canvas.fps ?? 30, 1)
        func edge(_ s: Shot, last: Bool) -> EdgePreview.Edge? {
            guard !Project.stillTypes.contains((s.src as NSString).pathExtension.lowercased()) else { return nil }
            let time = last ? s.source(at: max(s.start, s.end - frame)) : s.inPoint
            return EdgePreview.Edge(file: Project.resolve(s.src, relativeTo: projectURL), time: time, flip: s.flip,
                                    label: (last ? t("последний кадр", "last frame", "dernière image") : t("первый кадр", "first frame", "première image"))
                                        + String(format: " · %.2f ", time) + t("с", "s"))
        }
        var edges: [EdgePreview.Edge?]
        switch kind {
        case .first: edges = [edge(s, last: false)]
        case .last: edges = [edge(s, last: true)]
        case .both: edges = [edge(s, last: false), edge(s, last: true)]
        case .cut:
            let next = shots.filter { $0.start >= s.end - 0.001 }.min { $0.start < $1.start }
            edges = [edge(s, last: true), next.flatMap { edge($0, last: false) }]
        }
        EdgePreview.shared.show(edges.compactMap { $0 })
    }
}

/// Over the picture while a trim or a slip lasts: the edge frames, one filling the picture, two side by side.
struct EdgeFrames: View {
    @ObservedObject var preview = EdgePreview.shared

    var body: some View {
        if !preview.shown.isEmpty {
            ZStack {
                Color.black
                HStack(spacing: 4) {
                    ForEach(Array(preview.shown.enumerated()), id: \.offset) { k, edge in
                        Group {
                            if k < preview.images.count, let image = preview.images[k] {
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    .scaleEffect(x: edge.flip ? -1 : 1, y: 1)
                                    .overlay(alignment: .topLeading) { label(edge) }
                            } else {
                                Color.white.opacity(0.06).overlay(alignment: .topLeading) { label(edge) }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func label(_ edge: EdgePreview.Edge) -> some View {
        Text(edge.label)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(8)
    }
}
