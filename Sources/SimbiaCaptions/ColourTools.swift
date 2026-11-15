import SimbiaCore
import SwiftUI

// MARK: - Editing colour

extension Job {
    /// Changes a shot's colour (creating its grade on first use). The preview shows it at once, no rebuild.
    func updateGrade(_ id: String, undoable: Bool = true, _ change: (inout Grade) -> Void) {
        updateShot(id, undoable: undoable) { s in
            var g = s.grade ?? Grade()
            change(&g)
            s.grade = g
        }
        pushColour()
    }

    /// The shot's colour matched to another shot's (as that one looks with its own grade): one undoable step.
    func matchColour(_ id: String, to referenceID: String) {
        guard let p = project, let target = p.shots.first(where: { $0.id == id }),
              let reference = p.shots.first(where: { $0.id == referenceID }), matchingColour == nil else { return }
        matchingColour = id
        let url = projectURL
        Task {
            let grade = await ColourMatch.grade(for: target, like: reference, projectURL: url)
            matchingColour = nil
            guard let grade else { show(t("Не удалось прочитать клипы", "Couldn't read the clips", "Impossible de lire les clips"), isError: true); return }
            updateGrade(id) { g in let on = g.on; g = grade; g.on = on }
        }
    }

    func setColourReference(_ id: String?) {
        guard var p = project else { return }
        pushHistory()
        p.colourReference = id
        project = p
    }

    /// The hand adjustments back to zero; Claude's match (and how much of it is used) stays.
    func resetGrade(_ id: String) {
        updateGrade(id) { g in
            g.on = true; g.exposure = 0; g.contrast = 1; g.saturation = 1; g.warmth = 0; g.tint = 0
        }
    }

    /// The shot's own colour gone: no match, no adjustments, no lipstick — the footage as it is under the project look.
    func deleteGrade(_ id: String) {
        updateShot(id) { $0.grade = nil }
        pushColour()
    }

    /// The overall filter gone (not just switched off).
    func deleteLook() {
        guard var p = project, p.look != nil else { return }
        pushHistory()
        p.look = nil
        project = p
        pushColour()
    }

    /// Changes the project's look (creating it on first use).
    func updateLook(undoable: Bool = true, _ change: (inout ColourLook) -> Void) {
        guard var p = project else { return }
        if undoable { pushHistory() }
        var look = p.look ?? ColourLook()
        change(&look)
        p.look = look
        project = p
        pushColour()
    }

    // MARK: Filters over a stretch

    var filters: [FilterClip] { project?.filters ?? [] }

    func filterClip(_ id: String) -> FilterClip? { filters.first { $0.id == id } }

    /// A new filter over `shot` — or the shot under the playhead (or 3 s from the playhead) — selected, its settings shown.
    func addFilter(over shot: Shot? = nil) {
        ensureProject()
        guard var p = project else { return }
        pushHistory()
        let under = shot ?? p.shots.first { currentTime >= $0.start && currentTime < $0.end }
        let start = under?.start ?? currentTime, length = under.map { $0.end - $0.start } ?? min(3, max(0.5, p.duration - currentTime))
        let clip = FilterClip(id: Project.newID("f"), start: start, duration: length, label: t("Фильтр", "Filter", "Filtre"))
        p.filters.append(clip)
        p.filters.sort { $0.start < $1.start }
        project = p
        focus = .filter(clip.id)
        libraryTab = .filters
        pushColour()
    }

    func updateFilter(_ id: String, undoable: Bool = true, _ change: (inout FilterClip) -> Void) {
        guard var p = project, let i = p.filters.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushHistory() }
        change(&p.filters[i])
        p.filters[i].start = max(0, p.filters[i].start)
        p.filters[i].duration = max(0.2, p.filters[i].duration)
        p.filters.sort { $0.start < $1.start }
        project = p
        pushColour()
    }

    func deleteFilter(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        p.filters.removeAll { $0.id == id }
        project = p
        focus = .look
        pushColour()
    }
}

// MARK: - Shot window

/// The colour of one shot, in its window: on/off, how much of Claude's match to its scene, and hand adjustments.
struct ShotColour: View {
    @ObservedObject var job: Job
    let shot: Shot

    var body: some View {
        let g = shot.grade ?? Grade()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FieldLabel(g.scene.map { job.t("Сцена: ", "Scene: ", "Scène : ") + $0 } ?? job.t("Цвет этого шота", "This shot's colour", "Couleur de ce plan"))
                Spacer()
                Switch(isOn: g.on) { job.updateGrade(shot.id) { $0.on.toggle() } }
                    .help(job.t("Выключено — шот как снят: без подгонки и без общего стиля", "Off — the shot as filmed: no match, no project look", "Désactivé — le plan tel que filmé : sans raccord ni filtre général"))
            }
            if g.on {
                // two columns: the shot window already holds a lot
                Grid(horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ColourSlider(job: job, label: job.t("Яркость", "Brightness", "Luminosité"), value: g.exposure, range: -1...1, neutral: 0,
                                     text: signed(g.exposure)) { v in job.updateGrade(shot.id, undoable: false) { $0.exposure = v } }
                        ColourSlider(job: job, label: job.t("Контраст", "Contrast", "Contraste"), value: g.contrast, range: 0.7...1.3, neutral: 1,
                                     text: signed(g.contrast - 1)) { v in job.updateGrade(shot.id, undoable: false) { $0.contrast = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Насыщенность", "Saturation"), value: g.saturation, range: 0...1.6, neutral: 1,
                                     text: signed(g.saturation - 1)) { v in job.updateGrade(shot.id, undoable: false) { $0.saturation = v } }
                        ColourSlider(job: job, label: job.t("Теплота", "Warmth", "Chaleur"), value: g.warmth, range: -1...1, neutral: 0,
                                     text: signed(g.warmth)) { v in job.updateGrade(shot.id, undoable: false) { $0.warmth = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Оттенок", "Tint", "Teinte"), value: g.tint, range: -1...1, neutral: 0,
                                     text: signed(g.tint)) { v in job.updateGrade(shot.id, undoable: false) { $0.tint = v } }
                        if g.hasMatch {
                            ColourSlider(job: job, label: job.t("Подгонка к сцене", "Match to scene", "Raccord à la scène"), value: g.match, range: 0...1, neutral: 0.7,
                                         text: "\(Int((g.match * 100).rounded())) %") { v in job.updateGrade(shot.id, undoable: false) { $0.match = v } }
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
                LipControls(job: job, grade: g) { change in job.updateGrade(shot.id, undoable: false, change) }
                PillGrid {
                    if !g.untouched {
                        Pill(job.t("Сбросить ручные правки", "Reset adjustments", "Réinitialiser les réglages"), icon: "arrow.counterclockwise") { job.resetGrade(shot.id) }
                    }
                    if shot.grade != nil {
                        Pill(job.t("Удалить цвет шота", "Delete shot colour", "Supprimer la couleur du plan"), icon: "trash", destructive: true) { job.deleteGrade(shot.id) }
                            .help(job.t("Убрать у этого шота подгонку, ручные правки и помаду — общий фильтр остаётся",
                                        "Remove this shot's match, adjustments and lipstick — the overall filter stays", "Retirer le raccord, les réglages et le rouge à lèvres de ce plan — le filtre général reste"))
                    }
                }
            }
            ColourMatchRow(job: job, shot: shot)
        }
    }

    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n == 0 ? "0" : (n > 0 ? "+\(n)" : "\(n)")
    }
}

/// Colour taken from another shot: the reference (marked once, kept in the project) or the shot next to it.
private struct ColourMatchRow: View {
    @ObservedObject var job: Job
    let shot: Shot

    var body: some View {
        let shots = job.shots
        let i = shots.firstIndex { $0.id == shot.id }
        let previous = i.flatMap { $0 > 0 ? shots[$0 - 1] : nil }
        let next = i.flatMap { $0 + 1 < shots.count ? shots[$0 + 1] : nil }
        let referenceID = job.project?.colourReference
        let reference = shots.first { $0.id == referenceID }
        let busy = job.matchingColour != nil
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(job.matchingColour == shot.id ? job.t("Подбираю цвет…", "Matching colour…", "Raccord couleur…")
                       : job.t("Подогнать цвет", "Match colour", "Raccorder la couleur"))
            PillGrid {
                if let previous {
                    Pill(job.t("Как предыдущий", "Like the previous", "Comme le précédent"), icon: "arrow.left") { job.matchColour(shot.id, to: previous.id) }
                        .help(job.t("Цвет, свет и насыщенность как у кадра перед этим", "Colour, light and saturation of the shot before", "Couleur, lumière et saturation du plan précédent"))
                }
                if let next {
                    Pill(job.t("Как следующий", "Like the next", "Comme le suivant"), icon: "arrow.right") { job.matchColour(shot.id, to: next.id) }
                }
                if let reference, reference.id != shot.id {
                    Pill(job.t("Под эталон", "To the reference", "Sur la référence"), icon: "scope", primary: true) { job.matchColour(shot.id, to: reference.id) }
                        .help(job.t("Эталон: ", "Reference: ", "Référence : ") + (reference.label ?? (reference.src as NSString).lastPathComponent))
                }
                if reference?.id == shot.id {
                    Pill(job.t("Эталон цвета", "Colour reference", "Référence couleur"), icon: "checkmark.seal.fill", primary: true) { job.setColourReference(nil) }
                        .help(job.t("Нажмите, чтобы снять", "Click to clear", "Cliquer pour retirer"))
                } else {
                    Pill(job.t("Сделать эталоном", "Make the reference", "Définir comme référence"), icon: "checkmark.seal") { job.setColourReference(shot.id) }
                        .help(job.t("Другие кадры можно будет подогнать под цвет этого", "Other shots can then be matched to this one's colour", "Les autres plans pourront ensuite être raccordés à la couleur de celui-ci"))
                }
            }
            .disabled(busy)
        }
    }
}

// MARK: - The Filters tab

/// The Filters tab: the settings of the filter picked on the filter track — or, with none picked, the overall
/// filter (the project look: curve, saturation, warmth, split toning, lifted blacks, vignette, grain, motion blur).
struct FiltersPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .filter(let id) = job.focus, let clip = job.filterClip(id) {
                FilterSettings(job: job, clip: clip)
            } else {
                LookSettings(job: job)
            }
            PillGrid {
                Pill(job.t("Фильтр на этот шот", "Filter on this shot", "Filtre sur ce plan"), icon: "plus") { job.addFilter() }
                    .help(job.t("Фильтр на дорожке «Фильтры» над шотом под курсором — его можно растянуть на всю сцену",
                                "A filter on the Filters track over the shot at the playhead — stretch it over the whole scene", "Un filtre sur la piste Filtres, au-dessus du plan sous la tête de lecture — à étirer sur toute la scène"))
                Pill(job.colourCompare ? job.t("Показать с цветом", "Show graded", "Afficher étalonné") : job.t("Сравнить с исходником", "Compare with original", "Comparer à l’original"),
                     icon: "rectangle.split.2x1", primary: job.colourCompare) { job.colourCompare.toggle(); job.pushColour() }
            }
            .disabled(job.project == nil)
        }
    }
}

/// The overall filter over the whole video.
private struct LookSettings: View {
    @ObservedObject var job: Job

    var body: some View {
        let look = job.project?.look
        let l = look ?? ColourLook()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.t("Общий фильтр — на весь ролик", "Overall filter — the whole video", "Filtre général — toute la vidéo")).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Switch(isOn: look?.on ?? false) {
                    if look == nil { job.updateLook { _ in } } else { job.updateLook { $0.on.toggle() } }
                    job.focus = .look
                }
            }
            if l.on, look != nil {
                Grid(horizontalSpacing: 22, verticalSpacing: 10) {
                    GridRow {
                        ColourSlider(job: job, label: job.t("Контраст · кривая", "Contrast · curve", "Contraste · courbe"), value: l.contrast, range: 0...1, neutral: 0,
                                     text: percent(l.contrast)) { v in job.updateLook(undoable: false) { $0.contrast = v } }
                        ColourSlider(job: job, label: job.t("Насыщенность", "Saturation"), value: l.saturation, range: 0.5...1.5, neutral: 1,
                                     text: percent(l.saturation)) { v in job.updateLook(undoable: false) { $0.saturation = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Теплота", "Warmth", "Chaleur"), value: l.warmth, range: -1...1, neutral: 0,
                                     text: percent(l.warmth)) { v in job.updateLook(undoable: false) { $0.warmth = v } }
                        ColourSlider(job: job, label: job.t("Оттенок", "Tint", "Teinte"), value: l.tint, range: -1...1, neutral: 0,
                                     text: percent(l.tint)) { v in job.updateLook(undoable: false) { $0.tint = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Бирюзовые тени · тёплые света", "Teal shadows · warm highlights", "Ombres bleu canard · hautes lumières chaudes"), value: l.split,
                                     range: 0...1, neutral: 0, text: percent(l.split)) { v in job.updateLook(undoable: false) { $0.split = v } }
                        ColourSlider(job: job, label: job.t("Мягкий чёрный", "Lifted blacks", "Noirs relevés"), value: l.fade, range: 0...1, neutral: 0,
                                     text: percent(l.fade)) { v in job.updateLook(undoable: false) { $0.fade = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Виньетка", "Vignette", "Vignettage"), value: l.vignette, range: 0...1, neutral: 0,
                                     text: percent(l.vignette)) { v in job.updateLook(undoable: false) { $0.vignette = v } }
                        ColourSlider(job: job, label: job.t("Зерно", "Grain"), value: l.grain, range: 0...1, neutral: 0,
                                     text: percent(l.grain)) { v in job.updateLook(undoable: false) { $0.grain = v } }
                    }
                    GridRow {
                        ColourSlider(job: job, label: job.t("Размытие движения · затвор", "Motion blur · shutter", "Flou de mouvement · obturateur"), value: l.motionBlur, range: 0...1,
                                     neutral: 0, text: "\(Int((l.motionBlur * 360).rounded()))°") { v in job.updateLook(undoable: false) { $0.motionBlur = v } }
                            .help(job.t("Как Pixel Motion Blur в After Effects: каждый пиксель размывается вдоль своего движения. 180° — как в кино. Включение и выключение пересобирает превью",
                                        "Like After Effects' Pixel Motion Blur: every pixel blurs along its own motion. 180° is film. Switching it on or off rebuilds the preview", "Comme Pixel Motion Blur d’After Effects : chaque pixel est flouté le long de son propre mouvement. 180° correspond au cinéma. L’activer ou le désactiver reconstruit l’aperçu"))
                        PillGrid {
                            Pill(job.t("По умолчанию", "Defaults", "Par défaut"), icon: "arrow.counterclockwise") { job.updateLook { $0 = ColourLook() } }
                            Pill(job.t("Удалить", "Delete", "Supprimer"), icon: "trash", destructive: true) { job.deleteLook() }
                                .help(job.t("Убрать общий фильтр с ролика", "Remove the overall filter from the video", "Retirer le filtre général de la vidéo"))
                        }
                    }
                    GridRow {
                        HStack {
                            FieldLabel(job.t("Размытие на склейках", "Blur across cuts", "Flou sur les coupes"))
                            Spacer()
                            Switch(isOn: l.cutBlur) { job.updateLook { $0.cutBlur.toggle() } }
                        }
                        .help(job.t("Шот, который заканчивается быстрым движением, переносит смаз в первые кадры следующего — склейка как рывок камеры",
                                    "A shot that ends on a fast move carries its smear into the next one's first frames — the cut reads like a whip", "Un plan qui finit sur un mouvement rapide prolonge son flou dans les premières images du suivant — la coupe ressemble à un panoramique filé"))
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            } else {
                Text(job.t("Один стиль на все кадры: кривая, теплота, тени и света, виньетка, зерно и размытие движения.",
                           "One style over every frame: curve, warmth, shadows and highlights, vignette, grain and motion blur.", "Un seul style sur toutes les images : courbe, chaleur, ombres et hautes lumières, vignettage, grain et flou de mouvement."))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
}

/// A filter over a stretch: on/off, name, its adjustments, delete.
private struct FilterSettings: View {
    @ObservedObject var job: Job
    let clip: FilterClip

    var body: some View {
        let g = clip.grade
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text((clip.label ?? job.t("Фильтр", "Filter", "Filtre")) + " · \(clock(clip.start)) – \(clock(clip.end))")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Switch(isOn: g.on) { job.updateFilter(clip.id) { $0.grade.on.toggle() } }
            }
            CommitField(job: job, value: clip.label ?? "", placeholder: job.t("Название, например «гараж ночь»", "Name, e.g. “garage night”", "Nom, p. ex. « garage de nuit »")) { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                job.updateFilter(clip.id) { $0.label = t.isEmpty ? nil : t }
            }
            Grid(horizontalSpacing: 22, verticalSpacing: 10) {
                GridRow {
                    ColourSlider(job: job, label: job.t("Яркость", "Brightness", "Luminosité"), value: g.exposure, range: -1...1, neutral: 0,
                                 text: signed(g.exposure)) { v in job.updateFilter(clip.id, undoable: false) { $0.grade.exposure = v } }
                    ColourSlider(job: job, label: job.t("Контраст", "Contrast", "Contraste"), value: g.contrast, range: 0.7...1.3, neutral: 1,
                                 text: signed(g.contrast - 1)) { v in job.updateFilter(clip.id, undoable: false) { $0.grade.contrast = v } }
                }
                GridRow {
                    ColourSlider(job: job, label: job.t("Насыщенность", "Saturation"), value: g.saturation, range: 0...1.6, neutral: 1,
                                 text: signed(g.saturation - 1)) { v in job.updateFilter(clip.id, undoable: false) { $0.grade.saturation = v } }
                    ColourSlider(job: job, label: job.t("Теплота", "Warmth", "Chaleur"), value: g.warmth, range: -1...1, neutral: 0,
                                 text: signed(g.warmth)) { v in job.updateFilter(clip.id, undoable: false) { $0.grade.warmth = v } }
                }
                GridRow {
                    ColourSlider(job: job, label: job.t("Оттенок", "Tint", "Teinte"), value: g.tint, range: -1...1, neutral: 0,
                                 text: signed(g.tint)) { v in job.updateFilter(clip.id, undoable: false) { $0.grade.tint = v } }
                    Pill(job.t("Удалить фильтр · ⌫", "Delete filter · ⌫", "Supprimer le filtre · ⌫"), icon: "trash", destructive: true) { job.deleteFilter(clip.id) }
                }
            }
            LipControls(job: job, grade: g) { change in job.updateFilter(clip.id, undoable: false) { change(&$0.grade) } }
        }
    }

    private func signed(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        return n == 0 ? "0" : (n > 0 ? "+\(n)" : "\(n)")
    }
}

// MARK: - Pieces

/// Lipstick for a shot or a filter: how strong, how soft the edge, which colour. The lips are found on every frame.
struct LipControls: View {
    @ObservedObject var job: Job
    let grade: Grade
    let change: ((inout Grade) -> Void) -> Void

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                ColourSlider(job: job, label: job.t("Губы · помада", "Lips · lipstick", "Lèvres · rouge à lèvres"), value: grade.lips, range: 0...1, neutral: 0,
                             text: "\(Int((grade.lips * 100).rounded())) %") { v in change { $0.lips = v } }
                    .help(job.t("Губы находятся на каждом кадре сами (точки лица), зубы и открытый рот не красятся",
                                "The lips are found on every frame (face landmarks); teeth and the open mouth stay as they are", "Les lèvres sont détectées sur chaque image (points du visage) ; les dents et la bouche ouverte restent intactes"))
                if grade.lips > 0 {
                    ColourSlider(job: job, label: job.t("Мягкость края губ", "Lip edge softness", "Douceur du contour des lèvres"), value: grade.lipSoftness, range: 0...1, neutral: 0.5,
                                 text: "\(Int((grade.lipSoftness * 100).rounded())) %") { v in change { $0.lipSoftness = v } }
                } else {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            if grade.lips > 0 {
                GridRow {
                    HStack {
                        FieldLabel(job.t("Цвет помады", "Lipstick colour", "Couleur du rouge à lèvres"))
                        Spacer()
                        ColorPicker("", selection: Binding(get: { grade.lipColour.color ?? .pink }, set: { c in change { $0.lipColour = c.hex } }),
                                    supportsOpacity: false).labelsHidden()
                    }
                    ColourSlider(job: job, label: job.t("Защита зубов", "Keep off teeth", "Protéger les dents"), value: grade.lipTeeth, range: 0...1, neutral: 0.6,
                                 text: "\(Int((grade.lipTeeth * 100).rounded())) %") { v in change { $0.lipTeeth = v } }
                        .help(job.t("Белое (зубы, даже в тени) не красится. Больше — щадит и сероватое белое; на 100 % могут побледнеть края губ",
                                    "Whites (teeth, even in shadow) stay unpainted. Higher spares greyer whites too; at 100 % the palest lip edges may go", "Les blancs (dents, même dans l’ombre) restent sans couleur. Plus haut, les blancs grisés sont aussi épargnés ; à 100 % les bords les plus pâles des lèvres peuvent disparaître"))
                }
                GridRow {
                    FieldLabel(job.t("Половина рта", "Half of the mouth", "Moitié de la bouche"))
                    Picker("", selection: Binding(get: { grade.lipSide ?? "" }, set: { v in change { $0.lipSide = v.isEmpty ? nil : v } })) {
                        Text(job.t("Весь рот", "Whole", "Entière")).tag("")
                        Text(job.t("Левая", "Left", "Gauche")).tag("left")
                        Text(job.t("Правая", "Right", "Droite")).tag("right")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help(job.t("Лицо с линией: помада только на одной половине губ, по средней линии лица",
                                "Split face: lipstick on one half of the lips only, cut at the face's middle line", "Visage partagé : rouge à lèvres sur une seule moitié des lèvres, coupée sur la ligne médiane du visage"))
                }
            }
        }
    }
}

/// A labelled slider that changes the picture live; the whole drag is one undo step. Double-click the value: back to neutral.
struct ColourSlider: View {
    @ObservedObject var job: Job
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let text: String
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                FieldLabel(label)
                Spacer()
                Text(text).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(abs(value - neutral) < 0.005 ? Theme.muted : Theme.text)
                    .onTapGesture(count: 2) { job.pushHistory(); set(neutral) }
                    .help(job.t("Двойной клик — сбросить", "Double-click to reset", "Double-clic pour réinitialiser"))
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range,
                   onEditingChanged: { began in if began { job.pushHistory() } })
                .tint(.white)
                .controlSize(.small)
        }
    }
}

/// The white capsule switch the windows use.
struct Switch: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Capsule().fill(isOn ? Color.white : Color.white.opacity(0.25))
                .frame(width: 36, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Color.black.opacity(0.85) : Color.white).frame(width: 16, height: 16).padding(2)
                }
                .animation(Theme.snappy, value: isOn)
        }
        .buttonStyle(.plain)
    }
}
