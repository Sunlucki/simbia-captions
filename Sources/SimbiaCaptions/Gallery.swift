import AVFoundation
import AppKit
import SimbiaCore
import SwiftUI

extension Job {
    /// Opens the whole footage library over the window, to pick a moment for the shot `id`.
    func openGallery(for id: String?) {
        loadFootage()
        galleryShot = id
        layerAt = nil
        galleryPicked = nil
        // start where what is said over the shot points
        if let shot = id.flatMap({ self.shot($0) }) {
            let said = cues.filter { $0.start < shot.end && $0.end > shot.start }.map(\.text).joined(separator: " ")
            galleryCategory = FootageIndex.category(for: said)
        }
        shotTools = nil
        withAnimation(Theme.settle) { galleryOpen = true }
    }

    func closeGallery() {
        withAnimation(Theme.settle) { galleryOpen = false }
    }

    /// The library's moments, read once per index.
    var galleryMoments: [FootageIndex.Moment] {
        if let cached = sync.moments { return cached }
        let made = footage?.moments() ?? []
        if footage != nil { sync.moments = made }
        return made
    }

    /// Takes a moment out of the gallery and the suggestions for good.
    func hideMoment(_ moment: FootageIndex.Moment, why: String) {
        guard var index = footage else { return }
        do {
            try index.hide(moment, why: why)
            footage = index
            sync.moments = nil
            galleryPicked = nil
            show(t("Убрано из библиотеки", "Taken out of the library", "Retiré de la bibliothèque"), isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    /// Puts a moment of the library into a shot.
    func useMoment(_ moment: FootageIndex.Moment, for id: String) {
        updateShot(id) {
            $0.src = moment.file.path
            $0.inPoint = moment.from
            $0.label = moment.clip
        }
    }
}

/// The whole footage library, full window, by what each moment shows — a click shows it playing, a double click (or
/// «Поставить в шот») puts it into the shot the gallery was opened for.
struct FootageGallery: View {
    @ObservedObject var job: Job
    @State private var who = Who.all
    @State private var search = ""
    @State private var order = Order.best
    private var category: FootageIndex.Category { job.galleryCategory }
    private var picked: FootageIndex.Moment? { job.galleryPicked }

    enum Who: CaseIterable { case all, real, ai, stock }
    enum Order: CaseIterable { case best, newest, oldest }

    private var shot: Shot? { job.galleryShot.flatMap { job.shot($0) } }

    var body: some View {
        let all = job.galleryMoments
        let filtered = all.filter(matches)
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rowStroke)
            HStack(spacing: 0) {
                sidebar(all.filter { whoMatches($0) && searchMatches($0) })
                Divider().overlay(Theme.rowStroke)
                grid(sorted(filtered.filter { $0.category == category }))
                if let picked {
                    Divider().overlay(Theme.rowStroke)
                    MomentPreview(job: job, moment: picked, shot: shot)
                        .frame(width: 360)
                        .id(picked.id)
                }
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .onAppear { job.loadFootage() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if job.galleryShot != nil, job.clipsFolder != nil { ClipSourceTabs(job: job, library: true) }
                else { Text(job.t("Библиотека футажей", "Footage library", "Bibliothèque de rushes")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text) }
                Text(shotLine).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(job.t("Поиск: имя, действие, деталь…", "Search: name, action, detail…", "Rechercher : nom, action, détail…"), text: $search)
                    .textFieldStyle(.plain).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(width: 300, height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            HStack(spacing: 6) {
                ForEach(Who.allCases, id: \.self) { w in
                    Button { who = w } label: {
                        Text(whoName(w)).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 30)
                            .foregroundStyle(who == w ? Color.black : Theme.text)
                            .background(who == w ? Color.white : Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            Picker("", selection: $order) {
                Text(job.t("Лучшие", "Best", "Meilleurs")).tag(Order.best)
                Text(job.t("Сначала новые", "Newest first", "Plus récents d’abord")).tag(Order.newest)
                Text(job.t("Сначала старые", "Oldest first", "Plus anciens d’abord")).tag(Order.oldest)
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .help(job.t("Давность: дата съёмки ролика, иначе — когда он появился на Drive", "Age: when the clip was filmed, else when it appeared on the Drive", "Ancienneté : date de tournage du clip, sinon date d’arrivée sur le Drive"))
            Button { job.closeGallery() } label: {
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
        guard let shot else { return job.t("Выберите шот на таймлайне, чтобы поставить в него кадр", "Select a shot on the timeline to put a moment into it", "Sélectionner un plan dans la timeline pour y placer un moment") }
        let n = (job.shots.firstIndex { $0.id == shot.id } ?? 0) + 1
        let said = job.cues.filter { $0.start < shot.end && $0.end > shot.start }.map(\.text).joined(separator: " ")
        return job.t("Для шота \(n): \(clock(shot.start)) – \(clock(shot.end))", "For shot \(n): \(clock(shot.start)) – \(clock(shot.end))", "Pour le plan \(n) : \(clock(shot.start)) – \(clock(shot.end))")
            + (said.isEmpty ? "" : " · «\(said.prefix(90))»")
    }

    private func whoName(_ w: Who) -> String {
        switch w {
        case .all: return job.t("Все", "All", "Tous")
        case .real: return job.t("Амбассадоры", "Ambassadors", "Ambassadrices")
        case .ai: return "AI"
        case .stock: return job.t("Сток и продукт", "Stock & product", "Stock et produit")
        }
    }

    // MARK: Filters

    /// Within a category: the index's best moments and real women first, or by how recent the footage is.
    private func sorted(_ list: [FootageIndex.Moment]) -> [FootageIndex.Moment] {
        switch order {
        case .best:
            func rank(_ m: FootageIndex.Moment) -> Int { (m.great ? 0 : 2) + (m.kind == "real_ambassador" ? 0 : 1) }
            return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        case .newest: return list.sorted { ($0.date ?? "", $0.from) > ($1.date ?? "", $1.from) }
        case .oldest: return list.sorted { ($0.date ?? "9999", $0.from) < ($1.date ?? "9999", $1.from) }
        }
    }

    private func whoMatches(_ m: FootageIndex.Moment) -> Bool {
        switch who {
        case .all: return true
        case .real: return m.kind == "real_ambassador"
        case .ai: return m.kind == "ai_generated"
        case .stock: return m.kind == "stock" || m.kind == "product_still"
        }
    }

    private func searchMatches(_ m: FootageIndex.Moment) -> Bool {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let text = (m.who + " " + m.description + " " + m.clip).lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    private func matches(_ m: FootageIndex.Moment) -> Bool { whoMatches(m) && searchMatches(m) }

    // MARK: Categories

    private func sidebar(_ pool: [FootageIndex.Moment]) -> some View {
        let counts = Dictionary(grouping: pool, by: \.category).mapValues(\.count)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(FootageIndex.Category.allCases) { c in
                    Button { job.galleryCategory = c; job.galleryPicked = nil } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol(c)).frame(width: 20)
                            Text(categoryName(c)).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(counts[c] ?? 0)").font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(category == c ? Color.black.opacity(0.55) : Theme.muted)
                        }
                        .foregroundStyle(category == c ? Color.black : Theme.text)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(category == c ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .frame(width: 250)
    }

    private func categoryName(_ c: FootageIndex.Category) -> String {
        switch c {
        case .applying: return job.t("Наносит помаду", "Applying it", "Application du rouge")
        case .tube: return job.t("Тюбик в камеру", "Tube to camera", "Tube face caméra")
        case .lips: return job.t("Губы крупно, результат", "Lips close-up, result", "Lèvres en gros plan, résultat")
        case .smile: return job.t("Улыбка, довольна", "Smile, happy", "Sourire, contente")
        case .talking: return job.t("Говорит в камеру", "Talking to camera", "Parle face caméra")
        case .pain: return job.t("Сухие губы, недовольна", "Dry lips, unhappy", "Lèvres sèches, mécontente")
        case .otherBrands: return job.t("Другие помады, ящик", "Other lipsticks, drawer", "Autres rouges à lèvres, tiroir")
        case .product: return job.t("Продукт отдельно", "Product alone", "Produit seul")
        case .broll: return job.t("B-roll и прочее", "B-roll and other", "B-roll et autres")
        }
    }

    private func symbol(_ c: FootageIndex.Category) -> String {
        switch c {
        case .applying: return "paintbrush.pointed"
        case .tube: return "hand.raised"
        case .lips: return "mouth"
        case .smile: return "face.smiling"
        case .talking: return "bubble.left"
        case .pain: return "cloud.rain"
        case .otherBrands: return "tray.full"
        case .product: return "shippingbox"
        case .broll: return "film"
        }
    }

    // MARK: Grid

    private func grid(_ list: [FootageIndex.Moment]) -> some View {
        let inEdit = Set(job.shots.map(\.src))
        return ScrollView {
            if case .ready = job.footageState, list.isEmpty {
                Text(job.t("Здесь ничего не нашлось", "Nothing here", "Rien ici")).font(.system(size: 14)).foregroundStyle(Theme.muted).padding(40)
            } else if case .ready = job.footageState {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 14) {
                    ForEach(list) { m in
                        MomentTile(job: job, moment: m, selected: picked?.id == m.id, inEdit: inEdit.contains(m.file.path))
                            .onTapGesture(count: 2) {
                                if let shot { job.useMoment(m, for: shot.id); job.closeGallery() } else if let t = job.layerAt { job.addLayer(m.file, at: t, inPoint: m.from, label: m.clip); job.closeGallery() }
                            }
                            .onTapGesture { job.galleryPicked = m }
                    }
                }
                .padding(18)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.t("Читаю библиотеку клипов…", "Reading the footage library…", "Lecture de la bibliothèque de rushes…")).foregroundStyle(Theme.muted)
                }
                .padding(40)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A moment as a 9:16 still from its middle, with who it is and how long it runs.
private struct MomentTile: View {
    @ObservedObject var job: Job
    let moment: FootageIndex.Moment
    let selected: Bool
    let inEdit: Bool
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.06)
                if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                if hovering { HoverPlayer(url: moment.file, from: moment.from, to: moment.to) }
                HStack(spacing: 4) {
                    if moment.kind == "ai_generated" { badge("AI", Color(red: 0.45, green: 0.35, blue: 0.85)) }
                    if moment.kind == "stock" || moment.kind == "product_still" { badge(job.t("СТОК", "STOCK"), Color(white: 0.35)) }
                    if moment.great { badge("★", Color(red: 0.85, green: 0.62, blue: 0.2)) }
                    if inEdit { badge(job.t("В РОЛИКЕ", "IN EDIT", "DANS LE MONTAGE"), Color(red: 0.2, green: 0.55, blue: 0.35)) }
                }
                .padding(6)
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.white : Theme.rowStroke, lineWidth: selected ? 2.5 : 1))
            Text(moment.who.isEmpty ? moment.clip : moment.who).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).foregroundStyle(Theme.text)
            Text((moment.date.map { shortDate($0) + " · " } ?? "") + String(format: "%.1f–%.1f s", moment.from, moment.to)
                 + (moment.usedIn.isEmpty ? "" : " · " + job.t("было в ", "used in ", "utilisé dans ") + moment.usedIn.joined(separator: ", ")))
                .font(.system(size: 10.5)).lineLimit(1).foregroundStyle(Theme.muted)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(moment.description)
        .task(id: moment.id) { image = await GalleryStills.shared.still(moment) }
    }

    /// "2026-10-06" → "6 окт 2026" / "Oct 6, 2026".
    private func shortDate(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter(); out.locale = Locale(identifier: ["ru": "ru_RU", "fr": "fr_FR"][job.language.rawValue] ?? "en_US"); out.dateFormat = job.language == .en ? "MMM d, yy" : "d MMM yy"
        return out.string(from: d)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2).background(color, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Stills for the tiles: one frame from each moment's middle, small, kept while the app runs.
actor GalleryStills {
    static let shared = GalleryStills()
    private var cache: [String: CGImage] = [:]

    func still(_ m: FootageIndex.Moment) async -> CGImage? {
        if let hit = cache[m.id] { return hit }
        let asset = AVURLAsset(url: m.file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 270, height: 480)
        let time = CMTime(seconds: m.from + min(1.0, (m.to - m.from) / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        if cache.count > 1500 { cache.removeAll() }
        cache[m.id] = image
        return image
    }
}

/// The picked moment playing on a loop, what it shows, and the button that puts it into the shot.
private struct MomentPreview: View {
    @ObservedObject var job: Job
    let moment: FootageIndex.Moment
    let shot: Shot?
    @State private var player = AVPlayer()
    @State private var loop: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LoopingPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
                .frame(maxHeight: 460)
                .frame(maxWidth: .infinity)
            Text(moment.who.isEmpty ? moment.clip : moment.who).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(String(format: "%.1f – %.1f s · ", moment.from, moment.to) + kindName)
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            ScrollView { Text(moment.description).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.85)) }
                .frame(maxHeight: 110)
            if !moment.usedIn.isEmpty {
                Text(job.t("Уже было в: ", "Already used in: ", "Déjà utilisé dans : ") + moment.usedIn.joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.5))
            }
            Spacer(minLength: 0)
            Pill(shot.map { _ in job.t("Поставить в шот", "Put into the shot", "Placer dans le plan") }
                 ?? (job.layerAt != nil ? job.t("Наложить поверх", "Lay over the picture", "Superposer à l’image") : job.t("Сначала выберите шот", "Select a shot first", "Sélectionner d’abord un plan")), primary: true) {
                if let shot { job.useMoment(moment, for: shot.id); job.closeGallery() }
                else if let t = job.layerAt { job.addLayer(moment.file, at: t, inPoint: moment.from, label: moment.clip); job.closeGallery() }
            }
            .disabled(shot == nil && job.layerAt == nil)
            HStack(spacing: 8) {
                Pill(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([moment.file]) }
                Menu {
                    Button(job.t("Розовый наконечник", "Pink tip", "Embout rose")) { job.hideMoment(moment, why: "pink tip") }
                    Button(job.t("Плохой кадр", "Bad shot", "Mauvais plan")) { job.hideMoment(moment, why: "bad shot") }
                    Button(job.t("Чужой бренд / не наш продукт", "Not our product", "Pas notre produit")) { job.hideMoment(moment, why: "not our product") }
                } label: { Text(job.t("Скрыть из библиотеки", "Hide from the library", "Masquer de la bibliothèque")) }
                .menuStyle(.button)
                .fixedSize()
                .help(job.t("Этот момент больше не будет в галерее и в подборе", "This moment will no longer show in the gallery or the suggestions", "Ce moment n’apparaîtra plus dans la galerie ni dans les suggestions"))
            }
        }
        .padding(18)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var kindName: String {
        switch moment.kind {
        case "real_ambassador": return job.t("амбассадор", "ambassador", "ambassadrice")
        case "ai_generated": return "AI"
        default: return job.t("сток", "stock")
        }
    }

    private func start() {
        let item = AVPlayerItem(url: moment.file)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        let from = CMTime(seconds: moment.from, preferredTimescale: 600)
        player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero)
        let end = moment.to
        loop = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [player] t in
            if t.seconds >= end { player.seek(to: from, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        player.play()
    }

    private func stop() {
        player.pause()
        if let loop { player.removeTimeObserver(loop) }
        loop = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// A tile's video playing, muted and round and round (`from`–`to`), while the mouse is over the tile.
struct HoverPlayer: View {
    let url: URL
    var from: Double = 0
    var to: Double?
    @State private var player = AVPlayer()
    @State private var loop: NSObjectProtocol?

    /// The picture only: clicks and the hover go through to the tile under it.
    private struct Picture: NSViewRepresentable {
        let player: AVPlayer
        final class View: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
        func makeNSView(context: Context) -> NSView {
            let view = View()
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            view.layer = layer
            view.wantsLayer = true
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    var body: some View {
        Picture(player: player)
            .allowsHitTesting(false)
            .onAppear {
                let item = AVPlayerItem(url: url)
                if let to { item.forwardPlaybackEndTime = CMTime(seconds: to, preferredTimescale: 600) }
                let start = CMTime(seconds: from, preferredTimescale: 600)
                player.isMuted = true
                player.replaceCurrentItem(with: item)
                player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                loop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [player] _ in
                    player.seek(to: start); player.play()
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

struct LoopingPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer                       // a layer-hosting view: the layer first, then wantsLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
}
