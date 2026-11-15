import AVFoundation
import AppKit
import Combine
import CoreImage
import SimbiaCore
import SwiftUI

extension Job {
    /// Crop mode for a shot: the picture shows the whole frame of its footage and the part the edit uses as a box
    /// to move and resize («Кадрировать» in the shot window).
    func beginCrop(_ id: String) {
        guard let s = shot(id) else { return }
        coverShot = nil
        player.pause()
        if currentTime < s.start || currentTime >= s.end { seek(min(s.end - 0.05, s.start + 0.1)) }
        shotTools = nil
        focus = .shot(id)
        cropShot = id
    }

    /// Keeps the box and the turn: one undo step. A shot with crop keys keeps the box as the key at the playhead.
    func applyCrop(_ id: String, scale: Double, panX: Double, panY: Double, rotation: Double) {
        if shot(id)?.keys.isEmpty == false { setCropKey(id, scale: scale, panX: panX, panY: panY, rotation: rotation); return }
        updateShot(id) { $0.scale = scale; $0.panX = panX; $0.panY = panY; $0.rotation = rotation }
        cropShot = nil
    }

    /// The box as a crop key at the playhead (a key within half a frame of it is replaced); the shot's frame then
    /// glides from key to key. One undo step.
    func setCropKey(_ id: String, scale: Double, panX: Double, panY: Double, rotation: Double, close: Bool = true) {
        guard let s = shot(id) else { return }
        let t = s.inPoint + max(0, min(s.duration, currentTime - s.start)) * s.speed, half = 0.5 / max(project?.canvas.fps ?? 30, 1)
        updateShot(id) {
            $0.keys.removeAll { abs($0.t - t) < half }
            $0.keys.append(CropKey(t: t, scale: scale, panX: panX, panY: panY))
            $0.keys.sort { $0.t < $1.t }
            $0.rotation = rotation
        }
        if close { cropShot = nil }
    }

    /// A key dragged on the key track to `time` on the edit: it stays inside its shot and between its neighbours.
    func moveCropKey(_ id: String, _ index: Int, to time: Double, undoable: Bool = true) {
        guard let s = shot(id), s.keys.indices.contains(index) else { return }
        let frame = 1 / max(project?.canvas.fps ?? 30, 1)
        let lo = max(s.inPoint, index > 0 ? s.keys[index - 1].t + frame : -.infinity)
        let hi = min(s.inPoint + s.footage, index + 1 < s.keys.count ? s.keys[index + 1].t - frame : .infinity)
        guard lo <= hi else { return }
        let t = min(hi, max(lo, s.source(at: time)))
        guard abs(t - s.keys[index].t) > 0.0005 else { return }
        updateShot(id, undoable: undoable) { $0.keys[index].t = t }
    }

    func deleteCropKey(_ id: String, _ index: Int) {
        guard shot(id)?.keys.indices.contains(index) == true else { return }
        updateShot(id) { $0.keys.remove(at: index) }
    }
}

/// On the paused picture: «Кадрировать» for the picked shot, else the one under the playhead.
struct CropButton: View {
    @ObservedObject var job: Job
    @ObservedObject var clock: PlayClock

    private var target: Shot? {
        if case .shot(let id) = job.focus, let s = job.shot(id) { return s }
        return job.layers.last { $0.start <= job.currentTime && job.currentTime < $0.end }        // what is on the picture
            ?? job.shots.first { $0.start <= job.currentTime && job.currentTime < $0.end }
    }

    var body: some View {
        if !clock.playing, let shot = target {
            Button { job.beginCrop(shot.id) } label: {
                Label(job.t("Кадрировать", "Crop", "Recadrer") + (shot.keys.isEmpty ? (shot.scale > 1.001 ? " · \(Int((shot.scale * 100).rounded())) %" : "")
                                                      : " · ◆ \(shot.keys.count)")
                      + (abs(shot.rotation) > 0.05 ? " · \(Self.degrees(shot.rotation))" : ""), systemImage: "crop")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: 30)
                    .glassBar(15)
            }
            .buttonStyle(BouncyButtonStyle())
            .help(job.t("Рамка на картинке: двигать и тянуть за углы — что войдёт в кадр этого шота; можно повернуть",
                        "A box on the picture: move it and drag its corners to choose what this shot shows; it can be turned", "Un cadre sur l’image : le déplacer et tirer ses coins pour choisir ce que montre ce plan ; il peut pivoter"))
        }
    }

    /// 12.5 → «12.5°», whole degrees without the fraction.
    static func degrees(_ d: Double) -> String {
        let r = (d * 10).rounded() / 10
        return (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)) + "°"
    }
}

/// Over the picture while a shot is cropped: its footage's whole frame (as it is at the playhead), dimmed outside
/// the box the edit shows. Drag inside the box to move it, a corner to resize it (the frame's proportions stay);
/// the turn bar rotates the footage (a quarter turn either way, or ±45° by the slider) and the box keeps its zoom
/// and place; «Готово» / ↩ keeps it, «Отмена» / Esc leaves the shot as it was. «Ключ в этой точке» keeps the box as
/// a key at the playhead: with two or more the frame glides from one to the next (a shot with keys keeps every «Готово» as one).
struct CropOverlay: View {
    @ObservedObject var job: Job
    let shot: Shot
    /// The footage's frame as filmed, and as turned (what the box sits on).
    @State private var source: CGImage?
    @State private var image: CGImage?
    /// Degrees clockwise, −180…180.
    @State private var rotation = 0.0
    /// The box in the footage's pixels (top-left origin), while it is being set.
    @State private var box: CGRect?
    @State private var dragStart: CGRect?
    /// The zoom when a pinch began.
    @State private var pinchStart: Double?
    /// Where on the edit the frame shown was taken.
    @State private var shownAt = -1.0

    private static let maxScale = 4.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image, let box {
                    let size = CGSize(width: image.width, height: image.height)
                    let d = min(proxy.size.width / size.width, proxy.size.height / size.height)
                    let shown = CGRect(x: (proxy.size.width - size.width * d) / 2, y: (proxy.size.height - size.height * d) / 2,
                                       width: size.width * d, height: size.height * d)
                    let r = CGRect(x: shown.minX + box.minX * d, y: shown.minY + box.minY * d, width: box.width * d, height: box.height * d)
                    Image(decorative: image, scale: 1).resizable().frame(width: shown.width, height: shown.height)
                        .position(x: shown.midX, y: shown.midY)
                    // what stays out of the frame
                    Path { p in p.addRect(shown); p.addRect(r) }
                        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    Path { p in
                        for k in 1...2 {
                            p.move(to: CGPoint(x: r.minX + r.width * Double(k) / 3, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * Double(k) / 3, y: r.maxY))
                            p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * Double(k) / 3)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * Double(k) / 3))
                        }
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    Rectangle().stroke(Color.white, lineWidth: 2).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { v in move(by: CGSize(width: v.translation.width / d, height: v.translation.height / d), in: size) }
                            .onEnded { _ in dragStart = nil; autoKey() })
                        .pointerStyle(.grabIdle)
                    ForEach(0..<4, id: \.self) { corner in
                        let at = CGPoint(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                        Circle().fill(Color.white).overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                            .frame(width: 16, height: 16)
                            .frame(width: 34, height: 34).contentShape(Rectangle())
                            .position(at)
                            .gesture(DragGesture().onChanged { v in resize(corner, by: CGSize(width: v.translation.width / d, height: v.translation.height / d), in: size) }
                                .onEnded { _ in dragStart = nil; autoKey() })
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack {
                    HStack(spacing: 8) {
                        Pill(job.t("Отмена", "Cancel", "Annuler")) { job.cropShot = nil }.keyboardShortcut(.cancelAction)
                        Pill(job.t("Без кадрирования", "No crop", "Sans recadrage")) {
                            setRotation(0)
                            if let image { box = Self.box(scale: 1, panX: 0, panY: 0, image: image, canvas: canvas) }
                            autoKey()
                        }
                        Pill(job.t("Готово", "Done", "Terminé"), primary: true) { done() }.keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                    Spacer()
                    VStack(spacing: 8) { keyBar; turnBar; zoomBar }.padding(.bottom, 84)       // over the player's bar
                }
            }
            .contentShape(Rectangle())
            // a pinch on the trackpad zooms like the slider
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    guard let image else { return }
                    let size = CGSize(width: image.width, height: image.height)
                    let from = pinchStart ?? zoom(size); pinchStart = from
                    setZoom(from * v.magnification, in: size)
                }
                .onEnded { _ in pinchStart = nil; autoKey() })
        }
        .task(id: shot.id) { await load(at: job.currentTime) }
        // the picture follows the playhead: moved on the timeline, the frame there is loaded (with keys, its box too)
        .onReceive(job.clock.ticks.debounce(for: .milliseconds(120), scheduler: RunLoop.main)) { t in
            guard abs(t - shownAt) > 0.01, t >= shot.start, t < shot.end else { return }
            Task { await load(at: t, keepBox: shot.keys.isEmpty) }
        }
    }

    /// How much bigger: the slider over the player's bar; the box grows or shrinks about its centre.
    @ViewBuilder private var zoomBar: some View {
        if let image {
            let size = CGSize(width: image.width, height: image.height)
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.muted)
                Slider(value: Binding(get: { zoom(size) }, set: { setZoom($0, in: size) }), in: 1...Self.maxScale,
                       onEditingChanged: { if !$0 { autoKey() } })
                    .tint(.white).controlSize(.small)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.muted)
                Text("\(Int((zoom(size) * 100).rounded())) %")
                    .font(.system(size: 12.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 14).frame(height: 40)
            .glassBar(20)
            .padding(.horizontal, 12)
        }
    }

    /// Crop keys: this box as a key at the playhead, how many the shot has, and taking them all away.
    @ViewBuilder private var keyBar: some View {
        if image != nil {
            HStack(spacing: 10) {
                Button { done(key: true) } label: {
                    Label(job.t("Ключ в этой точке", "Key here", "Clé ici"), systemImage: "diamond.fill").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.42))
                .help(job.t("Запомнить эту рамку в точке плейхеда: между ключами кадр плавно наезжает и движется",
                            "Keep this box at the playhead: between keys the frame glides — a push and a move", "Fixer ce cadre à la tête de lecture : entre les clés, l’image glisse — zoom et déplacement"))
                Spacer(minLength: 8)
                if !shot.keys.isEmpty {
                    Text(job.t(ruPlural(shot.keys.count, "ключ", "ключа", "ключей"), shot.keys.count == 1 ? "1 key" : "\(shot.keys.count) keys", shot.keys.count == 1 ? "1 clé" : "\(shot.keys.count) clés"))
                        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.muted)
                    Button { job.updateShot(shot.id) { $0.keys = [] }; job.cropShot = nil } label: {
                        Text(job.t("Убрать", "Remove", "Supprimer")).font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.text)
                    .help(job.t("Кадр снова один на весь шот — как до ключей", "One frame for the whole shot again, as before the keys", "De nouveau un seul cadre pour tout le plan, comme avant les clés"))
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            .glassBar(20)
            .padding(.horizontal, 12)
        }
    }

    /// The turn: a quarter turn either way, and the slider for the rest (±45°); a click on the degrees sets it straight.
    @ViewBuilder private var turnBar: some View {
        if source != nil {
            let quarter = (rotation / 90).rounded() * 90
            HStack(spacing: 10) {
                Button { setRotation(rotation - 90) } label: { Image(systemName: "rotate.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text).help(job.t("Повернуть на 90° влево", "Turn 90° left", "Pivoter de 90° à gauche"))
                Slider(value: Binding(get: { rotation - quarter }, set: { setRotation(quarter + $0) }), in: -45...45)
                    .tint(.white).controlSize(.small)
                Button { setRotation(rotation + 90) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text).help(job.t("Повернуть на 90° вправо", "Turn 90° right", "Pivoter de 90° à droite"))
                Button { setRotation(0) } label: {
                    Text(CropButton.degrees(rotation)).font(.system(size: 12.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text)
                        .frame(width: 48, alignment: .trailing)
                }
                .buttonStyle(.plain).help(job.t("Ровно — без поворота", "Straight — no turn", "Droit — sans rotation"))
            }
            .padding(.horizontal, 14).frame(height: 40)
            .glassBar(20)
            .padding(.horizontal, 12)
        }
    }

    /// Turns the footage; the box keeps its zoom and its place in the (new) picture.
    private func setRotation(_ degrees: Double) {
        guard let source else { return }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        if abs(d) < 0.05 { d = 0 }
        var z = 1.0, px = 0.0, py = 0.0
        if let image, let box {
            let iw = Double(image.width), ih = Double(image.height)
            let ox = iw - box.width, oy = ih - box.height
            px = ox > 0.5 ? box.minX / ox * 2 - 1 : 0; py = oy > 0.5 ? box.minY / oy * 2 - 1 : 0
            z = zoom(CGSize(width: iw, height: ih))
        }
        rotation = d
        guard let turned = Self.turned(source, d, aspect: canvas.width / canvas.height) else { return }
        image = turned
        box = Self.box(scale: z, panX: px, panY: py, image: turned, canvas: canvas)
    }

    private static let ci = CIContext(options: [.workingColorSpace: NSNull()])

    /// The footage's frame turned the way the renderer turns it (`Rotation`).
    static func turned(_ still: CGImage, _ degrees: Double, aspect: Double) -> CGImage? {
        guard abs(degrees) > 0.001 else { return still }
        let out = Rotation.apply(CIImage(cgImage: still), degrees: degrees, aspect: aspect)
        return ci.createCGImage(out, from: out.extent.integral)
    }

    private func setZoom(_ z: Double, in size: CGSize) {
        guard let current = box else { return }
        let k = max(canvas.width / size.width, canvas.height / size.height) * min(Self.maxScale, max(1, z))
        let w = canvas.width / k, h = canvas.height / k
        box = CGRect(x: min(max(0, current.midX - w / 2), size.width - w), y: min(max(0, current.midY - h / 2), size.height - h), width: w, height: h)
    }

    private var canvas: CGSize { CGSize(width: job.project?.canvas.width ?? 1080, height: job.project?.canvas.height ?? 1920) }

    /// How much bigger than filling the frame the box makes the picture.
    private func zoom(_ size: CGSize) -> Double {
        guard let box, box.width > 0 else { return 1 }
        let fill = max(canvas.width / size.width, canvas.height / size.height)
        return canvas.width / (fill * box.width)
    }

    /// The footage's frame at `time` on the edit; without keys a box already set stays as it is.
    private func load(at time: Double, keepBox: Bool = false) async {
        let url = Project.resolve(shot.src, relativeTo: job.projectURL)
        var still: CGImage?
        if Project.stillTypes.contains(url.pathExtension.lowercased()) {
            still = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let at = shot.inPoint + max(0, min(shot.duration, time - shot.start)) * shot.speed
            still = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
        }
        guard let still else { return }
        shownAt = time
        if keepBox, box != nil, still.width == source?.width, still.height == source?.height {
            source = still
            image = Self.turned(still, rotation, aspect: canvas.width / canvas.height) ?? still
            return
        }
        source = still
        rotation = shot.rotation
        let turned = Self.turned(still, shot.rotation, aspect: canvas.width / canvas.height) ?? still
        image = turned
        let f = shot.framing(at: time)                                              // with keys: the frame as it is here
        box = Self.box(scale: f.scale, panX: shot.flip ? -f.panX : f.panX, panY: f.panY, image: turned, canvas: canvas)
    }

    /// The part of the footage a shot shows — the renderer's `fill` with its scale and pan, read back.
    static func box(scale: Double, panX: Double, panY: Double, image: CGImage, canvas: CGSize) -> CGRect {
        let iw = Double(image.width), ih = Double(image.height)
        let k = max(canvas.width / iw, canvas.height / ih) * max(1, scale)
        let w = canvas.width / k, h = canvas.height / k
        return CGRect(x: (iw - w) * (1 + panX) / 2, y: (ih - h) * (1 + panY) / 2, width: w, height: h)
    }

    private func move(by d: CGSize, in size: CGSize) {
        guard let current = box else { return }
        let from = dragStart ?? current; dragStart = from
        box = CGRect(x: min(max(0, from.minX + d.width), size.width - from.width),
                     y: min(max(0, from.minY + d.height), size.height - from.height), width: from.width, height: from.height)
    }

    /// A corner dragged: the opposite one stays put, the box keeps the frame's proportions and stays on the footage.
    private func resize(_ corner: Int, by d: CGSize, in size: CGSize) {
        guard let current = box else { return }
        let from = dragStart ?? current; dragStart = from
        let aspect = from.width / from.height
        let anchor = CGPoint(x: corner % 2 == 0 ? from.maxX : from.minX, y: corner < 2 ? from.maxY : from.minY)
        let dx = corner % 2 == 0 ? -d.width : d.width, dy = corner < 2 ? -d.height : d.height
        let fill = max(canvas.width / size.width, canvas.height / size.height)
        let widest = canvas.width / fill, narrowest = widest / Self.maxScale
        let room = min(corner % 2 == 0 ? anchor.x : size.width - anchor.x, (corner < 2 ? anchor.y : size.height - anchor.y) * aspect)
        let w = min(max(narrowest, from.width + max(dx, dy * aspect)), min(widest, room))
        let h = w / aspect
        box = CGRect(x: corner % 2 == 0 ? anchor.x - w : anchor.x, y: corner < 2 ? anchor.y - h : anchor.y, width: w, height: h)
    }

    /// A shot that has keys keeps every finished move of the box as the key at the playhead (the window stays open).
    private func autoKey() {
        guard !shot.keys.isEmpty else { return }
        done(key: true, close: false)
    }

    private func done(key: Bool = false, close: Bool = true) {
        guard let image, let box else { job.cropShot = nil; return }
        let iw = Double(image.width), ih = Double(image.height)
        let ox = iw - box.width, oy = ih - box.height
        var px = ox > 0.5 ? box.minX / ox * 2 - 1 : 0
        let py = oy > 0.5 ? box.minY / oy * 2 - 1 : 0
        if shot.flip { px = -px }
        let scale = zoom(CGSize(width: iw, height: ih))
        let (s, x, y) = (abs(scale - 1) < 0.005 ? 1 : scale, abs(px) < 0.005 ? 0 : px, abs(py) < 0.005 ? 0 : py)
        if key { job.setCropKey(shot.id, scale: s, panX: x, panY: y, rotation: rotation, close: close) }
        else { job.applyCrop(shot.id, scale: s, panX: x, panY: y, rotation: rotation) }
    }
}
