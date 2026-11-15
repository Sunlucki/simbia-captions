import AVFoundation
import AVKit
import Combine
import SimbiaCore
import SwiftUI

struct EditorView: View {
    @ObservedObject var job: Job

    var body: some View {
        Group {
            if job.editorReady { workspace } else { WelcomeView(job: job) }
        }
        .preferredColorScheme(.dark)
        .background(Theme.bg)
        .overlay(alignment: .top) { if !job.editorReady { NoticeBar(job: job) } }
    }

    private var workspace: some View {
        WorkspaceView(job: job)
    }
}

// MARK: - Video stage

struct VideoStage: View {
    @ObservedObject var job: Job
    /// Wide footage puts the controls under the card instead, where they do not cover the frame.
    var showsTransport = true

    var body: some View {
        GeometryReader { proxy in
            let frame = job.videoRect(in: proxy.size)
            ZStack {
                Color.black
                VideoCanvas(player: job.player)

                // Titles always, captions in the native styles: drawn by the same engine as the export.
                NativeOverlay(job: job)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)

                // captions, titles, graphics and scenes are moved by dragging them on the picture
                if job.project != nil, job.captionStyle != "legacy" {
                    PictureDrag(job: job)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                if job.captionStyle == "legacy" {
                    LegacyCaption(job: job, clock: job.clock, videoRect: frame, stage: proxy.size)
                }

                // while a trim or a slip on the timeline lasts: the frames it leaves at the shot's edges
                EdgeFrames()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                if let id = job.cropShot, let shot = job.shot(id) {
                    CropOverlay(job: job, shot: shot)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                } else if let id = job.coverShot, let shot = job.shot(id) {
                    CoverOverlay(job: job, shot: shot)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                } else if job.project != nil {
                    HStack(spacing: 8) {
                        CoverButton(job: job, clock: job.clock)
                        CropButton(job: job, clock: job.clock)
                    }
                        .padding(12)
                        .frame(width: frame.width, height: frame.height, alignment: .topTrailing)
                        .position(x: frame.midX, y: frame.midY)
                }

                // Drawn after the caption: the caption is burned into the video, so the app's
                // UI covers it — which is the whole point of showing this.
                if job.social != .off {
                    SocialFrame(mode: job.social, rect: frame)
                        .animation(Theme.settle, value: job.social)
                }

                if job.busy { ExportOverlay(progress: job.progress, status: job.status) }

                // outcomes of operations float over the top of the picture, clear of the panels
                VStack { NoticeBar(job: job).padding(.horizontal, 12); Spacer() }

                if showsTransport {
                    VStack {
                        Spacer()
                        TransportBar(job: job, clock: job.clock)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.30), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
    }
}

private struct ExportOverlay: View {
    let progress: Int
    let status: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(progress), total: 100)
                .tint(.white)
                .frame(width: 190)
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .padding(22)
        .glassBar(18)
        .allowsHitTesting(false)
    }
}

// MARK: - Native overlay

/// Captions and titles from the native engine. A layer of its own, redrawn by a display link at the
/// video's frame rate while playing — SwiftUI is not involved frame by frame — and on a seek or an
/// edit while paused.
private struct NativeOverlay: NSViewRepresentable {
    /// Observed so an edit (new captions, titles, style) reaches `updateNSView`.
    @ObservedObject var job: Job

    func makeNSView(context: Context) -> OverlayView { OverlayView(job: job) }
    func updateNSView(_ view: OverlayView, context: Context) { view.needsDisplay = true }

    final class OverlayView: NSView {
        private let job: Job
        private var link: CADisplayLink?
        private var subscriptions: Set<AnyCancellable> = []

        init(job: Job) {
            self.job = job
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            job.clock.ticks
                .sink { [weak self] _ in MainActor.assumeIsolated { if self?.link == nil { self?.needsDisplay = true } } }
                .store(in: &subscriptions)
            job.clock.$playing
                .sink { [weak self] playing in MainActor.assumeIsolated { self?.follow(playing) } }
                .store(in: &subscriptions)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func follow(_ playing: Bool) {
            if playing, link == nil {
                let link = displayLink(target: self, selector: #selector(step))
                // the video's own frame rate: drawing more often than the picture changes only costs time
                let fps = Float(max(job.project?.canvas.fps ?? 30, 1))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, fps), maximum: fps, preferred: fps)
                link.add(to: .main, forMode: .common)
                self.link = link
            } else if !playing, let link {
                link.invalidate()
                self.link = nil
                needsDisplay = true
            }
        }

        @objc private func step(_ link: CADisplayLink) { needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            let time = link != nil ? job.player.currentTime().seconds : job.currentTime
            job.overlayRenderer.draw(in: cg, size: bounds.size, time: time, flipped: true)
        }
    }
}

// MARK: - Dragging on the picture

/// Grabs whatever is drawn under the pointer — a caption, title, Trustpilot graphic or kit scene — and moves it; a
/// double click puts it back in its own place. While dragging, the social apps' safe zone and the centre lines show,
/// and the piece snaps (magnet) to the centre, the safe-zone edges and its own place; ⌘ while dragging turns the magnet
/// off. A kit scene is part of the video, so its outline moves and the picture follows on release.
private struct PictureDrag: NSViewRepresentable {
    @ObservedObject var job: Job

    func makeNSView(context: Context) -> DragView { DragView(job: job) }
    func updateNSView(_ view: DragView, context: Context) { view.needsDisplay = true }     // the picked emoji's handles follow edits

    /// Where TikTok / Reels / Shorts put their own buttons and text: keep captions and titles inside (stage px).
    static let safe = CGRect(x: 60, y: 1920 * 0.12, width: 1080 - 60 - 140, height: 1920 * (0.80 - 0.12))

    final class DragView: NSView {
        private let job: Job
        private var piece: OverlayRenderer.Piece?
        private var grabbed = CGPoint.zero
        private var from = CGPoint.zero
        private var moved = false
        /// Where the piece is drawn as the drag starts, and now (stage px).
        private var start: CGRect?
        private var now: CGRect?
        private var guides: [(CGPoint, CGPoint)] = []
        /// Turning and scaling the picked emoji (or the picked video of the overlay track) by its corner handle: its centre,
        /// the pointer's angle and distance from it, and its size (the video's scale) and turn as the drag started.
        private var turning: (target: Handled, centre: CGPoint, angle: Double, distance: Double, size: Double, rotation: Double)?

        /// What the corner handle turns and scales.
        private enum Handled { case sticker(StickerRef), layer(String) }

        init(job: Job) { self.job = job; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        /// The stage (1080 wide, y down) fitted into the view as the overlay draws it.
        private var fit: (scale: Double, left: Double) {
            let s = min(bounds.width / 1080, bounds.height / 1920)
            return (s, (bounds.width - 1080 * s) / 2)
        }

        private func stage(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil), f = fit
            return CGPoint(x: (p.x - f.left) / f.scale, y: p.y / f.scale)
        }

        private func view(_ r: CGRect) -> CGRect {
            let f = fit
            return CGRect(x: f.left + r.minX * f.scale, y: r.minY * f.scale, width: r.width * f.scale, height: r.height * f.scale)
        }

        private func view(_ p: CGPoint) -> CGPoint { let f = fit; return CGPoint(x: f.left + p.x * f.scale, y: p.y * f.scale) }

        /// The picked emoji, if its title is on screen — else the picked video of the overlay track, when it is cut out or
        /// made smaller and plays now: its centre, its box's size and turn, and the corner handle that turns and scales it
        /// (stage px). `size` is the emoji's side, or the video's scale.
        private func handle() -> (target: Handled, centre: CGPoint, box: CGSize, rotation: Double, size: Double, corner: CGPoint)? {
            func corner(_ c: CGPoint, _ box: CGSize, _ degrees: Double) -> CGPoint {
                let a = degrees * .pi / 180, w = box.width / 2, h = box.height / 2
                return CGPoint(x: c.x + w * cos(a) + h * sin(a), y: c.y + w * sin(a) - h * cos(a))
            }
            if let ref = job.sticker, case .title(let id) = job.focus, id == ref.title, let title = job.title(id),
               job.currentTime >= title.start, job.currentTime <= title.end, let s = job.stickerAt(id, ref.index) {
                let c = CGPoint(x: 540 + s.x + (title.x ?? 0), y: 960 + s.y + (title.y ?? 0)), box = CGSize(width: s.size, height: s.size)
                return (.sticker(ref), c, box, s.rotation, s.size, corner(c, box, s.rotation))
            }
            guard case .shot(let id) = job.focus, let v = job.layers.first(where: { $0.id == id }), v.cutout,
                  job.currentTime >= v.start, job.currentTime < v.end else { return nil }
            let t = v.transform ?? LayerTransform(), r = t.box()
            let c = CGPoint(x: r.midX, y: r.midY)
            return (.layer(id), c, r.size, t.rotation, t.scale, corner(c, r.size, t.rotation))
        }

        override func mouseDown(with event: NSEvent) {
            let point = stage(event), time = job.currentTime
            if let h = handle(), hypot(view(point).x - view(h.corner).x, view(point).y - view(h.corner).y) < 14 {
                turning = (h.target, h.centre, atan2(point.y - h.centre.y, point.x - h.centre.x),
                           max(hypot(point.x - h.centre.x, point.y - h.centre.y), 1), h.size, h.rotation)
                moved = false
                return
            }
            guard let hit = job.overlayRenderer.piece(at: point, time: time) else {
                piece = nil
                if job.sticker != nil { job.sticker = nil; needsDisplay = true }
                return
            }
            if event.clickCount == 2 { job.setOffset(hit, nil); piece = nil; return }
            piece = hit
            grabbed = point
            moved = false
            guides = []
            job.select(hit)
            start = job.overlayRenderer.bounds(of: hit, time: time)
            now = start
            from = job.offset(of: hit) ?? .zero
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            if let t = turning {
                let p = stage(event)
                if !moved { moved = true; job.pushHistory() }
                var turn = t.rotation + (atan2(p.y - t.centre.y, p.x - t.centre.x) - t.angle) * 180 / .pi
                if !event.modifierFlags.contains(.command) {                        // upright and quarter turns catch within 4°
                    let quarter = (turn / 90).rounded() * 90
                    if abs(turn - quarter) < 4 { turn = quarter }
                }
                let size = t.size * hypot(p.x - t.centre.x, p.y - t.centre.y) / t.distance
                switch t.target {
                case .sticker(let ref):
                    job.updateSticker(ref.title, ref.index, undoable: false) { $0.rotation = turn; $0.size = (size * 2).rounded() / 2 }
                case .layer(let id):                                                  // the video's scale and turn
                    job.updateCutout(id, undoable: false) { s in
                        var place = s.transform ?? LayerTransform()
                        place.scale = min(3, max(0.05, (size * 1000).rounded() / 1000))
                        place.rotation = (turn * 10).rounded() / 10
                        s.transform = place.isIdentity ? nil : place
                    }
                }
                needsDisplay = true
                return
            }
            guard let piece else { return }
            let p = stage(event)
            var delta = CGPoint(x: p.x - grabbed.x, y: p.y - grabbed.y)
            if !moved {
                guard hypot(delta.x, delta.y) > 3 else { return }
                moved = true
                job.pushHistory()
                if case .overlay = piece { job.sync.holdRebuild = true }
            }
            guides = []
            if let start, !event.modifierFlags.contains(.command) {
                let snapped = snap(start.offsetBy(dx: delta.x, dy: delta.y), delta: delta)
                delta = snapped
            }
            now = start?.offsetBy(dx: delta.x, dy: delta.y)
            job.setOffset(piece, CGPoint(x: from.x + delta.x, y: from.y + delta.y), undoable: false)
            needsDisplay = true
        }

        /// The magnet: within ~8 screen points, a side or the middle of the piece lands on the frame's centre, a safe-zone
        /// edge, or the piece's own place (offset 0). Returns the adjusted move and records the guides that caught it.
        private func snap(_ r: CGRect, delta: CGPoint) -> CGPoint {
            let reach = 8 / max(fit.scale, 0.01)
            let safe = PictureDrag.safe
            var d = delta
            // x: centre of the frame, safe sides, home
            let homeX = -from.x - delta.x                                               // what puts the offset back to 0
            let xs: [(Double, Double, Bool)] = [(r.midX, 540, true), (r.minX, safe.minX, true), (r.maxX, safe.maxX, true), (0, 0, false)]
            var bestX: (Double, Double, Bool)?
            for (have, want, line) in xs {
                let gap = line ? want - have : homeX
                if abs(gap) < reach, abs(gap) < abs(bestX?.0 ?? .infinity) { bestX = (gap, want, line) }
            }
            if let (gap, want, line) = bestX {
                d.x += gap
                if line { guides.append((CGPoint(x: want, y: 0), CGPoint(x: want, y: 1920))) }
            }
            let homeY = -from.y - delta.y
            let ys: [(Double, Double, Bool)] = [(r.midY, 960, true), (r.minY, safe.minY, true), (r.maxY, safe.maxY, true), (0, 0, false)]
            var bestY: (Double, Double, Bool)?
            for (have, want, line) in ys {
                let gap = line ? want - have : homeY
                if abs(gap) < reach, abs(gap) < abs(bestY?.0 ?? .infinity) { bestY = (gap, want, line) }
            }
            if let (gap, want, line) = bestY {
                d.y += gap
                if line { guides.append((CGPoint(x: 0, y: want), CGPoint(x: 1080, y: want))) }
            }
            return d
        }

        /// A right click (or a two-finger click) on a title on the picture: its menu, the title picked first.
        override func menu(for event: NSEvent) -> NSMenu? {
            guard case .title(let id)? = job.overlayRenderer.piece(at: stage(event), time: job.currentTime) else { return nil }
            job.select(.title(id))
            let menu = NSMenu()
            menu.autoenablesItems = false
            let item = NSMenuItem(title: job.t("Выровнять все заголовки по этому", "Align all titles to this one", "Aligner tous les titres sur celui-ci"),
                                  action: #selector(alignTitles(_:)), keyEquivalent: "a")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.representedObject = id
            item.target = self
            item.isEnabled = (job.project?.titles.count ?? 0) > 1
            menu.addItem(item)
            return menu
        }

        @objc private func alignTitles(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { job.alignTitles(to: id) }
        }

        override func mouseUp(with event: NSEvent) {
            turning = nil
            if piece != nil { NSCursor.pop() }
            if moved, case .overlay = piece {
                job.sync.holdRebuild = false
                job.rebuildIfPictureChanged()
            }
            piece = nil
            start = nil
            now = nil
            guides = []
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            // the picked emoji (or video): its box, turned with it, and the handle that turns and scales it
            if let h = handle() {
                let f = fit, w = h.box.width * f.scale, side = h.box.height * f.scale, c = view(h.centre)
                let frame = NSBezierPath(rect: NSRect(x: -w / 2, y: -side / 2, width: w, height: side))
                var turn = AffineTransform(translationByX: c.x, byY: c.y)
                turn.rotate(byDegrees: h.rotation)
                frame.transform(using: turn)
                frame.lineWidth = 1.5
                frame.setLineDash([5, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                frame.stroke()
                let k = view(h.corner)
                let knob = NSBezierPath(ovalIn: NSRect(x: k.x - 7, y: k.y - 7, width: 14, height: 14))
                NSColor.white.setFill(); knob.fill()
                NSColor(red: 1, green: 0.3, blue: 0.55, alpha: 1).setStroke(); knob.lineWidth = 2; knob.stroke()
            }
            guard let piece, moved else { return }
            // the safe zone and the centre lines
            let zone = NSBezierPath(rect: view(PictureDrag.safe))
            zone.lineWidth = 1
            zone.setLineDash([5, 5], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.55).setStroke()
            zone.stroke()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            for (a, b) in [(CGPoint(x: 540, y: 0), CGPoint(x: 540, y: 1920)), (CGPoint(x: 0, y: 960), CGPoint(x: 1080, y: 960))] {
                let line = NSBezierPath(); line.move(to: view(a)); line.line(to: view(b)); line.lineWidth = 1; line.stroke()
            }
            // what the magnet caught
            NSColor(red: 1, green: 0.3, blue: 0.55, alpha: 0.95).setStroke()
            for (a, b) in guides {
                let line = NSBezierPath(); line.move(to: view(a)); line.line(to: view(b)); line.lineWidth = 1.5; line.stroke()
            }
            // a kit scene is in the video: its outline shows where it goes (a video of the overlay track moves live, its
            // own box follows it)
            if case .overlay = piece, let now {
                let path = NSBezierPath(roundedRect: view(now), xRadius: 8, yRadius: 8)
                path.lineWidth = 2
                path.setLineDash([6, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                path.stroke()
            }
            // the piece leaving the safe zone
            if let now, !PictureDrag.safe.contains(now) {
                let warn = NSBezierPath(rect: view(now).insetBy(dx: -2, dy: -2))
                warn.lineWidth = 1.5
                NSColor(red: 1, green: 0.6, blue: 0.2, alpha: 0.9).setStroke()
                warn.stroke()
            }
        }
    }
}

// MARK: - Caption preview

/// The classic caption under the playhead: SwiftUI animations, so this one does follow the clock.
private struct LegacyCaption: View {
    @ObservedObject var job: Job
    let clock: PlayClock
    let videoRect: CGRect
    let stage: CGSize
    @State private var now = 0.0

    var body: some View {
        ZStack {
            if let cue = job.cues.first(where: { now >= $0.start && now <= $0.end }) {
                CaptionOverlay(job: job, now: now, cue: cue, videoRect: videoRect, stage: stage)
            }
        }
        .onAppear { now = clock.time }
        .onReceive(clock.ticks) { now = $0 }
    }
}

/// The live caption, drawn where it will burn in — and draggable to set Position.
///
/// The anchor maths mirror `Job.centre(box:)` in Export.swift: the user's anchor is the
/// bottom-left / bottom-centre / bottom-right of the caption, and both sides convert it to a
/// centre point the same way, so the preview lands where libass will draw.
private struct CaptionOverlay: View {
    @ObservedObject var job: Job
    /// The playhead.
    let now: Double
    let cue: Cue
    let videoRect: CGRect
    let stage: CGSize
    @State private var dragOrigin: CGPoint?
    @State private var captionSize: CGSize = .zero

    var body: some View {
        let scale = videoRect.height / max(job.videoSize.height, 1)
        let anchorX = videoRect.minX + job.look.posX * videoRect.width
        let anchorY = videoRect.minY + job.look.posY * videoRect.height
        let dx: CGFloat = job.look.alignment == .left ? captionSize.width / 2
                        : job.look.alignment == .right ? -captionSize.width / 2 : 0

        CaptionChrome(look: job.look, animation: job.look.animationsOn ? job.animation : .none,
                      outro: job.outro, accent: cue.accent,
                      text: job.displayText(job.captionText(for: cue, at: now)),
                      progress: progress, scale: scale)
            .id(job.captionKey(for: cue, at: now))
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: CaptionSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(CaptionSizeKey.self) { captionSize = $0 }
            .position(x: anchorX + dx, y: anchorY - captionSize.height / 2)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = CGPoint(x: job.look.posX, y: job.look.posY)
                            job.pushHistory()
                        }
                        guard let origin = dragOrigin else { return }
                        let x = origin.x + value.translation.width / videoRect.width
                        let y = origin.y + value.translation.height / videoRect.height
                        job.look.posX = min(visibleX.upperBound, max(visibleX.lowerBound, x))
                        job.look.posY = min(visibleY.upperBound, max(visibleY.lowerBound, y))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .help(job.s.dragCaption)
    }

    /// The slice of the video frame actually on screen, as position fractions. Aspect-fill
    /// crops the frame, and a caption dragged into the cropped part would vanish from the
    /// preview while still burning into the file.
    private var visibleX: ClosedRange<Double> {
        let low = (0 - videoRect.minX) / videoRect.width + 0.03
        let high = (stage.width - videoRect.minX) / videoRect.width - 0.03
        return low < high ? low...high : 0.5...0.5
    }

    private var visibleY: ClosedRange<Double> {
        let low = (0 - videoRect.minY) / videoRect.height + 0.04
        let high = (stage.height - videoRect.minY) / videoRect.height - 0.04
        return low < high ? low...high : 0.5...0.5
    }

    /// How far through the caption we are — drives the time-based presets.
    private var progress: Double {
        let span = max(0.05, cue.end - cue.start)
        return min(1, max(0, (now - cue.start) / span))
    }
}

struct CaptionSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The caption as it will burn in. Padding and corner radius come from `Plate`, the same
/// constants Export.swift uses to size the drawn backplate.
struct CaptionChrome: View {
    let look: Look
    let animation: Anim
    var outro: Outro = .none
    var accent = false
    let text: String
    let progress: Double
    let scale: Double

    @State private var phase = false

    private var size: Double { max(6, (accent ? look.size * look.accentScale : look.size) * scale) }

    var body: some View {
        let shown = animation == .typewriter ? typed : text

        OutlinedText(text: shown, look: look, size: size, accent: accent)
            .padding(.horizontal, max(4, size * Plate.padX))
            .padding(.vertical, max(2, size * Plate.padY))
            .background(plate)
            .overlay(alignment: .center) { if animation == .glitch { ghosts(shown) } }
            .modifier(AnimationModifier(animation: animation, phase: phase, progress: progress, size: size))
            .modifier(OutroModifier(outro: look.animationsOn ? outro : .none,
                                    progress: progress, size: size))
            .rotationEffect(.degrees(accent ? look.accentAngle : 0))
            .onAppear(perform: replay)
    }

    /// Let SwiftUI commit the pre-animation frame first. Setting `phase` false and true inside
    /// one synchronous block coalesces into a single update, and nothing animates.
    private func replay() {
        phase = false
        DispatchQueue.main.async { withAnimation(animation.curve) { phase = true } }
    }

    @ViewBuilder private var plate: some View {
        if look.fillOn, let colour = look.fillColor.color {
            RoundedRectangle(cornerRadius: max(3, size * Plate.radius), style: .continuous)
                .fill(colour)
                .shadow(color: look.fillShadow ? (look.shadowColor.color ?? .black).opacity(0.85) : .clear,
                        radius: size * look.shadowDepth * 0.5,
                        x: size * look.shadowDepth * 0.6, y: size * look.shadowDepth * 0.6)
        }
    }

    /// Characters land one at a time, matching the burn-in's stagger.
    private var typed: String {
        let characters = Array(text)
        guard !characters.isEmpty else { return text }
        let shown = Int((progress / 0.55 * Double(characters.count)).rounded(.down))
        return String(characters.prefix(max(1, min(characters.count, shown))))
    }

    /// Chromatic ghosts, matching the export's RGB split.
    @ViewBuilder private func ghosts(_ shown: String) -> some View {
        let kick = size * 0.14 * (1 - min(1, progress / 0.35))
        if kick > 0.4 {
            ZStack {
                OutlinedText(text: shown, look: look, size: size, accent: accent,
                             override: Color(red: 1, green: 0, blue: 0.27)).offset(x: -kick)
                OutlinedText(text: shown, look: look, size: size, accent: accent,
                             override: Color(red: 0, green: 0.9, blue: 1)).offset(x: kick)
            }
            .opacity(0.55)
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }
}

/// SwiftUI has no text stroke, so the outline is eight offset copies behind the glyphs —
/// close enough to libass's `\bord` for a preview.
private struct OutlinedText: View {
    let text: String
    let look: Look
    let size: Double
    var accent = false
    var override: Color?

    var body: some View {
        let base = accent && look.accentColorOn ? look.accentColor : look.textColor
        let fill = override ?? (base.color ?? .white)
        let stroke = look.outlineColor.color ?? .black
        let width = look.outlineOn ? size * look.outlineWidth * 0.75 : 0

        ZStack {
            if width > 0.3 {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8 * 2 * .pi
                    core(fill: stroke)
                        .offset(x: cos(angle) * width, y: sin(angle) * width)
                }
            }
            core(fill: fill)
        }
        .shadow(color: look.shadowOn ? (look.shadowColor.color ?? .black).opacity(0.9) : .clear,
                radius: size * look.shadowDepth * 0.4,
                x: size * look.shadowDepth * 0.7, y: size * look.shadowDepth * 0.7)
        .shadow(color: look.glow > 0 ? (look.outlineColor.color ?? .white).opacity(0.9) : .clear,
                radius: look.glow * 1.6)
    }

    private func core(fill: Color) -> some View {
        Text(text)
            .font(.custom(accent ? look.accentFont : look.font, size: size))
            .fontWeight(look.bold ? .bold : .regular)
            .italic(look.italic)
            .tracking(size * look.tracking)
            .multilineTextAlignment(look.alignment.swiftUI)
            .foregroundStyle(fill)
    }
}

/// Preview counterparts of the burn-in presets.
private struct AnimationModifier: ViewModifier {
    let animation: Anim
    let phase: Bool
    let progress: Double
    let size: Double

    func body(content: Content) -> some View {
        switch animation {
        case .pop:
            content.scaleEffect(phase ? 1 : 0.6).opacity(phase ? 1 : 0)
        case .fade:
            content.opacity(phase ? 1 : 0)
        case .slideUp, .wave:
            content.offset(y: phase ? 0 : size * 0.55).opacity(phase ? 1 : 0)
        case .bounce:
            content.scaleEffect(phase ? 1 : 0.55)
        case .zoomOut:
            content.scaleEffect(phase ? 1 : 1.4).opacity(phase ? 1 : 0)
        case .shake:
            content.rotationEffect(.degrees(phase ? 0 : -5))
        case .typewriter:
            content
        case .glitch:
            content.offset(x: progress < 0.2 ? size * 0.05 : 0)
        case .none:
            content
        }
    }
}

/// Preview counterpart of the exit presets, driven by position within the cue rather than by
/// an on-appear phase — the export runs these over the tail of the caption.
private struct OutroModifier: ViewModifier {
    let outro: Outro
    let progress: Double
    let size: Double

    /// Matches `Outro.length(of:)`: the last 42% of the cue, capped.
    private var t: Double { min(1, max(0, (progress - 0.58) / 0.42)) }

    func body(content: Content) -> some View {
        switch outro {
        case .none:
            content
        case .fade:
            content.opacity(1 - t)
        case .shrink:
            content.scaleEffect(1 - t * 0.45).opacity(1 - t)
        case .grow:
            content.scaleEffect(1 + t * 0.45).opacity(1 - t)
        case .slideDown:
            content.offset(y: t * size * 0.8).opacity(1 - t)
        case .riseUp:
            content.offset(y: -t * size * 0.8).opacity(1 - t)
        case .blurOut:
            content.blur(radius: t * 9).opacity(1 - t)
        case .spin:
            content.rotationEffect(.degrees(t * 30)).scaleEffect(1 - t * 0.65).opacity(1 - t)
        case .particles:
            content.scaleEffect(1 - t * 0.7).blur(radius: t * 6).opacity(1 - t)
        case .glitchOut:
            content.offset(x: t * size * 0.18).blur(radius: t * 2).opacity(1 - t)
        }
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var job: Job
    @ObservedObject var clock: PlayClock
    /// Over the video it is frosted glass; standing on the background it needs a real surface.
    var floating = true

    /// The playhead's time, a few times a second (the clock itself ticks every frame).
    @State private var now = 0.0

    var body: some View {
        // the time | previous caption · play/pause · next caption | the phone preview — the middle stays centred
        HStack(spacing: 0) {
            Text(String(format: "%@ / %@", clock2(now), clock2(job.duration)))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            control("chevron.left.2", job.s.prevCue, active: true, action: job.previousCue)
            Button { if clock.playing { job.player.pause() } else { job.play() } } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black).frame(width: 46, height: 46).background(Color.white, in: Circle())
            }
            .buttonStyle(BouncyButtonStyle())
            .help((clock.playing ? job.s.pause : job.s.play) + " · " + job.t("пробел", "space", "espace"))
            .padding(.horizontal, 6)
            control("chevron.right.2", job.s.nextCue, active: true, action: job.nextCue)
            control("iphone", "\(job.s.previewAs): \(job.s.socialTitle(job.social.next))",
                    active: job.social != .off) { job.social = job.social.next }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .modifier(TransportSurface(floating: floating))
        .onReceive(clock.ticks.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)) { now = $0 }
        .onAppear { now = clock.time }
    }

    /// 0:26.1
    private func clock2(_ t: Double) -> String {
        let t = max(0, t)
        return String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private func control(_ symbol: String, _ hint: String, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Theme.text.opacity(active ? 1 : 0.38))
        }
        .buttonStyle(IconButtonStyle(size: 24))
        .frame(width: 48)
        .help(hint)
    }
}

private struct TransportSurface: ViewModifier {
    let floating: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if floating { content.glassBar(22) } else { content.card(22) }
    }
}

// MARK: - Player surface

private struct VideoCanvas: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView { PlayerLayerView(player: player) }
    func updateNSView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }

    final class PlayerLayerView: NSView {
        let playerLayer: AVPlayerLayer
        init(player: AVPlayer) {
            playerLayer = AVPlayerLayer(player: player)
            super.init(frame: .zero)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}


/// Outcome of the last operation, visible after `busy` drops.
private struct NoticeBar: View {
    @ObservedObject var job: Job

    var body: some View {
        if let notice = job.notice {
            HStack(spacing: 9) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13))
                Text(notice.text).font(.system(size: 13)).lineLimit(2)
                Button { job.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
            }
            .foregroundStyle(notice.isError ? Color(red: 1, green: 0.72, blue: 0.6) : Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 620)
            .glassBar(14)
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Theme.bounce, value: job.notice)
        }
    }
}
