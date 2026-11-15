import AppKit
import SimbiaCore
import SwiftUI

/// A project file of the folder, as its card needs it.
struct ProjectCard: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    /// "VD 12 DEMO AD - HOOK" → 12 and "DEMO AD" (before " - "); nil without a number.
    let number: Int?
    let category: String
    var status: ProjectStatus
    var tasks: [ProjectTask]
    let duration: Double
    let shots: Int
    let captions: Int
    /// The first shot's clip and the moment of it the card shows.
    let poster: URL?
    let posterAt: Double
    let modified: Date
    let revision: Int
    let savedBy: String

    init(url: URL, project p: Project, modified: Date) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: " ", maxSplits: 2).map(String.init)
        number = parts.count > 1 && parts[0] == "VD" ? Int(parts[1]) : nil
        let rest = number != nil && parts.count > 2 ? parts[2] : name
        category = rest.components(separatedBy: " - ").first ?? rest
        status = ProjectStatus(p.status)
        tasks = p.tasks ?? []
        duration = p.duration
        shots = p.shots.count
        captions = p.captions.chunks.count
        let first = p.shots.min { $0.start < $1.start }
        poster = first.map { Project.resolve($0.src, relativeTo: url) }
        posterAt = first.map { $0.inPoint + min(0.6, $0.duration / 2) * $0.speed } ?? 0
        self.modified = modified
        revision = p.revision
        savedBy = p.savedBy
    }

    static func scan(_ folder: URL) -> [ProjectCard] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == Project.fileExtension && !$0.lastPathComponent.hasPrefix("_") }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Project.self, from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ProjectCard(url: url, project: p, modified: date)
        }
    }

    /// The cards in batches as the briefs come: numbers in a row of one kind, at most four numbers each (a second
    /// version of a video stays with its number); the newest batch first, cards in order inside it.
    static func batches(_ cards: [ProjectCard]) -> [ProjectBatch] {
        let numbered = cards.filter { $0.number != nil }.sorted { ($0.number!, $0.name) < ($1.number!, $1.name) }
        var out: [[ProjectCard]] = []
        for card in numbered {
            if let last = out.last?.last, let n = last.number, card.category == last.category,
               card.number! - n <= 1, Set(out[out.count - 1].compactMap(\.number)).union([card.number!]).count <= 4 {
                out[out.count - 1].append(card)
            } else { out.append([card]) }
        }
        var titled = out.reversed().map { group -> ProjectBatch in
            let a = group.first!.number!, b = group.last!.number!
            return ProjectBatch(title: (a == b ? "VD \(a)" : "VD \(a)–\(b)") + " · " + group[0].category, cards: group)
        }
        let other = cards.filter { $0.number == nil }.sorted { $0.name < $1.name }
        if !other.isEmpty { titled.append(ProjectBatch(title: tr("Другие", "Other", "Autres"), cards: other)) }
        return titled
    }
}

struct ProjectBatch: Identifiable {
    let title: String
    let cards: [ProjectCard]
    var id: String { title }
}

extension ProjectStatus {
    var colour: Color {
        switch self {
        case .new: Color(red: 0.62, green: 0.45, blue: 1.0)
        case .review: Color(red: 1.0, green: 0.76, blue: 0.2)
        case .done: Color(red: 0.24, green: 0.8, blue: 0.4)
        }
    }

    /// The status's name in the interface's language (`name` is the Russian one the journal writes).
    var title: String {
        switch self {
        case .new: tr("Новый", "New", "Nouveau")
        case .review: tr("На проверке", "In review", "En vérification")
        case .done: tr("Готово", "Done", "Terminé")
        }
    }

    /// Short, for the status buttons.
    var short: String { self == .review ? tr("Проверка", "Review", "Vérification") : title }

    func count(_ n: Int) -> String {
        switch self {
        case .new: tr(ruPlural(n, "новый", "новых", "новых"), "\(n) new", n > 1 ? "\(n) nouveaux" : "\(n) nouveau")
        case .review: tr("\(n) на проверке", "\(n) in review", "\(n) en vérification")
        case .done: tr("\(n) сдано", "\(n) done", n > 1 ? "\(n) terminés" : "\(n) terminé")
        }
    }

    var symbol: String {
        switch self {
        case .new: "sparkles"
        case .review: "eye"
        case .done: "checkmark"
        }
    }
}

extension Job {
    func openBrowser() {
        saveIfChanged()
        flushJournal()
        player.pause()
        withAnimation(Theme.settle) { browserOpen = true }
    }

    func closeBrowser() { withAnimation(Theme.settle) { browserOpen = false } }

    /// A change to a project's status or list. The open project changes in the editor (and saves as usual); any other
    /// is rewritten on disk as a new revision, with a journal entry.
    func updateProject(_ url: URL, _ change: (inout Project) -> Void) {
        if url.standardizedFileURL == projectURL?.standardizedFileURL, var p = project {
            change(&p)
            project = p
            saveIfChanged()
            flushJournal()
            return
        }
        guard let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Project.self, from: data) else { return }
        var p = old
        change(&p)
        guard p != old else { return }
        p.revision = old.revision + 1
        p.savedBy = "app"
        guard let out = try? p.encoded(), (try? out.write(to: url, options: .atomic)) != nil else {
            show(t("Не удалось записать \(url.lastPathComponent)", "Could not write \(url.lastPathComponent)", "Impossible d’écrire \(url.lastPathComponent)"), isError: true)
            return
        }
        let changes = p.changes(from: old)
        if !changes.isEmpty {
            Journal.append(JournalEntry(project: url.lastPathComponent, revision: p.revision, by: "app", changes: changes),
                           inFolder: url.deletingLastPathComponent())
        }
    }
}

/// Every project of the folder over the whole window, by batch. Green with a tick — delivered; yellow — made, to be
/// checked; violet — still to make. A click shows the project's list (done / left) and its journal; a double click,
/// or «Открыть», switches to it.
struct ProjectBrowser: View {
    @ObservedObject var job: Job
    @State private var cards: [ProjectCard] = []
    @State private var loading = true
    @State private var filter: ProjectStatus?
    @State private var search = ""
    @State private var picked: String?

    /// The open project, or on the start screen the last one opened.
    private var current: URL? { job.projectURL ?? job.recentProjects.first }
    private var folder: URL? { current?.deletingLastPathComponent() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rowStroke)
            HStack(spacing: 0) {
                grid
                if let card = cards.first(where: { $0.id == picked }) {
                    Divider().overlay(Theme.rowStroke)
                    ProjectDetail(job: job, card: card, reload: { Task { await load() } }).frame(width: 380).id(card.id)
                }
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .task { await load() }
    }

    private func load() async {
        guard let folder else { loading = false; return }
        cards = await Task.detached(priority: .userInitiated) { ProjectCard.scan(folder) }.value
        loading = false
        if picked == nil { picked = current?.path }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.t("Проекты", "Projects", "Projets")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text(folder?.path ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            chip(nil, job.t("Все", "All", "Tous"), cards.count, Color.white)
            ForEach(ProjectStatus.allCases, id: \.self) { s in chip(s, s.title, cards.filter { $0.status == s }.count, s.colour) }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(job.t("Поиск…", "Search…", "Rechercher…"), text: $search).textFieldStyle(.plain).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(width: 200, height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            Button { job.closeBrowser() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(BouncyButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(job.t("Закрыть · Esc", "Close · Esc", "Fermer · Esc"))
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func chip(_ status: ProjectStatus?, _ title: String, _ count: Int, _ colour: Color) -> some View {
        let on = filter == status
        return Button { withAnimation(Theme.snappy) { filter = status } } label: {
            HStack(spacing: 7) {
                if status != nil { Circle().fill(colour).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text("\(count)").font(.system(size: 12).monospacedDigit()).opacity(0.6)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(on ? Color.black : Theme.text)
            .background(on ? colour : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(BouncyButtonStyle())
    }

    private var grid: some View {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let shown = cards.filter { c in (filter == nil || c.status == filter) && words.allSatisfy { c.name.lowercased().contains($0) } }
        return ScrollView {
            if loading {
                ProgressView().controlSize(.small).padding(40)
            } else if shown.isEmpty {
                Text(job.t("Нет проектов", "No projects", "Aucun projet")).foregroundStyle(Theme.muted).padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 4 * 118 + 3 * 12), spacing: 28, alignment: .topLeading)],
                          alignment: .leading, spacing: 24) {
                    ForEach(ProjectCard.batches(shown)) { batch in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text(batch.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                                ForEach(ProjectStatus.allCases, id: \.self) { s in
                                    let n = batch.cards.filter { $0.status == s }.count
                                    if n > 0 {
                                        Text(s.count(n)).font(.system(size: 11, weight: .semibold)).foregroundStyle(s.colour)
                                    }
                                }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), alignment: .leading, spacing: 14) {
                                ForEach(batch.cards) { card in
                                    ProjectTile(job: job, card: card, selected: picked == card.id, open: card.url.path == job.projectURL?.path)
                                        .onTapGesture(count: 2) { open(card) }
                                        .onTapGesture { picked = card.id }
                                        .contextMenu {
                                            ForEach(ProjectStatus.allCases, id: \.self) { s in
                                                Button(s.title) { setStatus(card, s) }.disabled(card.status == s)
                                            }
                                            Divider()
                                            Button(job.t("Открыть", "Open", "Ouvrir")) { open(card) }
                                            Button(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([card.url]) }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func setStatus(_ card: ProjectCard, _ status: ProjectStatus) {
        job.updateProject(card.url) { $0.status = status.rawValue }
        if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i].status = status }
    }

    private func open(_ card: ProjectCard) {
        if card.url.path != job.projectURL?.path { job.openProject(card.url) }
        job.closeBrowser()
    }
}

/// 41.3 → "0:41".
private func minutes(_ t: Double) -> String { String(format: "%d:%02d", Int(t.rounded()) / 60, Int(t.rounded()) % 60) }

/// A project as a 9:16 frame of its first shot, ringed in its status colour.
private struct ProjectTile: View {
    @ObservedObject var job: Job
    let card: ProjectCard
    let selected: Bool
    let open: Bool
    @State private var still: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                card.status.colour.opacity(0.14)
                if let still { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                else if card.shots == 0 {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 22, weight: .semibold))
                        Text(job.t("ещё не собран", "not built yet", "pas encore monté")).font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(card.status.colour.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 4) {
                    Image(systemName: card.status.symbol).font(.system(size: 9.5, weight: .heavy))
                    Text(card.status.title.uppercased()).font(.system(size: 9, weight: .heavy))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(card.status.colour, in: Capsule())
                .padding(6)
                if open {
                    Text(job.t("ОТКРЫТ", "OPEN", "OUVERT")).font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Color.white, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.white : card.status.colour, lineWidth: selected ? 3 : 2))
            HStack(spacing: 4) {
                Text(card.number.map { "VD \($0)" } ?? card.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 2)
                if card.duration > 0 { Text(minutes(card.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted) }
            }
            let left = card.tasks.filter { !$0.done }.count
            Text(left > 0 ? job.t("осталось: \(left)", "left: \(left)", "reste : \(left)") : card.category)
                .font(.system(size: 10.5)).foregroundStyle(left > 0 ? card.status.colour : Theme.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(card.name)
        .task(id: card.id) {
            if let poster = card.poster { still = await ClipStills.shared.frame(poster, at: card.posterAt) }
        }
    }
}

/// The picked project: its frame, status, what was done and what is left, and the journal of its edits.
private struct ProjectDetail: View {
    @ObservedObject var job: Job
    let card: ProjectCard
    let reload: () -> Void
    @State private var still: CGImage?
    @State private var tasks: [ProjectTask] = []
    @State private var draft = ""
    @State private var entries: [JournalEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        card.status.colour.opacity(0.14)
                        if let still { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    }
                    .frame(width: 120, height: 213)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(card.status.colour, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Text("\(minutes(card.duration)) · " + job.t(ruPlural(card.shots, "шот", "шота", "шотов"), "\(card.shots) shots", "\(card.shots) plans") + " · "
                             + captionCount(job, card.captions))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.muted)
                        Text(job.t("ревизия \(card.revision) · ", "revision \(card.revision) · ", "révision \(card.revision) · ") + (card.savedBy == "app" ? job.t("правил Богдан", "edited by Bogdan", "modifié par Bogdan") : "Claude")
                             + " · " + card.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer(minLength: 6)
                        Pill(card.url.path == job.projectURL?.path ? job.t("Открыт", "Open", "Ouvrir") : job.t("Открыть проект", "Open project", "Ouvrir le projet"), primary: true) {
                            if card.url.path != job.projectURL?.path { job.openProject(card.url) }
                            job.closeBrowser()
                        }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(ProjectStatus.allCases, id: \.self) { s in
                        let on = card.status == s
                        Button {
                            job.updateProject(card.url) { $0.status = s.rawValue }
                            reload()
                        } label: {
                            Label(s.short, systemImage: s.symbol).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: .infinity)
                                .foregroundStyle(on ? Color.black : Theme.text)
                                .background(on ? s.colour : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
                section(job.t("Предстоит", "To do", "À faire"), tasks.indices.filter { !tasks[$0].done })
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(Theme.muted)
                    TextField(job.t("Новая задача…", "New task…", "Nouvelle tâche…"), text: $draft)
                        .textFieldStyle(.plain).foregroundStyle(Theme.text)
                        .onSubmit {
                            let text = draft.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            tasks.append(ProjectTask(text: text)); draft = ""; save()
                        }
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                section(job.t("Сделано", "Done", "Terminé"), tasks.indices.filter { tasks[$0].done })
                Text(job.t("Журнал правок", "Edit journal", "Journal des modifications")).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                if entries.isEmpty {
                    Text(job.t("Пока пусто: сюда попадают правки — твои и Claude", "Empty so far: edits land here — yours and Claude's", "Vide pour l’instant : les modifications arrivent ici — les vôtres et celles de Claude"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(e.by == "app" ? Color(red: 0.35, green: 0.65, blue: 1) : Color(red: 1, green: 0.6, blue: 0.3)).frame(width: 7, height: 7)
                            Text((e.by == "app" ? job.t("Богдан", "Bogdan") : "Claude") + " · " + e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        ForEach(Array(e.changes.enumerated()), id: \.offset) { _, line in
                            Text("· " + line).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(18)
        }
        .task(id: "\(card.id)|\(card.revision)") {
            tasks = card.tasks
            entries = Journal.read(inFolder: card.url.deletingLastPathComponent(), project: card.url.lastPathComponent, limit: 30)
            if let poster = card.poster { still = await ClipStills.shared.frame(poster, at: card.posterAt) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [Int]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                ForEach(rows, id: \.self) { i in
                    HStack(alignment: .top, spacing: 9) {
                        Button {
                            tasks[i].done.toggle(); save()
                        } label: {
                            Image(systemName: tasks[i].done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15)).foregroundStyle(tasks[i].done ? ProjectStatus.done.colour : Theme.muted)
                        }
                        .buttonStyle(.plain)
                        Text(tasks[i].text).font(.system(size: 12.5)).foregroundStyle(tasks[i].done ? Theme.muted : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contextMenu { Button(job.t("Удалить задачу", "Delete task", "Supprimer la tâche"), role: .destructive) { tasks.remove(at: i); save() } }
                }
            }
        }
    }

    private func save() {
        let list = tasks
        job.updateProject(card.url) { $0.tasks = list.isEmpty ? nil : list }
        reload()
    }
}
