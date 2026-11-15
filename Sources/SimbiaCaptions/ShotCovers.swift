import AVFoundation
import AppKit
import Combine
import CoreImage
import SimbiaCore
import SwiftUI

extension Job {
    /// «Закрыть текст» for a shot: the picture shows its footage's whole frame with the zones painted over (`Covers`),
    /// to draw, move and size them.
    func beginCovers(_ id: String) {
        guard let s = shot(id) else { return }
        player.pause()
        if currentTime < s.start || currentTime >= s.end { seek(min(s.end - 0.05, s.start + 0.1)) }
        shotTools = nil
        cropShot = nil
        focus = .shot(id)
        coverShot = id
    }
}

/// On the paused picture beside «Кадрировать»: «Закрыть текст» for the same shot.
struct CoverButton: View {
    @ObservedObject var job: Job
    @ObservedObject var clock: PlayClock

    private var target: Shot? {
        if case .shot(let id) = job.focus, let s = job.shot(id) { return s }
        return job.layers.last { $0.start <= job.currentTime && job.currentTime < $0.end }
            ?? job.shots.first { $0.start <= job.currentTime && job.currentTime < $0.end }
    }

    var body: some View {
        if !clock.playing, let shot = target {
            Button { job.beginCovers(shot.id) } label: {
                Label(job.t("Закрыть текст", "Cover text", "Masquer le texte") + (shot.covers.isEmpty ? "" : " · \(shot.covers.count)"), systemImage: "eraser")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .glassBar(15)
            }
            .buttonStyle(BouncyButtonStyle())
            .help(job.t("Закрасить вшитые субтитры или логотип на этом шоте: пиксели зоны берутся из её краёв",
                        "Paint over burned-in captions or a logo on this shot: the zone takes its pixels from its edges", "Masquer des sous-titres incrustés ou un logo sur ce plan : la zone prend ses pixels sur ses bords"))
        }
    }
}

/// Over the picture while a shot's covers are edited: its footage's whole frame at the playhead with the zones painted
/// over, each zone a dashed box — drag it to move, a corner to size it; a click on the frame picks none. «Найти текст»
/// lets Vision find the burned-in text across the shot and covers it; «+ Зона» adds one where captions usually sit.
/// Every finished drag is one undo step; «Готово» / Esc closes.
struct CoverOverlay: View {
    @ObservedObject var job: Job
    let shot: Shot
    @State private var source: CGImage?
    @State private var painted: CGImage?
    @State private var zones: [CoverZone] = []
    @State private var picked: Int?
    @State private var dragStart: CoverZone?
    @State private var finding = false
    @State private var shownAt = -1.0

    private static let ci = CIContext(options: [.workingColorSpace: NSNull()])

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = painted ?? source {
                    let size = CGSize(width: image.width, height: image.height)
                    let d = min(proxy.size.width / size.width, proxy.size.height / size.height)
                    let shown = CGRect(x: (proxy.size.width - size.width * d) / 2, y: (proxy.size.height - size.height * d) / 2,
                                       width: size.width * d, height: size.height * d)
                    Image(decorative: image, scale: 1).resizable().frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                        .onTapGesture { picked = nil }
                    ForEach(zones.indices, id: \.self) { i in
                        let z = zones[i]
                        let r = CGRect(x: shown.minX + z.x * shown.width, y: shown.minY + z.y * shown.height, width: z.w * shown.width, height: z.h * shown.height)
                        let on = picked == i
                        Rectangle().stroke(on ? Color.white : Color(red: 1, green: 0.8, blue: 0.3), style: StrokeStyle(lineWidth: on ? 2 : 1.5, dash: [6, 4]))
                            .background(Color.white.opacity(on ? 0.06 : 0.001))
                            .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                            .contentShape(Rectangle())
                            .onTapGesture { picked = i }
                            .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                                picked = i
                                let from = dragStart ?? z; dragStart = from
                                zones[i].x = min(max(0, from.x + v.translation.width / shown.width), 1 - from.w)
                                zones[i].y = min(max(0, from.y + v.translation.height / shown.height), 1 - from.h)
                            }.onEnded { _ in dragStart = nil; keep() })
                            .pointerStyle(.grabIdle)
                        if on {
                            ForEach(0..<4, id: \.self) { corner in
                                let at = CGPoint(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                                Circle().fill(Color.white).overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                                    .frame(width: 14, height: 14).frame(width: 30, height: 30).contentShape(Rectangle())
                                    .position(at)
                                    .gesture(DragGesture().onChanged { v in resize(i, corner, by: CGSize(width: v.translation.width / shown.width,
                                                                                                       height: v.translation.height / shown.height)) }
                                        .onEnded { _ in dragStart = nil; keep() })
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack {
                    HStack(spacing: 8) {
                        Pill(finding ? job.t("Ищу текст…", "Finding text…", "Recherche du texte…") : job.t("Найти текст", "Find text", "Trouver le texte")) { find() }.disabled(finding)
                        Pill(job.t("+ Зона", "+ Zone")) {
                            zones.append(CoverZone(x: 0.2, y: 0.68, w: 0.6, h: 0.1)); picked = zones.count - 1; keep()
                        }
                        Pill(job.t("Готово", "Done", "Terminé"), primary: true) { job.coverShot = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                    Spacer()
                    if let i = picked, zones.indices.contains(i) { zoneBar(i).padding(.bottom, 84) }
                }
            }
        }
        .task(id: shot.id) { zones = shot.covers; await load(at: job.currentTime) }
        .onChange(of: zones) { repaint() }
        // the picture follows the playhead: moved on the timeline, the frame there is loaded
        .onReceive(job.clock.ticks.debounce(for: .milliseconds(120), scheduler: RunLoop.main)) { t in
            guard abs(t - shownAt) > 0.01, t >= shot.start, t < shot.end else { return }
            Task { await load(at: t) }
        }
    }

    /// The picked zone: fill or blur, how soft its edge is, and taking it away.
    private func zoneBar(_ i: Int) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { zones[i].mode }, set: { zones[i].mode = $0; keep() })) {
                Text(job.t("Заливка", "Fill", "Remplissage")).tag("fill")
                Text(job.t("Размытие", "Blur", "Flou")).tag("blur")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            Text(job.t("Край", "Edge", "Bord")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Slider(value: Binding(get: { zones[i].soft }, set: { zones[i].soft = $0 }), in: 0...1, onEditingChanged: { if !$0 { keep() } })
                .tint(.white).controlSize(.small)
            Button { zones.remove(at: i); picked = nil; keep() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.text).help(job.t("Удалить зону", "Delete the zone", "Supprimer la zone"))
        }
        .padding(.horizontal, 14).frame(height: 40)
        .glassBar(20)
        .padding(.horizontal, 12)
    }

    /// A corner dragged: the opposite one stays, the zone keeps at least 2 % a side and stays on the frame.
    private func resize(_ i: Int, _ corner: Int, by d: CGSize) {
        let from = dragStart ?? zones[i]; dragStart = from
        var x0 = from.x, y0 = from.y, x1 = from.x + from.w, y1 = from.y + from.h
        if corner % 2 == 0 { x0 = min(max(0, x0 + d.width), x1 - 0.02) } else { x1 = max(min(1, x1 + d.width), x0 + 0.02) }
        if corner < 2 { y0 = min(max(0, y0 + d.height), y1 - 0.02) } else { y1 = max(min(1, y1 + d.height), y0 + 0.02) }
        zones[i].x = x0; zones[i].y = y0; zones[i].w = x1 - x0; zones[i].h = y1 - y0
    }

    /// The zones into the shot: one undo step, the preview rebuilt.
    private func keep() {
        let list = zones
        guard job.shot(shot.id)?.covers != list else { return }
        job.updateShot(shot.id) { $0.covers = list }
    }

    /// Vision reads the shot's footage and the text it finds becomes the zones (the ones drawn by hand are kept).
    private func find() {
        finding = true
        let url = Project.resolve(shot.src, relativeTo: job.projectURL)
        let aspect = Double(job.project?.canvas.width ?? 1080) / Double(job.project?.canvas.height ?? 1920)
        Task {
            let found = await Covers.findText(in: url, from: shot.inPoint, to: shot.inPoint + shot.footage, rotation: shot.rotation, aspect: aspect)
            finding = false
            guard !found.isEmpty else { job.show(job.t("Текста на этом шоте не нашлось", "No text found on this shot", "Aucun texte trouvé sur ce plan"), isError: false); return }
            zones += found
            picked = zones.count - 1
            keep()
        }
    }

    private func repaint() {
        guard let source else { painted = nil; return }
        let out = Covers.apply(CIImage(cgImage: source), zones)
        painted = Self.ci.createCGImage(out, from: out.extent)
    }

    /// The footage's frame at `time` on the edit, turned as the shot shows it.
    private func load(at time: Double) async {
        let url = Project.resolve(shot.src, relativeTo: job.projectURL)
        var still: CGImage?
        if Project.stillTypes.contains(url.pathExtension.lowercased()) {
            still = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            still = try? await generator.image(at: CMTime(seconds: shot.inPoint + max(0, min(shot.duration, time - shot.start)) * shot.speed, preferredTimescale: 600)).image
        }
        guard let still else { return }
        shownAt = time
        let aspect = Double(job.project?.canvas.width ?? 1080) / Double(job.project?.canvas.height ?? 1920)
        source = CropOverlay.turned(still, shot.rotation, aspect: aspect) ?? still
        repaint()
    }
}
