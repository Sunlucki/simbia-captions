import AVFoundation
import AppKit
import Combine
import SimbiaCore
import SwiftUI

/// The edit on a time ruler: shots, titles, captions and sound, one track each, with the beat grid
/// behind them. Everything can be selected; edges and blocks can be dragged.
struct MultiTimeline: View {
    @ObservedObject var job: Job
    /// `MultiTimeline.stretch` as the workspace set it: a new value lays the tracks out again.
    var stretch: CGFloat = 1

    private let labelWidth: CGFloat = 116
    private let gap: CGFloat = 6
    /// How much taller the clip tracks are than usual: above 1 when the right-hand panel is folded and the timeline
    /// has the room (set by the workspace before it lays the timeline out).
    nonisolated(unsafe) static var stretch: CGFloat = 1
    /// The timeline's usual height, and how much of it is clip tracks (what `stretch` grows).
    static let usualHeight: CGFloat = 508
    static let clipTracks: CGFloat = 318
    static var heights: (ruler: CGFloat, bars: CGFloat, look: CGFloat, filters: CGFloat, layers: CGFloat, keys: CGFloat, shots: CGFloat, pivot: CGFloat,
                         titles: CGFloat, graphics: CGFloat, captions: CGFloat, voice: CGFloat, music: CGFloat) {
        let k = stretch
        let lane = 27 * k                                    // every thin track the same: overall, filters, overlay, keys, titles, graphics
        return (20, 20, lane, lane, lane, lane, 50 * k, 12, lane, lane, 46 * k, 30 * k, 30 * k)
    }

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            GeometryReader { geometry in
                let width = Double(max(geometry.size.width - labelWidth, 1))
                let full = max(job.duration, job.cues.map(\.end).max() ?? 1, 1)
                let span = max(0.4, full / job.timelineZoom)
                let start = min(max(0, job.timelineOffset), max(0, full - span))
                let scale = TimeScale(start: start, span: span, width: width)
                let lanes = Lane.allCases
                let open = job.drawer.flatMap { lanes.firstIndex(of: $0) }
                let split = open.map { $0 + 1 } ?? lanes.count

                // the tracks down to the one whose settings are open, its drawer, then the rest
                VStack(alignment: .leading, spacing: gap) {
                    segment(Array(lanes[..<split]), ruler: true, scale: scale, full: full)
                    if let open {
                        LaneDrawer(job: job, lane: lanes[open])
                            .frame(height: min(lanes[open].drawerHeight, max(160, geometry.size.height - Self.tracksHeight - gap * 2)))
                            .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity), removal: .opacity))
                    }
                    if split < lanes.count { segment(Array(lanes[split...]), ruler: false, scale: scale, full: full) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .card(outlined: false)
        .onChange(of: job.focus) { _, new in
            // what is picked on the timeline or the picture opens its settings under its track
            // (a title or a scene opens its own settings window; «Заменить» there opens the choice under its track)
            switch new {
            case .filter: job.openDrawer(.filters)
            case .look: job.openDrawer(.look)
            case .transition: job.openDrawer(.shots)
            default: break
            }
        }
    }

    /// Every track and the gaps between them at the usual height (the drawer takes what is left).
    static var tracksHeight: CGFloat {
        let h = heights
        return h.ruler + h.bars + h.titles + h.graphics + h.look + h.filters + h.layers + h.keys + h.shots + h.pivot + h.voice + h.captions + h.music
            + 12 * 6
    }

    /// Some tracks with their names, the playhead over them, fading out at an edge past which the edit goes on.
    private func segment(_ lanes: [Lane], ruler: Bool, scale: TimeScale, full: Double) -> some View {
        let width = scale.width
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: gap) {
                if ruler {
                    Color.clear.frame(height: Self.heights.ruler)
                    label(job.t("Такты", "Bars", "Mesures"), "metronome").frame(height: Self.heights.bars)
                        .help(job.t("Такты музыки: склейки и края прилипают к долям, когда включена «Привязка»", "The music's bars: cuts and edges stick to the beats while Snap is on", "Les mesures de la musique : coupes et bords s’aimantent aux temps quand le magnétisme est activé"))
                }
                ForEach(lanes, id: \.self) { laneLabel($0) }
            }
            .frame(width: labelWidth)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        job.seek(scale.time(at: Double(value.location.x)))
                    })
                // zoomed in, a shot or title can be wider than the view: pinned to the left edge, it runs off to the
                // right (centred, the way SwiftUI places anything too wide, the timeline's start slid off the left)
                VStack(alignment: .leading, spacing: gap) {
                    if ruler {
                        Ruler(scale: scale)
                            .frame(height: Self.heights.ruler)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                job.seek(scale.time(at: Double(value.location.x)))
                            })
                        BarsTrack(job: job, scale: scale)
                            .frame(height: Self.heights.bars)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                job.seek(scale.time(at: Double(value.location.x)))
                            })
                    }
                    ForEach(lanes, id: \.self) { track($0, scale) }
                }
                .frame(width: CGFloat(width), alignment: .topLeading)
            }
            .overlay(alignment: .topLeading) {
                Playhead(clock: job.clock, scale: scale).frame(width: CGFloat(width)).allowsHitTesting(false)
            }
            .frame(width: CGFloat(width))
            .clipped()
            // what runs on past either edge goes into the dark; at the end of the edit its last clip stays sharp
            .mask(HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: scale.start > 0.01 ? 64 : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: scale.start + scale.span < full - 0.01 ? 64 : 0)
            })
            .background(TimelineEvents(onZoom: job.zoomTimeline,
                                       onPan: { job.panTimeline(-$0 / width * scale.span * 0.7) }))
        }
    }

    /// One track — what lies over the picture on top, the picture, then the sound: the voice with its captions right
    /// under it, the music last. The thin tracks offer what they can take where they are empty.
    @ViewBuilder private func track(_ lane: Lane, _ scale: TimeScale) -> some View {
        switch lane {
        case .titles:
            TitleTrack(job: job, scale: scale).frame(height: Self.heights.titles)
                .modifier(AddOffer(job: job, scale: scale, title: job.t("+ Заголовок", "+ Title", "+ Titre"),
                                   taken: { job.titles.filter { !$0.isGraphic }.map { ($0.start, $0.end) } }) { a, _ in
                    job.ensureProject(); job.chooseTitle(at: a)
                })
        case .graphics:
            GraphicsTrack(job: job, scale: scale).frame(height: Self.heights.graphics)
                .modifier(AddOffer(job: job, scale: scale, title: job.t("+ Графика — выбрать отзыв", "+ Graphics — pick a review", "+ Graphismes — choisir un avis"),
                                   taken: { job.titles.filter(\.isGraphic).map { ($0.start, $0.end) }
                                       + job.overlays.map { ($0.start, $0.start + MotionLibrary.duration($0, projectURL: job.projectURL)) } }) { a, _ in
                    job.seek(a); job.focus = .caption; job.titleTools = nil; job.overlayTools = nil; job.openDrawer(.graphics)
                })
        case .look: LookTrack(job: job, scale: scale).frame(height: Self.heights.look)
        case .filters: FilterTrack(job: job, scale: scale).frame(height: Self.heights.filters)
        case .layers:
            LayerTrack(job: job, scale: scale).frame(height: Self.heights.layers)
                .modifier(AddOffer(job: job, scale: scale, title: job.t("+ Видео поверх", "+ Video over the picture", "+ Vidéo en superposition"),
                                   taken: { job.layers.map { ($0.start, $0.end) } }) { a, _ in job.openClipsForLayer(at: a) })
        case .keys:
            KeyTrack(job: job, scale: scale).frame(height: Self.heights.keys)
                .modifier(AddOffer(job: job, scale: scale, title: job.t("+ Кадрирование с ключами", "+ Crop with keys", "+ Recadrage avec clés"),
                                   taken: { job.shots.filter { !$0.keys.isEmpty }.map { ($0.start, $0.end) } }) { a, _ in
                    guard let shot = job.shots.first(where: { a >= $0.start && a < $0.end }) else { return }
                    job.seek(min(shot.end - 0.05, a + 0.05)); job.beginCrop(shot.id)
                })
        case .shots: ShotTrack(job: job, scale: scale).frame(height: Self.heights.shots)
        case .voice:
            VStack(alignment: .leading, spacing: gap) {
                PivotTrack(job: job, scale: scale)
                AudioTrack(job: job, scale: scale, roles: [.voice]).frame(height: Self.heights.voice)
            }
        case .captions:
            // an empty stretch over the voice: the Mac listens there and captions it
            CaptionTrack(job: job, scale: scale).frame(height: Self.heights.captions)
                .modifier(AddOffer(job: job, scale: scale, title: job.t("+ Субтитры по голосу", "+ Captions from the voice", "+ Sous-titres d’après la voix"),
                                   taken: { job.cues.map { ($0.start, $0.end) } },
                                   bounds: { t in
                                       job.project?.audio.first { $0.role == .voice && t >= $0.start && t < $0.start + ($0.duration ?? .infinity) }
                                           .map { ($0.start, $0.start + ($0.duration ?? job.duration)) }
                                   },
                                   height: Self.heights.captions) { a, b in job.captionsFromVoice(in: a, b) })
        case .music: AudioTrack(job: job, scale: scale, roles: [.music, .effect]).frame(height: Self.heights.music)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            CaptionsState(job: job)

            Spacer(minLength: 8)
            Button { job.ensureProject(); job.toolPanel = .pauses } label: {
                Image(systemName: "waveform.path").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32).background(Color.white.opacity(0.1), in: Circle())
                    .overlay(Circle().stroke(Theme.rowStroke, lineWidth: 1))
            }
            .buttonStyle(BouncyButtonStyle())
            .disabled(job.project == nil && job.video == nil)
            .help(job.t("Вырезать паузы: тишина между словами, по звуку голоса", "Remove pauses: the silence between words, found in the voice", "Supprimer les pauses : les silences entre les mots, détectés dans la voix"))
            .popover(isPresented: Binding(get: { job.toolPanel == .pauses }, set: { if !$0, job.toolPanel == .pauses { job.toolPanel = nil } }),
                     arrowEdge: .bottom) { PausesPanel(job: job).preferredColorScheme(.dark) }
            HStack(spacing: 6) {
                Switch(isOn: job.magnet) { job.magnet.toggle() }
                Text(job.t("Привязка", "Snap", "Magnétisme")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize()
            }
            .help(job.t("Склейки, заголовки, субтитры и края шотов прилипают к долям музыки", "Cuts, titles, captions and shot edges stick to the music's beats", "Coupes, titres, sous-titres et bords de plans s’aimantent aux temps de la musique"))
            TempoLabel(job: job).fixedSize()
            // what part of the edit is in view — when there is room for it (the ruler shows it too)
            ViewThatFits(in: .horizontal) {
                Text(rangeLabel).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            // one control for the zoom: out, in, the whole edit
            HStack(spacing: 0) {
                zoom("minus", job.t("Отдалить", "Zoom out", "Zoom arrière")) { job.zoomTimeline(-0.3) }
                Rectangle().fill(Theme.rowStroke).frame(width: 1, height: 18)
                zoom("plus", job.t("Приблизить", "Zoom in", "Zoom avant")) { job.zoomTimeline(0.3) }
                Rectangle().fill(Theme.rowStroke).frame(width: 1, height: 18)
                zoom("arrow.left.and.right", job.t("Весь ролик", "The whole edit", "Tout le montage")) { job.fitTimeline() }
            }
            .background(Color.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(Theme.rowStroke, lineWidth: 1))
        }
        .frame(height: 36)
    }

    private func zoom(_ symbol: String, _ hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 36, height: 32)
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .help(hint)
    }

    private var rangeLabel: String {
        let full = max(job.duration, 1)
        let span = max(0.4, full / job.timelineZoom)
        let start = min(max(0, job.timelineOffset), max(0, full - span))
        func mm(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        return "\(mm(start)) – \(mm(start + span)) \(job.t("из", "of", "sur")) \(mm(full))"
    }

    // MARK: Labels

    /// A track's name; one with settings opens and closes its drawer with a click.
    @ViewBuilder private func laneLabel(_ lane: Lane) -> some View {
        switch lane {
        case .titles: name(lane, job.t("Заголовки", "Titles", "Titres"), "textformat").frame(height: Self.heights.titles)
        case .graphics: name(lane, job.t("Графика", "Graphics", "Graphismes"), "sparkles").frame(height: Self.heights.graphics)
        case .look: name(lane, job.t("Общий", "Overall", "Général"), "camera.filters").frame(height: Self.heights.look)
        case .filters: name(lane, job.t("Фильтры", "Filters", "Filtres"), "slider.horizontal.3").frame(height: Self.heights.filters)
        case .layers: name(lane, job.t("Наложение", "Overlay", "Superposition"), "square.on.square").frame(height: Self.heights.layers)
        case .keys:
            name(lane, job.t("Ключи", "Keys", "Clés"), "diamond").frame(height: Self.heights.keys)
                .help(job.t("Ключи кадрирования: «◆ Ключ» в окне «Кадрировать» ставит рамку в точке плейхеда, между ключами кадр плавно наезжает и движется",
                            "Crop keys: «◆ Key» in the crop window keeps the box at the playhead; between keys the frame glides", "Clés de recadrage : « ◆ Clé » dans la fenêtre de recadrage fixe le cadre à la tête de lecture ; entre les clés, l’image glisse"))
        case .shots: name(lane, job.t("Шоты", "Shots", "Plans"), "film").frame(height: Self.heights.shots)
        case .voice:
            VStack(alignment: .leading, spacing: gap) {
                Color.clear.frame(height: Self.heights.pivot)
                name(lane, job.t("Голос", "Voice", "Voix"), "mic").frame(height: Self.heights.voice)
            }
        case .captions: name(lane, job.t("Субтитры", "Captions", "Sous-titres"), "captions.bubble").frame(height: Self.heights.captions)
        case .music:                                   // the track's name opens the music library
            Button { job.openMusic() } label: {
                HStack(spacing: 0) {
                    label(job.t("Музыка", "Music", "Musique"), "music.note")
                    Image(systemName: "square.grid.2x2").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted).padding(.trailing, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.t("Аудиобиблиотека: выбрать трек для музыки", "Music library: pick the track for the music", "Bibliothèque musicale : choisir le morceau de la musique"))
            .frame(height: Self.heights.music)
        }
    }

    @ViewBuilder private func name(_ lane: Lane, _ title: String, _ symbol: String) -> some View {
        if lane.tabs.isEmpty {
            label(title, symbol)
        } else {
            let open = job.drawer == lane
            Button { job.openDrawer(open ? nil : lane) } label: {
                HStack(spacing: 0) {
                    label(title, symbol)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(open ? Theme.text : Theme.muted)
                        .padding(.trailing, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? job.t("Свернуть настройки", "Fold the settings", "Replier les réglages") : job.t("Настройки этой дорожки — под ней", "This track's settings, under it", "Réglages de cette piste, en dessous"))
        }
    }

    private func label(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text.opacity(0.8))
            .lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The timeline's tracks top to bottom. The ones with settings open them in a drawer under themselves.
enum Lane: CaseIterable {
    case titles, graphics, look, filters, layers, keys, shots, voice, captions, music

    /// How tall the drawer is: the text and the filters need room, a strip of styles does not.
    var drawerHeight: CGFloat {
        switch self {
        case .captions: 330
        case .look, .filters: 300
        case .graphics: 250
        case .shots: 330
        case .titles: 170
        case .layers, .keys, .voice, .music: 0
        }
    }

    /// The tabs of the settings the drawer under the track shows; none — the track has no drawer.
    var tabs: [LibraryTab] {
        switch self {
        case .titles: [.titles]
        case .graphics: [.graphics]
        case .look, .filters: [.filters]
        case .shots: [.transitions]
        case .captions: [.paragraph, .text, .captions]
        case .layers, .keys, .voice, .music: []
        }
    }
}

extension Job {
    /// The drawer under a track open (nil = closed), with a bounce; the tracks give it the room.
    func openDrawer(_ lane: Lane?) {
        if lane == nil { addAt = nil }
        guard drawer != lane else { return }
        withAnimation(Theme.bounce) { drawer = lane }
    }

    /// Adding a title starts with its look: the styles open under the titles track, and the one picked goes in at `time`.
    func chooseTitle(at time: Double) {
        titleTools = nil
        focus = .caption
        openDrawer(.titles)
        addAt = time
    }
}

/// Under its track: the settings that track's items take — the text and caption styles under the captions, the title
/// styles under the titles, the reviews under the graphics, the filters, the transitions.
private struct LaneDrawer: View {
    @ObservedObject var job: Job
    let lane: Lane

    var body: some View {
        // never past its own frame: what is taller scrolls or fades inside it, the tracks around stay clear
        StyleLibrary(job: job, tabs: lane.tabs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Maps between seconds and points for everything drawn on the timeline.
struct TimeScale {
    let start: Double
    let span: Double
    let width: Double

    func x(_ time: Double) -> Double { (time - start) / span * width }
    func time(at point: Double) -> Double { start + (point / width) * span }
    var secondsPerPoint: Double { span / width }

    func visible(_ from: Double, _ to: Double) -> Bool {
        to >= start - span * 0.1 && from <= start + span * 1.1
    }
}

// MARK: - Ruler

/// Time labels.
private struct Ruler: View {
    let scale: TimeScale

    private static let ladder: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        Canvas { context, size in
            let width = Double(size.width)
            context.stroke(Path { $0.move(to: .init(x: 0, y: size.height - 0.5)); $0.addLine(to: .init(x: size.width, y: size.height - 0.5)) },
                           with: .color(.white.opacity(0.5)), lineWidth: 1)

            let major = Self.ladder.first { $0 / scale.span * width >= 70 } ?? Self.ladder.last!
            var t = (scale.start / major).rounded(.up) * major
            while t <= scale.start + scale.span {
                let x = scale.x(t)
                let text = context.resolve(Text(label(t, major)).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75)))
                let half = Double(text.measure(in: size).width) / 2
                context.draw(text, at: CGPoint(x: min(max(x, half), width - half), y: 0), anchor: .top)
                t += major
            }
        }
    }

    private func label(_ t: Double, _ major: Double) -> String {
        if major < 1 { return String(format: "%.1f", t) }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Bars

/// The music's bars under the ruler: numbered, every other one shaded, beats as ticks when there is room. They come
/// from the music itself (its tempo found in its sound), each music clip laying its own and moving with it; the
/// numbers run on through the whole video.
private struct BarsTrack: View {
    @ObservedObject var job: Job
    @ObservedObject private var media = MediaCache.shared
    let scale: TimeScale

    var body: some View {
        let spans = job.gridSpans
        Canvas { context, size in
            let h = Double(size.height), end = scale.start + scale.span
            var base = 0                                       // bars numbered in the pieces before this one
            for span in spans {
                let grid = span.grid, bar = grid.beat * 4
                let barWidth = bar / scale.secondsPerPoint, beatWidth = grid.beat / scale.secondsPerPoint
                var every = 1                                  // bars between numbers: 1, 2, 4, 8… so they never crowd
                while Double(every) * barWidth < 26 { every *= 2 }
                let first = ((max(span.from, 0) - grid.offset) / bar).rounded(.up)      // this piece's first downbeat
                var k = max(first, ((scale.start - grid.offset) / bar).rounded(.down))
                while grid.offset + k * bar < min(span.to, end) {
                    let t = grid.offset + k * bar, x = scale.x(t)
                    let n = base + Int(k - first) + 1
                    let right = scale.x(min(t + bar, span.to))
                    if n % 2 == 0 && barWidth >= 8 {
                        context.fill(Path(CGRect(x: x, y: 0, width: right - x, height: h)), with: .color(.white.opacity(0.06)))
                    }
                    let numbered = (n - 1) % every == 0
                    if barWidth >= 5 || numbered {
                        context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: h)) },
                                       with: .color(.white.opacity(numbered ? 0.55 : 0.3)), lineWidth: 1)
                    }
                    if beatWidth >= 7 {
                        for b in 1..<4 where t + Double(b) * grid.beat < span.to {
                            let bx = x + Double(b) * beatWidth
                            context.stroke(Path { $0.move(to: .init(x: bx, y: h - 6)); $0.addLine(to: .init(x: bx, y: h)) },
                                           with: .color(.white.opacity(0.3)), lineWidth: 1)
                        }
                    }
                    if numbered {
                        let text = context.resolve(Text("\(n)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.7)))
                        context.draw(text, at: CGPoint(x: x + 4, y: h / 2), anchor: .leading)
                    }
                    k += 1
                }
                guard span.to.isFinite else { break }
                base += max(0, Int(((span.to - grid.offset) / bar).rounded(.up) - first))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // the file keeps the tempo the timeline shows (scripts and `simbia` read it from there)
        .task(id: spans.first?.grid) {
            if let grid = spans.first?.grid, job.project != nil, job.project?.grid != grid { job.project?.grid = grid }
        }
    }
}

/// The music's tempo, in the toolbar.
private struct TempoLabel: View {
    @ObservedObject var job: Job
    @ObservedObject private var media = MediaCache.shared

    var body: some View {
        if let grid = job.grid {
            let bpm = abs(grid.bpm - grid.bpm.rounded()) < 0.005 ? String(format: "%.0f", grid.bpm) : String(format: "%.2f", grid.bpm)
            Label(bpm + " BPM", systemImage: "metronome")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .help(job.project?.beatSource != nil
                      ? job.t("Темп и такты определены по музыке и двигаются вместе с ней", "Tempo and bars found in the music; they move with it", "Tempo et mesures détectés dans la musique ; ils se déplacent avec elle")
                      : job.t("Темп из файла проекта — музыки в проекте нет", "Tempo from the project file — the project has no music", "Tempo issu du fichier de projet — le projet n’a pas de musique"))
        }
    }
}

// MARK: - Shots

private struct ShotTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            // track backgrounds let clicks through to the seek layer, so an empty spot moves the playhead
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            if job.project == nil, job.video != nil {
                // A transcribed video is one long shot until it becomes a project.
                Text(job.video?.lastPathComponent ?? "")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10)
                    .frame(width: max(0, scale.x(job.duration) - scale.x(0)), height: MultiTimeline.heights.shots, alignment: .leading)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .offset(x: scale.x(0))
                    .allowsHitTesting(false)
            }
            let shots = job.shots
            ForEach(shots) { shot in
                if scale.visible(shot.start, shot.end) {
                    ShotCell(job: job, shot: shot, scale: scale)
                        .offset(x: scale.x(shot.start))
                }
            }
            // a right click on a shot opens its window
            RightClicks { x in
                let t = scale.time(at: x)
                guard let shot = shots.first(where: { t >= $0.start && t < $0.end }) else { return false }
                withAnimation(Theme.snappy) { job.focus = .shot(shot.id) }
                if job.currentTime < shot.start || job.currentTime >= shot.end { job.seek(shot.start) }
                job.shotTools = shot.id
                return true
            }
            .allowsHitTesting(false)
            // the selected shot's two edges carry its knobs, above every cell so a neighbour does not cover them
            if case .shot(let id) = job.focus, let k = shots.firstIndex(where: { $0.id == id }) {
                let shot = shots[k]
                ForEach([CutHandle.Edge.start, .end], id: \.self) { edge in
                    let x = edge == .start ? shot.start : shot.end
                    if scale.visible(x, x) {
                        CutHandle(job: job, shot: shot, edge: edge, scale: scale,
                                  neighbour: edge == .start ? (k > 0 ? shots[k - 1] : nil) : (k + 1 < shots.count ? shots[k + 1] : nil))
                            .offset(x: scale.x(x) - CutHandle.width / 2)
                    }
                }
            }
            // transitions: a cut that has one always shows its band and its knob (with its icon); the selected
            // shot's cuts without one get a «+» knob that adds it
            ForEach(Array(zip(shots.indices.dropLast(), shots.dropFirst())), id: \.0) { k, next in
                let cut = shots[k].end
                let clip = job.transition(after: shots[k].id)
                let picked: Bool = { if case .shot(let id) = job.focus { return id == shots[k].id || id == next.id }; return false }()
                if scale.visible(cut, cut), clip != nil || picked {
                    if let clip {
                        let half = clip.duration / 2
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(red: 0.62, green: 0.42, blue: 0.98).opacity(0.28))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(red: 0.78, green: 0.66, blue: 1).opacity(0.6), lineWidth: 1))
                            .frame(width: max(4, scale.x(cut + half) - scale.x(cut - half)), height: MultiTimeline.heights.shots - 8)
                            .offset(x: scale.x(cut - half), y: 4)
                            .allowsHitTesting(false)
                    }
                    TransitionKnob(job: job, after: shots[k].id, clip: clip)
                        .offset(x: scale.x(cut) - TransitionKnob.size / 2, y: (MultiTimeline.heights.shots - TransitionKnob.size) / 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The middle knob on a cut: a transition's icon (click — its settings in the Transitions tab), or «+» to add one.
private struct TransitionKnob: View {
    @ObservedObject var job: Job
    let after: String
    let clip: TransitionClip?
    /// Under the pointer: the knob itself or one of the two choices beside it (0 = knob, 1 = «Видео», 2 = «Переход»).
    @State private var over: Set<Int> = []
    @State private var open = false

    static let size: CGFloat = 20

    var body: some View {
        let selected = clip.map { job.focus == .transition($0.id) } ?? false
        let colour = clip == nil ? Color.white : Color(red: 0.66, green: 0.47, blue: 1)
        let grown = open || !over.isEmpty || selected
        ZStack {
            Circle().fill(colour)
                .overlay(Circle().stroke(selected ? Color.white : Color.black.opacity(0.6), lineWidth: selected ? 2 : 1.5))
                .shadow(color: .black.opacity(0.45), radius: 2)
            Image(systemName: clip?.kind.symbol ?? "plus").font(.system(size: clip == nil ? 10 : 9.5, weight: .heavy))
                .foregroundStyle(clip == nil ? Color.black.opacity(0.8) : .white)
        }
        .frame(width: grown ? 24 : 18, height: grown ? 24 : 18)
        .animation(Theme.snappy, value: grown)
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .onHover { hover(0, $0) }
        .onTapGesture {
            if let clip { withAnimation(Theme.snappy) { job.focus = .transition(clip.id); job.libraryTab = .transitions } }
            else { job.addTransition(after: after) }
        }
        // the «+» of a cut without a transition offers both things a cut can take: a clip put in, or a transition
        .overlay(alignment: .trailing) {
            if clip == nil, open {
                choice("film", job.t("Видео", "Clip"), tag: 1) { pickClip() }
                    .offset(x: -(Self.size + 6))
                    .transition(.opacity.combined(with: .offset(x: 8)))
            }
        }
        .overlay(alignment: .leading) {
            if clip == nil, open {
                choice("square.on.square", job.t("Переход", "Transition"), tag: 2) { job.addTransition(after: after) }
                    .offset(x: Self.size + 6)
                    .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
        .help(clip.map { $0.kind.name(job) + String(format: " · %.1f ", $0.duration) + job.t("с — настройки во вкладке «Переходы»", "s — settings in the Transitions tab", "s — réglages dans l’onglet Transitions") }
              ?? job.t("Вставить клип или переход на эту склейку", "Put a clip or a transition on this cut", "Placer un clip ou une transition sur cette coupe"))
        .zIndex(open ? 5 : 2)
    }

    private func choice(_ symbol: String, _ title: String, tag: Int, action: @escaping () -> Void) -> some View {
        let lit = over.contains(tag)
        return Button(action: { over = []; open = false; action() }) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(lit ? Color.black : Color.white)
            .background(lit ? Color.white : Color.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(lit ? 0 : 0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover(tag, $0) }
    }

    /// The choices stay while the pointer is on the knob or on either of them, and go a moment after it leaves all
    /// three (crossing the gap between them doesn't close them).
    private func hover(_ tag: Int, _ inside: Bool) {
        if inside { over.insert(tag); withAnimation(Theme.snappy) { open = true }; return }
        over.remove(tag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if over.isEmpty { withAnimation(Theme.snappy) { open = false } }
        }
    }

    private func pickClip() { job.openClips(insertingAfter: after) }
}

/// The knobs on the selected shot's edges — they belong to that shot. Upper (gold): the cut moves between it and
/// its neighbour (one longer, the other shorter, the edit keeps its length). Lower (white): only this shot gets
/// longer or shorter at that edge — the neighbour stays as it is and everything after slides along. Under the
/// pointer a knob grows and shows its icon inside.
private struct CutHandle: View {
    enum Edge: Hashable { case start, end }

    @ObservedObject var job: Job
    let shot: Shot
    let edge: Edge
    let scale: TimeScale
    /// The shot across this edge (none at the very start or end: no upper knob there).
    let neighbour: Shot?
    @State private var anchor: Double?
    @State private var base: (project: Project, cues: [Cue])?
    /// The knob under the pointer or being dragged: true = upper (roll), false = lower (ripple).
    @State private var hovered: Bool?
    @State private var dragged: Bool?

    static let width: CGFloat = 26
    /// The upper and lower knobs keep the middle of the cut free for the transition knob.
    static let knobHeight: CGFloat = 17

    var body: some View {
        let h = MultiTimeline.heights.shots
        ZStack {
            Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: h - 12).allowsHitTesting(false)
            VStack(spacing: 0) {
                if neighbour == nil { Color.clear.frame(width: Self.width, height: Self.knobHeight).allowsHitTesting(false) }
                else {
                    knob(roll: true)
                        .help(job.t("Верхний: склейка двигается — этот шот длиннее/короче, соседний наоборот",
                                    "Upper: the cut moves — this shot longer/shorter, the neighbour the other way", "Haut : la coupe se déplace — ce plan plus long/court, le voisin à l’inverse"))
                }
                Spacer(minLength: 0)
                knob(roll: false)
                    .help(edge == .end
                          ? job.t("Нижний: конец этого шота — длиннее/короче, следующий не меняется, всё после сдвигается",
                                  "Lower: this shot's end — longer/shorter, the next one stays, everything after slides", "Bas : fin de ce plan — plus long/court, le suivant reste, tout ce qui suit glisse")
                          : job.t("Нижний: начало этого шота — короче/длиннее, предыдущий не меняется, всё после сдвигается",
                                  "Lower: this shot's beginning — shorter/longer, the one before stays, everything after slides", "Bas : début de ce plan — plus court/long, le précédent reste, tout ce qui suit glisse"))
            }
        }
        .frame(width: Self.width, height: h)
        // dragged out of view the handle goes and its drag never ends: let the player catch up
        .onDisappear { if anchor != nil { finish() } }
    }

    /// Gold above (roll), white below (ripple); bigger with its icon inside while under the pointer or dragged.
    private func knob(roll: Bool) -> some View {
        let active = hovered == roll || dragged == roll
        let colour = roll ? Color(red: 0.95, green: 0.78, blue: 0.42) : Color.white
        let symbol = roll ? "arrow.left.arrow.right" : (edge == .end ? "arrow.right.to.line" : "arrow.left.to.line")
        return ZStack {
            Circle().fill(colour)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 2)
            if active {
                Image(systemName: symbol).font(.system(size: 10, weight: .heavy)).foregroundStyle(.black.opacity(0.85))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: active ? 23 : 13, height: active ? 23 : 13)
        .animation(Theme.snappy, value: active)
        .frame(width: Self.width, height: Self.knobHeight).contentShape(Rectangle())
        .onHover { inside in hovered = inside ? roll : (hovered == roll ? nil : hovered) }
        .gesture(drag(roll: roll))
        .pointerStyle(.columnResize)
        .zIndex(active ? 1 : 0)
    }

    private func drag(roll: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if anchor == nil {
                    anchor = edge == .end ? shot.end : shot.start
                    dragged = roll; job.pushHistory(); job.sync.holdRebuild = true; job.shotTools = nil
                    if !roll, let p = job.project { base = (p, job.cues) }
                }
                guard let anchor else { return }
                let time = anchor + Double(value.translation.width) * scale.secondsPerPoint
                let tolerance = scale.secondsPerPoint * 6                       // the beat catches within 6 points
                switch (roll, edge) {
                case (true, .end): job.moveCut(after: shot.id, to: time, snap: tolerance, undoable: false)
                case (true, .start): if let neighbour { job.moveCut(after: neighbour.id, to: time, snap: tolerance, undoable: false) }
                case (false, .end): job.rippleEnd(of: shot.id, to: time, base: base, snap: tolerance, undoable: false)
                case (false, .start): job.rippleStart(of: shot.id, to: time, base: base, snap: tolerance, undoable: false)
                }
                // the frames the edit leaves at the edge, over the picture (as Final Cut): a roll shows both sides of the cut
                switch (roll, edge) {
                case (true, .end): job.showEdges(.cut, of: shot.id)
                case (true, .start): if let neighbour { job.showEdges(.cut, of: neighbour.id) }
                case (false, .end): job.showEdges(.last, of: shot.id)
                case (false, .start): job.showEdges(.first, of: shot.id)
                }
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        EdgePreview.shared.clear()
        anchor = nil; base = nil; dragged = nil
        job.sync.holdRebuild = false
        job.rebuildIfPictureChanged()
    }
}

private struct ShotCell: View {
    @ObservedObject var job: Job
    let shot: Shot
    let scale: TimeScale
    @ObservedObject private var media = MediaCache.shared
    /// While the shot is being dragged to a new place.
    @State private var dragX: CGFloat?
    /// Where a dropped shot goes, while it asks whether its voice and captions go with it.
    @State private var pendingMove: Int?
    /// The whole clip's length (nil for a still), for the strip on top that shows and slips the moment in the shot.
    @State private var clipLength: Double?
    /// The in-point when the strip's drag began.
    @State private var slipFrom: Double?

    private var selected: Bool { job.focus == .shot(shot.id) }
    private var width: Double { max(4, scale.x(shot.end) - scale.x(shot.start) - 2) }
    /// The strip takes the top fifth of the cell.
    private var strip: CGFloat { (clipLength ?? 0) > 0 && width > 30 ? (MultiTimeline.heights.shots / 5).rounded() : 0 }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 5) {
                if width > 30 {
                    Group {
                        if let image = media.thumbnail(shot, projectURL: job.projectURL) {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 24, height: MultiTimeline.heights.shots - 8 - strip)
                    .scaleEffect(x: shot.flip ? -1 : 1, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if width > 60 {
                    Text(shortName)
                        .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        .foregroundStyle(selected ? .black.opacity(0.86) : Theme.text)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .padding(.top, strip)
            .frame(width: width, height: MultiTimeline.heights.shots)
            .background(selected ? AnyShapeStyle(selectableFill(true)) : AnyShapeStyle(Color.white.opacity(0.1)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.white : (shot.dim ? Color.blue.opacity(0.5) : Theme.rowStroke), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    if dragX == nil { job.shotTools = nil }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    // the shot goes where its middle was dropped; it waits there while it asks what goes with it
                    let centre = (shot.start + shot.end) / 2 + Double(value.translation.width) * scale.secondsPerPoint
                    let others = job.shots.filter { $0.id != shot.id }
                    let target = others.firstIndex { centre < ($0.start + $0.end) / 2 } ?? others.count
                    if target == job.shots.firstIndex(where: { $0.id == shot.id }) { dragX = nil } else { pendingMove = target }
                })
            // a double click: replace its video — from the project's own generations (a story), else the UGC library
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                job.clipsFolder != nil ? job.openClips(for: shot.id) : job.openGallery(for: shot.id)
            })
            .onTapGesture { location in
                // a click picks the shot (its knobs appear on its edges) and puts the playhead where it was; the right
                // click opens its window
                withAnimation(Theme.snappy) { job.focus = .shot(shot.id) }
                job.seek(min(shot.end - 0.001, shot.start + location.x * scale.secondsPerPoint))
                job.shotTools = nil
            }
            .popover(isPresented: Binding(get: { job.shotTools == shot.id },
                                          set: { if !$0, job.shotTools == shot.id { job.shotTools = nil } }),
                     arrowEdge: .top) {
                if let current = job.shot(shot.id) { ShotTools(job: job, shot: current).preferredColorScheme(.dark) }
            }
            .help(helpText)
            if strip > 0, let length = clipLength { slipStrip(length) }
            if shot.flagged {                                     // marked for Claude: a red dot in the corner
                Circle().fill(Theme.flag).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                    .padding(5)
                    .frame(width: width, height: MultiTimeline.heights.shots, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: MultiTimeline.heights.shots, alignment: .leading)
        .task(id: shot.src) { clipLength = await Self.length(Project.resolve(shot.src, relativeTo: job.projectURL)) }
        .offset(x: dragX ?? 0)
        .opacity(dragX == nil ? 1 : 0.75)
        .zIndex(dragX == nil ? 0 : 10)
        .popover(isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil; dragX = nil } }),
                 arrowEdge: .top) {
            MoveChoice(job: job) { videoOnly in
                if let target = pendingMove { job.moveShot(shot.id, toIndex: target, videoOnly: videoOnly) }
                pendingMove = nil; dragX = nil
            }
            .preferredColorScheme(.dark)
        }
    }

    /// A mini timeline of the whole clip on top of the cell: the lit part is the moment the shot shows. Dragging it
    /// takes an earlier or later moment (as «−0.5 / +0.5» in the shot's window, but by hand); the shot keeps its place
    /// and length, its own sound slips with it. One undo step per drag.
    private func slipStrip(_ length: Double) -> some View {
        let w = max(1, CGFloat(width) - 12)
        let part = min(1, shot.footage / length)
        let from = min(shot.inPoint / length, 1 - part)
        let gold = Color(red: 1, green: 0.78, blue: 0.3)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.black.opacity(0.4))
            Capsule().fill(gold.opacity(slipFrom == nil ? 0.8 : 1))
                .frame(width: max(4, w * CGFloat(part)))
                .offset(x: w * CGFloat(from))
        }
        .frame(width: w, height: max(4, strip - 4))
        .frame(height: strip + 2)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                if slipFrom == nil {
                    slipFrom = shot.inPoint
                    job.pushHistory()
                    job.shotTools = nil
                    withAnimation(Theme.snappy) { job.focus = .shot(shot.id) }
                }
                let to = (slipFrom ?? shot.inPoint) + Double(value.translation.width / w) * length
                job.slipShot(shot.id, to: to, length: length, undoable: false)
                if job.currentTime < shot.start || job.currentTime >= shot.end { job.seek(shot.start) }
                job.showEdges(.both, of: shot.id)              // its new first and last frames, side by side
            }
            .onEnded { _ in slipFrom = nil; EdgePreview.shared.clear() })
        .help(job.t("Потяните: другой момент клипа — шот остаётся на месте и той же длины, его звук сдвигается вместе с ним",
                    "Drag: another moment of the clip — the shot keeps its place and length, its own sound moves with it", "Glisser : un autre moment du clip — le plan garde sa place et sa durée, son propre son suit")
              + String(format: job.t("\nсейчас %.2f–%.2f с из %.2f с", "\nnow %.2f–%.2f s of %.2f s", "\nactuellement %.2f–%.2f s sur %.2f s"), shot.inPoint, shot.inPoint + shot.footage, length))
        .padding(.horizontal, 6)
        .frame(width: width, height: MultiTimeline.heights.shots, alignment: .top)
    }

    /// A video's length, read once per clip; nil for a still.
    nonisolated private static func length(_ url: URL) async -> Double? {
        guard !Project.stillTypes.contains(url.pathExtension.lowercased()) else { return nil }
        guard let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    private var helpText: String {
        var text = "\(shot.label ?? shot.src)\n\(clock(shot.start)) – \(clock(shot.end))\n" + job.t("Правый клик — настройки шота · двойной — заменить видео", "Right click: the shot's settings · double click: replace its video", "Clic droit : réglages du plan · double-clic : remplacer sa vidéo")
        if shot.flagged {
            let marks: [String] = shot.issues + [shot.note ?? ""]
            text += "\n⚑ " + marks.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return text
    }

    private var shortName: String {
        let name = shot.label ?? (shot.src as NSString).lastPathComponent
        return name.replacingOccurrences(of: #"_ArelSignLips_[0-9a-f_]+$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Pivots

/// Between the picture and the voice: a pivot under the middle of every voice clip. Filled = hooked to the picture, it
/// goes along when a shot over it is moved with its sound; a ring = unhooked, it stays where it is. A click toggles.
/// Lit for the picked clip, or for the clip under the middle of the picked shot.
/// The crop keys over the shot track (overlay videos' too): a ◆ where each key is. A click goes there and picks the
/// shot, a drag moves the key in time (inside its shot, between its neighbours), a right click takes it away.
private struct KeyTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { job.seek(scale.time(at: Double($0.location.x))) })
            // the run between two keys of a shot: its arc, dragged up or down for the speed
            ForEach(job.shots + job.layers) { shot in
                ForEach(Array(shot.keys.indices.dropLast()), id: \.self) { index in
                    let from = shot.start + (shot.keys[index].t - shot.inPoint) / shot.speed, to = shot.start + (shot.keys[index + 1].t - shot.inPoint) / shot.speed
                    if scale.visible(from, to), scale.x(to) - scale.x(from) > 10 {
                        KeyEase(job: job, shot: shot, index: index, from: from, to: to, scale: scale).offset(x: scale.x(from))
                    }
                }
            }
            ForEach(job.shots + job.layers) { shot in
                ForEach(Array(shot.keys.enumerated()), id: \.offset) { index, key in
                    let at = shot.start + (key.t - shot.inPoint) / shot.speed
                    if at >= shot.start - 0.001, at <= shot.end + 0.001, scale.visible(at, at) {
                        KeyDiamond(job: job, shot: shot, index: index, at: at, scale: scale)
                            .offset(x: scale.x(at) - KeyDiamond.size / 2, y: (MultiTimeline.heights.keys - KeyDiamond.size) / 2)
                    }
                }
            }
        }
    }
}

/// Between two crop keys: how the frame gets from one to the next, drawn as its arc. Drag it up and most of the move
/// happens early (a quick push that settles), down and it starts slow and speeds up; straight = even (eased at both ends).
private struct KeyEase: View {
    @ObservedObject var job: Job
    let shot: Shot
    let index: Int
    let from: Double, to: Double
    let scale: TimeScale
    @State private var anchor: Double?
    @State private var hovering = false

    var body: some View {
        let bend = index < shot.keys.count ? (shot.keys[index].ease ?? 0) : 0
        let lit = hovering || anchor != nil
        Canvas { context, size in
            var line = Path()
            for k in 0...32 {
                let u = Double(k) / 32, e0 = Bend.apply(u, bend), e = e0 * e0 * (3 - 2 * e0)
                let p = CGPoint(x: u * size.width, y: size.height - 4 - e * (size.height - 8))
                if k == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            context.stroke(line, with: .color(Color(red: 0.95, green: 0.78, blue: 0.42).opacity(lit ? 1 : 0.55)), lineWidth: lit ? 2 : 1.2)
            if anchor != nil {
                let label = context.resolve(Text(job.t("скорость ", "speed ", "vitesse ") + String(format: "%+.0f %%", bend * 100))
                    .font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white))
                context.draw(label, at: CGPoint(x: size.width / 2, y: 1), anchor: .top)
            }
        }
        .frame(width: max(1, scale.x(to) - scale.x(from)), height: MultiTimeline.heights.keys)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if anchor == nil { anchor = bend; job.pushHistory(); job.sync.holdRebuild = true; job.focus = .shot(shot.id) }
                guard let anchor else { return }
                let b = (max(-1, min(1, anchor - Double(value.translation.height) / 30)) * 20).rounded() / 20
                job.updateShot(shot.id, undoable: false) { if index < $0.keys.count { $0.keys[index].ease = abs(b) < 0.001 ? nil : b } }
            }
            .onEnded { _ in
                anchor = nil
                job.sync.holdRebuild = false
                job.rebuildIfPictureChanged()
            })
        .pointerStyle(.rowResize)
        .help(job.t("Скорость между ключами: тяните вверх — быстрее в начале, вниз — быстрее в конце",
                    "Speed between the keys: drag up for a quick start, down for a quick finish", "Vitesse entre les clés : glisser vers le haut pour un départ rapide, vers le bas pour une fin rapide"))
    }
}

private struct KeyDiamond: View {
    @ObservedObject var job: Job
    let shot: Shot
    let index: Int
    let at: Double
    let scale: TimeScale
    @State private var anchor: Double?
    static let size: CGFloat = 16

    var body: some View {
        let lit = job.focus == .shot(shot.id) || anchor != nil
        let colour = lit ? Color(red: 0.95, green: 0.78, blue: 0.42) : Color.white.opacity(0.7)
        return Rectangle().fill(colour)
            .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 8, height: 8).rotationEffect(.degrees(45))
            .frame(width: Self.size, height: Self.size).contentShape(Rectangle())
            .onTapGesture { withAnimation(Theme.snappy) { job.focus = .shot(shot.id) }; job.seek(at) }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if anchor == nil { anchor = at; job.pushHistory(); job.sync.holdRebuild = true; job.focus = .shot(shot.id) }
                    guard let anchor else { return }
                    let time = anchor + Double(value.translation.width) * scale.secondsPerPoint
                    job.moveCropKey(shot.id, index, to: time, undoable: false)
                    job.seek(min(shot.end - 0.001, max(shot.start, time)))
                }
                .onEnded { _ in
                    anchor = nil
                    job.sync.holdRebuild = false
                    job.rebuildIfPictureChanged()
                })
            .contextMenu {
                Button(job.t("Удалить ключ", "Delete key", "Supprimer la clé")) { job.deleteCropKey(shot.id, index) }
            }
            .pointerStyle(.columnResize)
            .help(job.t("Ключ кадрирования: клик — перейти, тянуть — сдвинуть, правый клик — удалить",
                        "Crop key: click to go there, drag to move it, right click to delete", "Clé de recadrage : clic pour y aller, glisser pour la déplacer, clic droit pour la supprimer"))
    }
}

private struct PivotTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    private static let size: CGFloat = 16

    var body: some View {
        let total = job.project?.duration ?? job.duration
        let picked = job.shots.first { job.focus == .shot($0.id) }
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach((job.project?.audio ?? []).filter { $0.role == .voice }, id: \.id) { clip in
                let end = min(total, clip.duration.map { clip.start + $0 } ?? total)
                if scale.visible(clip.start, end) {
                    let mid = (clip.start + end) / 2
                    let lit = job.focus == .audio(clip.id) || picked.map { clip.start < $0.end && end > $0.start } == true
                    knob(clip, lit: lit)
                        .offset(x: scale.x(mid) - Self.size / 2, y: (MultiTimeline.heights.pivot - Self.size) / 2)
                }
            }
        }
        .frame(height: MultiTimeline.heights.pivot)
    }

    private func knob(_ clip: AudioClip, lit: Bool) -> some View {
        let tone = Color.white.opacity(lit ? 0.95 : 0.5)
        return ZStack {
            Circle().fill(clip.unlinked ? Color.black.opacity(0.7) : tone)
            Circle().stroke(tone, lineWidth: 1.5)
        }
        .frame(width: lit ? 10 : 8, height: lit ? 10 : 8)
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .onTapGesture { job.updateAudio(clip.id) { $0.unlinked.toggle() } }
        .pointerStyle(.link)
        .help(clip.unlinked
              ? job.t("Голос отвязан от видео: остаётся на месте, когда шот двигают. Клик — привязать",
                      "Voice unhooked from the picture: it stays put when a shot is moved. Click to hook it", "Voix détachée de l’image : elle reste en place quand un plan bouge. Cliquer pour l’attacher")
              : job.t("Голос привязан к видео: едет вместе с шотом. Клик — отвязать",
                      "Voice hooked to the picture: it goes with the shot. Click to unhook it", "Voix attachée à l’image : elle suit le plan. Cliquer pour la détacher"))
    }
}

/// The question when a shot is dropped in a new place: does its stretch of voice and captions go with it, or only
/// the picture moves (Esc or a click outside: it stays where it was).
private struct MoveChoice: View {
    @ObservedObject var job: Job
    let pick: (_ videoOnly: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.t("Переместить шот", "Move the shot", "Déplacer le plan")).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            PillGrid {
                Pill(job.t("С голосом и субтитрами", "With the voice and captions", "Avec la voix et les sous-titres"), icon: "rectangle.stack", primary: true) { pick(false) }
                    .keyboardShortcut(.defaultAction)
                    .help(job.t("Его кусок голоса, звуки, субтитры и надписи едут вместе с картинкой",
                                "Its stretch of voice, sounds, captions and titles go with the picture", "Sa portion de voix, de sons, de sous-titres et de titres suit l’image"))
                Pill(job.t("Только видео", "Video only", "Vidéo seule"), icon: "film") { pick(true) }
                    .help(job.t("Меняются местами только картинки; голос, субтитры и надписи остаются как были",
                                "Only the pictures change places; the voice, captions and titles stay as they were", "Seules les images changent de place ; la voix, les sous-titres et les titres restent tels quels"))
            }
        }
        .padding(14)
    }
}

/// Over the timeline: no captions yet — «Создать субтитры» (the Mac listens to every voice clip); made — a green
/// «Субтитры созданы» that opens them under the captions track.
private struct CaptionsState: View {
    @ObservedObject var job: Job

    var body: some View {
        let made = !job.cues.isEmpty
        let green = Color(red: 0.45, green: 0.85, blue: 0.55)
        if made {
            Button { job.libraryTab = .text; job.openDrawer(.captions) } label: {
                Label(job.t("Субтитры созданы · \(job.cues.count)", "Captions made · \(job.cues.count)", "Sous-titres créés · \(job.cues.count)"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 36)
                    .foregroundStyle(green)
                    .background(green.opacity(0.13), in: Capsule())
                    .overlay(Capsule().stroke(green.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(BouncyButtonStyle())
            .help(job.t("Открыть весь текст под дорожкой «Субтитры»", "Open the whole text under the Captions track", "Ouvrir tout le texte sous la piste Sous-titres"))
        } else {
            Pill(job.busy ? job.t("Создаю субтитры…", "Making captions…", "Création des sous-titres…") : job.t("Создать субтитры", "Make captions", "Créer les sous-titres"),
                 icon: "captions.bubble", primary: true) {
                if job.project?.audio.contains(where: { $0.role == .voice }) == true { job.captionsFromAllVoice() } else { job.transcribe() }
            }
            .fixedSize()
            .disabled(job.busy || (job.project == nil && job.video == nil))
            .help(job.t("Mac прослушает голос ролика и поставит субтитры слово в слово", "The Mac listens to the voice and captions it word by word", "Le Mac écoute la voix et la sous-titre mot à mot"))
        }
    }
}

// MARK: - Adding on an empty track

/// The pointer over an empty stretch of a thin track: a dashed cell over the free part of the shot there, saying what a
/// click adds there — the same on every track.
struct AddOffer: ViewModifier {
    @ObservedObject var job: Job
    let scale: TimeScale
    let title: String
    /// What the track already holds, on the edit's clock: no offer over it, and the cell stops at its edges.
    let taken: () -> [(Double, Double)]
    /// The stretch an offer may fill at a time: the shot there unless the track says otherwise (captions: the voice).
    var bounds: ((Double) -> (Double, Double)?)? = nil
    var height = MultiTimeline.heights.titles
    let add: (_ from: Double, _ to: Double) -> Void
    @State private var gap: (from: Double, to: Double)?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let gap {
                    Self.cell(title, width: max(8, scale.x(gap.to) - scale.x(gap.from) - 2), height: height)
                        .onTapGesture { add(gap.from, gap.to); self.gap = nil }
                        .offset(x: scale.x(gap.from))
                }
            }
            .onContinuousHover { phase in
                guard case .active(let point) = phase, job.project != nil else { gap = nil; return }
                let t = scale.time(at: point.x)
                let spans = taken()
                let room = bounds.map { $0(t) } ?? job.shots.first(where: { t >= $0.start && t < $0.end }).map { ($0.start, $0.end) }
                guard let room, !spans.contains(where: { t >= $0.0 && t < $0.1 }) else { gap = nil; return }
                let from = max(room.0, spans.map(\.1).filter { $0 <= t }.max() ?? room.0)
                let to = min(room.1, spans.map(\.0).filter { $0 > t }.min() ?? room.1)
                gap = to - from > 0.1 ? (from, to) : nil
            }
    }

    /// The dashed cell itself, the height of the thin tracks.
    static func cell(_ title: String, width: Double, height: Double = MultiTimeline.heights.titles) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .bold)).lineLimit(1)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(width: width, height: height, alignment: .leading)
            .background(Color(red: 0.12, green: 0.62, blue: 0.68).opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(red: 0.6, green: 0.95, blue: 1).opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
    }
}

// MARK: - Filters

/// The overall filter (the project look): one block over the whole video. A click shows its settings in the Filters tab.
private struct LookTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    @State private var offered = false

    var body: some View {
        let look = job.project?.look
        let selected = job.focus == .look
        let end = job.project?.duration ?? job.duration
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            if job.project != nil, look == nil {
                if offered { AddOffer.cell(job.t("+ Общий фильтр на весь ролик", "+ Overall filter for the whole video", "+ Filtre général sur toute la vidéo"), width: max(8, scale.x(end) - scale.x(0) - 2))
                    .onTapGesture { withAnimation(Theme.snappy) { job.focus = .look; job.libraryTab = .filters }; job.updateLook { _ in } }
                    .offset(x: scale.x(0))
                }
            } else if job.project != nil {
                let on = look?.on ?? false
                Text(look == nil ? job.t("+ Общий фильтр на весь ролик", "+ Overall filter for the whole video", "+ Filtre général sur toute la vidéo")
                     : job.t("Общий фильтр", "Overall filter", "Filtre général") + (on ? "" : " · " + job.t("выключен", "off", "désactivé")))
                    .font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                    .foregroundStyle(look == nil ? Theme.muted : .white)
                    .padding(.horizontal, 9)
                    .frame(width: max(8, scale.x(end) - scale.x(0) - 2), height: MultiTimeline.heights.look, alignment: .leading)
                    .background(look == nil ? AnyShapeStyle(Color.clear)
                                : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.86), Color(red: 0.86, green: 0.45, blue: 0.62)],
                                                               startPoint: .leading, endPoint: .trailing).opacity(on ? (selected ? 1 : 0.7) : 0.25)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(selected ? Color.white : Color.white.opacity(look == nil ? 0.15 : 0.35), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.snappy) { job.focus = .look; job.libraryTab = .filters }
                        if look == nil { job.updateLook { _ in } }
                    }
                    .offset(x: scale.x(0))
                    .help(job.t("Один стиль на все кадры — настройки во вкладке «Фильтры»", "One style over every frame — settings in the Filters tab", "Un seul style sur toutes les images — réglages dans l’onglet Filtres"))
                    .contextMenu {
                        if look != nil {
                            Button(job.t("Удалить общий фильтр", "Delete overall filter", "Supprimer le filtre général"), role: .destructive) { job.deleteLook() }
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onHover { offered = $0 }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Filters over stretches of the edit (adjustment layers): drag to move, drag the right edge to lengthen,
/// click for the settings in the Filters tab. Hovering where there is none offers one over that clip.
private struct FilterTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    @State private var offer: String?                                  // the shot under the pointer with no filter at that point

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            if let id = offer, let shot = job.shots.first(where: { $0.id == id }) {
                AddOffer.cell(job.t("+ Фильтр на длину клипа", "+ Filter for this clip", "+ Filtre pour ce clip"), width: max(8, scale.x(shot.end) - scale.x(shot.start) - 2))
                    .onTapGesture { withAnimation(Theme.snappy) { job.addFilter(over: shot) }; offer = nil }
                    .offset(x: scale.x(shot.start))
            }
            ForEach(job.filters) { clip in
                if scale.visible(clip.start, clip.end) {
                    FilterCell(job: job, clip: clip, scale: scale).offset(x: scale.x(clip.start))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase, job.project != nil else { offer = nil; return }
            let t = scale.time(at: point.x)
            offer = job.filters.contains(where: { t >= $0.start && t < $0.end }) ? nil
                : job.shots.first(where: { t >= $0.start && t < $0.end })?.id
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct FilterCell: View {
    @ObservedObject var job: Job
    let clip: FilterClip
    let scale: TimeScale
    @State private var anchor: (start: Double, length: Double)?

    private var selected: Bool { job.focus == .filter(clip.id) }
    private var width: Double { max(8, scale.x(clip.end) - scale.x(clip.start) - 2) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text((clip.label ?? job.t("Фильтр", "Filter", "Filtre")) + (clip.grade.on ? "" : " · " + job.t("выкл", "off", "désactivé")))
                .font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(width: width, height: MultiTimeline.heights.filters, alignment: .leading)
                .background(Color(red: 0.12, green: 0.62, blue: 0.68).opacity(clip.grade.on ? (selected ? 1 : 0.72) : 0.3),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.white : Color(red: 0.6, green: 0.95, blue: 1).opacity(0.5), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    withAnimation(Theme.snappy) { job.focus = .filter(clip.id); job.libraryTab = .filters }
                    job.seek(min(clip.end - 0.001, clip.start + location.x * scale.secondsPerPoint))   // the playhead where the click was
                }
                .gesture(drag(resize: false))
                .help("\(clip.label ?? job.t("Фильтр", "Filter", "Filtre"))\n\(clock(clip.start)) – \(clock(clip.end))")
                .contextMenu {
                    Button(job.t("Удалить фильтр", "Delete filter", "Supprimer le filtre"), role: .destructive) { job.deleteFilter(clip.id) }
                }

            if width > 24 || anchor != nil {
                Rectangle().fill(Color.clear).frame(width: 10, height: MultiTimeline.heights.filters)
                    .contentShape(Rectangle())
                    .overlay(Capsule().fill(Color.white.opacity(0.7)).frame(width: 3, height: 13))
                    .gesture(drag(resize: true))
                    .pointerStyle(.columnResize)
            }
        }
        .frame(width: width, height: MultiTimeline.heights.filters, alignment: .leading)
        .onDisappear { anchor = nil }
    }

    /// Drag the block to move the filter, its right edge to change how long it lasts; edges stick to the cuts.
    private func drag(resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if anchor == nil { anchor = (clip.start, clip.duration); job.pushHistory(); job.focus = .filter(clip.id); job.libraryTab = .filters }
                guard let anchor else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let tolerance = scale.secondsPerPoint * 6
                let edges = job.shots.flatMap { [$0.start, $0.end] }
                func cut(_ t: Double) -> Double {                      // a shot's edge within 6 points catches it
                    edges.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) <= tolerance ? $0 : nil } ?? t
                }
                job.updateFilter(clip.id, undoable: false) { f in
                    if resize { f.duration = max(0.2, cut(anchor.start + anchor.length + delta) - anchor.start) }
                    else {
                        let s = cut(anchor.start + delta), e = cut(anchor.start + delta + anchor.length) - anchor.length
                        f.start = max(0, abs(s - (anchor.start + delta)) <= abs(e - (anchor.start + delta)) ? s : e)
                    }
                }
            }
            .onEnded { _ in anchor = nil }
    }
}

// MARK: - Titles

private struct TitleTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            ForEach(job.titles.filter { !$0.isGraphic }) { item in
                if scale.visible(item.start, item.end) {
                    TitleCell(job: job, item: item, scale: scale).offset(x: scale.x(item.start))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The motion-graphics scenes of the kit and the Trustpilot graphics (T8–T10), each a block to move and to lengthen.
private struct GraphicsTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            ForEach(job.overlays) { clip in
                let end = clip.start + MotionLibrary.duration(clip, projectURL: job.projectURL)
                if scale.visible(clip.start, end) {
                    OverlayCell(job: job, clip: clip, end: end, scale: scale).offset(x: scale.x(clip.start))
                }
            }
            ForEach(job.titles.filter(\.isGraphic)) { item in
                if scale.visible(item.start, item.end) {
                    TitleCell(job: job, item: item, scale: scale).offset(x: scale.x(item.start))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct OverlayCell: View {
    @ObservedObject var job: Job
    let clip: OverlayClip
    let end: Double
    let scale: TimeScale
    @State private var anchor: (start: Double, length: Double)?

    private var selected: Bool { job.focus == .overlay(clip.id) }
    private var width: Double { max(8, scale.x(end) - scale.x(clip.start) - 2) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(motionName(clip.label ?? (clip.src as NSString).lastPathComponent, job))
                .font(.system(size: 12, weight: .bold)).lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(width: width, height: MultiTimeline.heights.graphics, alignment: .leading)
                .background(Color(red: 0.33, green: 0.38, blue: 0.86).opacity(selected ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.white : Color(red: 0.7, green: 0.75, blue: 1).opacity(0.5), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    withAnimation(Theme.snappy) { job.focus = .overlay(clip.id) }
                    job.seek(min(end - 0.001, clip.start + location.x * scale.secondsPerPoint))   // the playhead where the click was
                    job.overlayTools = clip.id
                }
                .gesture(drag(resize: false))
                .popover(isPresented: Binding(get: { job.overlayTools == clip.id }, set: { if !$0, job.overlayTools == clip.id { job.overlayTools = nil } }),
                         arrowEdge: .top) {
                    if let current = job.overlay(clip.id) { OverlayTools(job: job, clip: current).preferredColorScheme(.dark) }
                }
                .help("\(clip.label ?? clip.src)\n\(clock(clip.start)) – \(clock(end))")
                .contextMenu {
                    let variants = job.overlayVariants(clip)
                    if !variants.isEmpty {
                        Menu(job.t("Заменить на…", "Replace with…", "Remplacer par…")) {
                            ForEach(variants, id: \.self) { url in
                                Button(url.lastPathComponent) { job.focus = .overlay(clip.id); job.replaceOverlay(clip.id, with: url) }
                            }
                        }
                    }
                }

            if width > 24 || anchor != nil {
                Rectangle().fill(Color.clear).frame(width: 10, height: MultiTimeline.heights.graphics)
                    .contentShape(Rectangle())
                    .overlay(Capsule().fill(Color.white.opacity(0.7)).frame(width: 3, height: 14))
                    .gesture(drag(resize: true))
                    .pointerStyle(.columnResize)
            }
        }
        .frame(width: width, height: MultiTimeline.heights.graphics, alignment: .leading)
        .onDisappear { if anchor != nil { finish() } }
    }

    private func finish() {
        anchor = nil
        job.sync.holdRebuild = false
        job.rebuildIfPictureChanged()
    }

    /// Drag the block to move the scene, its right edge to change how long it stays (it holds its full frame, then fades out).
    private func drag(resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if anchor == nil { anchor = (clip.start, end - clip.start); job.pushHistory(); job.sync.holdRebuild = true; job.focus = .overlay(clip.id) }
                guard let anchor else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let tolerance = scale.secondsPerPoint * 6
                job.updateOverlay(clip.id, undoable: false) { o in
                    if resize { o.duration = max(0.3, job.snapToGrid(anchor.start + anchor.length + delta, tolerance: tolerance) - anchor.start) }
                    else { o.start = max(0, job.snapToGrid(anchor.start + delta, tolerance: tolerance)) }
                }
            }
            .onEnded { _ in finish() }
    }
}

private struct TitleCell: View {
    @ObservedObject var job: Job
    let item: TitleItem
    let scale: TimeScale
    @State private var anchor: (start: Double, duration: Double)?

    private var selected: Bool { job.focus == .title(item.id) }
    private var width: Double { max(8, scale.x(item.end) - scale.x(item.start) - 2) }
    private let red = LinearGradient(colors: [Color(red: 0.89, green: 0.42, blue: 0.47), Color(red: 0.56, green: 0.11, blue: 0.17)],
                                     startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(timelineName(item))
                .font(.system(size: 12, weight: .bold)).lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(width: width, height: MultiTimeline.heights.titles, alignment: .leading)
                .background(item.isGraphic ? AnyShapeStyle(Color(red: 0, green: 0.62, blue: 0.42).opacity(selected ? 1 : 0.75)) : AnyShapeStyle(red.opacity(selected ? 1 : 0.75)),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Color.white : (item.isGraphic ? Color(red: 0.6, green: 1, blue: 0.8) : Color(red: 1, green: 0.75, blue: 0.8)).opacity(0.5),
                            lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    withAnimation(Theme.snappy) { job.focus = .title(item.id) }
                    job.seek(min(item.end - 0.001, item.start + location.x * scale.secondsPerPoint))   // the playhead where the click was
                    job.titleTools = item.id
                }
                .popover(isPresented: Binding(get: { job.titleTools == item.id }, set: { if !$0, job.titleTools == item.id { job.titleTools = nil } }),
                         arrowEdge: .top) {
                    if let current = job.title(item.id) { TitleSettings(job: job, item: current).preferredColorScheme(.dark) }
                }
                .gesture(drag(resize: false))
                .help("\(item.text)\n\(clock(item.start)) · \(seconds(item.duration)) \(job.t("с", "s"))")
                .contextMenu {
                    Button(job.t("Выровнять все заголовки по этому", "Align all titles to this one", "Aligner tous les titres sur celui-ci")) {
                        job.focus = .title(item.id); job.alignTitles(to: item.id)
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled((job.project?.titles.count ?? 0) < 2)
                }

            if width > 24 || anchor != nil {
                Rectangle().fill(Color.clear).frame(width: 10, height: MultiTimeline.heights.titles)
                    .contentShape(Rectangle())
                    .overlay(Capsule().fill(Color.white.opacity(0.7)).frame(width: 3, height: 14))
                    .gesture(drag(resize: true))
                    .pointerStyle(.columnResize)
            }
        }
        .frame(width: width, height: MultiTimeline.heights.titles, alignment: .leading)
        .onDisappear { if anchor != nil { finish() } }
    }

    private func finish() {
        anchor = nil
        job.sync.holdRebuild = false
        job.rebuildIfPictureChanged()
    }

    private func timelineName(_ item: TitleItem) -> String {
        switch TitleStyle(id: item.style)?.number {
        case 8: return "★ Trustpilot · \(item.reviewer.name)"
        case 9: return "★ " + job.t("Коллаж отзывов", "Review collage", "Collage d’avis") + " · \(item.reviews?.count ?? 0)"
        case 10: return "★ " + job.t("Слайдер отзывов", "Review slider", "Carrousel d’avis") + " · \(item.reviews?.count ?? 0)"
        case 13: return "💬 " + job.t("Комментарии", "Comments", "Commentaires") + " · \(item.reviews?.count ?? 0)"
        default: return "\(item.style) · \(item.text.replacingOccurrences(of: "|", with: " "))"
        }
    }

    /// Drag the block to move the title, its right edge to change how long it stays.
    private func drag(resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if anchor == nil { anchor = (item.start, item.duration); job.pushHistory(); job.sync.holdRebuild = true; job.focus = .title(item.id) }
                guard let anchor else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                let tolerance = scale.secondsPerPoint * 6
                job.updateTitle(item.id, undoable: false) { t in
                    if resize { t.duration = max(0.5, job.snapToGrid(anchor.start + anchor.duration + delta, tolerance: tolerance) - anchor.start) }
                    else { t.start = max(0, job.snapToGrid(anchor.start + delta, tolerance: tolerance)) }
                }
            }
            .onEnded { _ in finish() }
    }
}

// MARK: - Captions

private struct CaptionTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    var body: some View {
        let (ordered, marks) = job.orderedAndStarts
        let starts = Set(zip(ordered, marks).filter(\.1).map(\.0.id))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)).allowsHitTesting(false)
            ForEach(job.cues) { cue in
                if scale.visible(cue.start, cue.end) {
                    CaptionCell(job: job, cue: cue, scale: scale, startsParagraph: starts.contains(cue.id))
                        .offset(x: scale.x(cue.start))
                        .animation(Theme.snappy, value: cue.start)
                        .animation(Theme.snappy, value: cue.end)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CaptionCell: View {
    @ObservedObject var job: Job
    let cue: Cue
    let scale: TimeScale
    /// Drawn with a gold mark on its left edge.
    let startsParagraph: Bool

    @State private var anchorStart: Double?
    @State private var anchorEnd: Double?
    /// The captions when a drag began: a moved caption trims its neighbours from these, so dragging back restores them.
    @State private var baseCues: [Cue]?
    @State private var dragging = false

    private var snapTolerance: Double { scale.secondsPerPoint * 6 }
    /// In the selection (one of several, or the only one).
    private var selected: Bool { job.focus == .caption && job.selection.contains(cue.id) }
    /// The one the inspector shows: white outline, and its edges can be dragged.
    private var anchor: Bool { selected && job.selected == cue.id }
    private var width: Double { max(6, scale.x(cue.end) - scale.x(cue.start) - 2) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        // the word lane under the selected caption, once it is wide enough to tell the words apart
        let count = job.timedWords(of: cue).count
        let lane = anchor && job.selection.count == 1 && count > 1 && width / Double(count) >= 16
        ZStack(alignment: .leading) {
            words(lane: lane)
                .padding(.leading, startsParagraph ? 9 : 6).padding(.trailing, 6)
                .frame(width: width, height: MultiTimeline.heights.captions, alignment: .leading)
                .background(selected ? AnyShapeStyle(selectableFill(true)) : AnyShapeStyle(Color.white.opacity(0.12)), in: shape)
                .overlay(shape.stroke(anchor ? Color.white : selected ? Color.white.opacity(0.55) : Theme.rowStroke,
                                      lineWidth: anchor ? 2 : 1))
                .clipShape(shape)
                .contentShape(shape)
                .onTapGesture { location in tap(at: location.x) }
                .gesture(move)
                .contextMenu { CaptionMenu(job: job, cue: cue) }

            WordMarks(job: job, cue: cue, scale: scale, width: width, lane: lane, ticks: !lane && spreadOut)

            if width > 24 {
                HStack(spacing: 0) {
                    edge(isEnd: false)
                    Spacer(minLength: 0)
                    edge(isEnd: true)
                }
                .frame(width: width, height: MultiTimeline.heights.captions)
            }

            if startsParagraph {
                Capsule().fill(Color(red: 0.95, green: 0.78, blue: 0.42))
                    .frame(width: 3, height: MultiTimeline.heights.captions - 14)
                    .padding(.leading, 3)
                    .allowsHitTesting(false)
                    .help(job.t("Начало абзаца", "Paragraph start", "Début de paragraphe"))
            }

        }
        .frame(width: width, height: MultiTimeline.heights.captions)
        .scaleEffect(dragging ? 1.05 : 1)
        .shadow(color: .black.opacity(dragging ? 0.55 : 0), radius: dragging ? 10 : 0, y: dragging ? 4 : 0)
        .zIndex(dragging ? 1 : 0)
        .help("\(cue.text)\n\(clock(cue.start)) – \(clock(cue.end))  (\(seconds(cue.end - cue.start)) \(job.t("с", "s")))")
        .onDisappear { if anchorStart != nil { end() } }
    }

    /// ⇧ adds the range, ⌘ adds or removes this one; a second click on the only selected caption edits its text.
    /// `x`: where in the caption the click was — the playhead goes there. The drawer under the captions opens on the
    /// picked ones (⇧ / ⌘ add to them), to edit there.
    private func tap(at x: Double) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            job.click(cue, extend: flags.contains(.shift), toggle: flags.contains(.command))
        } else {
            withAnimation(Theme.snappy) { job.select(cue) }
            job.seek(min(cue.end - 0.001, cue.start + x * scale.secondsPerPoint))
        }
        job.libraryTab = .paragraph
        job.openDrawer(.captions)
    }

    /// Zoomed in far enough for every word to sit at its own time.
    private var spreadOut: Bool {
        let list = job.timedWords(of: cue)
        return list.count > 1 && list.indices.allSatisfy { i in
            scale.x(i + 1 < list.count ? list[i + 1].start : cue.end) - scale.x(list[i].start) >= Double(list[i].text.count) * 6.8 + 6
        }
    }

    /// The words, accent words in gold — what the style will emphasise. Each word sits at its own time when
    /// zoomed in far enough, and always on the selected caption, between the separators that move it (a word
    /// longer than its time is cut short there); otherwise the caption reads as one line.
    @ViewBuilder private func words(lane: Bool) -> some View {
        let list = job.timedWords(of: cue)
        let gold = selected ? Color(red: 0.54, green: 0.35, blue: 0.0) : Color(red: 0.95, green: 0.78, blue: 0.42)
        let base = selected ? Color.black.opacity(0.86) : Theme.text
        if lane || spreadOut {
            let origin = scale.x(cue.start) + (startsParagraph ? 9 : 6) - 3
            let ends = list.indices.map { i in scale.x(i + 1 < list.count ? list[i + 1].start : cue.end) - origin }
            ZStack(alignment: .leading) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, w in
                    let from = max(0, scale.x(w.start) - origin)
                    Text(w.text)
                        .font(.system(size: 11.5, weight: w.accent ? .heavy : .semibold))
                        .foregroundStyle(w.accent ? gold : base)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: max(0, ends[i] - from - 6), alignment: .leading)
                        .offset(x: from)
                }
            }
        } else {
            list.enumerated().reduce(Text("")) { text, item in
                let (i, w) = item
                let piece = Text((i > 0 ? " " : "") + w.text)
                    .font(.system(size: 11.5, weight: w.accent ? .heavy : .semibold))
                    .foregroundStyle(w.accent ? gold : base)
                return text + piece
            }
            .lineLimit(1)
        }
    }

    private func begin() {
        guard anchorStart == nil else { return }
        withAnimation(Theme.snappy) { dragging = true }
        anchorStart = cue.start
        anchorEnd = cue.end
        baseCues = job.cues
        job.pushHistory()
        job.selected = cue.id
        job.focus = .caption
    }

    private func end() {
        anchorStart = nil
        anchorEnd = nil
        baseCues = nil
        withAnimation(Theme.bounce) { dragging = false }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                begin()
                guard let from = anchorStart, let to = anchorEnd else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                job.move(cue.id, to: max(0, from + delta), keeping: to - from, snapping: snapTolerance, base: baseCues)
            }
            .onEnded { _ in end() }
    }

    /// A grip on each end: dragged, the caption starts or ends there (longer or shorter).
    private func edge(isEnd: Bool) -> some View {
        Rectangle().fill(Color.clear).frame(width: 8, height: MultiTimeline.heights.captions)
            .contentShape(Rectangle())
            .overlay(Capsule().fill(selected ? Color.black.opacity(0.45) : Color.white.opacity(0.35)).frame(width: 3, height: 16))
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    begin()
                    guard let from = anchorStart, let to = anchorEnd else { return }
                    let delta = Double(value.translation.width) * scale.secondsPerPoint
                    job.trimCaption(cue.id, start: isEnd ? nil : from + delta, end: isEnd ? to + delta : nil,
                                    snapping: snapTolerance, base: baseCues)
                }
                .onEnded { _ in end() })
            .pointerStyle(.columnResize)
            .help(isEnd ? job.s.dragEnd : job.s.dragStart)
    }

}

/// Where each word of a caption starts. On the selected caption, separators between its words, dragged to move
/// where a word starts (to the frame); zoomed in far enough, faint ticks under the other captions' words.
private struct WordMarks: View {
    @ObservedObject var job: Job
    let cue: Cue
    let scale: TimeScale
    let width: Double
    let lane: Bool
    let ticks: Bool
    @State private var anchor: Double?

    var body: some View {
        let words = job.timedWords(of: cue)
        let x = words.map { scale.x($0.start) - scale.x(cue.start) }
        ZStack(alignment: .topLeading) {
            if lane {
                ForEach(Array(words.enumerated().dropFirst()), id: \.offset) { i, w in
                    if x[i] > 4, x[i] < width - 4 { handle(i, x[i], w.start) }
                }
            } else if ticks {
                ForEach(Array(x.enumerated().dropFirst()), id: \.offset) { _, at in
                    if at > 4, at < width - 4 {
                        Rectangle().fill(Color.white.opacity(0.28)).frame(width: 1, height: 9)
                            .offset(x: at - 0.5, y: MultiTimeline.heights.captions - 13)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: MultiTimeline.heights.captions, alignment: .topLeading)
        .onDisappear { anchor = nil }
    }

    private func handle(_ index: Int, _ x: Double, _ start: Double) -> some View {
        Capsule().fill(Color.black.opacity(0.5)).frame(width: 1.5, height: 26)
            .frame(width: 9, height: MultiTimeline.heights.captions)
            .contentShape(Rectangle())
            .offset(x: x - 4.5)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if anchor == nil { anchor = start; job.pushHistory() }
                    guard let anchor else { return }
                    job.moveWordStart(cue.id, word: index, to: anchor + Double(value.translation.width) * scale.secondsPerPoint)
                }
                .onEnded { _ in anchor = nil })
            .pointerStyle(.columnResize)
            .help(job.t("Тяните: здесь начинается слово", "Drag: where the word starts", "Glisser : début du mot"))
    }
}

/// Right-click on a caption, in the timeline and in the text panel.
struct CaptionMenu: View {
    @ObservedObject var job: Job
    let cue: Cue

    var body: some View {
        let words = job.timedWords(of: cue)
        let (ordered, starts) = job.orderedAndStarts
        let k = ordered.firstIndex { $0.id == cue.id } ?? 0
        let inSelection = job.selection.contains(cue.id) && job.selection.count > 1

        if inSelection {
            Button(job.t("Объединить выделенные (\(job.selection.count)) · M", "Join selected (\(job.selection.count)) · M", "Fusionner la sélection (\(job.selection.count)) · M")) { job.mergeSelection() }
            Button(job.t("Сделать одним абзацем", "Make one paragraph", "Faire un seul paragraphe")) { job.joinParagraphs(of: job.selectedCues.map(\.id)) }
            Divider()
        }
        if words.count > 1 {
            Menu(job.t("Разделить перед словом", "Split before word", "Scinder avant le mot")) {
                ForEach(1..<words.count, id: \.self) { i in
                    Button(words[i].text) { job.splitCaption(cue.id, beforeWord: i); job.selected = cue.id }
                }
            }
        }
        Button(job.t("Объединить с предыдущим", "Join with previous", "Fusionner avec le précédent")) { job.mergeWithPrevious(cue.id) }.disabled(k == 0)
        Button(job.t("Объединить со следующим", "Join with next", "Fusionner avec le suivant")) { job.mergeWithNext(cue.id) }.disabled(k + 1 >= ordered.count)
        Divider()
        Button(job.t("Пересчитать по словам", "Re-time to the words", "Recaler sur les mots") + (inSelection ? " (\(job.selection.count))" : "")) {
            job.syncToVoice(inSelection ? job.selection : [cue.id])
        }
        Button(job.t("Пересчитать все субтитры по словам", "Re-time all captions to the words", "Recaler tous les sous-titres sur les mots")) { job.syncToVoice(nil) }
        Divider()
        if k > 0 {
            Button(starts.indices.contains(k) && starts[k]
                   ? job.t("Соединить с предыдущим абзацем · ↩", "Join with previous paragraph · ↩", "Fusionner avec le paragraphe précédent · ↩")
                   : job.t("Начать абзац с этого субтитра · ↩", "Start a paragraph here · ↩", "Commencer un paragraphe ici · ↩")) { job.toggleParagraph(at: cue.id) }
        }
        Button(job.t("Выделить абзац", "Select paragraph", "Sélectionner le paragraphe")) { job.selectParagraph(containing: cue.id) }
        Divider()
        Button(job.t("Удалить", "Delete", "Supprimer") + (inSelection ? " (\(job.selection.count))" : "") + " · ⌫", role: .destructive) {
            if !inSelection { job.select(cue) }
            job.deleteSelection()
        }
    }
}

// MARK: - Sound

/// One sound track: the voice in white, or the music (and effects) in pink with its dips under the voice.
/// Every clip is a block: drag it to move it, drag its edge to trim it, click it to select it and open its
/// volume (S then cuts it at the playhead, ⌫ deletes it). A drag on the empty track scrubs. A track dropped from
/// Finder on the music track plays from where it is dropped.
private struct AudioTrack: View {
    @ObservedObject var job: Job
    let scale: TimeScale
    let roles: [AudioClip.Role]
    @ObservedObject private var media = MediaCache.shared
    @State private var dropping = false
    @State private var clickedX = 0.0
    /// The time under the last click: the volume window's «Разрезать здесь» cuts there.
    @State private var clickedTime: Double?
    @State private var grabbed: Grab?

    private enum Mode { case move, head, tail, scrub, fadeIn, fadeOut, fadeInCurve, fadeOutCurve }
    /// What a drag holds: the clip, its span and (for a fade knob or slope) that fade and its arc when the drag began.
    private struct Grab { let id: String; let mode: Mode; let start: Double; let end: Double; var fade = 0.0; var bend = 0.0 }
    /// The track's height: where a fade's slope runs on it.
    private var trackHeight: Double { Double(roles.contains(.voice) ? MultiTimeline.heights.voice : MultiTimeline.heights.music) }
    /// The fade knobs: their size, and how far down the track a press still takes one (below it the edge trims).
    private static let knob = 9.0, knobZone = 16.0
    /// Points from a clip's edge that trim it instead of moving it.
    private static let edge = 6.0

    var body: some View {
        Canvas { context, size in
            for clip in clips where roles.contains(clip.role) {
                if let values = media.envelope(clip, projectURL: job.projectURL), !values.isEmpty {
                    let duck = clip.role != .voice && clip.duck ? job.project.flatMap { media.duckCurve($0, clip: clip, projectURL: job.projectURL) } : nil
                    let color = clip.role == .voice ? Color.white.opacity(0.78) : Color(red: 0.91, green: 0.55, blue: 0.63).opacity(0.78)
                    draw(values, clip: clip, duck: duck, in: &context, top: 2, height: size.height - 4, width: size.width, color: color)
                }
                let (a, b) = span(clip)
                let block = CGRect(x: scale.x(a), y: 1, width: max(2, scale.x(b) - scale.x(a)), height: size.height - 2)
                let selected = job.focus == .audio(clip.id)
                context.stroke(Path(roundedRect: block, cornerRadius: 6), with: .color(Color.white.opacity(selected ? 0.9 : 0.22)),
                               lineWidth: selected ? 1.5 : 1)
                // what the piece is (the line it carries), and a red dot when it is marked for Claude
                if let label = clip.label, block.width > 40 {
                    let text = context.resolve(Text(label).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(selected ? 0.95 : 0.6)))
                    context.drawLayer { layer in
                        layer.clip(to: Path(block.insetBy(dx: 5, dy: 1)))
                        layer.draw(text, at: CGPoint(x: block.minX + 6, y: block.minY + 2), anchor: .topLeading)
                    }
                }
                if clip.flagged {
                    context.fill(Path(ellipseIn: CGRect(x: block.maxX - 11, y: block.minY + 3, width: 7, height: 7)), with: .color(Theme.flag))
                }
                if selected, block.width > 16 {                       // grips: an edge drag trims the clip
                    for x in [block.minX + 3, block.maxX - 6] {
                        context.fill(Path(roundedRect: CGRect(x: x, y: block.midY - 7, width: 3, height: 14), cornerRadius: 1.5),
                                     with: .color(.white))
                    }
                }
                // the fades: a slope from the clip's edge to its knob in the top corner — drag the knob in for a longer fade
                if block.width > 24 {
                    let inX = scale.x(a + clip.fadeIn), outX = scale.x(b - clip.fadeOut)
                    for (edgeX, knobX, on, bend) in [(block.minX, inX, clip.fadeIn > 0.005, clip.fadeInCurve),
                                                     (block.maxX, outX, clip.fadeOut > 0.005, clip.fadeOutCurve)] {
                        if on {
                            // the slope's arc from the silent edge (bottom) to the knob (full level, top)
                            let points = (0...24).map { k -> CGPoint in
                                let u = Double(k) / 24
                                return CGPoint(x: edgeX + (knobX - edgeX) * u, y: block.maxY - 1 - Bend.apply(u, bend) * (block.height - 2))
                            }
                            var shade = Path()
                            shade.move(to: CGPoint(x: edgeX, y: block.minY + 1)); points.forEach { shade.addLine(to: $0) }; shade.closeSubpath()
                            context.fill(shade, with: .color(Color.black.opacity(0.45)))
                            var line = Path()
                            line.move(to: points[0]); points.dropFirst().forEach { line.addLine(to: $0) }
                            let dragged = grabbed.map { $0.id == clip.id && ($0.mode == .fadeInCurve || $0.mode == .fadeOutCurve) } ?? false
                            context.stroke(line, with: .color(Color.white.opacity(dragged ? 1 : 0.8)), lineWidth: dragged ? 2 : 1)
                        }
                        let r = CGRect(x: knobX - Self.knob / 2, y: block.minY + 2, width: Self.knob, height: Self.knob)
                        context.fill(Path(ellipseIn: r), with: .color(Color.white.opacity(selected || on ? 0.95 : 0.45)))
                        context.stroke(Path(ellipseIn: r), with: .color(Color.black.opacity(0.6)), lineWidth: 1)
                    }
                    // while a knob is dragged, its length
                    if let g = grabbed, g.id == clip.id, g.mode != .move, g.mode != .head, g.mode != .tail, g.mode != .scrub {
                        let entering = g.mode == .fadeIn || g.mode == .fadeInCurve
                        let text = g.mode == .fadeIn || g.mode == .fadeOut
                            ? String(format: "%.2f", entering ? clip.fadeIn : clip.fadeOut) + job.t(" с", " s")
                            : job.t("дуга ", "arc ") + String(format: "%+.0f %%", (entering ? clip.fadeInCurve : clip.fadeOutCurve) * 100)
                        let label = context.resolve(Text(text).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white))
                        let x = entering ? inX + 8 : outX - 8
                        context.draw(label, at: CGPoint(x: x, y: block.minY + 3), anchor: entering ? .topLeading : .topTrailing)
                    }
                }
            }
        }
        .background(Color.white.opacity(dropping ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .dropDestination(for: URL.self) { urls, point in
            guard roles.contains(.music), let url = urls.first else { return false }
            job.addMusic(url, at: scale.time(at: Double(point.x)))
            return true
        } isTargeted: { dropping = roles.contains(.music) && $0 }
        .overlay(alignment: .trailing) {
            if let clip = shown, abs(clip.gain - 1) > 0.001 {
                Text(decibels(clip.gain)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.black.opacity(0.6), in: Capsule())
                    .padding(.trailing, 4).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grabbed == nil {
                    guard max(abs(value.translation.width), abs(value.translation.height)) > 3 else { return }
                    if let (clip, mode) = grab(at: Double(value.startLocation.x), y: Double(value.startLocation.y)) {
                        job.pushHistory(); job.sync.holdRebuild = true; job.focus = .audio(clip.id)
                        let (a, b) = span(clip)
                        let entering = mode == .fadeIn || mode == .fadeInCurve
                        grabbed = Grab(id: clip.id, mode: mode, start: a, end: b, fade: entering ? clip.fadeIn : clip.fadeOut,
                                       bend: entering ? clip.fadeInCurve : clip.fadeOutCurve)
                    } else {
                        grabbed = Grab(id: "", mode: .scrub, start: 0, end: 0)
                    }
                }
                guard let g = grabbed else { return }
                let delta = Double(value.translation.width) * scale.secondsPerPoint
                switch g.mode {
                case .scrub: job.seek(scale.time(at: Double(value.location.x)))
                case .move: job.moveAudio(g.id, to: snapped(g.start + delta, length: g.end - g.start), undoable: false)
                case .head: job.trimAudio(g.id, from: snapped(g.start + delta), to: g.end, undoable: false)
                case .tail: job.trimAudio(g.id, from: g.start, to: min(snapped(g.end + delta), sourceEnd(g.id)), undoable: false)
                // a fade at most half the clip, in hundredths of a second
                case .fadeIn: job.updateAudio(g.id, undoable: false) { $0.fadeIn = (max(0, min((g.end - g.start) / 2, g.fade + delta)) * 100).rounded() / 100 }
                case .fadeOut: job.updateAudio(g.id, undoable: false) { $0.fadeOut = (max(0, min((g.end - g.start) / 2, g.fade - delta)) * 100).rounded() / 100 }
                // the slope dragged up or down bends it: up keeps the sound loud for longer, down brings it in gently
                case .fadeInCurve, .fadeOutCurve:
                    let bend = (max(-1, min(1, g.bend - Double(value.translation.height) / 40)) * 20).rounded() / 20
                    job.updateAudio(g.id, undoable: false) { if g.mode == .fadeInCurve { $0.fadeInCurve = bend } else { $0.fadeOutCurve = bend } }
                }
            }
            .onEnded { value in
                if let g = grabbed {
                    grabbed = nil
                    if g.mode != .scrub { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                    return
                }
                let time = scale.time(at: Double(value.location.x))
                guard let clip = clip(at: time) else { return }
                clickedX = Double(value.location.x)
                job.focus = .audio(clip.id)
                // the playhead goes where the click was, so «Разрезать» (S) cuts the sound right there
                let (a, b) = span(clip)
                clickedTime = time > a && time < b ? time : nil
                if let clickedTime { job.seek(clickedTime) }
                job.audioTools = clip.id
            })
        .onContinuousHover { phase in
            guard grabbed == nil else { return }
            if case .active(let point) = phase, let (_, mode) = grab(at: Double(point.x), y: Double(point.y)) {
                (mode == .move ? NSCursor.openHand : mode == .fadeIn || mode == .fadeOut ? NSCursor.pointingHand
                 : mode == .fadeInCurve || mode == .fadeOutCurve ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        // a drag cut short (the track went out of view) must not leave the player waiting
        .onDisappear { if grabbed != nil { grabbed = nil; job.sync.holdRebuild = false; job.rebuildIfPictureChanged() } }
        .popover(isPresented: Binding(get: { job.audioTools.map { id in clips.contains { $0.id == id && roles.contains($0.role) } } ?? false },
                                      set: { if !$0 { job.audioTools = nil } }),
                 attachmentAnchor: .point(UnitPoint(x: clickedX / max(1, scale.width), y: 0)), arrowEdge: .top) {
            if let id = job.audioTools, let clip = job.project?.audio.first(where: { $0.id == id }) {
                AudioTools(job: job, clip: clip, at: clickedTime).preferredColorScheme(.dark)
            }
        }
    }

    /// The track's clip at `time` — or its first one, when the click falls outside them all.
    private func clip(at time: Double) -> AudioClip? {
        let own = (job.project?.audio ?? []).filter { roles.contains($0.role) }
        return own.first { time >= $0.start && time < $0.start + ($0.duration ?? .infinity) } ?? own.first
    }

    /// The clip whose volume the track shows at its end: the first one.
    private var shown: AudioClip? { (job.project?.audio ?? []).first { roles.contains($0.role) } }

    /// Where a clip is on the edit's clock. One without a length plays to the end of its source (or of the edit).
    private func span(_ clip: AudioClip) -> (Double, Double) {
        let total = job.project?.duration ?? job.duration
        let end = clip.duration.map { clip.start + $0 }
            ?? media.length(clip, projectURL: job.projectURL).map { clip.start + ($0 - clip.inPoint) / clip.speed } ?? total
        return (clip.start, max(clip.start + 0.1, min(end, total)))
    }

    /// The furthest a clip's end can go: the end of its source.
    private func sourceEnd(_ id: String) -> Double {
        guard let c = job.audioClip(id), let length = media.length(c, projectURL: job.projectURL) else { return .infinity }
        return c.start + (length - c.inPoint) / c.speed
    }

    /// The clip under `x` and what a drag there does: an edge trims (the side the pointer is on — at a cut, the
    /// end of the clip before or the start of the next), the body moves.
    private func grab(at x: Double, y: Double = .infinity) -> (AudioClip, Mode)? {
        let own = (job.project?.audio ?? []).filter { roles.contains($0.role) }
        // a fade knob in a clip's top corner, before anything else
        if y <= Self.knobZone {
            var near: (clip: AudioClip, mode: Mode, distance: Double)?
            for c in own {
                let (a, b) = span(c)
                guard scale.x(b) - scale.x(a) > 24 else { continue }
                for (knobX, mode) in [(scale.x(a + c.fadeIn), Mode.fadeIn), (scale.x(b - c.fadeOut), Mode.fadeOut)] {
                    let d = abs(x - knobX)
                    if d <= Self.knob, d < (near?.distance ?? .infinity) { near = (c, mode, d) }
                }
            }
            if let near { return (near.clip, near.mode) }
        }
        // a fade's slope: within a few points of its arc
        for c in own {
            let (a, b) = span(c)
            for (from, length, bend, mode) in [(a, c.fadeIn, c.fadeInCurve, Mode.fadeInCurve), (b, -c.fadeOut, c.fadeOutCurve, Mode.fadeOutCurve)] {
                guard abs(scale.x(from + length) - scale.x(from)) > 12 else { continue }
                let u = (scale.time(at: x) - from) / length
                guard u > 0.05, u < 0.95 else { continue }
                let lineY = trackHeight - 2 - Bend.apply(u, bend) * (trackHeight - 4)
                if abs(y - lineY) <= 8 { return (c, mode) }
            }
        }
        var best: (clip: AudioClip, mode: Mode, distance: Double)?
        for c in own {
            let (a, b) = span(c)
            let xa = scale.x(a), xb = scale.x(b)
            for (edgeX, mode) in [(xa, Mode.head), (xb, Mode.tail)] {
                let d = abs(x - edgeX)
                guard d <= Self.edge, mode == .head ? x >= xa - 2 : x <= xb + 2 else { continue }
                if d < (best?.distance ?? .infinity) { best = (c, mode, d) }
            }
        }
        if let best { return (best.clip, best.mode) }
        return own.last { let (a, b) = span($0); return x >= scale.x(a) && x <= scale.x(b) }.map { ($0, Mode.move) }
    }

    /// A dragged edge sticks to the playhead when it comes within a few points of it.
    private func snapped(_ time: Double) -> Double {
        abs(scale.x(time) - scale.x(job.currentTime)) <= Self.edge ? job.currentTime : time
    }

    /// A moved clip's start, or its end, sticks to the playhead.
    private func snapped(_ start: Double, length: Double) -> Double {
        if abs(scale.x(start) - scale.x(job.currentTime)) <= Self.edge { return job.currentTime }
        if abs(scale.x(start + length) - scale.x(job.currentTime)) <= Self.edge { return job.currentTime - length }
        return start
    }

    private var clips: [AudioClip] {
        if let project = job.project { return project.audio }
        if let video = job.video { return [AudioClip(id: "v", role: .voice, src: video.path)] }
        return []
    }

    private func draw(_ values: [Float], clip: AudioClip, duck: [Float]?, in context: inout GraphicsContext,
                      top: CGFloat, height: CGFloat, width: CGFloat, color: Color) {
        let peak = max(values.max() ?? 1, 0.0001)
        let rate = 50.0
        var top_: [CGPoint] = [], bottom: [CGPoint] = []
        let step = max(1.0, Double(width) / 400)
        var x = 0.0
        let end = clip.duration.map { clip.start + $0 } ?? .infinity
        while x <= Double(width) {
            let t = scale.time(at: x)
            let k = Int(clip.source(at: t) * rate)                  // the outline covers the whole source
            if t >= clip.start, t < end, k >= 0, k < values.count {
                var v = Double(values[k]) / Double(peak)
                if clip.fadeIn > 0 { v *= Bend.apply((t - clip.start) / clip.fadeIn, clip.fadeInCurve) }
                if clip.fadeOut > 0, end.isFinite { v *= Bend.apply((end - t) / clip.fadeOut, clip.fadeOutCurve) }
                if let duck, !duck.isEmpty {
                    let d = min(duck.count - 1, max(0, Int(t * Project.duckCurveRate)))
                    v *= Double(duck[d])
                }
                let h = max(0.5, min(1, v) * Double(height) / 2)
                top_.append(CGPoint(x: x, y: Double(top) + Double(height) / 2 - h))
                bottom.append(CGPoint(x: x, y: Double(top) + Double(height) / 2 + h))
            }
            x += step
        }
        guard top_.count > 1 else { return }
        // One outline: along the top, back along the bottom. (addLines would start a new subpath.)
        var path = Path()
        path.move(to: top_[0])
        top_.dropFirst().forEach { path.addLine(to: $0) }
        bottom.reversed().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

// MARK: - Playhead and gestures

/// The playhead line: a Core Animation layer moved straight from the clock, so following playback
/// costs no SwiftUI update at all. `pinned`: outside the view it waits at the edge (the timeline); otherwise it hides
/// (a caption's own little timeline).
struct Playhead: NSViewRepresentable {
    let clock: PlayClock
    let scale: TimeScale
    var pinned = true

    func makeNSView(context: Context) -> LineView { LineView(clock: clock) }
    func updateNSView(_ view: LineView, context: Context) { view.scale = scale; view.pinned = pinned; view.place() }

    final class LineView: NSView {
        var scale = TimeScale(start: 0, span: 1, width: 1)
        var pinned = true
        private let clock: PlayClock
        private let marker = CAShapeLayer()
        private var subscription: AnyCancellable?

        init(clock: PlayClock) {
            self.clock = clock
            super.init(frame: .zero)
            wantsLayer = true
            marker.fillColor = NSColor.white.cgColor
            marker.shadowColor = NSColor.white.cgColor
            marker.shadowOpacity = 0.5
            marker.shadowRadius = 3
            marker.shadowOffset = .zero
            layer?.addSublayer(marker)
            subscription = clock.ticks.sink { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // a 12 × 7 triangle on top of a 2 pt line (y up), drawn once; only the position changes
            let h = bounds.height
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 0, y: h), CGPoint(x: 12, y: h), CGPoint(x: 6, y: h - 7)])
            path.closeSubpath()
            path.addRect(CGRect(x: 5, y: 0, width: 2, height: h - 7))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            marker.bounds = CGRect(x: 0, y: 0, width: 12, height: h)
            marker.path = path
            marker.shadowPath = path            // the glow from the shape itself, not from an offscreen pass
            CATransaction.commit()
            place()
        }

        func place() {
            let at = scale.x(clock.time), x = min(max(at, 0), Double(bounds.width))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            marker.isHidden = !pinned && abs(at - x) > 0.5
            marker.position = CGPoint(x: x, y: bounds.height / 2)
            CATransaction.commit()
        }
    }
}

/// Right clicks inside the view, caught before SwiftUI sees them (it has no right-click gesture of its own):
/// `handle` gets the x of the click and says whether it used it.
struct RightClicks: NSViewRepresentable {
    let handle: (Double) -> Bool

    func makeNSView(context: Context) -> CatchView { CatchView(handle: handle) }
    func updateNSView(_ view: CatchView, context: Context) { view.handle = handle }

    final class CatchView: NSView {
        var handle: (Double) -> Bool
        private var monitor: Any?

        init(handle: @escaping (Double) -> Bool) {
            self.handle = handle
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                return MainActor.assumeIsolated { self.handle(Double(point.x)) } ? nil : event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

/// Trackpad pinch-to-zoom, Option-scroll zoom and two-finger pan over the timeline.
struct TimelineEvents: NSViewRepresentable {
    let onZoom: (Double) -> Void
    let onPan: (Double) -> Void

    func makeNSView(context: Context) -> EventView { EventView(onZoom: onZoom, onPan: onPan) }
    func updateNSView(_ view: EventView, context: Context) { view.onZoom = onZoom; view.onPan = onPan }

    final class EventView: NSView {
        var onZoom: (Double) -> Void
        var onPan: (Double) -> Void
        private var monitor: Any?

        init(onZoom: @escaping (Double) -> Void, onPan: @escaping (Double) -> Void) {
            self.onZoom = onZoom
            self.onPan = onPan
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .magnify {
                    self.onZoom(Double(event.magnification))
                } else if event.modifierFlags.contains(.option) {
                    self.onZoom(Double(event.scrollingDeltaY) / 180)
                } else {
                    self.onPan(Double(event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY))
                }
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
