import AVFoundation
import AppKit
import SimbiaCore
import SwiftUI

extension Job {
    /// Opens the project's folder of generated videos over the window, to pick a replacement for the shot `id`
    /// (a double click on the shot).
    func openClips(for id: String) {
        clipsShot = id
        clipsInsertAfter = nil
        layerAt = nil
        shotTools = nil
        player.pause()
        withAnimation(Theme.settle) { clipsOpen = true }
    }

    func closeClips() {
        withAnimation(Theme.settle) { clipsOpen = false }
    }

    /// The clip window for a video put in on the cut after the shot `id`; without a project folder, the library.
    func openClips(insertingAfter id: String) {
        clipsShot = nil
        layerAt = nil
        shotTools = nil
        clipsInsertAfter = id
        player.pause()
        withAnimation(Theme.settle) { clipsOpen = true }
    }

    /// Videos chosen in Finder copied into the project's folder («Загружено»), or into a new folder by the project
    /// when it has none; the window then shows them. Returns the copies.
    func importClips() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.message = t("Видео, которые появятся в библиотеке проекта", "Videos to add to the project's library", "Vidéos à ajouter à la bibliothèque du projet")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return [] }
        let folder: URL
        if let clipsFolder { folder = clipsFolder.appending(path: t("Загружено", "Imported"), directoryHint: .isDirectory) }
        else {
            guard let projectURL, var p = project else { return [] }
            let made = projectURL.deletingLastPathComponent().appending(path: projectURL.deletingPathExtension().lastPathComponent + t(" — видео", " — videos"),
                                                                       directoryHint: .isDirectory)
            p.clipsFolder = made.path
            project = p
            folder = made
        }
        let picked = panel.urls
        let copies: [URL] = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return picked.compactMap { url -> URL? in
                var target = folder.appending(path: url.lastPathComponent), n = 2
                if target.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path { return url }
                while fm.fileExists(atPath: target.path) {
                    target = folder.appending(path: url.deletingPathExtension().lastPathComponent + " \(n)." + url.pathExtension); n += 1
                }
                return (try? fm.copyItem(at: url, to: target)).map { target }
            }
        }.value
        appendLog("Imported \(copies.count) video(s) into \(folder.path)")
        return copies
    }

    /// The folder this project's videos are picked from, kept in the project file.
    var clipsFolder: URL? { project?.clipsFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func chooseClipsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = clipsFolder ?? projectURL?.deletingLastPathComponent()
        panel.message = t("Папка со всеми сгенерированными видео этого проекта", "The folder with all of this project's generated videos", "Le dossier avec toutes les vidéos générées de ce projet")
        guard panel.runModal() == .OK, let url = panel.url, var p = project else { return }
        p.clipsFolder = url.path
        project = p
    }

    /// A video from the folder into the shot: the same place and length, from the clip's start.
    func putClip(_ url: URL, into id: String) {
        replaceClip(id, with: url.resolvingSymlinksInPath())
        focus = .shot(id)
    }

    /// Swaps the open window for the same shot: the project's videos ⇄ the whole footage library.
    func showClipSource(library: Bool) {
        if library, clipsOpen, let id = clipsShot {
            clipsOpen = false
            openGallery(for: id)
        } else if !library, galleryOpen, let id = galleryShot, clipsFolder != nil {
            galleryOpen = false
            openClips(for: id)
        }
    }
}

/// Tabs over both windows a shot's double click opens: its project's videos and the whole footage library.
struct ClipSourceTabs: View {
    @ObservedObject var job: Job
    let library: Bool

    var body: some View {
        HStack(spacing: 6) {
            tab(job.t("Видео проекта", "Project videos", "Vidéos du projet"), on: !library) { job.showClipSource(library: false) }
            tab(job.t("Вся библиотека", "Whole library", "Toute la bibliothèque"), on: library) { job.showClipSource(library: true) }
        }
    }

    private func tab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 32)
                .foregroundStyle(on ? Color.black : Theme.text)
                .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(on)
    }
}

/// A video in the project's folder and the subfolder it sits in.
struct FolderClip: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let group: String
    let added: Date
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum FolderClips {
    static let types: Set<String> = ["mp4", "mov", "m4v"]

    /// Every video under `folder`. Its folders may be links to the generation folders elsewhere; names starting
    /// with "_" are working files and are left out.
    static func scan(_ folder: URL) -> [FolderClip] {
        let fm = FileManager.default
        var out: [FolderClip] = []
        func add(_ url: URL, _ group: String) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(FolderClip(url: url, group: group, added: date))
        }
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in top where !item.lastPathComponent.hasPrefix("_") {
            let real = item.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: real.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else {
                if types.contains(real.pathExtension.lowercased()) { add(item, "") }
                continue
            }
            guard let walk = fm.enumerator(at: real, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                if url.lastPathComponent.hasPrefix("_") { walk.skipDescendants(); continue }
                guard types.contains(url.pathExtension.lowercased()) else { continue }
                let sub = String(url.deletingLastPathComponent().path.dropFirst(real.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                add(url, item.lastPathComponent + (sub.isEmpty ? "" : "/" + sub))
            }
        }
        return out
    }
}

/// The project's generated videos over the whole window, by folder — a click plays one, a double click (or
/// «Поставить в шот») puts it into the shot the window was opened for, in the same place and length.
struct ProjectClipsView: View {
    @ObservedObject var job: Job
    @State private var clips: [FolderClip] = []
    @State private var loading = true
    /// The folder picked in the sidebar; nil = all.
    @State private var group: String?
    @State private var search = ""
    @State private var picked: FolderClip?
    /// Our generations in the footage index by real file path: the picked take's prompt.
    @State private var generations: [String: FootageIndex.Clip] = [:]

    private var shot: Shot? { job.clipsShot.flatMap { job.shot($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rowStroke)
            if job.clipsFolder == nil {
                VStack(spacing: 14) {
                    Text(job.t("К проекту не подключена папка с видео", "No video folder is connected to this project", "Aucun dossier vidéo n’est connecté à ce projet"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        Pill(job.t("Подключить папку…", "Connect a folder…", "Connecter un dossier…"), primary: true) { job.chooseClipsFolder() }
                        Pill(job.t("Загрузить видео…", "Add videos…", "Ajouter des vidéos…")) { importVideos() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(Theme.rowStroke)
                    grid
                    if let picked {
                        Divider().overlay(Theme.rowStroke)
                        ClipPreview(job: job, clip: picked, shot: shot, generation: generations[picked.url.resolvingSymlinksInPath().path],
                                    use: { use(picked) }).frame(width: 360).id(picked.id)
                    }
                }
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .task(id: job.project?.clipsFolder) { await load() }
        .task(id: job.footage?.clips.count) {
            guard let index = job.footage else { return job.loadFootage() }
            generations = await Task.detached(priority: .utility) { index.generationsByFile() }.value
        }
    }

    /// Videos from Finder into the library; the window shows them, the first one picked.
    private func importVideos() {
        Task {
            let copies = await job.importClips()
            guard let first = copies.first else { return }
            await load()
            let path = first.resolvingSymlinksInPath().path
            if let clip = clips.first(where: { $0.url.resolvingSymlinksInPath().path == path }) { group = clip.group; picked = clip }
        }
    }

    /// The window's video goes where it was opened for: into the shot, over the picture, or onto the cut.
    private func use(_ c: FolderClip) {
        if let shot { job.putClip(c.url, into: shot.id) }
        else if let t = job.layerAt { job.addLayer(c.url, at: t) }
        else if let cut = job.clipsInsertAfter { job.insertClip(c.url, after: cut) }
        else { return }
        job.closeClips()
    }

    private func load() async {
        guard let folder = job.clipsFolder else { return }
        loading = true
        clips = await Task.detached(priority: .userInitiated) { FolderClips.scan(folder) }.value
        loading = false
        // start in the folder of the shot's own video
        if let src = shot.map({ Project.resolve($0.src, relativeTo: job.projectURL).resolvingSymlinksInPath().path }) {
            group = clips.first { $0.url.resolvingSymlinksInPath().path == src }?.group
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if job.clipsShot != nil { ClipSourceTabs(job: job, library: false) }
                else { Text(job.t("Видео проекта", "Project videos", "Vidéos du projet")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text) }
                Text(shotLine).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button { importVideos() } label: {
                Label(job.t("Загрузить видео…", "Add videos…", "Ajouter des vidéos…"), systemImage: "square.and.arrow.down").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 30).foregroundStyle(Theme.text)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(BouncyButtonStyle())
            .help(job.t("Скопировать видео из Finder в библиотеку проекта (папка «Загружено»)", "Copy videos from Finder into the project's library («Imported»)", "Copier des vidéos du Finder dans la bibliothèque du projet (« Importées »)"))
            if let folder = job.clipsFolder {
                Button { job.chooseClipsFolder() } label: {
                    Label(folder.lastPathComponent, systemImage: "folder").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 30).foregroundStyle(Theme.text)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(BouncyButtonStyle())
                .help(folder.path + "\n" + job.t("Клик — подключить другую папку", "Click to connect another folder", "Cliquer pour connecter un autre dossier"))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(job.t("Поиск по имени файла…", "Search file names…", "Rechercher un nom de fichier…"), text: $search)
                    .textFieldStyle(.plain).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(width: 280, height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            Button { job.closeClips() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(BouncyButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(job.t("Закрыть · Esc", "Close · Esc", "Fermer · Esc"))
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var shotLine: String {
        if shot == nil, let t = job.layerAt { return job.t("Ляжет поверх шотов с \(clock(t))", "Goes over the shots from \(clock(t))", "Se superpose aux plans à partir de \(clock(t))") }
        if shot == nil, let cut = job.clipsInsertAfter, let s = job.shot(cut) {
            let n = (job.shots.firstIndex { $0.id == cut } ?? 0) + 1
            return job.t("Встанет на склейку после шота \(n) (\(clock(s.end))), до 5 с — всё после сдвинется",
                         "Goes onto the cut after shot \(n) (\(clock(s.end))), up to 5 s — everything after moves along", "Se place sur la coupe après le plan \(n) (\(clock(s.end))), 5 s max — tout ce qui suit se décale")
        }
        guard let shot else { return job.t("Двойной клик по шоту на таймлайне открывает это окно для него", "Double-click a shot on the timeline to open this for it", "Double-cliquer sur un plan de la timeline ouvre cette fenêtre pour lui") }
        let n = (job.shots.firstIndex { $0.id == shot.id } ?? 0) + 1
        let said = job.cues.filter { $0.start < shot.end && $0.end > shot.start }.map(\.text).joined(separator: " ")
        return job.t("Замена для шота \(n): \(clock(shot.start)) – \(clock(shot.end)), сейчас «\(shot.label ?? "")»",
                     "Replacing shot \(n): \(clock(shot.start)) – \(clock(shot.end)), now “\(shot.label ?? "")”", "Remplacement du plan \(n) : \(clock(shot.start)) – \(clock(shot.end)), actuellement « \(shot.label ?? "") »")
            + (said.isEmpty ? "" : " · «\(said.prefix(80))»")
    }

    // MARK: Folders

    private var sidebar: some View {
        let pool = clips.filter(searchMatches)
        let counts = Dictionary(grouping: pool, by: \.group).mapValues(\.count)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                row(nil, job.t("Все", "All", "Tous"), pool.count)
                ForEach(counts.keys.sorted(), id: \.self) { g in row(g, g.isEmpty ? job.t("В корне", "Top level", "Racine") : g, counts[g] ?? 0) }
            }
            .padding(14)
        }
        .frame(width: 250)
    }

    private func row(_ g: String?, _ title: String, _ count: Int) -> some View {
        let on = group == g
        return Button { group = g; picked = nil } label: {
            HStack(spacing: 10) {
                Image(systemName: g == nil ? "square.grid.2x2" : "folder").frame(width: 20)
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(on ? Color.black.opacity(0.55) : Theme.muted)
            }
            .foregroundStyle(on ? Color.black : Theme.text)
            .padding(.horizontal, 12).frame(height: 38)
            .background(on ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchMatches(_ c: FolderClip) -> Bool {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return words.allSatisfy { (c.group + "/" + c.name).lowercased().contains($0) }
    }

    // MARK: Grid

    private var grid: some View {
        let list = clips.filter { searchMatches($0) && (group == nil || $0.group == group) }.sorted { $0.added > $1.added }
        let inEdit = Set(job.shots.map { Project.resolve($0.src, relativeTo: job.projectURL).resolvingSymlinksInPath().path })
        let current = shot.map { Project.resolve($0.src, relativeTo: job.projectURL).resolvingSymlinksInPath().path }
        return ScrollView {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.t("Читаю папку…", "Reading the folder…", "Lecture du dossier…")).foregroundStyle(Theme.muted)
                }
                .padding(40)
            } else if list.isEmpty {
                Text(job.t("Здесь нет видео", "No videos here", "Aucune vidéo ici")).font(.system(size: 14)).foregroundStyle(Theme.muted).padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 14) {
                    ForEach(list) { c in
                        let real = c.url.resolvingSymlinksInPath().path
                        ClipTile(job: job, clip: c, selected: picked?.id == c.id, now: real == current, inEdit: inEdit.contains(real))
                            .onTapGesture(count: 2) { use(c) }
                            .onTapGesture { picked = c }
                    }
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A video as a 9:16 still from its first second, its name and length.
private struct ClipTile: View {
    @ObservedObject var job: Job
    let clip: FolderClip
    let selected: Bool
    let now: Bool
    let inEdit: Bool
    @State private var still: ClipStills.Still?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.06)
                if let image = still?.image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                if hovering { HoverPlayer(url: clip.url) }
                HStack(spacing: 4) {
                    if now { badge(job.t("СЕЙЧАС В ШОТЕ", "IN THIS SHOT", "DANS CE PLAN"), Color(red: 0.85, green: 0.62, blue: 0.2)) }
                    else if inEdit { badge(job.t("В РОЛИКЕ", "IN EDIT", "DANS LE MONTAGE"), Color(red: 0.2, green: 0.55, blue: 0.35)) }
                }
                .padding(6)
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.white : Theme.rowStroke, lineWidth: selected ? 2.5 : 1))
            Text(clip.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.text)
            Text((still.map { String(format: "%.1f s · ", $0.length) } ?? "") + clip.group)
                .font(.system(size: 10.5)).lineLimit(1).truncationMode(.head).foregroundStyle(Theme.muted)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(clip.url.resolvingSymlinksInPath().path)
        .task(id: clip.id) { still = await ClipStills.shared.still(clip.url) }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2).background(color, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A frame from each video's first second and its length, kept while the app runs.
actor ClipStills {
    static let shared = ClipStills()
    struct Still: Sendable { let image: CGImage?; let length: Double }
    private var cache: [String: Still] = [:]

    /// A frame of the video at `time` (a project card's poster), kept like the stills.
    func frame(_ url: URL, at time: Double) async -> CGImage? {
        let key = url.path + "|" + String(format: "%.2f", time)
        if let hit = posters[key] { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 640)
        let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        if posters.count > 500 { posters.removeAll() }
        posters[key] = image
        return image
    }
    private var posters: [String: CGImage?] = [:]

    func still(_ url: URL) async -> Still {
        if let hit = cache[url.path] { return hit }
        let asset = AVURLAsset(url: url)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 270, height: 480)
        let image = try? await generator.image(at: CMTime(seconds: min(1.0, length / 3), preferredTimescale: 600)).image
        let made = Still(image: image, length: length)
        if cache.count > 2000 { cache.removeAll() }
        cache[url.path] = made
        return made
    }
}

/// The picked video playing on a loop with its sound, and the button that puts it into the shot.
private struct ClipPreview: View {
    @ObservedObject var job: Job
    let clip: FolderClip
    let shot: Shot?
    /// The take's record when it is one of our generations: what it was prompted to be.
    let generation: FootageIndex.Clip?
    let use: () -> Void
    @State private var fullPrompt = false
    @State private var player = AVPlayer()
    @State private var loop: NSObjectProtocol?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoopingPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
                .frame(maxHeight: 460)
                .frame(maxWidth: .infinity)
            Text(clip.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(clip.group).font(.system(size: 12)).foregroundStyle(Theme.muted)
            if let shot {
                Text(job.t("Встанет на место шота: \(String(format: "%.2f", shot.duration)) с, с начала клипа",
                           "Takes the shot's place: \(String(format: "%.2f", shot.duration)) s, from the clip's start", "Prend la place du plan : \(String(format: "%.2f", shot.duration)) s, depuis le début du clip"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.8))
            }
            if let generation {
                let segment = generation.segments?.first
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.t("Промпт", "Prompt") + (generation.source?.model.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                    Text(generation.source?.summary ?? segment?.description ?? job.t("Промпт не сохранился", "No prompt on record", "Aucun prompt enregistré"))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(7).textSelection(.enabled)
                    if segment?.usable == "avoid" {
                        Text(job.t("Брак: ", "Flawed: ", "Défaut : ") + (segment?.whyAvoid ?? ""))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    }
                    if let prompt = generation.source?.prompt {
                        Button(fullPrompt ? job.t("Скрыть промпт", "Hide the prompt", "Masquer le prompt") : job.t("Весь промпт", "Whole prompt", "Prompt complet")) { fullPrompt.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        if fullPrompt {
                            ScrollView {
                                Text(prompt).font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.85)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Pill(shot.map { _ in job.t("Поставить в шот", "Put into the shot", "Placer dans le plan") }
                 ?? (job.layerAt != nil ? job.t("Наложить поверх", "Lay over the picture", "Superposer à l’image")
                     : job.clipsInsertAfter != nil ? job.t("Вставить на склейку", "Put onto the cut", "Placer sur la coupe") : job.t("Сначала выберите шот", "Select a shot first", "Sélectionner d’abord un plan")),
                 primary: true, action: use)
            .disabled(shot == nil && job.layerAt == nil && job.clipsInsertAfter == nil)
            Pill(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([clip.url.resolvingSymlinksInPath()]) }
        }
        .padding(18)
        .onAppear {
            let item = AVPlayerItem(url: clip.url)
            player.replaceCurrentItem(with: item)
            loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [player] _ in
                player.seek(to: .zero); player.play()
            }
            player.play()
        }
        .onDisappear {
            player.pause()
            if let loop { NotificationCenter.default.removeObserver(loop) }
            loop = nil
            player.replaceCurrentItem(with: nil)
        }
    }
}
