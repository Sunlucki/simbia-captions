import AVFoundation
import AppKit
import SimbiaCore
import SwiftUI

extension Job {
    /// «Аудиобиблиотека» over the whole window (the Music track's name, «Другой трек…» in a music clip's window).
    func openMusic() {
        audioTools = nil
        withAnimation(Theme.settle) { musicOpen = true }
    }

    func closeMusic() {
        MusicPreview.shared.stop()
        withAnimation(Theme.settle) { musicOpen = false }
    }

    /// `track` as the project's music, one undo step: every music clip gets its file and name, keeps its place, length,
    /// fades and ducking, and a gain that keeps it as loud as it was (`MusicLibrary.matched`). A project without music gets
    /// the track over the whole edit at the house level — as loud as `Brand.houseMusic` at 0.025 — fading out over 1.15 s.
    func useMusic(_ track: MusicLibrary.Track) {
        guard let start = project else { return }
        let ffmpeg = self.ffmpeg, url = projectURL
        Task { [weak self] in
            guard let new = await MusicLibrary.sound(of: track.url, ffmpeg: ffmpeg), let self else { return }
            // the loudness of what each bed plays now (or of the house track for a project without one)
            var before: [String: Double] = [:]
            for clip in start.audio where clip.role == .music {
                let file = Project.resolve(clip.src, relativeTo: url)
                if before[file.path] == nil, let l = await MusicLibrary.sound(of: file, ffmpeg: ffmpeg)?.lufs { before[file.path] = l }
            }
            var house: Double?
            if !start.audio.contains(where: { $0.role == .music }), let root = MusicLibrary.find(near: url), let track = Brand.current.houseMusic {
                house = await MusicLibrary.sound(of: root.appending(path: track), ffmpeg: ffmpeg)?.lufs
            }
            guard var p = self.project else { return }
            var notes: [String] = []
            let beds = p.audio.indices.filter { p.audio[$0].role == .music }
            if beds.isEmpty {
                let gain = house.flatMap { h in new.lufs.map { MusicLibrary.matched(gain: 0.025, from: h, to: $0) } } ?? 0.025
                var clip = AudioClip(id: Project.newID("a"), role: .music, src: track.url.path, start: 0, inPoint: 0,
                                     duration: p.duration, gain: gain, fadeOut: 1.15)
                clip.label = track.name
                p.audio.append(clip)
                notes.append(String(format: "gain %.4f", gain))
            }
            for k in beds {
                let old = p.audio[k]
                let was = before[Project.resolve(old.src, relativeTo: url).path]
                let gain = was.flatMap { w in new.lufs.map { MusicLibrary.matched(gain: old.gain, from: w, to: $0) } } ?? old.gain
                p.audio[k].src = track.url.path
                p.audio[k].label = track.name
                p.audio[k].gain = gain
                notes.append(String(format: "gain %.4f → %.4f", old.gain, gain))
                if let length = old.duration, new.duration < old.inPoint + length - 0.05 {
                    notes.append(self.t(String(format: "трек короче на %.1f с", old.inPoint + length - new.duration),
                                        String(format: "the track is %.1f s short", old.inPoint + length - new.duration), String(format: "le morceau est trop court de %.1f s", old.inPoint + length - new.duration)))
                }
            }
            self.pushHistory()
            self.project = p
            self.show(self.t("Музыка: «\(track.title)» · ", "Music: «\(track.title)» · ", "Musique : « \(track.title) » · ") + notes.joined(separator: " · ")
                      + (new.lufs == nil ? self.t(" · громкость не измерена (нет ffmpeg)", " · loudness not measured (no ffmpeg)", " · sonie non mesurée (pas de ffmpeg)") : ""),
                      isError: false)
        }
    }
}

/// Listening to a track in the library: one at a time, from its start; the edit's player is paused meanwhile.
@MainActor final class MusicPreview: ObservableObject {
    static let shared = MusicPreview()
    @Published private(set) var playing: URL?
    @Published private(set) var progress = 0.0
    private let player = AVPlayer()
    private var observer: Any?

    func toggle(_ url: URL, pausing other: AVPlayer) {
        if playing == url { stop(); return }
        other.pause()
        stop()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        playing = url
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d > 0 else { return }
                self.progress = t.seconds / d
                if t.seconds >= d - 0.05 { self.stop() }
            }
        }
        player.play()
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        playing = nil
        progress = 0
    }
}

/// The music library, full window, as the footage library: folders on the left, a card per track — its name, length,
/// outline and loudness, where it is already the music (so a bed is not used again and again), a button to listen and
/// one to put it in (a double click does too).
struct MusicLibraryView: View {
    @ObservedObject var job: Job
    @ObservedObject private var preview = MusicPreview.shared
    @State private var tracks: [MusicLibrary.Track] = []
    @State private var usage: [String: [String]] = [:]
    @State private var loaded = false
    @State private var folder: String?
    @State private var search = ""
    @State private var freeFirst = true
    @State private var asking: MusicLibrary.Track?

    private var root: URL? { MusicLibrary.find(near: job.projectURL) }
    private var beds: [AudioClip] { (job.project?.audio ?? []).filter { $0.role == .music } }
    private var here: String? { job.projectURL.map { MusicLibrary.shortName($0.lastPathComponent) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rowStroke)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Theme.rowStroke)
                grid
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .task { await load() }
        .onDisappear { preview.stop() }
        .confirmationDialog(job.t("В проекте нет музыки. Поставить «\(asking?.title ?? "")» на весь ролик?",
                                  "The project has no music. Put «\(asking?.title ?? "")» over the whole edit?", "Le projet n’a pas de musique. Placer « \(asking?.title ?? "") » sur tout le montage ?"),
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button(job.t("Поставить", "Put it in", "Placer")) { if let t = asking { job.useMusic(t) }; asking = nil }
            Button(job.t("Отмена", "Cancel", "Annuler"), role: .cancel) { asking = nil }
        } message: {
            Text(job.t("Громкость — как у «Hit» на 0.025, затухание в конце 1.15 с.", "Level as «Hit» at 0.025, fading out over 1.15 s.", "Volume comme « Hit » à 0.025, fondu de sortie de 1.15 s."))
        }
    }

    private func load() async {
        guard let root else { loaded = true; return }
        let folder = job.projectURL?.deletingLastPathComponent()
        let (t, u) = await Task.detached(priority: .userInitiated) {
            (MusicLibrary.tracks(in: root), folder.map { MusicLibrary.usage(projectsIn: $0) } ?? [:])
        }.value
        tracks = t; usage = u; loaded = true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.t("Аудиобиблиотека", "Music library", "Bibliothèque musicale")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text(nowLine).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(job.t("Поиск по названию…", "Search by name…", "Rechercher par nom…"), text: $search).textFieldStyle(.plain).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(width: 260, height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            Button { freeFirst.toggle() } label: {
                Text(job.t("Сначала свободные", "Unused first", "Libres d’abord")).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 30)
                    .foregroundStyle(freeFirst ? Color.black : Theme.text)
                    .background(freeFirst ? Color.white : Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(BouncyButtonStyle())
            .help(job.t("Треки, которых ещё нет ни в одном проекте этой папки, — первыми", "Tracks no project in this folder has yet come first", "Les morceaux absents de tous les projets de ce dossier en premier"))
            Button { job.closeMusic() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(BouncyButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(job.t("Закрыть · Esc", "Close · Esc", "Fermer · Esc"))
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var nowLine: String {
        guard let bed = beds.first else {
            return job.t("В проекте нет музыки — трек ляжет на весь ролик", "No music in the project — a track goes over the whole edit", "Pas de musique dans le projet — le morceau couvrira tout le montage")
        }
        return job.t("Сейчас: ", "Now: ", "Actuel : ") + (bed.label ?? (bed.src as NSString).lastPathComponent)
            + String(format: " · gain %.4f", bed.gain) + job.t(" · клик — послушать, двойной клик или «Поставить» — заменить",
                                                              " · click to listen, double-click or «Put in» to swap", " · clic pour écouter, double-clic ou « Placer » pour remplacer")
    }

    // MARK: Folders

    private var sidebar: some View {
        let folders = tracks.reduce(into: [String]()) { if !$0.contains($1.folder) { $0.append($1.folder) } }
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                row(nil, job.t("Все треки", "All tracks", "Tous les morceaux"), tracks.count)
                ForEach(folders, id: \.self) { f in row(f, f.isEmpty ? "MUSIC" : f, tracks.filter { $0.folder == f }.count) }
            }
            .padding(14)
        }
        .frame(width: 250)
    }

    private func row(_ f: String?, _ title: String, _ count: Int) -> some View {
        Button { folder = f } label: {
            HStack(spacing: 10) {
                Image(systemName: f == nil ? "music.note.list" : "folder").frame(width: 20)
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(folder == f ? Color.black.opacity(0.55) : Theme.muted)
            }
            .foregroundStyle(folder == f ? Color.black : Theme.text)
            .padding(.horizontal, 12).frame(height: 38)
            .background(folder == f ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private var shown: [MusicLibrary.Track] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let list = tracks.filter { t in (folder == nil || t.folder == folder) && words.allSatisfy { t.name.lowercased().contains($0) } }
        guard freeFirst else { return list }
        return list.enumerated().sorted { a, b in
            let ua = (usage[a.element.url.standardizedFileURL.path] ?? []).count, ub = (usage[b.element.url.standardizedFileURL.path] ?? []).count
            return (min(ua, 1), a.offset) < (min(ub, 1), b.offset)
        }.map(\.element)
    }

    private var grid: some View {
        let current = Set(beds.map { Project.resolve($0.src, relativeTo: job.projectURL).standardizedFileURL.path })
        return ScrollView {
            if !loaded {
                ProgressView().controlSize(.small).padding(40)
            } else if root == nil {
                Text(job.t("Папка _ASSETS/MUSIC рядом с проектом не найдена", "No _ASSETS/MUSIC folder found above the project", "Aucun dossier _ASSETS/MUSIC trouvé au-dessus du projet"))
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], spacing: 14) {
                    ForEach(shown) { t in
                        let path = t.url.standardizedFileURL.path
                        MusicCard(job: job, track: t, usedIn: usage[path] ?? [], here: here, current: current.contains(path),
                                  bed: beds.first, put: { put(t) })
                    }
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func put(_ t: MusicLibrary.Track) {
        if beds.isEmpty { asking = t; return }
        job.useMusic(t)
        // its place in the usage list now: this project
        if let here {
            for k in usage.keys { usage[k]?.removeAll { $0 == here } }
            usage[t.url.standardizedFileURL.path, default: []].append(here)
        }
    }
}

/// One track: listen, see how long and how loud it is and where it already plays, put it in.
private struct MusicCard: View {
    @ObservedObject var job: Job
    let track: MusicLibrary.Track
    let usedIn: [String]
    let here: String?
    let current: Bool
    let bed: AudioClip?
    let put: () -> Void
    @ObservedObject private var preview = MusicPreview.shared
    @State private var sound: MusicLibrary.Sound?

    private var playing: Bool { preview.playing == track.url }
    private static let gate = Gate(3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { preview.toggle(track.url, pausing: job.player) } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black).frame(width: 34, height: 34).background(Color.white, in: Circle())
                }
                .buttonStyle(BouncyButtonStyle())
                .help(job.t("Послушать", "Listen", "Écouter"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)   // «… a» and «… b» both readable
                    Text(track.folder.isEmpty ? "MUSIC" : track.folder).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(height: 48, alignment: .leading)                    // one height for one- and two-line names
                Spacer(minLength: 0)
                Text(sound.map { clock($0.duration) } ?? "–").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            outline.frame(height: 38)
            HStack(spacing: 8) {
                usageChip
                if let l = sound?.lufs { Text(String(format: "%.1f LUFS", l)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted) }
                Spacer(minLength: 0)
                if current {
                    Text(job.t("стоит в проекте", "in the project", "dans le projet")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text)
                } else {
                    Button(action: put) {
                        Text(job.t("Поставить", "Put in", "Placer")).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 12).frame(height: 28).background(Color.white, in: Capsule())
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            if let bed, let s = sound, let length = bed.duration, s.duration < bed.inPoint + length - 0.05 {
                Text(job.t(String(format: "Короче музыки в проекте на %.1f с", bed.inPoint + length - s.duration),
                           String(format: "%.1f s shorter than the project's music", bed.inPoint + length - s.duration), String(format: "%.1f s plus court que la musique du projet", bed.inPoint + length - s.duration)))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.orange)
            }
        }
        .padding(14)
        .background(current ? Color.white.opacity(0.16) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(current ? Color.white : (playing ? Color.white.opacity(0.6) : Theme.rowStroke), lineWidth: current ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !current { put() } }
        .onTapGesture { preview.toggle(track.url, pausing: job.player) }
        .task(id: track.id) {
            if let known = MusicLibrary.known(track.url) { sound = known; if known.lufs != nil { return } }
            let ffmpeg = job.ffmpeg
            await Self.gate.enter()
            sound = await MusicLibrary.sound(of: track.url, ffmpeg: ffmpeg) ?? sound
            await Self.gate.leave()
        }
    }

    private var usageChip: some View {
        let others = usedIn.filter { $0 != here }
        let text: String, colour: Color
        if others.isEmpty {
            text = usedIn.isEmpty ? job.t("свободен", "unused", "libre") : job.t("только здесь", "only here", "seulement ici"); colour = Color.green.opacity(0.8)
        } else {
            text = job.t("в ", "in ", "dans ") + others.prefix(6).joined(separator: ", ") + (others.count > 6 ? " +\(others.count - 6)" : "")
            colour = others.count > 2 ? Color.red.opacity(0.85) : Color.orange
        }
        return Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 3).background(colour, in: Capsule()).lineLimit(1)
            .help(usedIn.isEmpty ? job.t("Ни в одном проекте этой папки", "In no project of this folder", "Dans aucun projet de ce dossier")
                                 : job.t("Музыка в: ", "The music in: ", "La musique dans : ") + usedIn.joined(separator: ", "))
    }

    private var outline: some View {
        let bars = sound?.bars ?? []
        let done = playing ? preview.progress : 0
        return Canvas { context, size in
            guard !bars.isEmpty else { return }
            let w = size.width / CGFloat(bars.count)
            for (i, v) in bars.enumerated() {
                let h = max(2, CGFloat(v) * size.height)
                let x = CGFloat(i) * w
                let lit = Double(i) / Double(bars.count) < done
                context.fill(Path(roundedRect: CGRect(x: x + 0.5, y: (size.height - h) / 2, width: max(1, w - 1), height: h), cornerRadius: 1),
                             with: .color(lit ? Color.white : Color.white.opacity(0.35)))
            }
        }
    }
}

/// At most `n` at once (the cards' loudness: an ffmpeg run each).
actor Gate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
