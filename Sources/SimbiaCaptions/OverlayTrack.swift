import AVFoundation
import AppKit
import SimbiaCore
import SwiftUI

extension Job {
    /// The overlay track's videos: each covers the shots under it while it plays, the edit's timing stays as it is.
    var layers: [Shot] { project?.layers ?? [] }

    func isLayer(_ id: String) -> Bool { layers.contains { $0.id == id } }

    /// A video laid over the picture from `time`, as long as the clip runs (to the edit's end at most).
    func addLayer(_ url: URL, at time: Double, inPoint: Double = 0, label: String? = nil) {
        ensureProject()
        let file = url.resolvingSymlinksInPath()
        Task {
            let still = Project.stillTypes.contains(file.pathExtension.lowercased())
            let length = still ? 3 : ((try? await AVURLAsset(url: file).load(.duration).seconds) ?? 3) - inPoint
            guard var p = project else { return }
            let start = max(0, min(time, p.duration - 0.5))
            pushHistory()
            let layer = Shot(id: Project.newID("v"), start: start, end: min(p.duration, start + max(0.5, length)), src: file.path,
                             inPoint: inPoint, label: label ?? file.deletingPathExtension().lastPathComponent)
            p.layers.append(layer)
            p.layers.sort { $0.start < $1.start }
            project = p
            focus = .shot(layer.id)
        }
    }

    func deleteLayer(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        p.layers.removeAll { $0.id == id }
        project = p
        shotTools = nil
        focus = .caption
    }

    /// The clip window for a new video over the picture at `time`: the project's generations, else the library.
    func openClipsForLayer(at time: Double) {
        if clipsFolder != nil {
            clipsShot = nil
            clipsInsertAfter = nil
            shotTools = nil
            player.pause()
            withAnimation(Theme.settle) { clipsOpen = true }
        } else {
            openGallery(for: nil)
        }
        layerAt = time
    }
}

/// «Наложение»: videos over the shots. Drag one to move it, an edge to trim it; a click picks it (the shot window,
/// crop and colour work on it), a double click swaps its video, ⌫ removes it. A double or right click on an empty
/// stretch lays a new one there from the clip window, and a video dropped from Finder lands where it is dropped.
struct LayerTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    @State private var dropping = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(dropping ? 0.14 : 0.04))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { job.seek(scale.time(at: Double($0.location.x))) })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { job.openClipsForLayer(at: scale.time(at: Double($0.location.x))) })
                .help(job.t("Двойной или правый клик — положить видео поверх отсюда; можно перетащить файл из Finder",
                            "Double- or right-click to lay a video over the picture from here, or drop a file from Finder", "Double-clic ou clic droit pour superposer une vidéo à l’image à partir d’ici, ou déposer un fichier depuis le Finder"))
            let layers = job.layers
            ForEach(layers) { layer in
                if scale.visible(layer.start, layer.end) {
                    LayerCell(job: job, layer: layer, scale: scale).offset(x: scale.x(layer.start))
                }
            }
            // a right click on a video opens its window (the shot window); on an empty stretch, the project's videos
            RightClicks { x in
                let t = scale.time(at: x)
                guard let layer = layers.last(where: { t >= $0.start && t < $0.end }) else {
                    job.openClipsForLayer(at: t)
                    return true
                }
                withAnimation(Theme.snappy) { job.focus = .shot(layer.id) }
                if job.currentTime < layer.start || job.currentTime >= layer.end { job.seek(layer.start) }
                job.shotTools = layer.id
                return true
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .dropDestination(for: URL.self) { urls, point in
            guard let url = urls.first else { return false }
            job.addLayer(url, at: scale.time(at: Double(point.x)))
            return true
        } isTargeted: { dropping = $0 }
    }
}

private struct LayerCell: View {
    @ObservedObject var job: Job
    let layer: Shot
    let scale: TimeScale
    @ObservedObject private var media = MediaCache.shared
    /// The video as it was when a drag began.
    @State private var anchor: Shot?
    /// How long its file runs: the right edge can't go past the footage.
    @State private var length: Double?

    private enum Grip { case body, start, end }

    private var selected: Bool { job.focus == .shot(layer.id) }
    private var width: Double { max(8, scale.x(layer.end) - scale.x(layer.start) - 2) }
    private var height: CGFloat { MultiTimeline.heights.layers }
    private static let tint = Color(red: 0.93, green: 0.52, blue: 0.2)

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 5) {
                if width > 30 {
                    Group {
                        if let image = media.thumbnail(layer, projectURL: job.projectURL) {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 20, height: height - 8)
                    .scaleEffect(x: layer.flip ? -1 : 1, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                if width > 56 {
                    Text(layer.label ?? (layer.src as NSString).lastPathComponent)
                        .font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(width: width, height: height, alignment: .leading)
            .background(Self.tint.opacity(selected ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.white : Self.tint.opacity(0.9), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { location in
                withAnimation(Theme.snappy) { job.focus = .shot(layer.id) }
                job.seek(min(layer.end - 0.001, layer.start + location.x * scale.secondsPerPoint))   // the playhead where the click was
                job.shotTools = nil
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                job.clipsFolder != nil ? job.openClips(for: layer.id) : job.openGallery(for: layer.id)
            })
            .gesture(drag(.body))
            .popover(isPresented: Binding(get: { job.shotTools == layer.id },
                                          set: { if !$0, job.shotTools == layer.id { job.shotTools = nil } }),
                     arrowEdge: .top) {
                if let current = job.shot(layer.id) { ShotTools(job: job, shot: current).preferredColorScheme(.dark) }
            }
            .help("\(layer.label ?? layer.src)\n\(clock(layer.start)) – \(clock(layer.end))")

            if width > 30 || anchor != nil {
                HStack(spacing: 0) {
                    edge(.start)
                    Spacer(minLength: 0)
                    edge(.end)
                }
                .frame(width: width, height: height)
            }
            if layer.flagged {
                Circle().fill(Theme.flag).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                    .padding(5)
                    .frame(width: width, height: height, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .task(id: layer.src) {
            let url = Project.resolve(layer.src, relativeTo: job.projectURL)
            length = Project.stillTypes.contains(url.pathExtension.lowercased()) ? nil : try? await AVURLAsset(url: url).load(.duration).seconds
        }
        .onDisappear { if anchor != nil { finish() } }
    }

    private func edge(_ grip: Grip) -> some View {
        Rectangle().fill(Color.clear).frame(width: 10, height: height)
            .contentShape(Rectangle())
            .overlay(Capsule().fill(Color.white.opacity(0.75)).frame(width: 3, height: 16))
            .gesture(drag(grip))
            .pointerStyle(.columnResize)
    }

    private func finish() {
        anchor = nil
        job.sync.holdRebuild = false
        job.rebuildIfPictureChanged()
    }

    /// Moves the video or trims an edge (the left one starts it later in its footage); edges stick to cuts and beats.
    private func drag(_ grip: Grip) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if anchor == nil { anchor = layer; job.pushHistory(); job.sync.holdRebuild = true; job.focus = .shot(layer.id); job.shotTools = nil }
                guard let a = anchor else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let tolerance = scale.secondsPerPoint * 6
                let cuts = job.shots.flatMap { [$0.start, $0.end] }
                @MainActor func stick(_ t: Double) -> Double {
                    cuts.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) <= tolerance ? $0 : nil } ?? job.snapToGrid(t, tolerance: tolerance)
                }
                var v = a
                switch grip {
                case .body:
                    let s = stick(a.start + delta), e = stick(a.end + delta) - a.duration
                    v.start = max(0, abs(s - (a.start + delta)) <= abs(e - (a.start + delta)) ? s : e)
                    v.end = v.start + a.duration
                case .start:
                    v.start = min(max(stick(a.start + delta), max(0, a.start - a.inPoint / a.speed)), a.end - 0.2)
                    v.inPoint = a.source(at: v.start)
                case .end:
                    let most = length.map { a.start + ($0 - a.inPoint) / a.speed } ?? .infinity
                    v.end = max(a.start + 0.2, min(stick(a.end + delta), most, job.duration))
                }
                job.updateShot(layer.id, undoable: false) { $0.start = v.start; $0.end = v.end; $0.inPoint = v.inPoint }
                switch grip {                                   // the frame the trim leaves at that edge, over the picture
                case .start: job.showEdges(.first, of: layer.id)
                case .end: job.showEdges(.last, of: layer.id)
                case .body: break
                }
            }
            .onEnded { _ in EdgePreview.shared.clear(); finish() }
    }
}
