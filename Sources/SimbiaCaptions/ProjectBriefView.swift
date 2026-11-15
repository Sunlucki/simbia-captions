import AppKit
import SimbiaCore
import SwiftUI

extension Job {
    func openBrief() {
        guard project != nil else { return }
        player.pause()
        refreshIssues()
        withAnimation(Theme.settle) { briefOpen = true }
    }

    func closeBrief() { withAnimation(Theme.settle) { briefOpen = false } }
}

/// A click on the project's name: over the whole window, in plain words, what we are making and what is asked of us
/// (the brief Claude writes from the card), then what waits for a check, what is left and what is done — the list
/// both of us tick. What the checks and the «Что не так» marks found sits under «Проверить» too.
struct ProjectBriefView: View {
    @ObservedObject var job: Job
    @State private var draft = ""
    @State private var entries: [JournalEntry] = []

    var body: some View {
        let tasks = job.project?.tasks ?? []
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rowStroke)
            HStack(alignment: .top, spacing: 0) {
                ScrollView { brief.padding(28).frame(maxWidth: 820, alignment: .leading) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Theme.rowStroke)
                ScrollView { work(tasks).padding(24) }.frame(width: 460)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .task(id: job.project?.revision) {
            guard let url = job.projectURL else { return }
            entries = Journal.read(inFolder: url.deletingLastPathComponent(), project: url.lastPathComponent, limit: 12)
        }
    }

    // MARK: Header

    private var header: some View {
        let status = ProjectStatus(job.project?.status)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.t("БРИФ И ЗАДАЧИ", "BRIEF AND TASKS", "BRIEF ET TÂCHES")).font(.system(size: 10.5, weight: .semibold)).tracking(1.6).foregroundStyle(Theme.muted)
                Text(job.displayName).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 12)
            // where the video is: one control, the three states
            HStack(spacing: 3) {
                ForEach(ProjectStatus.allCases, id: \.self) { s in
                    let on = status == s
                    Button { if let url = job.projectURL { job.updateProject(url) { $0.status = s.rawValue } } } label: {
                        Label(s.short, systemImage: s.symbol).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            .frame(width: 120, height: 30)
                            .foregroundStyle(on ? Color.black : Theme.text.opacity(0.8))
                            .background(on ? s.colour : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let link = job.project?.brief?.card, let url = URL(string: link) {
                Pill(job.t("Карточка", "Card", "Carte"), icon: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    .help(link)
            }
            Pill(job.t("Все проекты", "All projects", "Tous les projets"), icon: "square.grid.2x2") { job.closeBrief(); job.openBrowser() }
            Button { job.closeBrief() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(BouncyButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(job.t("Закрыть · Esc", "Close · Esc", "Fermer · Esc"))
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: The brief

    @ViewBuilder private var brief: some View {
        if let b = job.project?.brief {
            VStack(alignment: .leading, spacing: 26) {
                // the references first: what the video is to look like
                if !b.refs.isEmpty {
                    block(job.t("Референсы", "References", "Références"), "link") {
                        WrapStack(spacing: 8) {
                            ForEach(Array(b.refs.enumerated()), id: \.offset) { _, ref in
                                Pill(ref.title, icon: icon(ref.url)) { open(ref.url) }.help(ref.url)
                            }
                        }
                    }
                }
                block(job.t("Над чем работаем", "What we are making", "Ce que nous réalisons"), "film") {
                    Text(b.about).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hook = b.hook {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.t("Хук этого ролика", "This video's hook", "L’accroche de cette vidéo")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                            Text(hook).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !b.needs.isEmpty {
                    block(job.t("Что от нас требуется", "What is asked of us", "Ce qu’on attend de nous"), "checklist") {
                        ForEach(Array(b.needs.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Circle().fill(Theme.muted).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                Text(line).font(.system(size: 13.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !b.scenes.isEmpty {
                    block(job.t("Сцены по порядку", "The scenes in order", "Les scènes dans l’ordre"), "list.number") {
                        ForEach(Array(b.scenes.enumerated()), id: \.offset) { i, scene in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(Theme.muted)
                                    .frame(width: 22, height: 22).background(Color.white.opacity(0.08), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    (Text(scene.who).bold() + Text(" — " + scene.gist))
                                        .font(.system(size: 13.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                                    if let words = scene.words {
                                        Text("«\(words)»").font(.system(size: 12).italic()).foregroundStyle(Theme.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let diff = scene.diff {
                                        (Text(job.t("В монтаже: ", "In the edit: ", "Au montage : ")).bold() + Text(diff))
                                            .font(.system(size: 12.5)).foregroundStyle(ProjectStatus.review.colour)
                                            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.t("Бриф ещё не записан", "No brief yet", "Pas encore de brief")).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(job.t("Напиши Claude «запиши бриф для этого проекта» — он перескажет карточку здесь коротко и по-русски.",
                           "Ask Claude to write this project's brief — the card, retold here in a few plain lines.", "Demandez à Claude d’écrire le brief de ce projet — la carte, résumée ici en quelques lignes simples."))
                    .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    /// A link opens in the browser, a file in its own app.
    private func open(_ ref: String) {
        let url = ref.hasPrefix("/") ? URL(fileURLWithPath: ref) : URL(string: ref)
        if let url { NSWorkspace.shared.open(url) }
    }

    private func icon(_ ref: String) -> String {
        let ext = (ref as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) { return "play.rectangle" }
        if ["jpg", "jpeg", "png", "webp", "heic"].contains(ext) { return "photo" }
        return ref.hasPrefix("/") ? "doc" : "safari"
    }

    private func block<Content: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
            content()
        }
    }

    // MARK: The work

    private func work(_ tasks: [ProjectTask]) -> some View {
        let toCheck = tasks.indices.filter { !tasks[$0].done && tasks[$0].review == true }
        let left = tasks.indices.filter { !tasks[$0].done && tasks[$0].review != true }
        let done = tasks.indices.filter { tasks[$0].done }
        let shots = (job.project?.shots ?? []).sorted { $0.start < $1.start }
        let marked = shots.filter(\.flagged)
        let sounds = (job.project?.audio ?? []).filter(\.flagged)
        let found = !toCheck.isEmpty || !job.issues.isEmpty || !marked.isEmpty || !sounds.isEmpty
        return VStack(alignment: .leading, spacing: 22) {
            section(job.t("Проверить", "To check", "À vérifier"), ProjectStatus.review.colour, toCheck.count + (job.issues.isEmpty ? 0 : 1) + marked.count + sounds.count) {
                ForEach(toCheck, id: \.self) { i in
                    row(tasks[i].text, symbol: "eye", tint: ProjectStatus.review.colour) {
                        Pill(job.t("Проверено", "Checked", "Vérifié"), icon: "checkmark") { change { $0[i].done = true } }.fixedSize()
                    }
                }
                if !job.issues.isEmpty {
                    row(job.t("Проверка перед экспортом: замечаний \(job.issues.count)", "Checks before export: \(job.issues.count) found", "Vérifications avant export : \(job.issues.count) à revoir"),
                        symbol: "exclamationmark.triangle", tint: ProjectStatus.review.colour) {
                        Pill(job.t("Открыть", "Open", "Ouvrir"), icon: "arrow.right") { job.closeBrief(); job.checksOpen = true }.fixedSize()
                    }
                }
                ForEach(marked, id: \.id) { s in
                    let n = (shots.firstIndex { $0.id == s.id } ?? 0) + 1
                    row(job.t("Шот \(n)", "Shot \(n)", "Plan \(n)") + " · " + (s.label ?? (s.src as NSString).lastPathComponent) + ": "
                        + marks(s.issues, Shot.issueKinds, s.note), symbol: "flag", tint: Theme.flag) { EmptyView() }
                }
                ForEach(sounds, id: \.id) { a in
                    row(job.t("Звук", "Sound", "Son") + " · " + (a.label ?? (a.src as NSString).lastPathComponent) + ": "
                        + marks(a.issues, AudioClip.issueKinds, a.note), symbol: "flag", tint: Theme.flag) { EmptyView() }
                }
                if !found { quiet(job.t("Нечего проверять", "Nothing to check", "Rien à vérifier")) }
            }

            section(job.t("Осталось сделать", "Left to do", "Reste à faire"), ProjectStatus.new.colour, left.count) {
                ForEach(left, id: \.self) { i in tick(tasks[i], i) }
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(Theme.muted)
                    TextField(job.t("Новая задача…", "New task…", "Nouvelle tâche…"), text: $draft)
                        .textFieldStyle(.plain).foregroundStyle(Theme.text)
                        .onSubmit {
                            let text = draft.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            change { $0.append(ProjectTask(text: text)) }
                            draft = ""
                        }
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            section(job.t("Сделано", "Done", "Terminé"), ProjectStatus.done.colour, done.count) {
                ForEach(done, id: \.self) { i in tick(tasks[i], i) }
                if done.isEmpty { quiet(job.t("Пока ничего", "Nothing yet", "Rien pour l’instant")) }
            }

            if !entries.isEmpty {
                section(job.t("Последние правки", "Latest edits", "Dernières modifications"), Theme.muted, 0) {
                    ForEach(Array(entries.reversed().enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((e.by == "app" ? job.t("Ты", "You", "Vous") : "Claude") + " · " + e.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(e.by == "app" ? Color(red: 0.45, green: 0.7, blue: 1) : Color(red: 1, green: 0.65, blue: 0.35))
                            Text(e.changes.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.8))
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, _ tint: Color, _ count: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11.5, weight: .bold).monospacedDigit()).foregroundStyle(.black)
                        .padding(.horizontal, 7).frame(height: 18).background(tint, in: Capsule())
                }
            }
            content()
        }
    }

    private func row<Trailing: View>(_ text: String, symbol: String, tint: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// A task with its tick: left ↔ done.
    private func tick(_ task: ProjectTask, _ i: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { change { $0[i].done.toggle() } } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(task.done ? ProjectStatus.done.colour : Theme.muted)
            }
            .buttonStyle(.plain)
            Text(task.text).font(.system(size: 13)).foregroundStyle(task.done ? Theme.muted : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu { Button(job.t("Удалить задачу", "Delete task", "Supprimer la tâche"), role: .destructive) { change { $0.remove(at: i) } } }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
    }

    /// "Не тот голос, Громкость — «note»".
    private func marks(_ keys: [String], _ kinds: [(key: String, ru: String, en: String)], _ note: String?) -> String {
        let names = keys.compactMap { k in kinds.first { $0.key == k }.map { job.t($0.ru, $0.en, frenchIssueNames[$0.en]) } }
        return (names + [(note ?? "").isEmpty ? nil : "«\(note!)»"].compactMap { $0 }).joined(separator: ", ")
    }

    private func change(_ edit: (inout [ProjectTask]) -> Void) {
        guard let url = job.projectURL else { return }
        var list = job.project?.tasks ?? []
        edit(&list)
        job.updateProject(url) { $0.tasks = list.isEmpty ? nil : list }
    }
}
