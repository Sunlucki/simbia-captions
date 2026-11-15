import AppKit
import SimbiaCore
import SwiftUI

// MARK: - Reviews

extension Job {
    /// Reads the reviews: the folder picked before, `_ASSETS/TRUSTPILOT` above the project, or beside the footage index.
    func loadReviews() {
        let picked = UserDefaults.standard.string(forKey: "reviewsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let besideFootage = UserDefaults.standard.string(forKey: "footageIndex")
            .map { URL(fileURLWithPath: $0, isDirectory: true).deletingLastPathComponent().appending(path: "TRUSTPILOT") }
        let found = [picked, ReviewLibrary.find(near: projectURL), besideFootage].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: ReviewLibrary.file).path) }
        guard let found else { reviews = nil; reviewsMissing = true; return }
        do {
            reviews = try ReviewLibrary.load(found)
            reviewsMissing = false
        } catch {
            reviews = nil
            reviewsMissing = true
            show(error.localizedDescription, isError: true)
        }
    }

    func chooseReviewsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = t("Папка с reviews.json (и фото в av/)", "The folder with reviews.json (and photos in av/)", "Le dossier contenant reviews.json (et les photos dans av/)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "reviewsFolder")
        loadReviews()
    }

    /// A review card at the playhead — the review given, or one to fill in — selected for its settings.
    func addReview(_ review: Review?) {
        ensureProject()
        guard var p = project else { return }
        pushHistory()
        let duration = 4.5
        let item = TitleItem(id: Project.newID("t"), style: "T8", text: review?.text ?? t("Текст отзыва", "Review text", "Texte de l’avis"),
                             kicker: review.map { $0.name + "|" + $0.date } ?? "Name|Oct 1, 2026",
                             start: max(0, min(currentTime, p.duration - duration)), duration: duration,
                             image: review.flatMap { reviews?.photo(of: $0)?.path })
        p.titles.append(item)
        p.titles.sort { $0.start < $1.start }
        project = p
        focus = .title(item.id)
        titleTools = item.id
        openDrawer(nil)
    }

    /// Puts another review on a card.
    func useReview(_ review: Review, on id: String) {
        updateTitle(id) {
            $0.text = review.text
            $0.kicker = review.name + "|" + review.date
            $0.image = reviews?.photo(of: review)?.path
        }
    }

    /// A review collage (T9, up to four cards) or the review slider (T10) at the playhead, with the library's first reviews.
    func addReviewGraphic(style: String) {
        ensureProject()
        guard var p = project else { return }
        if reviews == nil { loadReviews() }
        pushHistory()
        let collage = style == "T9"
        let duration = 4.2
        let picked = Array((reviews?.reviews ?? []).prefix(collage ? 4 : 5)).map(absolute)
        let item = TitleItem(id: Project.newID("t"), style: style, text: collage ? "" : "Reviews shaping this summary",
                             start: max(0, min(currentTime, p.duration - duration)), duration: duration)
        var made = item
        made.reviews = picked
        p.titles.append(made)
        p.titles.sort { $0.start < $1.start }
        project = p
        focus = .title(made.id)
        titleTools = made.id
        openDrawer(nil)
    }

    /// A pile of TikTok comments (T13) at the playhead: eight to start with, each line editable in its window.
    func addComments() {
        ensureProject()
        guard var p = project else { return }
        pushHistory()
        let duration = 3.0
        var item = TitleItem(id: Project.newID("t"), style: "T13", text: "", start: max(0, min(currentTime, p.duration - duration)), duration: duration)
        item.reviews = [("linda.m58", "2d", "Girl, try the clear one!! 💄"), ("pam_reads", "2d", "Do the clear tube. Trust me."),
                        ("debbie.k", "1d", "My whole book club wears it now 😂"), ("sue.j.1964", "1d", "Please try it and show us!"),
                        ("carolw", "1d", "It goes on clear, then it's YOUR color"), ("marybeth55", "20h", "Try it before Sunday 🙏"),
                        ("ruth.t", "18h", "My daughter stole mine. Just saying"), ("janet_a", "9h", "Everyone over 50 knows this one 😉")]
            .map { Review(name: $0.0, date: $0.1, text: $0.2) }
        p.titles.append(item)
        p.titles.sort { $0.start < $1.start }
        project = p
        focus = .title(item.id)
        titleTools = item.id
        openDrawer(nil)
    }

    /// A library review with its photo as a full path, as a graphic keeps it.
    func absolute(_ review: Review) -> Review {
        var r = review
        r.avatar = reviews?.photo(of: review)?.path
        return r
    }

    /// Puts a review on a collage or slider, or takes it off (a collage holds four).
    func toggleReview(_ review: Review, in id: String) {
        updateTitle(id) { t in
            var list = t.reviews ?? []
            if let i = list.firstIndex(where: { $0.name == review.name && $0.text == review.text }) { list.remove(at: i) }
            else if t.style != "T9" || list.count < 4 { list.append(absolute(review)) }
            t.reviews = list
        }
    }

    /// The kit's motion-graphics scenes, read once per project.
    func loadMotion() {
        guard let folder = MotionLibrary.find(near: projectURL, project: project) else { motionScenes = []; return }
        motionScenes = MotionLibrary.scenes(in: folder)
    }

    /// Keeps a card's review in the library for the next videos.
    func saveReview(from item: TitleItem) {
        guard var library = reviews else { return }
        let who = item.reviewer
        do {
            try library.save(Review(name: who.name, date: who.date, text: item.text, avatar: item.image))
            reviews = library
            show(t("Отзыв сохранён в библиотеку", "Review saved to the library", "Avis enregistré dans la bibliothèque"), isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }
}

/// The Graphics tab: the selected graphic's settings, the review collage and slider, every review in the library
/// (a click adds its card — or, with a collage or slider selected, puts it on or takes it off), and the kit's scenes.
/// The three graphics made from the reviews, in the Graphics drawer's header.
struct GraphicsMakers: View {
    @ObservedObject var job: Job

    var body: some View {
        PillGrid(columns: 3) {
            Pill(job.t("Коллаж отзывов", "Review collage", "Collage d’avis"), icon: "rectangle.stack") { job.addReviewGraphic(style: "T9") }
                .help(job.t("4 карточки влетают веером", "four cards drop in, fanned", "quatre cartes tombent en éventail"))
            Pill(job.t("Слайдер отзывов", "Review slider", "Carrousel d’avis"), icon: "rectangle.split.3x1") { job.addReviewGraphic(style: "T10") }
                .help(job.t("«Reviews shaping this summary», листается", "the panel slides card by card", "le panneau défile carte par carte"))
            Pill(job.t("Комментарии", "Comments", "Commentaires"), icon: "bubble.left.and.bubble.right") { job.addComments() }
                .help(job.t("8 комментариев TikTok влетают и плавают, любая длина", "8 TikTok comments drop in and float, any length", "8 commentaires TikTok arrivent et flottent, toute longueur"))
        }
        .frame(width: 540)
        .disabled(job.project == nil && job.video == nil)
    }
}

struct GraphicsPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        let target: TitleItem? = { if case .title(let id) = job.focus, let item = job.title(id), item.isGraphic, item.style != "T13" { return item }; return nil }()
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                scenes
                reviewList(target)
            }
            .padding(.bottom, 4)
        }
        .onAppear {
            if job.reviews == nil { job.loadReviews() }
            if job.motionScenes == nil { job.loadMotion() }
        }
        .onChange(of: job.projectURL) { _, _ in job.loadReviews(); job.loadMotion() }
    }

    @ViewBuilder private func reviewList(_ target: TitleItem?) -> some View {
        HStack(spacing: 8) {
            Text(job.t("Отзывы Trustpilot", "Trustpilot reviews", "Avis Trustpilot")).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            if let reviews = job.reviews {
                Text("\(reviews.reviews.count)").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let folder = job.reviews?.folder {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: ReviewLibrary.file)]) } label: {
                    Text(folder.lastPathComponent + "/" + ReviewLibrary.file).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help(folder.path)
            }
        }
        if job.reviewsMissing {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.t("Не нашёл _ASSETS/TRUSTPILOT/reviews.json рядом с проектом.", "No _ASSETS/TRUSTPILOT/reviews.json near the project.", "Aucun _ASSETS/TRUSTPILOT/reviews.json près du projet."))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Pill(job.t("Выбрать папку…", "Choose folder…", "Choisir un dossier…")) { job.chooseReviewsFolder() }
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
            ForEach(job.reviews?.reviews ?? []) { review in
                let chosen = target.map { t in
                    t.style == "T8" ? t.text == review.text && t.reviewer.name == review.name
                                    : (t.reviews ?? []).contains { $0.name == review.name && $0.text == review.text }
                } ?? false
                Button {
                    if let target {
                        // another review on a card: done, its settings again; a collage takes several, the drawer stays
                        if target.style == "T8" { job.useReview(review, on: target.id); job.openDrawer(nil); job.titleTools = target.id }
                        else { job.toggleReview(review, in: target.id) }
                    } else { job.addReview(review) }
                } label: {
                    ReviewTile(review: review, photo: job.reviews?.photo(of: review), selected: chosen)
                }
                .buttonStyle(BouncyButtonStyle())
            }
            Button { job.addReview(nil) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    Text(job.t("Свой отзыв", "Your own review", "Avis personnalisé")).font(.system(size: 13, weight: .bold))
                    Text(job.t("вставьте текст, имя и фото", "paste the text, name and photo", "coller le texte, le nom et la photo")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity).frame(height: 104)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.rowStroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .buttonStyle(BouncyButtonStyle())
        }
        .disabled(job.project == nil && job.video == nil)
    }

    @ViewBuilder private var scenes: some View {
        if let list = job.motionScenes, !list.isEmpty {
            HStack {
                Text(job.t("Сцены из кита", "Kit scenes", "Scènes du kit")).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                Text(job.t("нажмите — встанет у курсора", "click to put it at the playhead", "cliquer pour la placer à la tête de lecture")).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(spacing: 10) {
                ForEach(list) { scene in
                    Button {
                        // «Заменить» on a scene: this one takes its place, then its settings again
                        if case .overlay(let id) = job.focus {
                            job.replaceOverlay(id, with: scene.folder, ownLength: true)      // (its glass goes or comes with it)
                            job.openDrawer(nil); job.overlayTools = id
                        } else { job.addOverlay(scene) }
                    } label: {
                        VStack(spacing: 6) {
                            SceneStill(url: scene.still).frame(height: 132)
                                .background(Color(red: 0.16, green: 0.11, blue: 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(motionName(scene.name, job)).font(.system(size: 11.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                            Text(String(format: "%.1f s", scene.duration)).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(8)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(scene.folder.path)
                    .frame(width: 124)
                }
              }
            }
            .frame(height: 214)
            .disabled(job.project == nil && job.video == nil)
        }
    }
}

/// A scene's still, read small.
private struct SceneStill: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) } else { Color.clear }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
            }.value
        }
    }
}

/// The kit's scene folders by what they show.
@MainActor func motionName(_ folder: String, _ job: Job) -> String {
    let names: [String: (String, String, String)] = [
        "comments": ("Коллаж отзывов (кит)", "Review collage (kit)", "Collage d’avis (kit)"),
        "reviews_carousel": ("Слайдер отзывов (кит)", "Review slider (kit)", "Carrousel d’avis (kit)"),
        "badge_bogo": ("Плашка BOGO", "BOGO badge", "Badge BOGO"), "badge_riskfree": ("90 дней без риска", "90 days risk-free", "90 jours sans risque"),
        "collage": ("Коллаж магазинов", "Store collage", "Collage de magasins"), "end_logo": ("Логотип в конце", "End logo", "Logo de fin"),
        "title": ("Титр 7 REASONS", "7 REASONS title", "Titre 7 REASONS"),
    ]
    if let n = names[folder] { return job.t(n.0, n.1, n.2) }
    if folder.hasPrefix("stat_") { return job.t("Цифра: ", "Stat: ", "Chiffre : ") + folder.dropFirst(5).replacingOccurrences(of: "_", with: " ") }
    if folder.hasPrefix("reason_") { return job.t("Причина #", "Reason #", "Raison #") + folder.dropFirst(7) }
    return folder
}

/// A review as the list shows it: photo, name, five green stars, the start of the text.
private struct ReviewTile: View {
    let review: Review
    let photo: URL?
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            avatar.frame(width: 40, height: 40).clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(review.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(review.date).font(.system(size: 10.5)).foregroundStyle(selected ? .black.opacity(0.55) : Theme.muted).lineLimit(1)
                }
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { _ in
                        Image(systemName: "star.fill").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 13, height: 13).background(Color(red: 0, green: 0.71, blue: 0.48))
                    }
                }
                Text(review.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")).font(.system(size: 11)).lineLimit(2)
                    .foregroundStyle(selected ? .black.opacity(0.7) : Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? .black.opacity(0.88) : Theme.text)
        .padding(12)
        .frame(height: 104, alignment: .top)
        .background(selectableFill(selected), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.9) : Theme.rowStroke, lineWidth: selected ? 1.5 : 1))
    }

    @ViewBuilder private var avatar: some View {
        if let photo, let image = NSImage(contentsOf: photo) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            let initials = review.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            Text(initials).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(white: 0.23))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.97, green: 0.85, blue: 0.77))
        }
    }
}
