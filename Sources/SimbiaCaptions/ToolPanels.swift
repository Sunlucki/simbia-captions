import SimbiaCore
import SwiftUI

// The windows of the editor's tools: the checks over the export button, find & replace and the glossary over
// the text, pause removal over the timeline, footage suggestions in a shot's window.

// MARK: - Checks

/// Next to Export: how many things are worth fixing; a click lists them.
struct ChecksButton: View {
    @ObservedObject var job: Job

    var body: some View {
        let count = job.issues.count
        let clean = count == 0
        let tint = clean ? Color(red: 0.45, green: 0.85, blue: 0.55) : Color(red: 1, green: 0.72, blue: 0.3)
        Button {
            job.refreshIssues()
            job.exportAfterChecks = false
            job.checksOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                Text(clean ? job.t("Проверено", "All good", "Tout est bon") : "\(count)").monospacedDigit()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 36)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(BouncyButtonStyle())
        .disabled(!job.canExport)
        .help(job.t("Проверка перед экспортом: читаемость, голос, склейки, написание, заголовки",
                    "Checks before export: reading speed, voice, cuts, spelling, titles", "Vérifications avant export : vitesse de lecture, voix, coupes, orthographe, titres"))
        .popover(isPresented: $job.checksOpen, arrowEdge: .bottom) { ChecksPanel(job: job).preferredColorScheme(.dark) }
    }
}

struct ChecksPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        let issues = job.issues
        let fixable = issues.filter(\.fixable)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.exportAfterChecks ? job.t("ПЕРЕД ЭКСПОРТОМ", "BEFORE EXPORT", "AVANT EXPORT") : job.t("ПРОВЕРКА", "CHECKS", "VÉRIFICATIONS"))
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                Text(issues.isEmpty ? job.t("Всё в порядке", "Nothing to fix", "Rien à corriger")
                                    : job.t("Замечаний: \(issues.count)", "\(issues.count) to look at", "\(issues.count) à vérifier"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }

            if issues.isEmpty {
                Text(job.t("Субтитры успевают прочитать, совпадают с голосом и склейками, заголовки держатся не меньше 2 с.",
                           "Captions are readable and sit on the voice and the cuts; titles stay up 2 s or more.", "Les sous-titres sont lisibles et calés sur la voix et les coupes ; les titres restent affichés 2 s ou plus."))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if issues.count <= 6 {
                list(issues)
            } else {
                // a long list scrolls in a window of fixed height — a popover gives a scroll view no height of its own
                ScrollView { list(issues) }.frame(height: 400)
            }

            PillGrid {
                if job.exportAfterChecks {
                    Pill(job.t("Экспортировать как есть", "Export as it is", "Exporter tel quel"), icon: "square.and.arrow.up") { job.checksOpen = false; job.export(checked: true) }
                    if !fixable.isEmpty {
                        Pill(job.t("Исправить и экспортировать", "Fix all, then export", "Tout corriger, puis exporter"), icon: "wand.and.stars", primary: true) {
                            job.fixAll(); job.checksOpen = false; job.export(checked: true)
                        }
                    }
                } else if !fixable.isEmpty {
                    Pill(job.t("Исправить всё (\(fixable.count))", "Fix all (\(fixable.count))", "Tout corriger (\(fixable.count))"), icon: "wand.and.stars", primary: true) { job.fixAll() }
                }
            }
        }
        .padding(16)
        .frame(width: 480, alignment: .leading)
    }

    private func list(_ issues: [Issue]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Issue.Kind.allCases, id: \.self) { kind in
                let group = issues.filter { $0.kind == kind }
                if !group.isEmpty {
                    HStack {
                        Text("\(job.kindName(kind)) · \(group.count)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.85))
                        Spacer()
                        if group.count > 1, kind != .missing {
                            Button(job.t("Исправить все", "Fix all", "Tout corriger")) { job.fix(group) }
                                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.45))
                        }
                    }
                    .padding(.top, 6)
                    ForEach(group) { IssueRow(job: job, issue: $0) }
                }
            }
        }
    }
}

private struct IssueRow: View {
    @ObservedObject var job: Job
    let issue: Issue

    var body: some View {
        HStack(spacing: 10) {
            Button { job.jump(to: issue) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(clock(issue.time)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                    Text(job.describe(issue)).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.t("Показать на таймлайне", "Show on the timeline", "Afficher dans la timeline"))
            if issue.fixable {
                Button(job.t("Исправить", "Fix", "Corriger")) { job.fix([issue]) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 26)
                    .foregroundStyle(Theme.text)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Theme.rowStroke, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.rowFill.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Text tools

/// A text field for the tool windows, edited live.
struct ToolField: View {
    @ObservedObject var job: Job
    let placeholder: String
    @Binding var text: String
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.fieldText)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($focused)
            .onSubmit(submit)
            .onChange(of: focused) { _, value in job.textEditing = value }
            .onDisappear { if focused { job.textEditing = false } }
    }
}

struct FindReplacePanel: View {
    @ObservedObject var job: Job
    @State private var find = ""
    @State private var replacement = ""
    @State private var wholeWords = true
    @State private var replaced: Int?

    var body: some View {
        let count = job.matches(find, wholeWords: wholeWords)
        VStack(alignment: .leading, spacing: 12) {
            Text(job.t("НАЙТИ И ЗАМЕНИТЬ", "FIND AND REPLACE", "RECHERCHER ET REMPLACER"))
                .font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
            ToolField(job: job, placeholder: job.t("Найти", "Find", "Rechercher"), text: $find)
            ToolField(job: job, placeholder: job.t("Заменить на", "Replace with", "Remplacer par"), text: $replacement) { replace() }
            Toggle(job.t("Только целые слова", "Whole words only", "Mots entiers uniquement"), isOn: $wholeWords)
                .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(Theme.text)
            HStack {
                Text(replaced.map { job.t("Заменено: \($0)", "Replaced: \($0)", "Remplacés : \($0)") }
                     ?? (find.isEmpty ? "" : count == 0 ? job.t("Не найдено", "Not found", "Introuvable") : job.t("Найдено: \(count)", "Found: \(count)", "Trouvés : \(count)")))
                    .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.muted)
                Spacer()
                Pill(job.t("Заменить всё", "Replace all", "Tout remplacer"), primary: true) { replace() }
                    .disabled(count == 0)
            }
            Text(job.t("Тайминг слов сохраняется.", "Word timing is kept.", "Le timing des mots est conservé."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .onChange(of: find) { _, _ in replaced = nil }
    }

    private func replace() {
        guard job.matches(find, wholeWords: wholeWords) > 0 else { return }
        replaced = job.replaceAll(find, with: replacement, wholeWords: wholeWords)
    }
}

struct GlossaryPanel: View {
    @ObservedObject var job: Job
    @State private var word = ""

    var body: some View {
        let wrong = job.issues.filter { $0.kind == .brand }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.t("СЛОВАРЬ", "GLOSSARY", "GLOSSAIRE"))
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                Text(job.t("Всегда пишутся так", "Always spelt like this", "Toujours écrits ainsi"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }
            WrapStack(spacing: 6) {
                ForEach(job.glossary.words, id: \.self) { w in
                    HStack(spacing: 6) {
                        Text(w).font(.system(size: 13, weight: .semibold))
                        Button { job.removeFromGlossary(w) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                            .help(job.t("Убрать из словаря", "Remove from the glossary", "Retirer du glossaire"))
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .foregroundStyle(Theme.text)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Theme.rowStroke, lineWidth: 1))
                }
            }
            HStack(spacing: 8) {
                ToolField(job: job, placeholder: job.t("Новое слово", "New word", "Nouveau mot"), text: $word) { add() }
                Pill(job.t("Добавить", "Add", "Ajouter")) { add() }.disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(job.t("Распознаватель Mac ждёт эти слова в речи, а похожие («Symbia» вместо «Simbia») исправляются сами.",
                       "The Mac's recogniser expects these words; near misses (“Symbia” for “Simbia”) are put right.", "La reconnaissance du Mac attend ces mots ; les variantes proches (« Symbia » pour « Simbia ») sont corrigées."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !wrong.isEmpty {
                HairlineDivider().opacity(0.3)
                ForEach(wrong.prefix(4)) { issue in
                    Text("\(clock(issue.time))  \(issue.text)").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.text)
                }
                Pill(job.t("Исправить в тексте (\(wrong.count))", "Fix in the text (\(wrong.count))", "Corriger dans le texte (\(wrong.count))"), primary: true) { job.fix(wrong) }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private func add() {
        job.addToGlossary(word)
        word = ""
    }
}

// MARK: - Pauses

struct PausesPanel: View {
    @ObservedObject var job: Job
    @State private var minimum = 0.4
    @State private var voice: VoiceActivity?
    @State private var listening = true

    var body: some View {
        let doc = job.document()
        let found = listening ? [] : doc.pauses(minimum: minimum, voice: voice)
        let total = found.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.t("ВЫРЕЗАТЬ ПАУЗЫ", "REMOVE PAUSES", "COUPER LES PAUSES"))
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                Text(job.t("Тишина между словами", "Silence between words", "Silence entre les mots"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(job.t("Паузы находятся по звуку голоса. Кадр говорящего и голос склеиваются встык, остальные шоты, субтитры и заголовки сдвигаются сами, музыка играет дальше.",
                       "Pauses are found in the voice itself. The speaker's picture and voice are jump-cut; other shots, captions and titles move up, the music plays on.", "Les pauses sont détectées dans la voix elle-même. L’image et la voix de l’orateur sont coupées en jump cut ; les autres plans, sous-titres et titres se décalent, la musique continue."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(job.t("Длиннее", "Longer than", "Plus longues que")).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Slider(value: $minimum, in: 0.25...1.5, step: 0.05)
                Text("\(seconds(minimum)) \(job.t("с", "s"))").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.text)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                if listening {
                    ProgressView().controlSize(.small)
                    Text(job.t("Слушаю голос…", "Listening to the voice…", "Écoute de la voix…")).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                } else {
                    Text(found.isEmpty ? job.t("Таких пауз нет", "No pauses that long", "Aucune pause aussi longue")
                         : job.t("\(ruPlural(found.count, "пауза", "паузы", "пауз")) · видео станет короче на \(seconds((total * 10).rounded() / 10)) с (\(clock(doc.duration)) → \(clock(doc.duration - total)))",
                                 "\(found.count) pause\(found.count == 1 ? "" : "s") · \(seconds((total * 10).rounded() / 10)) s shorter (\(clock(doc.duration)) → \(clock(doc.duration - total)))", "\(found.count) pause\(found.count == 1 ? "" : "s") · \(seconds((total * 10).rounded() / 10)) s de moins (\(clock(doc.duration)) → \(clock(doc.duration - total)))"))
                        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Pill(job.t("Вырезать", "Remove", "Supprimer"), primary: true) { job.removePauses(found); job.toolPanel = nil }
                .disabled(found.isEmpty)
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .task {
            voice = await job.voiceActivity()
            listening = false
        }
    }
}

// MARK: - Footage

/// In a shot's window: the library's best moments for what is said over the shot; a click puts one in.
struct FootageSuggestions: View {
    @ObservedObject var job: Job
    let shot: Shot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(job.t("Подобрать из библиотеки", "From the library", "Depuis la bibliothèque"))
            PillGrid {
                Pill(job.t("Видео проекта…", "Project videos…", "Vidéos du projet…"), icon: "film.stack") { job.openClips(for: shot.id) }
                    .help(job.t("Папка со всеми сгенерированными видео этого проекта (для историй)", "The folder with all of this project's generated videos (for stories)", "Le dossier de toutes les vidéos générées de ce projet (pour les stories)"))
                Pill(job.t("Вся библиотека…", "Whole library…", "Toute la bibliothèque…"), icon: "square.grid.2x2") { job.openGallery(for: shot.id) }
                    .help(job.t("Все футажи по категориям, на весь экран", "All footage by category, full window", "Tous les rushes par catégorie, en pleine fenêtre"))
            }
            switch job.footageState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.t("Читаю библиотеку клипов…", "Reading the footage library…", "Lecture de la bibliothèque de rushes…")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            case .missing:
                HStack(spacing: 8) {
                    Text(job.t("Библиотека не найдена", "No footage library found", "Aucune bibliothèque de rushes trouvée")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Pill(job.t("Указать папку…", "Choose folder…", "Choisir un dossier…")) { job.chooseFootageFolder() }
                }
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.7))
            case .ready:
                let list = job.suggestions(for: shot)
                if list.isEmpty {
                    Text(job.t("Под этот текст ничего не подобралось", "Nothing fits what is said here", "Rien ne correspond à ce qui est dit ici"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(list) { SuggestionCard(job: job, suggestion: $0, shot: shot) }
                    }
                }
            }
        }
        .onAppear { job.loadFootage() }
    }
}

private struct SuggestionCard: View {
    @ObservedObject var job: Job
    let suggestion: FootageIndex.Suggestion
    let shot: Shot
    @ObservedObject private var media = MediaCache.shared

    var body: some View {
        let preview = Shot(id: "preview", start: 0, end: 1, src: suggestion.file.path, inPoint: suggestion.from)
        Button { job.useFootage(suggestion, for: shot.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let image = media.thumbnail(preview, projectURL: nil) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 104, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(suggestion.who.isEmpty ? suggestion.clip : suggestion.who)
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text(suggestion.note.isEmpty ? suggestion.tag : suggestion.note)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(suggestion.usedIn.isEmpty ? (suggestion.real ? job.t("Амбассадор · новое", "Ambassador · unused", "Ambassadrice · non utilisé") : job.t("ИИ · новое", "AI · unused", "IA · non utilisé"))
                     : job.t("Было в ", "Used in ", "Utilisé dans ") + suggestion.usedIn.joined(separator: ", "))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(suggestion.usedIn.isEmpty ? Color(red: 0.55, green: 0.9, blue: 0.6) : Color(red: 1, green: 0.75, blue: 0.4))
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            .foregroundStyle(Theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .help("\(suggestion.clip)  \(seconds(suggestion.from))–\(seconds(suggestion.to)) \(job.t("с", "s"))\n\(suggestion.note)")
    }
}
