import AVFoundation
import AVKit
import SimbiaCore
import SwiftUI
import UniformTypeIdentifiers

/// The start screen, two panels: on the left the latest batches of projects (a row per brief card, a square per
/// video — a click opens it), on the right the place a new video comes in (a click picks it, or drop it anywhere).
struct WelcomeView: View {
    @ObservedObject var job: Job
    @State private var targeted = false
    @State private var hovering = false
    @State private var batches: [ProjectBatch] = []

    /// LogoWhiteLoop is the yo-yo build (forward + reversed) so the loop has no jump cut.
    private var brandVideo: URL? {
        Bundle.main.url(forResource: "LogoWhiteLoop", withExtension: "mov")
            ?? Bundle.main.url(forResource: "LogoWhite", withExtension: "mov")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if job.busy { ProcessingAura().ignoresSafeArea().allowsHitTesting(false) }

            HStack(spacing: 14) {
                recent
                upload
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 16)
        }
        // the batches as they are now: on coming back here, and when the project browser closes (statuses change there)
        .task(id: job.browserOpen) { if !job.browserOpen { await loadRecent() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !job.busy, let item = providers.first else { return false }
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                guard let data = value as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { job.open(url) }
            }
            return true
        }
        .overlay { if job.browserOpen { ProjectBrowser(job: job).transition(.opacity) } }
    }

    /// The folder of the last project, by batch, the one changed last on top (the «Другие» without a number left out).
    private func loadRecent() async {
        guard let folder = job.recentProjects.first?.deletingLastPathComponent() else { batches = []; return }
        let cards = await Task.detached(priority: .userInitiated) { ProjectCard.scan(folder) }.value
        let latest = { (b: ProjectBatch) in b.cards.map(\.modified).max() ?? .distantPast }
        batches = ProjectCard.batches(cards.filter { $0.number != nil }).sorted { latest($0) > latest($1) }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(job.t("ПОСЛЕДНИЕ ПРОЕКТЫ", "RECENT PROJECTS", "PROJETS RÉCENTS"))
                    .font(.system(size: 13, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                Spacer()
                Button { job.recentProjects.isEmpty ? job.projectPicker() : job.openBrowser() } label: {
                    Label(job.t("ВСЕ ПРОЕКТЫ", "ALL PROJECTS", "TOUS LES PROJETS"), systemImage: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold)).tracking(1)
                        .padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(Theme.text)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(BouncyButtonStyle())
                .help(job.t("Все проекты: статусы, что сделано и что предстоит", "All projects: status, done and to do", "Tous les projets : statut, fait et à faire"))
            }
            .padding(.horizontal, 18).frame(height: 58)

            if batches.isEmpty {
                Text(job.recentProjects.isEmpty ? job.t("Пока нет проектов", "No projects yet", "Aucun projet pour l’instant") : "")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // six rows fill the panel; more scroll
                GeometryReader { proxy in
                    let row = max(64, (proxy.size.height - 5 * 10) / 6)
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(batches) { BatchRow(job: job, batch: $0, height: row) }
                        }
                    }
                    .scrollIndicators(.never)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panel(lit: false))
    }

    private var upload: some View {
        ZStack {
            if job.busy {
                VStack(spacing: 22) {
                    if let brandVideo { BrandVideo(url: brandVideo, playing: true).frame(width: 240, height: 240) }
                    ProcessingHUD(progress: job.progress, status: job.status, title: job.s.processing)
                }
                .padding(24)
            } else {
                Button { job.videoPicker() } label: {
                    VStack(spacing: 16) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 64, weight: .light))
                            .scaleEffect(hovering || targeted ? 1.08 : 1)
                        Text(job.s.uploadVideo).font(.system(size: 15, weight: .medium)).tracking(1.2)
                        Text(job.t("или перетащи файл сюда", "or drop a file here", "ou déposez un fichier ici"))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Theme.snappy) { hovering = h } }

                VStack(spacing: 10) {
                    Spacer()
                    SpeechLanguage(job: job)
                    if job.video != nil {
                        Text(job.status)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: 380)
                        // Without this the user is stranded here when transcription fails —
                        // srtPicker() is otherwise only reachable from inside the editor.
                        Button(job.s.loadExistingSRT, action: job.srtPicker)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panel(lit: !job.busy && (targeted || hovering)))
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func panel(lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return shape.fill(Color.white.opacity(lit ? 0.07 : 0.035))
            .overlay(shape.stroke(Color.white.opacity(lit ? 0.85 : 0.14), lineWidth: lit ? 1.5 : 1))
    }
}

/// A batch on the start screen: its numbers, kind and statuses, then a square per video.
private struct BatchRow: View {
    @ObservedObject var job: Job
    let batch: ProjectBatch
    let height: CGFloat

    var body: some View {
        let first = batch.cards[0]
        let parts = first.name.split(separator: " ", maxSplits: 2).map(String.init)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.title.components(separatedBy: " · ")[0])
                    .font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text)
                Text((parts.count > 2 ? parts[2] : first.category).replacingOccurrences(of: " - ", with: " · "))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 8) {
                    ForEach(ProjectStatus.allCases, id: \.self) { s in
                        let n = batch.cards.filter { $0.status == s }.count
                        if n > 0 { Text(s.count(n)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(s.colour).lineLimit(1) }
                    }
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            ForEach(batch.cards) { RecentTile(job: job, card: $0, side: height - 18) }
        }
        .padding(.horizontal, 9)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// A video of the batch: a square of its first shot ringed in its status colour, its number in the corner; a click opens it.
private struct RecentTile: View {
    @ObservedObject var job: Job
    let card: ProjectCard
    let side: CGFloat
    @State private var still: CGImage?
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button { job.openProject(card.url) } label: {
            ZStack(alignment: .bottomLeading) {
                card.status.colour.opacity(0.14)
                if let still {
                    Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill).frame(width: side, height: side)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                Text(card.number.map(String.init) ?? "")
                    .font(.system(size: 10.5, weight: .heavy).monospacedDigit()).foregroundStyle(.white).padding(5)
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.stroke(hover ? Color.white : card.status.colour, lineWidth: hover ? 2.5 : 1.5))
            .contentShape(shape)
            .scaleEffect(hover ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.snappy) { hover = h } }
        .help(card.name + " · " + card.status.title)
        .task(id: card.id) { if let poster = card.poster { still = await ClipStills.shared.frame(poster, at: card.posterAt) } }
    }
}

private struct ProcessingHUD: View {
    let progress: Int
    let status: String
    let title: String
    @State private var spin = false

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .medium))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                Text(title).font(.system(size: 16, weight: .medium)).tracking(1.6)
            }
            .foregroundStyle(Theme.text)

            Text("\(progress)%  ·  \(status)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .onAppear {
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// Light bleeding inward from the window edges while the local engine runs.
/// `strokeBorder` keeps the stroke inside the shape, so blurring it glows inwards; the mask
/// then clips whatever spills past the edge.
private struct ProcessingAura: View {
    @State private var breathe = false

    private let radius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.white.opacity(breathe ? 0.50 : 0.20), lineWidth: 34)
                .blur(radius: 26)
                .mask(shape)

            shape.strokeBorder(Color.white.opacity(breathe ? 0.85 : 0.35), lineWidth: 6)
                .blur(radius: 7)
                .mask(shape)

            shape.strokeBorder(Color.white.opacity(breathe ? 0.75 : 0.30), lineWidth: 1)
        }
        .drawingGroup()
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

struct BrandVideo: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: context.coordinator.player, templateItem: item)
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if playing {
            context.coordinator.player.play()
        } else {
            context.coordinator.player.pause()
            context.coordinator.player.seek(to: .zero)
        }
    }

    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
    }
}

/// «Язык речи»: what the Mac listens for when a video is transcribed (English unless another is picked).
private struct SpeechLanguage: View {
    @ObservedObject var job: Job
    @State private var languages: [Locale] = []
    @State private var current = MacSpeech.locale

    var body: some View {
        Menu {
            ForEach(languages, id: \.identifier) { locale in
                Button(MacSpeech.name(locale, in: job.language.rawValue)) { MacSpeech.locale = locale; current = locale }
            }
        } label: {
            Label(job.t("Язык речи: ", "Speech: ", "Langue de la parole : ") + MacSpeech.name(current, in: job.language.rawValue), systemImage: "waveform")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.muted)
        .help(job.t("Речь распознаёт сам Mac, на устройстве", "Speech is recognised by the Mac itself, on the device", "La parole est reconnue par le Mac lui-même, sur l’appareil"))
        .task { languages = await MacSpeech.languages() }
    }
}
