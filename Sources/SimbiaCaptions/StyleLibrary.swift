import SimbiaCore
import SwiftUI

enum LibraryTab: String, CaseIterable { case paragraph, text, captions, titles, graphics, filters, transitions, classic }

/// The settings of one timeline track, in the drawer under it: the text by paragraphs, the caption styles and the
/// classic presets under the captions; the title styles; the graphics (Trustpilot reviews); the filters; the transitions.
struct StyleLibrary: View {
    @ObservedObject var job: Job
    /// The tabs of this track's drawer.
    var tabs: [LibraryTab] = LibraryTab.allCases
    /// The app's earlier caption styles, folded at the bottom of «Стили».
    @State private var classicOpen = false

    /// The tab asked for, else the one the picked thing has its settings in — among this drawer's tabs.
    private var current: LibraryTab {
        let wanted: LibraryTab = {
            if let tab = job.libraryTab { return tab }
            if case .title(let id) = job.focus { return job.title(id)?.isGraphic == true ? .graphics : .titles }
            if case .overlay = job.focus { return .graphics }
            if case .filter = job.focus { return .filters }
            if job.focus == .look { return .filters }
            if case .transition = job.focus { return .transitions }
            return .text
        }()
        return tabs.contains(wanted) ? wanted : tabs[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if tabs.count > 1 {
                    // the tabs as one segmented bar: every tab the same width, its symbol and name
                    HStack(spacing: 3) {
                        ForEach(tabs, id: \.self) { option in
                            let on = current == option
                            Button { withAnimation(Theme.bounce) { job.libraryTab = option } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: symbol(option)).font(.system(size: 12, weight: .semibold))
                                    Text(title(option)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity).frame(height: 26)
                                .foregroundStyle(on ? .black : Theme.text.opacity(0.75))
                                .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(BouncyButtonStyle())
                        }
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 420)
                } else {
                    Label(title(current), systemImage: symbol(current)).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                }
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if current == .graphics { GraphicsMakers(job: job) }
                Button { job.openDrawer(nil) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.1), in: Circle())
                        .overlay(Circle().stroke(Theme.rowStroke, lineWidth: 1))
                }
                .buttonStyle(BouncyButtonStyle())
                .help(job.t("Свернуть — дорожки займут место · Esc", "Fold away — the tracks take the room · Esc", "Replier — les pistes prennent la place · Esc"))
            }

            Group {
                switch current {
                // «Абзац»: the captions picked on the timeline, to edit; «Весь текст»: all of it
                case .paragraph:
                    if job.selected != nil || !job.selection.isEmpty { CaptionEditor(job: job) } else {
                        Text(job.t("Нажмите на субтитр на дорожке — он откроется здесь", "Click a caption on the track to open it here", "Cliquez sur un sous-titre de la piste pour l’ouvrir ici"))
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                case .text: TranscriptPanel(job: job)
                // «Стили»: the styles, and the earlier ones of the app folded under them
                case .captions:
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            captionOptions
                            captionGrid
                            Button { withAnimation(Theme.snappy) { classicOpen.toggle() } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                        .rotationEffect(.degrees(classicOpen ? 90 : 0)).foregroundStyle(Theme.muted)
                                    Label(job.t("Классика — прежние стили программы", "Classic — the app's earlier styles", "Classique — les anciens styles de l’app"), systemImage: "clock.arrow.circlepath")
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if classicOpen { classic }
                        }
                        .padding(.bottom, 24)
                    }
                case .titles: titleGrid
                case .graphics: GraphicsPanel(job: job)
                // taller than their drawer on a small window: they scroll inside it
                case .filters: ScrollView(showsIndicators: false) { FiltersPanel(job: job).padding(.bottom, 24) }
                case .transitions: ScrollView(showsIndicators: false) { TransitionsPanel(job: job).padding(.bottom, 24) }
                case .classic: classic
                }
            }
            // what runs past the bottom of the drawer fades out instead of being cut
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 36)
            })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: job.focus) { old, new in
            // a title shows the title styles; leaving it shows the text again
            if case .title = new { job.libraryTab = nil } else if case .title = old, job.libraryTab == .titles { job.libraryTab = nil }
        }
    }

    private func symbol(_ tab: LibraryTab) -> String {
        switch tab {
        case .paragraph: return "paragraphsign"
        case .text: return "text.alignleft"
        case .captions: return "captions.bubble"
        case .titles: return "textformat"
        case .graphics: return "sparkles"
        case .filters: return "camera.filters"
        case .transitions: return "rectangle.2.swap"
        case .classic: return "clock.arrow.circlepath"
        }
    }

    private func title(_ tab: LibraryTab) -> String {
        switch tab {
        case .paragraph: return job.t("Абзац", "Paragraph", "Paragraphe")
        case .text: return job.t("Весь текст", "Whole text", "Tout le texte")
        case .captions: return job.t("Стили", "Styles")
        case .titles: return job.t("Заголовки", "Titles", "Titres")
        case .graphics: return job.t("Графика", "Graphics", "Graphismes")
        case .filters: return job.t("Фильтры", "Filters", "Filtres")
        case .transitions: return job.t("Переходы", "Transitions")
        case .classic: return job.t("Классика", "Classic", "Classique")
        }
    }

    private var hint: String {
        switch current {
        case .paragraph: return job.t("клик по слову — его инструменты; тяните слово или всю ячейку", "click a word for its tools; drag a word or the whole cell", "cliquez sur un mot pour ses outils ; faites glisser un mot ou toute la cellule")
        case .text: return job.t("нажмите на слово — откроются его инструменты; ⇧ или ⌘ с кликом — выделить несколько субтитров",
                                 "click a word for its tools; ⇧ or ⌘ with a click selects several captions", "cliquez sur un mot pour ses outils ; ⇧ ou ⌘ + clic sélectionne plusieurs sous-titres")
        case .captions: return job.t("для всего ролика", "for the whole video", "pour toute la vidéo")
        case .titles:
            if case .title = job.focus { return job.t("нажмите на стиль — он сменится у выбранного заголовка", "click a style to give it to the selected title", "cliquez sur un style pour l’appliquer au titre sélectionné") }
            return job.t("нажмите на стиль — добавится заголовок", "click a style to add a title", "cliquez sur un style pour ajouter un titre")
        case .graphics:
            if case .overlay = job.focus { return job.t("нажмите на сцену — она встанет вместо выбранной", "click a scene to put it in place of the selected one", "cliquez sur une scène pour remplacer la scène sélectionnée") }
            if case .title(let id) = job.focus, let item = job.title(id) {
                return item.style == "T8" ? job.t("нажмите на отзыв — он заменит этот", "click a review to put it on this card", "cliquez sur un avis pour le mettre sur cette carte")
                                          : job.t("нажмите на отзыв — добавить или убрать", "click a review to add or remove it", "cliquez sur un avis pour l’ajouter ou le retirer")
            }
            return job.t("нажмите на отзыв — добавится карточка", "click a review to add its card", "cliquez sur un avis pour ajouter sa carte")
        case .filters:
            if case .filter = job.focus { return job.t("фильтр на отрезок — тяните его на дорожке «Фильтры»", "a filter over a stretch — drag it on the Filters track", "un filtre sur un passage — faites-le glisser sur la piste Filtres") }
            return job.t("цвет всех кадров; у каждого шота свой цвет — в его окне", "colour of every frame; each shot has its own in its window", "couleur de toutes les images ; chaque plan a la sienne dans sa fenêtre")
        case .transitions:
            if case .transition = job.focus { return job.t("переход на склейке — выберите вид", "the transition on a cut — pick its kind", "la transition sur une coupe — choisissez son type") }
            return job.t("выберите шот и нажмите + на его склейке", "pick a shot and press + on its cut", "sélectionnez un plan et appuyez sur le + de sa coupe")
        case .classic: return job.t("прежние стили программы", "the app's earlier styles", "les anciens styles de l’app")
        }
    }

    // MARK: Captions

    /// For the whole video, whatever the style: all capitals, italic, the accent words — and how the plain captions come in.
    private var captionOptions: some View {
        let track = job.project?.captions ?? CaptionTrack()
        // the classic presets keep these in their own look
        let classic = job.captionStyle == "legacy"
        return HStack(spacing: 7) {
            option(job.t("ВСЕ ЗАГЛАВНЫЕ", "ALL CAPS", "MAJUSCULES"), on: classic ? job.look.uppercase : track.uppercase) {
                if classic { job.edit { $0.look.uppercase.toggle() } } else { job.setCaptions { $0.uppercase.toggle() } }
            }
            option(job.t("Курсив", "Italic", "Italique"), on: classic ? job.look.italic : track.italic, italic: true) {
                if classic { job.edit { $0.look.italic.toggle() } } else { job.setCaptions { $0.italic.toggle() } }
            }
            if !classic {
                option(job.t("Акцентные слова", "Accent words", "Mots en accent"), on: track.accents) { job.setCaptions { $0.accents.toggle() } }
                    .help(job.t("Выключено — все слова одинаковые, без выделения", "Off: every word looks the same, nothing stands out", "Désactivé : tous les mots se ressemblent, rien ne ressort"))
                if CaptionStyle(id: job.captionStyle)?.twoLine == true || CaptionStyle(id: job.captionStyle)?.look.isFilm == true {
                    Rectangle().fill(Theme.rowStroke).frame(width: 1, height: 18).padding(.horizontal, 4)
                    Text(job.t("Между строк", "Line spacing", "Interligne")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    option("−", on: false) { job.setCaptions { $0.lineSpacing = max(0.6, (($0.lineSpacing - 0.05) * 100).rounded() / 100) } }
                    Text("\(Int((track.lineSpacing * 100).rounded())) %").font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(abs(track.lineSpacing - 1) < 0.001 ? Theme.muted : Theme.text)
                        .onTapGesture(count: 2) { job.setCaptions { $0.lineSpacing = 1 } }
                        .help(job.t("Шаг между строками субтитра. Двойной клик — как в стиле", "The step between a caption's lines. Double-click: as the style has it", "L’écart entre les lignes d’un sous-titre. Double-clic : valeur du style"))
                    option("+", on: false) { job.setCaptions { $0.lineSpacing = min(1.4, (($0.lineSpacing + 0.05) * 100).rounded() / 100) } }
                }
            }
            if CaptionStyle(id: job.captionStyle)?.look == .plain {
                Rectangle().fill(Theme.rowStroke).frame(width: 1, height: 18).padding(.horizontal, 4)
                Text(job.t("Появление", "Comes in", "Apparition")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(CaptionEntrance.allCases, id: \.self) { entrance in
                    option(entranceName(entrance), on: (track.entrance ?? .pop) == entrance) {
                        job.setCaptions { $0.entrance = entrance == .pop ? nil : entrance }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(job.project == nil && job.video == nil)
    }

    private func entranceName(_ entrance: CaptionEntrance) -> String {
        switch entrance {
        case .pop: return "Pop"
        case .words: return job.t("По словам", "Word by word", "Mot par mot")
        case .rise: return job.t("Снизу", "Rise", "Montée")
        case .fade: return job.t("Плавно", "Fade", "Fondu")
        case .karaoke: return job.t("Караоке", "Karaoke", "Karaoké")
        }
    }

    private func option(_ title: String, on: Bool, italic: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).italic(italic).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(on ? Color.black : Theme.text)
                .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
        }
        .buttonStyle(BouncyButtonStyle())
    }

    private var captionGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(CaptionStyle.all) { style in
                    let selected = job.captionStyle == style.id
                    Button { job.applyCaptionStyle(style.id) } label: {
                        tile(selected) {
                            CaptionSwatch(style: style, sample: sample, options: job.project?.captions.options ?? CaptionOptions())
                        } name: { "\(style.number) · \(styleName(style))" }
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(style.twoLine ? job.t("2 строки · ", "2 lines · ", "2 lignes · ") + style.fonts : style.fonts)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// One style in a drawer's strip: what it looks like over a frame, its number and name under it.
    private func tile<Swatch: View>(_ selected: Bool, @ViewBuilder _ swatch: () -> Swatch, name: () -> String) -> some View {
        VStack(spacing: 0) {
            swatch().frame(width: 148, height: 70).background(swatchGround).clipped()
            Text(name()).font(.system(size: 11.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 8).frame(width: 148, height: 26)
        }
        .foregroundStyle(selected ? .black.opacity(0.88) : Theme.text)
        .background(selectableFill(selected), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.9) : Theme.rowStroke, lineWidth: selected ? 1.5 : 1))
    }

    /// Plain captions are named in the app's language; the five web looks keep their names.
    private func styleName(_ style: CaptionStyle) -> String {
        if style.look.isFilm { return style.look == .filmBold ? job.t("Фильм жирный", "Film Bold", "Film gras") : job.t("Фильм", "Film") }
        guard style.look == .plain else { return style.name }
        return job.t("Обычные", "Plain", "Simple") + (style.twoLine ? " · 2" : "")
    }

    /// The selected caption's words: an ordinary one and the accent (or a stand-in pair).
    private var sample: (String, String) {
        let words = job.selectedCue.map { job.timedWords(of: $0) } ?? []
        let accent = words.first(where: \.accent)?.text ?? words.max(by: { $0.text.count < $1.text.count })?.text ?? "shade"
        let plain = words.first { !$0.accent && $0.text != accent }?.text ?? "your"
        return (String(plain.prefix(9)), String(accent.prefix(10)))
    }

    private var swatchGround: some View {
        RadialGradient(colors: [Color(red: 0.56, green: 0.35, blue: 0.30), Color(red: 0.16, green: 0.11, blue: 0.09)],
                       center: .init(x: 0.5, y: 0.4), startRadius: 4, endRadius: 90)
    }

    // MARK: Titles

    private var titleGrid: some View {
        let target: TitleItem? = { if case .title(let id) = job.focus, let item = job.title(id), !item.isGraphic { return item }; return nil }()
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(TitleStyle.all.filter { $0.number < 8 || ($0.number > 10 && $0.number < 13) }) { style in       // T8–T10 and T13 are in Graphics
                    let selected = target?.style == style.id
                    Button {
                        // the choice made: the drawer closes and the title's settings open
                        if let target {
                            job.updateTitle(target.id) { $0.style = style.id }
                            job.openDrawer(nil); job.titleTools = target.id
                        } else {
                            job.ensureProject()
                            job.addTitle(at: job.addAt ?? job.currentTime, style: style.id)
                            job.openDrawer(nil)
                        }
                    } label: {
                        tile(selected) { TitleSwatch(style: style, text: target?.text ?? "7 Reasons") } name: { "\(style.id) · \(titleName(style))" }
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(titleHint(style))
                    .disabled(job.project == nil && job.video == nil)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func titleName(_ style: TitleStyle) -> String {
        [job.t("Мазок и размытие", "Swipe & blur", "Balayage et flou"), job.t("Помада пишет", "Lipstick writes", "Le rouge écrit"),
         job.t("Жирный мазок", "Smear band", "Bande étalée"), job.t("Отпечаток поцелуя", "Kiss stamp", "Empreinte de baiser"),
         job.t("Свотчи оттенков", "Swatch stack", "Pile de nuances"), job.t("Текст", "Plain text", "Texte simple"), job.t("Плашка", "Pill", "Pastille"),
         job.t("Отзыв Trustpilot", "Trustpilot review", "Avis Trustpilot"), job.t("Коллаж отзывов", "Review collage", "Collage d’avis"),
         job.t("Слайдер отзывов", "Review slider", "Carrousel d’avis"), job.t("Текст TikTok", "TikTok text", "Texte TikTok"),
         job.t("Ответ на комментарий", "Comment reply", "Réponse à un commentaire"), job.t("Комментарии", "Comments", "Commentaires")][style.number - 1]
    }

    private func titleHint(_ style: TitleStyle) -> String {
        [job.t("восковой мазок, фон размыт", "waxy stroke, blurred background", "trait cireux, fond flou"),
         job.t("настоящий тюбик пишет текст", "the real tube writes the text", "le vrai tube écrit le texte"),
         job.t("широкий мазок, текст внутри", "wide smear with the text inside", "large trait étalé, texte à l’intérieur"),
         job.t("губы шлёпаются с отскоком", "lips stamp on with a bounce", "des lèvres s’impriment avec un rebond"),
         job.t("нюд, роза, ягода", "nude, rose, berry", "nude, rose, baie"),
         job.t("белые заглавные, как в прежних роликах", "white capitals, as in the earlier ads", "capitales blanches, comme dans les anciennes pubs"),
         job.t("чёрный текст на белой плашке", "black text on a white pill", "texte noir sur pastille blanche"),
         job.t("карточка отзыва", "a review card", "une carte d’avis"), job.t("4 карточки веером", "four cards, fanned", "quatre cartes en éventail"),
         job.t("панель с листанием", "a panel that slides", "un panneau qui défile"),
         job.t("текст TikTok на белых плашках", "TikTok's own text on white plates", "le texte TikTok natif sur fonds blancs"),
         job.t("пузырь «ответ на комментарий»", "the reply-to-comment bubble", "la bulle de réponse à un commentaire"), job.t("до 8 комментариев TikTok", "up to 8 TikTok comments", "jusqu’à 8 commentaires TikTok")][style.number - 1]
    }

    // MARK: Classic

    private var classic: some View { ClassicPanel(job: job) }
}

// MARK: - Swatches

/// A two-word sample in a caption style, drawn with the style's own fonts and the track's settings.
private struct CaptionSwatch: View {
    let style: CaptionStyle
    let sample: (String, String)
    let options: CaptionOptions

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                plain(cased(sample.0))
                if options.accents { accent(cased(sample.1)) } else { plain(cased(sample.1)) }
            }
            if style.twoLine { plain(cased("for you.")) }
        }
        .lineLimit(1)
        // italic as the renderer sets it: upright faces slanted 12°
        .transformEffect(options.italic ? CGAffineTransform(a: 1, b: 0, c: -tan(12 * .pi / 180), d: 1, tx: 0, ty: 0) : .identity)
        .padding(.horizontal, 6)
    }

    private func cased(_ text: String) -> String { options.uppercase ? text.uppercased() : text }

    private func font(_ face: FontLibrary.Face, _ size: Double) -> Font { Font(FontLibrary.font(face, size: size)) }

    @ViewBuilder private func plain(_ text: String) -> some View {
        switch style.look {
        case .goldScript: Text(text).font(font(.montserrat800, 12)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        case .highlighter: Text(text.uppercased()).font(font(.archivoBlack, 11.5)).foregroundStyle(.white).shadow(color: .black, radius: 0.6)
        case .editorial: Text(text).font(font(.dmSans700, 12.5)).foregroundStyle(Color(red: 1, green: 0.98, blue: 0.96)).shadow(color: .black.opacity(0.6), radius: 2)
        case .handwritten: Text(text).font(font(.poppins700, 11.5)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        case .cleanBox: Text(text).font(font(.interTight800, 11.5)).foregroundStyle(Color(red: 0.08, green: 0.07, blue: 0.06))
            .padding(.horizontal, 4).padding(.vertical, 2).background(.white, in: RoundedRectangle(cornerRadius: 3.5))
        case .plain: Text(text).font(font(.montserrat800, 12)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 0.7).shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        case .film: Text(text).font(font(.inter600, 9)).foregroundStyle(.white).shadow(color: .black.opacity(0.75), radius: 1.2, y: 0.5)
        case .filmBold: Text(text).font(font(.inter700, 9)).foregroundStyle(.white).shadow(color: .black.opacity(0.75), radius: 1.2, y: 0.5)
        }
    }

    @ViewBuilder private func accent(_ text: String) -> some View {
        switch style.look {
        case .goldScript:
            Text(text).font(font(.playfairItalic800, 17))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.72, green: 0.54, blue: 0.23), Color(red: 0.96, green: 0.86, blue: 0.61),
                                                         Color(red: 1, green: 0.95, blue: 0.82), Color(red: 0.85, green: 0.70, blue: 0.42),
                                                         Color(red: 0.66, green: 0.48, blue: 0.18)], startPoint: .leading, endPoint: .trailing))
        case .highlighter:
            Text(text.uppercased()).font(font(.archivoBlack, 13)).foregroundStyle(.white).shadow(color: .black, radius: 0.6)
                .padding(.horizontal, 3)
                .background(Color(red: 0.91, green: 0.64, blue: 0.66).cornerRadius(2).transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.105, d: 1, tx: 1, ty: 0)))
        case .editorial:
            Text(text).font(font(.dmSerifItalic, 18)).foregroundStyle(Color(red: 0.91, green: 0.64, blue: 0.66))
        case .handwritten:
            Text(text).font(font(.caveat700, 20)).foregroundStyle(Color(red: 0.91, green: 0.09, blue: 0.25))
                .shadow(color: .white, radius: 0.8).shadow(color: .white, radius: 0.8)
                .overlay(alignment: .bottom) { Capsule().fill(Color(red: 0.91, green: 0.09, blue: 0.25)).frame(height: 2).offset(y: 2) }
                .rotationEffect(.degrees(-3))
        case .cleanBox:
            Text(text).font(font(.playfairItalic800, 13)).foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.42))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color(red: 0.1, green: 0.08, blue: 0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 1.2))
        case .plain:
            Text(text).font(font(.montserrat800, 14.6)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 0.7).shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        case .film, .filmBold:
            plain(text)
        }
    }
}

private struct TitleSwatch: View {
    let style: TitleStyle
    let text: String
    private let red = LinearGradient(colors: [Color(red: 0.89, green: 0.42, blue: 0.47), Color(red: 0.56, green: 0.11, blue: 0.17)], startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack {
            switch style.number {
            case 1:
                Capsule().fill(red).frame(height: 20).rotationEffect(.degrees(-4)).padding(.horizontal, -6).offset(y: 6)
                Text(text).font(Font(FontLibrary.font(.playfairItalic800, size: 22))).foregroundStyle(Color(red: 1, green: 0.96, blue: 0.92))
            case 2:
                Text(text).font(Font(FontLibrary.font(.caveat700, size: 28))).foregroundStyle(Color(red: 0.76, green: 0.16, blue: 0.27))
            case 3:
                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(red: 0.62, green: 0.13, blue: 0.21), Color(red: 0.82, green: 0.30, blue: 0.37), Color(red: 0.91, green: 0.54, blue: 0.58), Color(red: 0.69, green: 0.17, blue: 0.25)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 36).rotationEffect(.degrees(-4)).padding(.horizontal, 8)
                Text(text.uppercased()).font(Font(FontLibrary.font(.archivoBlack, size: 15))).foregroundStyle(.white)
            case 4:
                Ellipse().fill(red).frame(width: 52, height: 26).rotationEffect(.degrees(-9)).offset(y: -18)
                Text(text).font(Font(FontLibrary.font(.frauncesItalic700, size: 20))).foregroundStyle(Color(red: 1, green: 0.96, blue: 0.92)).offset(y: 14)
            case 6:
                Text(text.uppercased()).font(Font(FontLibrary.font(.montserrat800, size: 17))).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            case 7:
                Text(text.uppercased()).font(Font(FontLibrary.font(.montserrat800, size: 12))).foregroundStyle(Color(white: 0.07))
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            default:
                VStack(spacing: 0) {
                    Color(red: 0.79, green: 0.60, blue: 0.48); Color(red: 0.84, green: 0.42, blue: 0.47); Color(red: 0.56, green: 0.16, blue: 0.27)
                }
                .frame(height: 42).clipShape(Capsule()).rotationEffect(.degrees(-3)).padding(.horizontal, 10)
                Text(text).font(Font(FontLibrary.font(.dmSerifItalic, size: 22))).foregroundStyle(Color(red: 1, green: 0.97, blue: 0.94))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.5)
        .padding(.horizontal, 6)
        .clipped()
    }
}

// MARK: - Applying a caption style

extension Job {
    /// Picks a caption style for the whole video. Moving between the one-line and two-line families
    /// regroups the words paragraph by paragraph — accents and timings stay with each word.
    func applyCaptionStyle(_ id: String) {
        guard id != captionStyle else { return }
        pushHistory()
        let before = CaptionStyle(id: captionStyle)
        let after = CaptionStyle(id: id)
        captionStyle = id
        guard let after, before?.twoLine != after.twoLine || before == nil else { return }
        let words = paragraphs.map { paragraph in
            paragraph.flatMap { cue in
                timedWords(of: cue).map { ChunkWord(text: $0.text, start: $0.start, end: $0.end, accent: $0.accent, voice: $0.voice) }
            }
        }
        guard words.contains(where: { !$0.isEmpty }) else { return }
        let chunks = CaptionGrouping.regroup(words, twoLine: after.twoLine, mark: cues.contains(where: \.paragraph))
        let keep = selectedCue?.start
        cues = chunks.map { chunk in
            var cue = Cue(chunk: chunk)
            cue.key = nil
            return cue
        }
        if let keep, let near = cues.min(by: { abs($0.start - keep) < abs($1.start - keep) }) { selected = near.id } else { keepSelectionValid() }
    }
}
