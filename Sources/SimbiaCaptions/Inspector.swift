import AppKit
import SimbiaCore
import SwiftUI

// The tools that used to sit in a column of their own now open where the thing is: a word's tools
// over the word in the text panel, a shot's over the shot in the timeline; a title's settings sit in
// the Titles tab above its styles.

// MARK: - Word

/// What opens on a click on a word in the text panel: the word itself (edit it, make it the accent,
/// start a new caption or paragraph with it, delete it), then its caption (timing, joins, delete).
struct WordTools: View {
    @ObservedObject var job: Job
    let cueID: Cue.ID
    let index: Int

    var body: some View {
        if let cue = job.cues.first(where: { $0.id == cueID }), job.timedWords(of: cue).indices.contains(index) {
            tools(cue, job.timedWords(of: cue))
                .padding(16)
                .frame(width: 440, alignment: .leading)
        }
    }

    private func close() { job.editingWord = nil }

    @ViewBuilder private func tools(_ cue: Cue, _ words: [Word]) -> some View {
        let word = words[index]
        let (ordered, starts) = job.orderedAndStarts
        let k = ordered.firstIndex { $0.id == cue.id } ?? 0
        let opensParagraph = index == 0 && starts.indices.contains(k) && starts[k]
        let first = index == 0 && k == 0

        VStack(alignment: .leading, spacing: 12) {
            Heading(kicker: job.t("СЛОВО \(index + 1) ИЗ \(words.count)", "WORD \(index + 1) OF \(words.count)", "MOT \(index + 1) SUR \(words.count)"),
                    title: nil, detail: clock(word.start))
            CommitField(job: job, value: word.text, autofocus: true) { text in
                job.updateWord(cue.id, word: index, to: text)
            } submitted: { close() }

            HStack(spacing: 8) {
                ToolButton(symbol: "sparkle", title: word.accent ? job.t("Акцент ✓", "Accent ✓") : job.t("Выделить", "Accent", "Accentuer"),
                           active: word.accent) { withAnimation(Theme.bounce) { job.toggleWordAccent(cue.id, word: index) } }
                    .help(job.t("Слово рисуется акцентным шрифтом и цветом стиля", "The style draws the word in its accent font and colour", "Le style affiche le mot avec sa police et sa couleur d’accent"))
                ToolButton(symbol: "scissors", title: index == 0 ? job.t("Без разрыва", "No break", "Sans séparation") : job.t("Разрыв", "Break", "Séparation")) {
                    job.toggleBreak(cue.id, word: index); close()
                }
                .disabled(first)
                .help(index == 0 ? job.t("Соединить с предыдущим субтитром", "Join with the previous caption", "Joindre au sous-titre précédent")
                                 : job.t("С этого слова начнётся новый субтитр", "A new caption starts with this word", "Un nouveau sous-titre commence à ce mot"))
                ToolButton(symbol: "paragraphsign", title: opensParagraph ? job.t("Без абзаца", "No paragraph", "Sans paragraphe") : job.t("Абзац", "Paragraph", "Paragraphe")) {
                    job.toggleParagraph(at: cue.id, word: index); close()
                }
                .disabled(first)
                .help(opensParagraph ? job.t("Соединить абзац с предыдущим", "Join the paragraph with the previous one", "Joindre le paragraphe au précédent")
                                     : job.t("С этого слова начнётся новый абзац", "A new paragraph starts with this word", "Un nouveau paragraphe commence à ce mot"))
                ToolButton(symbol: "trash", title: job.t("Удалить", "Delete", "Supprimer"), destructive: true) {
                    job.updateWord(cue.id, word: index, to: ""); close()
                }
                .help(job.t("Удалить слово из субтитра", "Remove the word from the caption", "Retirer le mot du sous-titre"))
            }

            HStack(spacing: 8) {
                FieldLabel(job.t("Звучит", "Heard", "Entendu"))
                FrameNudge(time: word.start) { job.nudgeWord(cue.id, word: index, start: true, frames: $0) }
                Text("–").foregroundStyle(Theme.muted)
                FrameNudge(time: word.end) { job.nudgeWord(cue.id, word: index, start: false, frames: $0) }
            }
            .help(job.t("Начало и конец слова, по кадру. На таймлайне границы слов можно тянуть.",
                        "The word's start and end, a frame at a time. On the timeline the word boundaries can be dragged.", "Début et fin du mot, image par image. Dans la timeline, les limites des mots peuvent être déplacées."))

            HairlineDivider().opacity(0.3)

            Heading(kicker: job.t("СУБТИТР \(k + 1) ИЗ \(ordered.count)", "CAPTION \(k + 1) OF \(ordered.count)", "SOUS-TITRE \(k + 1) SUR \(ordered.count)"),
                    title: nil, detail: "\(clock(cue.start)) – \(clock(cue.end)) · \(seconds(cue.end - cue.start)) \(job.t("с", "s"))")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel(job.t("Начало", "Start", "Début"))
                    TimeField(job: job, value: cue.start) { job.pushHistory(); job.retime(cue.id, start: $0) }
                    Nudge(job: job) { job.nudge(cue.id, start: $0) }
                }
                GridRow {
                    FieldLabel(job.t("Конец", "End", "Fin"))
                    TimeField(job: job, value: cue.end) { job.pushHistory(); job.retime(cue.id, end: $0) }
                    Nudge(job: job) { job.nudge(cue.id, end: $0) }
                }
            }
            PillGrid {
                Pill(job.t("Объединить с предыдущим", "Join with previous", "Fusionner avec le précédent"), icon: "arrow.left.to.line") { job.mergeWithPrevious(cue.id); close() }
                    .disabled(k == 0)
                Pill(job.t("Объединить со следующим", "Join with next", "Fusionner avec le suivant"), icon: "arrow.right.to.line") { job.mergeWithNext(cue.id); close() }
                    .disabled(k + 1 >= ordered.count)
                    .help(job.t("Объединить со следующим субтитром · M", "Join with the next caption · M", "Joindre au sous-titre suivant · M"))
                Pill(job.t("Растянуть до следующего", "Extend to next", "Étendre jusqu’au suivant"), icon: "arrow.left.and.right") { job.extendToNext(cue.id) }
                Pill(job.t("Удалить субтитр", "Delete caption", "Supprimer le sous-titre"), icon: "trash", destructive: true) { job.select(cue); job.deleteSelection(); close() }
            }
        }
    }
}

/// A square tool in the word window: a symbol over a short label.
private struct ToolButton: View {
    let symbol: String
    let title: String
    var active = false
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let gold = Color(red: 0.85, green: 0.70, blue: 0.42)
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 94, height: 60)
            .foregroundStyle(active ? Color(red: 0.1, green: 0.07, blue: 0.06) : destructive ? Color(red: 1, green: 0.7, blue: 0.7) : Theme.text)
            .background(active ? gold : destructive ? Color.red.opacity(0.14) : Theme.rowFill,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(active ? Color(red: 0.95, green: 0.84, blue: 0.54) : destructive ? Color.red.opacity(0.45) : Theme.rowStroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

// MARK: - Several captions

/// Two or more captions selected: the strip over the text that joins them, makes them one paragraph or deletes them.
struct SelectionBar: View {
    @ObservedObject var job: Job

    var body: some View {
        let list = job.selectedCues
        let runs = job.selectedRuns
        let paragraphs = job.paragraphs
        let touched = paragraphs.indices.filter { p in paragraphs[p].contains { job.selection.contains($0.id) } }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.t("ВЫДЕЛЕНО", "SELECTED", "SÉLECTION")).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(Theme.muted)
                Text(captionCount(job, list.count) + job.t(" · абзацев: \(touched.count)", " · paragraphs: \(touched.count)", " · paragraphes : \(touched.count)"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .fixedSize()
            PillGrid(columns: 4) {
                Pill(job.t("Объединить", "Join", "Joindre"), icon: "arrow.right.to.line", primary: true) { job.mergeSelection() }
                    .disabled(!runs.contains { $0.count > 1 })
                    .help(runs.count > 1 ? job.t("Выделены не соседние субтитры — объединится каждая группа подряд идущих · M",
                                                 "The selection has gaps — each group of neighbours joins separately · M", "La sélection a des trous — chaque groupe de voisins est joint à part · M")
                                         : job.t("Объединить в один субтитр · M", "Join into one caption · M", "Joindre en un seul sous-titre · M"))
                Pill(job.t("Одним абзацем", "One paragraph", "Un seul paragraphe"), icon: "paragraphsign") { job.joinParagraphs(of: list.map(\.id)) }
                    .disabled(touched.count < 2)
                Pill(job.t("Снять выделение", "Clear", "Désélectionner"), icon: "xmark") { job.collapseSelection() }
                    .help("Esc")
                Pill(job.t("Удалить", "Delete", "Supprimer"), icon: "trash", destructive: true) { job.deleteSelection() }
                    .help("⌫")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
    }
}

/// "5 субтитров" / "5 captions".
@MainActor func captionCount(_ job: Job, _ n: Int) -> String {
    job.t(ruPlural(n, "субтитр", "субтитра", "субтитров"), n == 1 ? "1 caption" : "\(n) captions", n > 1 ? "\(n) sous-titres" : "\(n) sous-titre")
}

/// A count with its Russian noun form: 1 шот, 2 шота, 5 шотов, 21 шот.
func ruPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let tens = n % 100, ones = n % 10
    return "\(n) " + ((11...14).contains(tens) ? many : ones == 1 ? one : (2...4).contains(ones) ? few : many)
}

// MARK: - Title

/// A title's (or Trustpilot graphic's) own settings: the window a click on it in the timeline opens.
struct TitleSettings: View {
    @ObservedObject var job: Job
    let item: TitleItem

    var body: some View {
        let style = TitleStyle(id: item.style) ?? TitleStyle(number: 1)
        let visible = fullyVisible(style: style.number, duration: item.duration)
        VStack(alignment: .leading, spacing: 12) {
            Heading(kicker: kicker(style.number), title: nil,
                    detail: "\(clock(item.start)) · \(seconds(item.duration)) \(job.t("с", "s"))")
            if style.number == 8 { review } else if style.number == 13 { comments } else if style.number >= 9 { reviewSet(slider: style.number == 10) } else {
                HStack(alignment: .top, spacing: 12) {
                    Field(label: job.t("Текст («|» — вторая строка)", "Text (\"|\" starts line 2)", "Texte (\"|\" commence la ligne 2)")) {
                        CommitField(job: job, value: item.text) { text in job.updateTitle(item.id) { $0.text = text } }
                    }
                    Field(label: job.t("Подпись снизу (необязательно)", "Line underneath (optional)", "Ligne en dessous (facultatif)")) {
                        CommitField(job: job, value: item.kicker ?? "", placeholder: "why women over 40 love it") { text in
                            job.updateTitle(item.id) { $0.kicker = text.isEmpty ? nil : text }
                        }
                    }
                }
            }
            if style.number < 8 { TitleEmoji(job: job, item: item) }
            HStack(alignment: .bottom, spacing: 12) {
                Field(label: job.t("Начало", "Start", "Début")) {
                    TimeField(job: job, value: item.start) { t in job.updateTitle(item.id) { $0.start = t } }
                }
                Field(label: job.t("Длительность, с", "Duration, s", "Durée, s")) {
                    CommitField(job: job, value: seconds(item.duration)) { text in
                        if let d = Double(text.replacingOccurrences(of: ",", with: ".")) { job.updateTitle(item.id) { $0.duration = d } }
                    }
                }
                .frame(width: 130)
                ToggleRow(title: job.t("Размыть фон", "Blur behind", "Flouter l’arrière-plan"), isOn: item.blur) { job.updateTitle(item.id) { $0.blur.toggle() } }
            }
            PillGrid(columns: 4) {
                // the choice under its track: the styles (a review card: the reviews) — the one picked replaces it
                Pill(job.t("Заменить", "Replace", "Remplacer"), icon: "arrow.triangle.2.circlepath", primary: true) {
                    job.titleTools = nil
                    job.openDrawer(item.isGraphic ? .graphics : .titles)
                }
                .help(style.number >= 8 ? job.t("Открыть выбор под дорожкой «Графика»", "Open the choice under the Graphics track", "Ouvrir le choix sous la piste « Graphismes »")
                                        : job.t("Открыть стили под дорожкой «Заголовки»", "Open the styles under the Titles track", "Ouvrir les styles sous la piste « Titres »"))
                Pill(job.t("Дублировать", "Duplicate", "Dupliquer"), icon: "plus.square.on.square") { job.duplicateTitle(item.id) }
                if item.x != nil || item.y != nil {
                    Pill(job.t("На место", "Back in place", "Remettre en place"), icon: "arrow.uturn.backward") { job.setOffset(.title(item.id), nil) }
                        .help(job.t("Вернуть туда, где стиль ставит его сам (его двигали на видео)", "Put it back where its style places it (it was dragged on the picture)", "Le remettre là où son style le place (il a été déplacé sur l’image)"))
                }
                if style.number == 8, job.reviews != nil {
                    Pill(job.t("В библиотеку", "Save to library", "Enregistrer en bibliothèque"), icon: "tray.and.arrow.down") { job.saveReview(from: item) }
                        .help(job.t("Сохранить отзыв в reviews.json — он появится в списке «Графики»", "Save the review to reviews.json, into the Graphics list", "Enregistrer l’avis dans reviews.json, dans la liste « Graphismes »"))
                }
                Pill(style.number >= 8 ? job.t("Удалить графику · ⌫", "Delete graphic · ⌫", "Supprimer le graphisme · ⌫") : job.t("Удалить заголовок · ⌫", "Delete title · ⌫", "Supprimer le titre · ⌫"),
                     icon: "trash", destructive: true) { job.deleteTitle(item.id) }
            }
            Label(visible >= 2
                  ? job.t("Полностью виден \(seconds(visible)) с — правило «не меньше 2 с» выполнено", "Fully visible \(seconds(visible)) s — meets the 2 s rule", "Entièrement visible \(seconds(visible)) s — respecte la règle des 2 s")
                  : job.t("Полностью виден только \(seconds(visible)) с — нужно не меньше 2 с", "Fully visible only \(seconds(visible)) s — needs at least 2 s", "Entièrement visible seulement \(seconds(visible)) s — il faut au moins 2 s"),
                  systemImage: visible >= 2 ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 12.5))
                .foregroundStyle(visible >= 2 ? Color(red: 0.56, green: 0.89, blue: 0.65) : Color(red: 1, green: 0.72, blue: 0.5))
        }
        .padding(16)
        .frame(width: 620, alignment: .leading)
    }

    private func kicker(_ number: Int) -> String {
        switch number {
        case 8: return job.t("ОТЗЫВ TRUSTPILOT", "TRUSTPILOT REVIEW", "AVIS TRUSTPILOT")
        case 9: return job.t("КОЛЛАЖ ОТЗЫВОВ", "REVIEW COLLAGE", "COLLAGE D’AVIS")
        case 10: return job.t("СЛАЙДЕР ОТЗЫВОВ", "REVIEW SLIDER", "CARROUSEL D’AVIS")
        case 13: return job.t("КОММЕНТАРИИ", "COMMENTS", "COMMENTAIRES")
        default: return job.t("ЗАГОЛОВОК", "TITLE", "TITRE")
        }
    }

    /// A comment pile's comments, in the order they drop in: handle, when, text; × takes one off, up to eight.
    @ViewBuilder private var comments: some View {
        let list = item.reviews ?? []
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(job.t("Комментарии по порядку появления (до 8): ник · когда · текст", "Comments in the order they come in (up to 8): handle · when · text", "Commentaires dans l’ordre d’apparition (jusqu’à 8) : pseudo · quand · texte"))
            ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                HStack(spacing: 6) {
                    CommitField(job: job, value: c.name, placeholder: "linda.m58") { v in job.updateTitle(item.id) { $0.reviews?[i].name = v } }
                        .frame(width: 130)
                    CommitField(job: job, value: c.date, placeholder: "2d") { v in job.updateTitle(item.id) { $0.reviews?[i].date = v } }
                        .frame(width: 52)
                    CommitField(job: job, value: c.text, placeholder: job.t("Текст комментария", "Comment text", "Texte du commentaire")) { v in
                        job.updateTitle(item.id) { $0.reviews?[i].text = v }
                    }
                    Button { job.updateTitle(item.id) { $0.reviews?.remove(at: i) } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted).frame(width: 20, height: 25)
                    }
                    .buttonStyle(.plain)
                }
            }
            if list.count < 8 {
                Pill(job.t("+ Комментарий", "+ Comment", "+ Commentaire")) {
                    job.updateTitle(item.id) { $0.reviews = ($0.reviews ?? []) + [Review(name: "user", date: "1d", text: job.t("Текст", "Text", "Texte"))] }
                }.fixedSize()
            }
        }
    }

    /// A collage's or slider's reviews, in order: × takes one off; the list below puts more on.
    @ViewBuilder private func reviewSet(slider: Bool) -> some View {
        if slider {
            Field(label: job.t("Заголовок панели", "Panel heading", "En-tête du panneau")) {
                CommitField(job: job, value: item.text, placeholder: "Reviews shaping this summary") { text in job.updateTitle(item.id) { $0.text = text } }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(slider ? job.t("Отзывы по порядку (листается каждые 0,9 с)", "Reviews in order (slides every 0.9 s)", "Avis dans l’ordre (défile toutes les 0,9 s)")
                              : job.t("Отзывы по порядку (до 4)", "Reviews in order (up to 4)", "Avis dans l’ordre (jusqu’à 4)"))
            WrapStack(spacing: 6) {
                ForEach(Array((item.reviews ?? []).enumerated()), id: \.offset) { i, review in
                    Button { job.updateTitle(item.id) { t in t.reviews?.remove(at: i) } } label: {
                        HStack(spacing: 5) {
                            Text("\(i + 1). \(review.name)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .foregroundStyle(Theme.text)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .overlay(Capsule().stroke(Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(review.text)
                }
            }
            Text(job.t("Нажмите на отзыв во вкладке «Графика» — он добавится сюда или уберётся.", "Click a review in the Graphics tab to add or remove it.", "Cliquez sur un avis dans l’onglet « Graphismes » pour l’ajouter ou le retirer."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    /// A review card's text, reviewer, date and photo.
    @ViewBuilder private var review: some View {
        let who = item.reviewer
        Field(label: job.t("Текст отзыва (на карточке до 5 строк)", "Review (up to 5 lines on the card)", "Avis (jusqu’à 5 lignes sur la carte)")) {
            CommitField(job: job, value: item.text) { text in job.updateTitle(item.id) { $0.text = text } }
        }
        HStack(alignment: .bottom, spacing: 12) {
            Field(label: job.t("Имя", "Name", "Nom")) {
                CommitField(job: job, value: who.name) { name in job.updateTitle(item.id) { $0.kicker = name + "|" + $0.reviewer.date } }
            }
            Field(label: job.t("Дата", "Date")) {
                CommitField(job: job, value: who.date, placeholder: "Oct 6, 2026") { date in job.updateTitle(item.id) { $0.kicker = $0.reviewer.name + "|" + date } }
            }
            .frame(width: 150)
            Field(label: job.t("Фото", "Photo")) { photoMenu }
                .frame(width: 170)
        }
    }

    private var photoMenu: some View {
        Menu {
            Button(job.t("Без фото — инициалы", "No photo — initials", "Sans photo — initiales")) { job.updateTitle(item.id) { $0.image = nil } }
            if let photos = job.reviews?.photos, !photos.isEmpty {
                Divider()
                ForEach(photos) { photo in
                    Button(photo.name) {
                        job.updateTitle(item.id) { t in
                            t.image = photo.url.path
                            if t.reviewer.name.isEmpty || t.reviewer.name == "Name" { t.kicker = photo.name + "|" + t.reviewer.date }
                        }
                    }
                }
            }
            Divider()
            Button(job.t("Выбрать файл…", "Choose a file…", "Choisir un fichier…")) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url { job.updateTitle(item.id) { $0.image = url.path } }
            }
        } label: {
            Text(item.image.map { ReviewLibrary.photoName($0) } ?? job.t("Инициалы", "Initials", "Initiales")).lineLimit(1)
        }
        .menuStyle(.button)
        .frame(height: 34)
    }

    /// How long the headline sits fully drawn and still, per animation.
    private func fullyVisible(style: Int, duration d: Double) -> Double {
        switch style {
        case 1: return (0.78 - 0.20) * d
        case 2: return max(0, d - 0.6 - 0.2 - 1.6)
        case 3: return (0.78 - 0.16) * d
        case 4: return (0.78 - 0.24) * d
        case 6, 7: return max(0, d - 0.36 - 0.3)
        case 8: return max(0, d - 0.53 - 0.3)
        case 9: return max(0, d - (0.08 + 3 * 0.42 + 0.38) - 0.3)       // all four cards in
        case 10: return max(0, d - 0.35 - 0.3)
        case 13: return max(0, d - (0.05 + 7 * 0.2 + 0.32) - 0.3)       // all eight in
        default: return (0.78 - 0.25) * d
        }
    }
}

// MARK: - Motion graphics

/// What opens on a click on a kit scene in the Graphics track (and sits in the Graphics tab while it is selected).
struct OverlayTools: View {
    @ObservedObject var job: Job
    let clip: OverlayClip

    var body: some View {
        let length = MotionLibrary.duration(clip, projectURL: job.projectURL)
        let scene = MotionLibrary.sceneDuration(clip, projectURL: job.projectURL)
        VStack(alignment: .leading, spacing: 12) {
            Heading(kicker: job.t("СЦЕНА ИЗ КИТА", "KIT SCENE", "SCÈNE DU KIT"), title: nil,
                    detail: "\(clock(clip.start)) – \(clock(clip.start + length))")
            Text(motionName(clip.label ?? (clip.src as NSString).lastPathComponent, job)).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            HStack(alignment: .bottom, spacing: 10) {
                Field(label: job.t("Начало", "Start", "Début")) {
                    TimeField(job: job, value: clip.start) { t in job.updateOverlay(clip.id) { $0.start = t } }
                }
                Nudge(job: job, step: 0.5) { delta in job.updateOverlay(clip.id) { $0.start += delta } }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(label: job.t("Длина", "Length", "Durée")) {
                    Text(String(format: job.t("%.1f с", "%.1f s"), length)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(minWidth: 56, alignment: .leading).padding(.bottom, 6)
                }
                Nudge(job: job, step: 0.5) { delta in job.updateOverlay(clip.id) { $0.duration = max(0.3, length + delta) } }
                Text(clip.duration == nil ? job.t("как у сцены", "the scene's own", "celle de la scène")
                     : length > scene ? job.t("дольше сцены: держит кадр, потом уходит", "longer: holds, then fades out", "plus longue : se fige, puis disparaît en fondu")
                     : job.t("короче сцены", "shorter than the scene", "plus courte que la scène"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.bottom, 8)
            }
            PillGrid {
                Pill(job.t("Заменить сцену", "Replace scene", "Remplacer la scène"), icon: "arrow.triangle.2.circlepath", primary: true) {
                    job.overlayTools = nil
                    job.openDrawer(.graphics)
                }
                .help(job.t("Сцены кита под дорожкой «Графика»: выбранная встанет на место этой", "The kit's scenes under the Graphics track: the one picked takes this one's place", "Les scènes du kit sous la piste « Graphismes » : celle choisie prend la place de celle-ci"))
                Pill(job.t("К началу сцены", "Go to its start", "Aller au début"), icon: "backward.end") { job.seek(clip.start) }
                Pill(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder"), icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Project.resolve(clip.src, relativeTo: job.projectURL)])
                }
                if clip.duration != nil {
                    Pill(job.t("Длина сцены", "Scene's own length", "Durée de la scène"), icon: "arrow.left.and.right") { job.updateOverlay(clip.id) { $0.duration = nil } }
                }
                if clip.x != nil || clip.y != nil {
                    Pill(job.t("На место", "Back in place", "Remettre en place"), icon: "arrow.uturn.backward") { job.setOffset(.overlay(clip.id), nil) }
                }
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            PillGrid(columns: 1) {
                Pill(job.t("Удалить сцену · ⌫", "Delete scene · ⌫", "Supprimer la scène · ⌫"), icon: "trash", destructive: true) { job.deleteOverlay(clip.id) }
            }
        }
        .padding(16)
        .frame(minWidth: 360, alignment: .leading)
    }
}

// MARK: - Sound

/// "−6 dB" for a linear gain; silence below −60 dB.
func decibels(_ gain: Double) -> String {
    guard gain > 0.001 else { return "−∞ dB" }
    let db = 20 * log10(gain)
    return (db >= 0.05 ? "+" : db <= -0.05 ? "−" : "") + String(format: "%.1f dB", abs(db))
}

/// What opens on a click on the voice or music track: the clip's volume.
struct AudioTools: View {
    @ObservedObject var job: Job
    let clip: AudioClip
    /// Where the click on the track was: «Разрезать здесь» cuts there (nil = at the playhead).
    var at: Double? = nil
    private static let floor = -45.0, ceiling = 12.0

    var body: some View {
        // the clip as it is now in the project (the popover may hold the one it opened with)
        let clip = job.project?.audio.first { $0.id == self.clip.id } ?? self.clip
        let db = clip.gain > 0.001 ? 20 * log10(clip.gain) : Self.floor
        VStack(alignment: .leading, spacing: 12) {
            Heading(kicker: kicker, title: nil, detail: clip.label ?? (clip.src as NSString).lastPathComponent)
            HStack {
                FieldLabel(job.t("Громкость", "Volume"))
                Spacer()
                Text(clip.gain > 0.001 ? decibels(clip.gain) : job.t("без звука", "muted", "muet"))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Slider(value: Binding(get: { max(Self.floor, min(Self.ceiling, db)) },
                                  set: { v in
                                      // all the way left is silence; near 0 dB it snaps to as recorded
                                      let gain = v <= Self.floor + 0.01 ? 0 : abs(v) < 0.4 ? 1 : pow(10, v / 20)
                                      job.updateAudio(clip.id, undoable: false) { $0.gain = gain }
                                  }),
                   in: Self.floor...Self.ceiling,
                   onEditingChanged: { began in
                       // the player is rebuilt once, when the knob is let go — not at every step of the drag
                       if began { job.pushHistory(); job.sync.holdRebuild = true }
                       else { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                   })
            PillGrid {
                Pill(job.t("Как записано · 0 dB", "As recorded · 0 dB", "Tel qu’enregistré · 0 dB"), icon: "speaker.wave.2") { job.updateAudio(clip.id) { $0.gain = 1 } }
                    .disabled(abs(clip.gain - 1) < 0.001)
                Pill(job.t("Без звука", "Mute", "Couper le son"), icon: "speaker.slash") { job.updateAudio(clip.id) { $0.gain = 0 } }
                    .disabled(clip.gain <= 0.001)
            }
            if clip.role == .voice {
                let replacing = captionsOver(clip)
                PillGrid(columns: 1) {
                    Pill(replacing > 0 ? job.t("Пересоздать субтитры по звуку", "Redo captions from the sound", "Refaire les sous-titres d’après le son")
                                       : job.t("Создать субтитры по звуку", "Make captions from the sound", "Créer les sous-titres d’après le son"),
                         icon: "captions.bubble", primary: true) { job.audioTools = nil; job.captionsFromVoice(clip.id) }
                        .disabled(job.busy)
                }
                Text(replacing > 0
                     ? job.t("Mac прослушает этот кусок и поставит субтитры слово в слово. Заменятся субтитры под ним: \(replacing). ⌘Z вернёт.",
                             "The Mac listens to this piece and captions it word by word. The \(replacing) caption(s) over it are replaced — ⌘Z undoes.", "Le Mac écoute ce segment et le sous-titre mot à mot. Les \(replacing) sous-titre(s) au-dessus sont remplacés — ⌘Z annule.")
                     : job.t("Mac прослушает этот кусок и поставит под ним субтитры слово в слово.",
                             "The Mac listens to this piece and captions it word by word.", "Le Mac écoute ce segment et le sous-titre mot à mot."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if clip.role != .voice { SidechainTools(job: job, clip: clip) } else { VoiceChainTools(job: job) }
            SoundIssues(job: job, clip: clip)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            PillGrid {
                // where the track was clicked (the playhead went there too, for S)
                Pill(job.t("Разрезать здесь · S", "Split here · S", "Couper ici · S"), icon: "scissors") { job.splitAudio(clip.id, at: at ?? job.currentTime); job.audioTools = nil }
                    .disabled(!inside(clip))
                Pill(job.t("Удалить · ⌫", "Delete · ⌫", "Supprimer · ⌫"), icon: "trash", destructive: true) { job.deleteAudio(clip.id) }
                if clip.role == .music {
                    Pill(job.t("Другой трек…", "Another track…", "Autre morceau…"), icon: "music.note.list") { job.openMusic() }
                        .help(job.t("Аудиобиблиотека: заменить трек, громкость останется прежней", "Music library: swap the track, the level stays as it is", "Bibliothèque musicale : changer de morceau, le volume reste le même"))
                }
            }
            Text(job.t("Тяните кусок — сдвинуть, тяните край — подрезать", "Drag a piece to move it, its edge to trim it", "Faites glisser un segment pour le déplacer, son bord pour le raccourcir"))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    /// How many captions are over the clip now: «Создать субтитры по звуку» puts new ones in their place.
    private func captionsOver(_ clip: AudioClip) -> Int {
        let end = clip.start + (clip.duration ?? max(0, (job.project?.duration ?? job.duration) - clip.start))
        return job.cues.filter { Job.over($0, clip.start, end) }.count
    }

    /// The cut point is inside the clip, far enough from its ends for a cut.
    private func inside(_ clip: AudioClip) -> Bool {
        let t = (at ?? job.currentTime) - clip.start
        return t > 0.05 && (clip.duration.map { t < $0 - 0.05 } ?? true)
    }

    private var kicker: String {
        switch clip.role {
        case .voice: return job.t("ГОЛОС", "VOICE", "VOIX")
        case .music: return job.t("МУЗЫКА", "MUSIC", "MUSIQUE")
        case .effect: return job.t("ЗВУК", "SOUND", "SON")
        }
    }
}

/// The sidechain on music: it goes down while anyone speaks and comes back in the pauses. Every piece of the
/// same music (a bed cut in pieces) gets the same settings.
private struct SidechainTools: View {
    @ObservedObject var job: Job
    let clip: AudioClip

    var body: some View {
        let s = clip.sidechain ?? Sidechain()
        let summary = !clip.duck ? job.t("выключен", "off", "désactivé")
            : clip.sidechain == nil ? job.t("старый, мягкий", "old, gentle", "ancien, doux") : String(format: "−%.0f ", s.depth) + job.t("дБ", "dB")
        Fold(job.t("Сайдчейн · под голосом", "Sidechain · under the voice", "Sidechain · sous la voix"), summary: summary, key: "audio.sidechain") {
            HStack {
                Text(job.t("Приглушать, когда звучит голос", "Duck when the voice speaks", "Atténuer quand la voix parle"))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Switch(isOn: clip.duck) {
                    change(undoable: true) { $0.duck.toggle(); if $0.duck, $0.sidechain == nil { $0.sidechain = Sidechain() } }
                }
            }
            if clip.duck {
                knob(job.t("Насколько тише", "How much lower", "Baisser de"), s.depth, 0...30, String(format: "−%.0f ", s.depth) + job.t("дБ", "dB")) {
                    $0.depth = $1.rounded()
                }
                knob(job.t("Уходит вниз за", "Goes down in", "Descend en"), s.attack, 0.02...1, String(format: "%.2f ", s.attack) + job.t("с", "s")) {
                    $0.attack = ($1 * 100).rounded() / 100
                }
                knob(job.t("Возвращается за", "Comes back in", "Remonte en"), s.release, 0.1...3, String(format: "%.1f ", s.release) + job.t("с", "s")) {
                    $0.release = ($1 * 10).rounded() / 10
                }
                Text(clip.sidechain == nil
                     ? job.t("Сейчас стоит старое автоприглушение (мягкое, около −6 дБ). Подвиньте ползунок — включится сайдчейн с этими настройками.",
                             "The old automatic ducking is on (gentle, about −6 dB). Move a slider to switch to the sidechain with these settings.", "L’ancienne atténuation (ducking) automatique est active (douce, environ −6 dB). Déplacez un curseur pour passer au sidechain avec ces réglages.")
                     : job.t("Музыка уходит вниз к началу реплики и возвращается в паузах. Для всех кусков этой музыки.",
                             "The music is down by the time a line starts and comes back in the pauses. For every piece of this music.", "La musique est baissée dès le début d’une réplique et remonte dans les pauses. Pour chaque segment de cette musique."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func knob(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ text: String,
                      _ apply: @escaping (inout Sidechain, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                FieldLabel(label)
                Spacer()
                Text(text).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) },
                                  set: { v in change(undoable: false) { var s = $0.sidechain ?? Sidechain(); apply(&s, v); $0.sidechain = s } }),
                   in: range,
                   onEditingChanged: { began in
                       // the player is rebuilt once, when the knob is let go
                       if began { job.pushHistory(); job.sync.holdRebuild = true }
                       else { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                   })
                .tint(.white).controlSize(.small)
        }
    }

    private func change(undoable: Bool, _ edit: (inout AudioClip) -> Void) {
        guard var p = job.project else { return }
        if undoable { job.pushHistory() }
        for i in p.audio.indices where p.audio[i].role == clip.role && p.audio[i].src == clip.src { edit(&p.audio[i]) }
        job.project = p
    }
}

/// The chain on every voice clip — leveller, compressor and limiter in the manner of FabFilter Pro-C 2 «Pro Voice
/// Over» and Pro-L 2 (SimbiaCore/VoiceChain.swift). One setting for the whole project.
private struct VoiceChainTools: View {
    @ObservedObject var job: Job

    var body: some View {
        let chain = job.project?.master.voice
        let c = chain ?? VoiceChain()
        let on = chain?.on ?? false
        let summary = on ? String(format: "%.0f LUFS · ", c.target) + squeezeName(c.squeeze) : job.t("выключена", "off", "désactivé")
        Fold(job.t("Обработка голоса · все голоса", "Voice processing · every voice", "Traitement de la voix · toutes les voix"), summary: summary, key: "audio.voicechain") {
            HStack {
                Text(job.t("Выровнять, сжать и ограничить", "Level, compress and limit", "Niveler, compresser et limiter"))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Switch(isOn: on) { change(undoable: true) { $0 = $0 ?? VoiceChain(); $0!.on = !on } }
            }
            if on {
                knob(job.t("Громкость голоса", "Voice loudness", "Intensité sonore de la voix"), c.target, -24 ... -10, String(format: "%.0f LUFS", c.target)) { $0.target = $1.rounded() }
                knob(job.t("Сжатие", "Compression"), c.squeeze, 0...1, squeezeName(c.squeeze)) { $0.squeeze = ($1 * 20).rounded() / 20 }
                knob(job.t("Потолок лимитера", "Limiter ceiling", "Plafond du limiteur"), c.ceiling, -6 ... -0.5, String(format: "%.1f dBTP", c.ceiling)) { $0.ceiling = ($1 * 2).rounded() / 2 }
                Text(job.t("Каждая реплика доводится до одной громкости, компрессор сглаживает перепады (как Pro-C 2 «Pro Voice Over»), лимитер не даёт пикам выше потолка (как Pro-L 2). Для всех голосов проекта.",
                           "Every line is brought to one loudness, the compressor evens it out (like Pro-C 2 «Pro Voice Over»), the limiter keeps peaks under the ceiling (like Pro-L 2). For every voice in the project.", "Chaque réplique est ramenée à une même intensité, le compresseur l’égalise (comme Pro-C 2 « Pro Voice Over »), le limiteur garde les crêtes sous le plafond (comme Pro-L 2). Pour toutes les voix du projet."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func squeezeName(_ v: Double) -> String {
        let ratio = 2 + 4 * v
        return (v < 0.34 ? job.t("мягко", "gentle", "doux") : v < 0.67 ? job.t("средне", "medium", "moyen") : job.t("плотно", "firm", "fort")) + String(format: " · %.1f:1", ratio)
    }

    private func knob(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ text: String,
                      _ apply: @escaping (inout VoiceChain, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                FieldLabel(label)
                Spacer()
                Text(text).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) },
                                  set: { v in change(undoable: false) { var c = $0 ?? VoiceChain(); apply(&c, v); $0 = c } }),
                   in: range,
                   onEditingChanged: { began in
                       // the voice is rendered again once, when the knob is let go
                       if began { job.pushHistory(); job.sync.holdRebuild = true }
                       else { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                   })
                .tint(.white).controlSize(.small)
        }
    }

    private func change(undoable: Bool, _ edit: (inout VoiceChain?) -> Void) {
        guard var p = job.project else { return }
        if undoable { job.pushHistory() }
        edit(&p.master.voice)
        job.project = p
    }
}

// MARK: - Shot

/// «Скорость» in the shot window: a knob from ×0.25 to ×4 (twice as fast is as far right of ×1 as half as fast is
/// left of it), the usual speeds and the exact number. The shot keeps its place and length; its own sound goes along.
private struct ShotSpeed: View {
    @ObservedObject var job: Job
    let shot: Shot

    static func name(_ speed: Double) -> String {
        abs(speed - 1) < 0.0005 ? "×1" : "×" + String(format: "%.2f", speed).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    FieldLabel(job.t("Скорость", "Speed", "Vitesse"))
                    Spacer()
                    Text(Self.name(shot.speed)).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(abs(shot.speed - 1) < 0.0005 ? Theme.muted : Theme.text)
                        .onTapGesture(count: 2) { job.setSpeed(shot.id, 1) }
                        .help(job.t("Двойной клик — обычная скорость", "Double-click for normal speed", "Double-clic : vitesse normale"))
                }
                Slider(value: Binding(get: { min(2, max(-2, log2(shot.speed))) },
                                      set: { v in job.setSpeed(shot.id, (pow(2, v) * 100).rounded() / 100, undoable: false) }),
                       in: -2...2,
                       onEditingChanged: { began in
                           // the preview is built again once, when the knob is let go
                           if began { job.pushHistory(); job.sync.holdRebuild = true }
                           else { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                       })
                    .tint(.white).controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(label: job.t("Точно, ×", "Exactly, ×", "Exactement, ×")) {
                    CommitField(job: job, value: String(format: "%.3f", shot.speed)) { text in
                        if let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 { job.setSpeed(shot.id, v) }
                    }
                }
                HStack(spacing: 4) {
                    ForEach([1.0, 1.5, 2, 3], id: \.self) { v in
                        Button { job.setSpeed(shot.id, v) } label: {
                            Text(Self.name(v)).font(.system(size: 12.5, weight: .semibold))
                                .frame(width: 40, height: 32)
                                .foregroundStyle(abs(shot.speed - v) < 0.0005 ? .black : Theme.text)
                                .background(abs(shot.speed - v) < 0.0005 ? Color.white : Color.white.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
            }
            Text(job.t("Шот остаётся на месте и той же длины — берёт больше клипа (быстрее) или меньше (медленнее): \(String(format: "%.2f", shot.footage)) с клипа с \(String(format: "%.2f", shot.inPoint)) с. Его звук идёт с той же скоростью, тон не меняется.",
                       "The shot keeps its place and length and uses more of the clip (faster) or less (slower): \(String(format: "%.2f", shot.footage)) s of the clip from \(String(format: "%.2f", shot.inPoint)) s. Its sound goes at the same speed, pitch kept.", "Le plan garde sa place et sa durée, et utilise plus du clip (plus rapide) ou moins (plus lent) : \(String(format: "%.2f", shot.footage)) s du clip à partir de \(String(format: "%.2f", shot.inPoint)) s. Le son suit la même vitesse, hauteur conservée."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            // past its footage's end the picture is stretched to fit (slower than asked) and the sound stops early
            if let end = job.pictureEnd(shot), shot.inPoint + shot.footage > end + 0.01 {
                Text(job.t("Клипа хватает только на \(Self.name(max(0.01, (end - shot.inPoint) / shot.duration))) — дальше картинка растянется, а звук кончится раньше.",
                           "The clip only has enough for \(Self.name(max(0.01, (end - shot.inPoint) / shot.duration))) — beyond that the picture is stretched and the sound ends early.", "Le clip ne suffit que pour \(Self.name(max(0.01, (end - shot.inPoint) / shot.duration))) — au-delà, l’image est étirée et le son s’arrête plus tôt."))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What opens on a right click on a shot in the timeline: everything about the shot, in sections that fold
/// open and shut (the open ones stay open next time).
struct ShotTools: View {
    @ObservedObject var job: Job
    let shot: Shot
    @ObservedObject private var media = MediaCache.shared

    var body: some View {
        let index = (job.shots.firstIndex { $0.id == shot.id } ?? 0) + 1
        let beats = job.grid.map { Int(((shot.end - shot.start) / $0.beat).rounded()) }
        let g = shot.grade ?? Grade()
        VStack(alignment: .leading, spacing: 6) {
            Heading(kicker: job.isLayer(shot.id) ? job.t("НАЛОЖЕНИЕ", "OVERLAY", "SUPERPOSITION") : job.t("ШОТ \(index) ИЗ \(job.shots.count)", "SHOT \(index) OF \(job.shots.count)", "PLAN \(index) SUR \(job.shots.count)"),
                    title: nil,
                    detail: "\(clock(shot.start)) – \(clock(shot.end))" + (beats.map { " · " + job.t(ruPlural($0, "доля", "доли", "долей"), "\($0) beats", "\($0) temps") } ?? ""))

            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let image = media.thumbnail(shot, projectURL: job.projectURL) {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
                .frame(width: 34, height: 60)
                .scaleEffect(x: shot.flip ? -1 : 1, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(shot.label ?? (shot.src as NSString).lastPathComponent)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text((shot.src as NSString).deletingLastPathComponent)
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.head)
                        .help(shot.src)
                }
            }
            .padding(.bottom, 4)

            Fold(job.t("Клип", "Clip"), summary: job.t("начало ", "starts ", "début ") + String(format: "%.2f", shot.inPoint) + job.t(" с", " s"), key: "shot.clip") {
                HStack(alignment: .bottom, spacing: 10) {
                    Field(label: job.t("Начало в клипе, с", "Starts in clip at, s", "Début dans le clip, s")) {
                        CommitField(job: job, value: String(format: "%.2f", shot.inPoint)) { text in
                            if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { job.updateShot(shot.id) { $0.inPoint = v } }
                        }
                    }
                    Nudge(job: job, step: 0.5) { delta in job.updateShot(shot.id) { $0.inPoint += delta } }
                }
                PillGrid {
                    Pill(job.t("Заменить клип…", "Replace clip…", "Remplacer le clip…"), icon: "arrow.triangle.2.circlepath", primary: true) { replace() }
                        .help(job.t("Поставить на это место другой клип", "Put another clip in its place", "Mettre un autre clip à sa place"))
                    Pill(job.t("Разрезать · S", "Split · S", "Couper · S"), icon: "scissors") { job.splitShotAtPlayhead(shot.id); job.shotTools = nil }
                        .help(job.t("По курсору воспроизведения, а если он на краю шота — посередине", "At the playhead — or in the middle when the playhead is at the shot's edge", "À la tête de lecture — ou au milieu si elle est au bord du plan"))
                    Pill(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder"), icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Project.resolve(shot.src, relativeTo: job.projectURL)])
                    }
                }
            }

            Fold(job.t("Скорость", "Speed", "Vitesse"), summary: ShotSpeed.name(shot.speed), key: "shot.speed") {
                ShotSpeed(job: job, shot: shot)
            }

            Fold(job.t("Камера", "Camera", "Caméra"), summary: zoomName(shot.zoom) + (shot.flip ? job.t(" · отражён", " · mirrored", " · en miroir") : "")
                 + (shot.scale > 1.001 ? " · \(Int((shot.scale * 100).rounded())) %" : "")
                 + (shot.dim ? job.t(" · затемнён", " · darkened", " · assombri") : ""), key: "shot.camera") {
                HStack(spacing: 3) {
                    ForEach([Shot.Zoom.in, .out, .none], id: \.self) { zoom in
                        Button { job.updateShot(shot.id) { $0.zoom = zoom } } label: {
                            Text(zoomName(zoom)).font(.system(size: 12.5, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 32)
                                .foregroundStyle(shot.zoom == zoom ? .black : Theme.text)
                                .background(shot.zoom == zoom ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                ToggleRow(title: job.t("Отразить по горизонтали", "Mirror left to right", "Retourner horizontalement"), isOn: shot.flip) {
                    job.updateShot(shot.id) { $0.flip.toggle() }
                }
                ToggleRow(title: job.t("Затемнить под графику", "Darken under graphics", "Assombrir sous les graphismes"), isOn: shot.dim) {
                    job.updateShot(shot.id) { $0.dim.toggle() }
                }
                // reframing: a box on the picture over the footage's whole frame
                PillGrid {
                    Pill(job.t("Кадрировать…", "Crop…", "Recadrer…"), icon: "crop") { job.beginCrop(shot.id) }
                        .help(job.t("Рамка на картинке: двигать и тянуть за углы — что войдёт в кадр", "A box on the picture: move it and drag its corners to choose what the frame shows", "Un rectangle sur l’image : déplacez-le et tirez ses coins pour choisir ce qui entre dans le cadre"))
                    Pill(job.t("Закрыть текст…", "Cover text…", "Masquer du texte…") + (shot.covers.isEmpty ? "" : " · \(shot.covers.count)"), icon: "eraser") {
                        job.shotTools = nil; job.beginCovers(shot.id)
                    }
                    .help(job.t("Закрасить вшитые субтитры или логотип на этом шоте", "Paint over burned-in captions or a logo on this shot", "Recouvrir des sous-titres incrustés ou un logo sur ce plan"))
                    if shot.scale > 1.001 || shot.panX != 0 || shot.panY != 0 || !shot.keys.isEmpty {
                        Pill(job.t("Без кадрирования", "No crop", "Sans recadrage"), icon: "arrow.up.left.and.arrow.down.right") { job.updateShot(shot.id) { $0.scale = 1; $0.panX = 0; $0.panY = 0; $0.keys = [] } }
                    }
                    if !shot.covers.isEmpty {
                        Pill(job.t("Убрать закраску", "Remove covers", "Retirer les masquages"), icon: "eraser.line.dashed") { job.updateShot(shot.id) { $0.covers = [] } }
                    }
                }
            }

            if job.isLayer(shot.id) {
                Fold(job.t("Вырезать фон · размер", "Key · size", "Incrustation · taille"), summary: LayerCutout.summary(shot, job), key: "layer.cutout") {
                    LayerCutout(job: job, shot: shot)
                }
            }

            Fold(job.t("Цвет", "Colour", "Couleur"), summary: !g.on ? job.t("выключен", "off", "désactivé")
                 : (g.untouched ? (g.hasMatch ? job.t("подогнан к сцене", "matched to its scene", "accordée à la scène") : job.t("как снят", "as filmed", "telle que filmée")) : job.t("свои правки", "adjusted", "ajustée")),
                 key: "shot.colour") {
                ShotColour(job: job, shot: shot)
            }

            Fold(job.t("Что не так — увидит Claude", "What's wrong — Claude will see it", "Ce qui ne va pas — Claude le verra"),
                 summary: shot.flagged ? job.t("отмечено: ", "marked: ", "marqué : ") + "\(shot.issues.count + ((shot.note ?? "").isEmpty ? 0 : 1))" : "",
                 key: "shot.issues") {
                ShotIssues(job: job, shot: shot)
            }

            Fold(job.t("Библиотека", "Library", "Bibliothèque"), key: "shot.library") {
                FootageSuggestions(job: job, shot: shot)
            }

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            PillGrid {
                Pill(job.t("Удалить шот · ⌫", "Delete shot · ⌫", "Supprimer le plan · ⌫"), icon: "trash", destructive: true) { job.deleteShot(shot.id) }
                    .help(job.t("Всё после сдвигается на его место; голос и субтитры этого куска уходят вместе с ним",
                                "Everything after moves up; that stretch of voice and its captions go with it", "Tout ce qui suit remonte ; ce passage de voix et ses sous-titres partent avec lui"))
                Pill(job.t("Удалить картинку", "Delete the picture", "Supprimer l’image"), icon: "video.slash", destructive: true) { job.deleteShot(shot.id, keepSound: true) }
                    .help(job.t("Уходит только картинка: предыдущий шот растягивается на её место, голос и длина ролика те же",
                                "Only the picture goes: the shot before stretches over its place, the voice and the length stay", "Seule l’image part : le plan précédent s’étire à sa place, la voix et la durée restent"))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private func zoomName(_ zoom: Shot.Zoom) -> String {
        switch zoom {
        case .in: return job.t("Наезд", "Push in", "Travelling avant")
        case .out: return job.t("Отъезд", "Pull out", "Travelling arrière")
        case .none: return job.t("Без", "None", "Aucun")
        }
    }

    private func replace() {
        job.shotTools = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.directoryURL = Project.resolve(shot.src, relativeTo: job.projectURL).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        job.replaceClip(shot.id, with: url)
    }
}

/// A video on the overlay track, as Final Cut's Keyer and Transform on a connected clip: its screen cut out and its size
/// and place — it then sits over the picture under it. Everything shows at once, no rebuild; the video itself can be
/// dragged on the picture.
private struct LayerCutout: View {
    @ObservedObject var job: Job
    let shot: Shot
    /// «Показать маску» — in the viewer only, off again when the window closes.
    @State private var matte = false

    static func summary(_ shot: Shot, _ job: Job) -> String {
        var parts: [String] = []
        if shot.chromaKey?.on == true { parts.append(job.t("фон вырезан", "keyed", "incrusté")) }
        if let t = shot.transform, !t.isIdentity {
            parts.append("\(Int((t.scale * 100).rounded())) %")
            if abs(t.rotation) >= 0.05 { parts.append(String(format: "%.0f°", t.rotation)) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let key = shot.chromaKey ?? ChromaKey()
        let on = shot.chromaKey?.on ?? false
        let place = shot.transform ?? LayerTransform()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job.t("Вырезать фон", "Remove the background", "Supprimer l’arrière-plan")).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                Spacer()
                Switch(isOn: on) { job.updateCutout(shot.id) { var k = $0.chromaKey ?? ChromaKey(); k.on = !on; $0.chromaKey = k } }
                    .help(job.t("Зелёный (или синий) фон за человеком становится прозрачным", "The green (or blue) screen behind the person goes transparent", "L’écran vert (ou bleu) derrière la personne devient transparent"))
            }
            if on {
                HStack(spacing: 8) {
                    Circle().fill(key.color?.color ?? Color(red: 0.3, green: 0.68, blue: 0.4)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    Text(key.color ?? job.t("авто · зелёный", "auto · green", "auto · vert"))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    Spacer()
                    Pill(job.t("Пипетка", "Eyedropper", "Pipette"), icon: "eyedropper") { sample() }
                        .help(job.t("Фон снова показывается — нажмите на него в кадре", "The screen shows again — click it on the picture", "L’écran réapparaît — cliquez dessus dans l’image"))
                    if key.color != nil {
                        Pill(job.t("Авто", "Auto"), icon: "wand.and.stars") { change { $0.color = nil } }
                            .help(job.t("Цвет фона находится сам в каждом кадре", "The screen's colour is found in every frame", "La couleur de l’écran est détectée dans chaque image"))
                    }
                }
                Grid(horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ColourSlider(job: job, label: job.t("Сила", "Strength", "Force"), value: key.strength, range: 0...1, neutral: 0.5,
                                     text: percent(key.strength)) { v in change(undoable: false) { $0.strength = v } }
                        ColourSlider(job: job, label: job.t("Зелень на персонаже", "Spill", "Débordement"), value: key.spill, range: 0...1, neutral: 0.9,
                                     text: percent(key.spill)) { v in change(undoable: false) { $0.spill = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Края", "Edges", "Bords"), value: key.shrink, range: -3...3, neutral: 1,
                                     text: pixels(key.shrink, signed: true)) { v in change(undoable: false) { $0.shrink = v.rounded() } }
                        ColourSlider(job: job, label: job.t("Мягкость", "Soften", "Adoucir"), value: key.soften, range: 0...3, neutral: 1,
                                     text: pixels(key.soften, signed: false)) { v in change(undoable: false) { $0.soften = v.rounded() } }
                    }
                }
                HStack {
                    Text(job.t("Показать маску", "Show the matte", "Afficher le cache")).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    Spacer()
                    Switch(isOn: matte) { matte.toggle(); job.showMatte(matte ? shot.id : nil) }
                        .help(job.t("Белое — что остаётся, чёрное — что вырезано; только в окне просмотра, в экспорт не попадает",
                                    "White stays, black is cut out — in the viewer only, never in the export", "Le blanc reste, le noir est découpé — dans le visualiseur uniquement, jamais à l’export"))
                }
                Text(job.t("Сила — сколько фона уходит; Края — поджать (+) или расширить (−) маску; Мягкость — сгладить край; Зелень на персонаже — снять зелёный отсвет с волос и кожи.",
                           "Strength — how much of the screen goes; Edges — shrink (+) or grow (−) the matte; Soften — smooth its edge; Spill — take the green cast off hair and skin.", "Force — quelle part de l’écran disparaît ; Bords — réduire (+) ou agrandir (−) le cache ; Adoucir — lisser son bord ; Débordement — retirer la dominante verte des cheveux et de la peau."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ColourSlider(job: job, label: job.t("Размер", "Size", "Taille"), value: place.scale, range: 0.1...1, neutral: 1,
                         text: "\(Int((place.scale * 100).rounded())) %") { v in
                job.updateCutout(shot.id, undoable: false) { s in
                    var t = s.transform ?? LayerTransform()
                    t.scale = (v * 100).rounded() / 100
                    s.transform = t.isIdentity ? nil : t
                }
            }
            ColourSlider(job: job, label: job.t("Поворот", "Rotation"), value: place.rotation, range: -180...180, neutral: 0,
                         text: String(format: "%.0f°", place.rotation)) { v in
                job.updateCutout(shot.id, undoable: false) { s in
                    var t = s.transform ?? LayerTransform()
                    t.rotation = abs(v) < 2 ? 0 : v.rounded()                  // catches upright
                    s.transform = t.isIdentity ? nil : t
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(label: job.t("Сдвиг X, px", "Move X, px", "Décalage X, px")) {
                    CommitField(job: job, value: String(format: "%.0f", place.x)) { text in
                        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) {
                            job.updateCutout(shot.id) { $0.transform = Job.placed($0.transform, x: v, y: place.y) }
                        }
                    }
                }
                Field(label: job.t("Сдвиг Y, px", "Move Y, px", "Décalage Y, px")) {
                    CommitField(job: job, value: String(format: "%.0f", place.y)) { text in
                        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) {
                            job.updateCutout(shot.id) { $0.transform = Job.placed($0.transform, x: place.x, y: v) }
                        }
                    }
                }
            }
            if shot.transform != nil {
                PillGrid(columns: 1) {
                    Pill(job.t("Во весь кадр", "Full frame", "Plein cadre"), icon: "arrow.up.left.and.arrow.down.right") { job.updateCutout(shot.id) { $0.transform = nil } }
                }
            }
            Text(job.t("На картинке: тяните видео — сдвинуть, ручку в углу рамки — увеличить, уменьшить и повернуть (⌘ — без прилипания к 0° и 90°); двойной клик — обратно в центр.",
                       "On the picture: drag the video to move it, its frame's corner handle to scale and turn it (⌘ — no catch at 0° and 90°); a double click puts it back in the middle.", "Sur l’image : faites glisser la vidéo pour la déplacer, la poignée d’angle de son cadre pour la redimensionner et la tourner (⌘ — sans aimantation à 0° et 90°) ; un double-clic la recentre."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { matte = job.sync.matteLayer == shot.id }
        .onDisappear { if job.sync.matteLayer == shot.id { job.showMatte(nil) } }
        .onChange(of: on) { _, isOn in if !isOn, matte { matte = false; job.showMatte(nil) } }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    private func pixels(_ v: Double, signed: Bool) -> String {
        let n = Int(v.rounded())
        return (signed && n > 0 ? "+" : "") + "\(n) " + job.t("пкс", "px")
    }

    private func change(undoable: Bool = true, _ edit: (inout ChromaKey) -> Void) {
        job.updateCutout(shot.id, undoable: undoable) { s in
            var k = s.chromaKey ?? ChromaKey()
            edit(&k)
            s.chromaKey = k
        }
    }

    /// The system eyedropper: the key goes off for a moment so the screen shows on the picture, the colour clicked is the
    /// screen's (Esc keeps the one there was). One undo step.
    private func sample() {
        let id = shot.id, job = self.job
        job.pushHistory()
        job.updateCutout(id, undoable: false) { $0.chromaKey?.on = false }
        NSColorSampler().show { picked in
            let hex = picked?.usingColorSpace(.sRGB).map {
                String(format: "#%02X%02X%02X", Int(($0.redComponent * 255).rounded()), Int(($0.greenComponent * 255).rounded()),
                       Int(($0.blueComponent * 255).rounded()))
            }
            Task { @MainActor in
                job.updateCutout(id, undoable: false) { s in
                    var k = s.chromaKey ?? ChromaKey()
                    k.on = true
                    if let hex { k.color = hex }
                    s.chromaKey = k
                }
            }
        }
    }
}

/// The editor ticks what is wrong with a shot and adds a note; both go into the .simbia file for Claude.
private struct ShotIssues: View {
    @ObservedObject var job: Job
    let shot: Shot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PillGrid {
                ForEach(Shot.issueKinds, id: \.key) { kind in
                    let on = shot.issues.contains(kind.key)
                    Button {
                        job.updateShot(shot.id) { s in
                            if on { s.issues.removeAll { $0 == kind.key } } else { s.issues.append(kind.key) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 12, weight: .semibold))
                            Text(job.t(kind.ru, kind.en, frenchIssueNames[kind.en])).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: 30)
                        .foregroundStyle(on ? .black : Theme.text)
                        .background(on ? Theme.flag : Theme.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            CommitField(job: job, value: shot.note ?? "", placeholder: job.t("Что именно исправить…", "What exactly to fix…", "Que corriger exactement…")) { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                job.updateShot(shot.id) { $0.note = t.isEmpty ? nil : t }
            }
        }
    }
}

// MARK: - Pieces

private struct Heading: View {
    let kicker: String
    let title: String?
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kicker).font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.muted)
                if let title { Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text) }
            }
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text.opacity(0.75))
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            content
        }
    }
}

/// A text field that edits a copy and writes back on Return or when it loses focus — one undo
/// step per edit, and a value changed elsewhere meanwhile is not overwritten.
struct CommitField: View {
    @ObservedObject var job: Job
    let value: String
    var placeholder = ""
    /// Takes the keyboard as soon as it appears (the word window: a click on a word is there to edit it).
    var autofocus = false
    let commit: (String) -> Void
    /// After Return has committed the text.
    var submitted: (() -> Void)? = nil

    @State private var draft = ""
    @State private var baseline = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.fieldText)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($focused)
            // Return commits and leaves the field, so Space, S and M work again straight away
            .onSubmit { save(); focused = false; submitted?() }
            .onChange(of: focused) { _, isFocused in
                job.textEditing = isFocused
                if isFocused { baseline = value } else { save() }
            }
            .onAppear {
                draft = value; baseline = value
                if autofocus { DispatchQueue.main.async { focused = true } }
            }
            .onChange(of: value) { _, new in if !focused { draft = new; baseline = new } }
            .onDisappear {
                // another item was picked while typing: what was typed belongs to this one
                if draft != baseline, value == baseline { commit(draft) }
                if focused { job.textEditing = false }
            }
    }

    private func save() {
        guard value == baseline else { draft = value; baseline = value; return }
        guard draft != value else { return }
        commit(draft)
        baseline = draft
    }
}

/// Seconds as m:ss.hh; accepts "1:02.5", "62.5" or "62,5".
struct TimeField: View {
    @ObservedObject var job: Job
    let value: Double
    let commit: (Double) -> Void

    var body: some View {
        CommitField(job: job, value: clock(value)) { text in
            if let seconds = parseClock(text) { commit(seconds) }
        }
        .frame(minWidth: 96)
    }
}

/// A time with one-frame steps either side.
private struct FrameNudge: View {
    let time: Double
    let step: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("chevron.left", -1)
            Text(clock(time)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.text).frame(minWidth: 62)
            button("chevron.right", 1)
        }
    }

    private func button(_ symbol: String, _ frames: Double) -> some View {
        Button { step(frames) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 28)
                .foregroundStyle(Theme.text)
                .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct Nudge: View {
    @ObservedObject var job: Job
    var step = 0.1
    let action: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            button("−" + seconds(step), -step)
            button("+" + seconds(step), step)
        }
    }

    private func button(_ label: String, _ delta: Double) -> some View {
        Button { action(delta) } label: {
            Text(label).font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .frame(width: 46, height: 32)
                .foregroundStyle(Theme.text)
                .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct Pill: View {
    let title: String
    var icon: String?
    var primary = false
    var destructive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    /// In a `PillGrid`: as wide as its column.
    @Environment(\.pillFill) private var fill

    init(_ title: String, icon: String? = nil, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.primary = primary; self.destructive = destructive; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 12.5, weight: primary ? .bold : .semibold))
                .padding(.horizontal, fill ? 10 : 13).frame(maxWidth: fill ? .infinity : nil).frame(height: 36)
                .foregroundStyle(primary ? .black : destructive ? Color(red: 1, green: 0.7, blue: 0.7) : Theme.text)
                .background(primary ? Color.white : destructive ? Color.red.opacity(0.14) : Theme.rowFill,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(primary ? .clear : destructive ? Color.red.opacity(0.45) : Theme.rowStroke, lineWidth: 1))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

private struct ToggleRow: View {
    let title: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                Capsule().fill(isOn ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 36, height: 20)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(isOn ? Color.black : Color.white).frame(width: 16, height: 16).padding(2)
                    }
                    .animation(Theme.bounce, value: isOn)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension EnvironmentValues {
    @Entry var pillFill = false
}

/// A window's buttons in rows of `columns`, the buttons of a row sharing its width evenly (a shorter last row
/// too), so they line up in clean columns from edge to edge.
struct PillGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder let content: Content

    var body: some View {
        EvenRows(columns: columns) { content }.environment(\.pillFill, true)
    }
}

private struct EvenRows: Layout {
    let columns: Int
    var spacing: CGFloat = 8

    private func rows(_ n: Int) -> [Range<Int>] {
        stride(from: 0, to: n, by: max(1, columns)).map { $0..<min(n, $0 + max(1, columns)) }
    }

    private func height(_ row: Range<Int>, _ subviews: Subviews) -> CGFloat {
        row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews.count)
        let natural = rows.map { r in r.reduce(0) { $0 + subviews[$1].sizeThatFits(.unspecified).width } + spacing * CGFloat(r.count - 1) }
        return CGSize(width: proposal.width ?? natural.max() ?? 0,
                      height: rows.reduce(0) { $0 + height($1, subviews) } + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(subviews.count) {
            let w = (bounds.width - spacing * CGFloat(r.count - 1)) / CGFloat(r.count), h = height(r, subviews)
            for (k, i) in r.enumerated() {
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(k) * (w + spacing), y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: h))
            }
            y += h + spacing
        }
    }
}

/// Lays children out left to right and wraps to the next line when the row is full.
struct WrapStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            // offered the row's width, so text longer than a row wraps instead of running past the edge
            let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

func selectableFill(_ selected: Bool) -> LinearGradient {
    LinearGradient(colors: selected ? [Theme.rowActiveTop, Theme.rowActiveBottom] : [Theme.rowFill, Theme.rowFill],
                   startPoint: .top, endPoint: .bottom)
}

func clock(_ t: Double) -> String {
    let c = Int((max(0, t) * 100).rounded())
    return String(format: "%d:%02d.%02d", c / 6000, (c / 100) % 60, c % 100)
}

func seconds(_ t: Double) -> String {
    String(format: t == t.rounded() ? "%.0f" : (abs(t * 10 - (t * 10).rounded()) < 0.001 ? "%.1f" : "%.2f"), t)
}

func parseClock(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
    switch parts.count {
    case 1: return Double(parts[0])
    case 2: guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }; return m * 60 + s
    case 3: guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }; return h * 3600 + m * 60 + s
    default: return nil
    }
}


/// A section of a window that folds open and shut with a click on its title; whether it is open is remembered.
struct Fold<Content: View>: View {
    let title: String
    var summary = ""
    let content: Content
    @AppStorage private var open: Bool

    init(_ title: String, summary: String = "", key: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.summary = summary; self.content = content()
        _open = AppStorage(wrappedValue: false, "fold." + key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            Button { withAnimation(Theme.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Theme.muted)
                        .frame(width: 12)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }
}


/// The editor ticks what is wrong with a piece of sound and adds a note; both go into the .simbia file for Claude.
private struct SoundIssues: View {
    @ObservedObject var job: Job
    let clip: AudioClip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            FieldLabel(job.t("Что не так — увидит Claude", "What's wrong — Claude will see it", "Ce qui ne va pas — Claude le verra"))
            PillGrid {
                ForEach(AudioClip.issueKinds, id: \.key) { kind in
                    let on = clip.issues.contains(kind.key)
                    Button {
                        job.updateAudio(clip.id) { a in
                            if on { a.issues.removeAll { $0 == kind.key } } else { a.issues.append(kind.key) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 12, weight: .semibold))
                            Text(job.t(kind.ru, kind.en, frenchIssueNames[kind.en])).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).frame(height: 30)
                        .foregroundStyle(on ? .black : Theme.text)
                        .background(on ? Theme.flag : Theme.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            CommitField(job: job, value: clip.note ?? "", placeholder: job.t("Что именно исправить…", "What exactly to fix…", "Que corriger exactement…")) { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                job.updateAudio(clip.id) { $0.note = t.isEmpty ? nil : t }
            }
        }
    }
}
