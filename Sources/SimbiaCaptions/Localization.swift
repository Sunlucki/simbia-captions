import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en, fr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .fr: "Français"
        }
    }

    /// The language picked in the menu bar, or nil: follow the Mac's language (the default).
    static var saved: AppLanguage? { UserDefaults.standard.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) }

    /// The Mac's own language: Russian for ru / uk / be, French for fr, English for everything else.
    static var system: AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return code == "ru" || code == "uk" || code == "be" ? .ru : code == "fr" ? .fr : .en
    }

    static var preferred: AppLanguage { saved ?? system }

    /// The interface's language now, for code with no `Job` at hand. `Job.language` keeps it current.
    nonisolated(unsafe) static var current: AppLanguage = .preferred   // written on the main thread only
}

/// A string in the interface's language, for code with no `Job` at hand. French falls back to English.
func tr(_ ru: String, _ en: String, _ fr: String? = nil) -> String {
    switch AppLanguage.current {
    case .ru: ru
    case .en: en
    case .fr: fr ?? en
    }
}

/// The French names of the "What's wrong" checkboxes (`Shot.issueKinds`, `AudioClip.issueKinds`), by their English name.
let frenchIssueNames: [String: String] = [
    "Wrong face": "Visage différent", "Wardrobe · hair": "Tenue · coiffure", "Artifacts · morphing": "Artefacts · morphing",
    "Wrong framing": "Mauvais cadrage", "Eyeline · into the lens": "Regard · vers l’objectif", "Lip sync": "Synchro labiale",
    "Voice · line": "Voix · réplique", "Background moves": "Le décor bouge", "Story unclear": "Histoire peu claire",
    "Soft · low quality": "Flou · basse qualité", "Redo the shot": "Refaire le plan",
    "Glitch · click": "Glitch · clic", "Word cut off": "Mot coupé", "Wrong voice": "Mauvaise voix", "Out of sync": "Désynchronisé",
    "Level": "Niveau", "Pause too long": "Pause trop longue", "Record again": "Réenregistrer",
]

/// Every user-visible string, as stored properties rather than dictionary keys — a missing
/// translation then fails to compile instead of silently falling back to the key.
struct Strings {
    // Welcome
    let uploadVideo, processing, loadExistingSRT: String
    // Project header
    let project, untitled, cuesShort: String
    // Toolbar / menu
    let undo, redo, saveSRT, exportVideo, openVideo, importSRT, language: String
    let undoHint, redoHint, saveHint, exportHint: String
    // Transport
    let prevCue, nextCue, play, pause, previewAs, dragCaption: String
    // Settings
    let settings, typography, split, position, dragInPlayer, reset: String
    let colorSection, textColor, fillBackground, fillShadow, outline, thickness: String
    let textShadow, offset, glow, size, tracking, uppercase: String
    let accent, makeAccent, selectCaption, accentedCount, tilt, ownColor: String
    // Library
    let styles, animations, entrance, exit, toggleAllAnimations: String
    // Timeline
    let dragStart, dragEnd, clickToEdit, empty: String
    // Status
    let recognising, transcribeDone, renderingVideo: String
    let savedTo, loadedCues, needVideoAndCues, waitForCurrent, operationStopped: String
    let noSpeech, cannotRun, installFFmpeg: String
    let noDuration, noVideoTrack, noFrameSize: String
    // Project (.simbia)
    let saveProjectAs, projectOpened, projectUpdated, projectSaveFailed: String

    // Lookups for enum cases
    let animHints: [String: String]
    let outroHints: [String: String]
    let splitTitles: [String: String]
    let alignHints: [String: String]
    let socialTitles: [String: String]
    let animTitles: [String: String]
    let outroTitles: [String: String]

    func animHint(_ value: Anim) -> String { animHints[value.rawValue] ?? value.rawValue }
    func outroHint(_ value: Outro) -> String { outroHints[value.rawValue] ?? value.rawValue }
    func animTitle(_ value: Anim) -> String { animTitles[value.rawValue] ?? value.rawValue }
    func outroTitle(_ value: Outro) -> String { outroTitles[value.rawValue] ?? value.rawValue }
    func splitTitle(_ value: CaptionSplit) -> String { splitTitles[String(describing: value)] ?? value.rawValue }
    func alignHint(_ value: TextAlign) -> String { alignHints[value.rawValue] ?? value.rawValue }
    func socialTitle(_ value: SocialOverlay) -> String { socialTitles[value.rawValue] ?? value.rawValue }

    static func table(_ language: AppLanguage) -> Strings {
        switch language {
        case .ru: .ru
        case .en: .en
        case .fr: .fr
        }
    }
}

extension Strings {
    static let ru = Strings(
        uploadVideo: "ЗАГРУЗИТЬ ВИДЕО", processing: "ОБРАБОТКА",
        loadExistingSRT: "Загрузить готовый SRT",
        project: "ПРОЕКТ", untitled: "Без названия", cuesShort: "реплик",
        undo: "Отменить", redo: "Повторить", saveSRT: "Сохранить SRT…",
        exportVideo: "Экспорт видео…", openVideo: "Открыть видео…",
        importSRT: "Импорт SRT…", language: "Язык",
        undoHint: "Отменить (⌘Z)", redoHint: "Повторить (⇧⌘Z)",
        saveHint: "Сохранить SRT (⌘S)", exportHint: "Экспорт видео с субтитрами (⌘E)",
        prevCue: "Предыдущий субтитр", nextCue: "Следующий субтитр",
        play: "Воспроизвести", pause: "Пауза", previewAs: "Как это будет выглядеть",
        dragCaption: "Перетащите, чтобы изменить положение",
        settings: "НАСТРОЙКИ", typography: "Типографика", split: "Разбивка",
        position: "Положение", dragInPlayer: "Перетащите субтитр в плеере", reset: "Сброс",
        colorSection: "Цвет", textColor: "Текст", fillBackground: "Заливка фона",
        fillShadow: "Тень у фона", outline: "Обводка", thickness: "Толщина",
        textShadow: "Тень текста", offset: "Смещение", glow: "Свечение",
        size: "Размер", tracking: "Межбуквенно", uppercase: "ВЕРХНИЙ РЕГИСТР",
        accent: "Акцент", makeAccent: "Сделать акцентным", selectCaption: "Выберите субтитр",
        accentedCount: "Акцентных", tilt: "Наклон", ownColor: "Свой цвет",
        styles: "СТИЛИ", animations: "АНИМАЦИИ", entrance: "Появление", exit: "Угасание",
        toggleAllAnimations: "Включить или выключить все анимации",
        dragStart: "Потяните, чтобы изменить начало", dragEnd: "Потяните, чтобы изменить конец",
        clickToEdit: "Нажмите ещё раз, чтобы изменить текст", empty: "—",
        recognising: "Mac распознаёт речь (%@)…",
        transcribeDone: "Готово: %@ реплик.",
        renderingVideo: "Рендер видео…", savedTo: "Сохранено: %@",
        loadedCues: "Загружено %@ реплик", needVideoAndCues: "Нужны видео и реплики.",
        waitForCurrent: "Дождитесь окончания текущей операции.",
        operationStopped: "Операция остановлена. Лог: Portable/Logs/analysis.log",
        noSpeech: "Речь не распознана — проверьте звук и язык речи.",
        cannotRun: "Не удалось запустить %@.", installFFmpeg: "Установите: brew install ffmpeg-full",
        noDuration: "Не удалось прочитать длительность файла — возможно, формат не поддерживается.",
        noVideoTrack: "В файле нет видеодорожки.",
        noFrameSize: "Не удалось определить размер кадра.",
        saveProjectAs: "Сохранить проект как…", projectOpened: "Открыт проект %@",
        projectUpdated: "Проект обновлён Claude — ⌘Z вернёт как было",
        projectSaveFailed: "Не удалось сохранить проект: %@",
        animHints: [
            "none": "Субтитр просто появляется", "pop": "Появление с увеличением",
            "fade": "Плавное появление", "slideUp": "Выезд снизу вверх",
            "bounce": "Пружинящее появление с перелётом", "zoomOut": "Появление с уменьшением",
            "shake": "Лёгкое покачивание", "typewriter": "Буквы появляются по очереди",
            "wave": "Волна: буквы поднимаются каскадом", "glitch": "Глитч: RGB-расщепление и срезы"],
        outroHints: [
            "none": "Субтитр просто исчезает", "fade": "Плавное угасание",
            "shrink": "Уменьшается и растворяется", "grow": "Увеличивается и растворяется",
            "slideDown": "Уезжает вниз", "riseUp": "Уходит вверх", "blurOut": "Размывается",
            "spin": "Закручивается и пропадает", "particles": "Рассыпается на частицы",
            "glitchOut": "Разваливается глитчем"],
        splitTitles: ["word": "1 слово", "pair": "2 слова", "lines": "2 строки"],
        alignHints: ["left": "По левому краю", "center": "По центру", "right": "По правому краю"],
        socialTitles: ["off": "Без рамки", "tiktok": "TikTok", "reels": "Instagram Reels"],
        animTitles: ["none": "БЕЗ АНИМАЦИИ", "pop": "POP", "fade": "FADE", "slideUp": "SLIDE UP",
                     "bounce": "BOUNCE", "zoomOut": "ZOOM OUT", "shake": "SHAKE",
                     "typewriter": "TYPEWRITER", "wave": "WAVE", "glitch": "GLITCH"],
        outroTitles: ["none": "БЕЗ УГАСАНИЯ", "fade": "FADE OUT", "shrink": "SHRINK",
                      "grow": "GROW", "slideDown": "SLIDE DOWN", "riseUp": "RISE UP",
                      "blurOut": "BLUR OUT", "spin": "SPIN OUT", "particles": "PARTICLES",
                      "glitchOut": "GLITCH OUT"])

    static let en = Strings(
        uploadVideo: "UPLOAD VIDEO", processing: "PROCESSING",
        loadExistingSRT: "Load an existing SRT",
        project: "PROJECT", untitled: "Untitled", cuesShort: "captions",
        undo: "Undo", redo: "Redo", saveSRT: "Save SRT…",
        exportVideo: "Export Video…", openVideo: "Open Video…",
        importSRT: "Import SRT…", language: "Language",
        undoHint: "Undo (⌘Z)", redoHint: "Redo (⇧⌘Z)",
        saveHint: "Save SRT (⌘S)", exportHint: "Export video with captions (⌘E)",
        prevCue: "Previous caption", nextCue: "Next caption",
        play: "Play", pause: "Pause", previewAs: "Preview as",
        dragCaption: "Drag to reposition",
        settings: "SETTINGS", typography: "Typography", split: "Split",
        position: "Position", dragInPlayer: "Drag the caption in the player", reset: "Reset",
        colorSection: "Color", textColor: "Text", fillBackground: "Background fill",
        fillShadow: "Background shadow", outline: "Outline", thickness: "Thickness",
        textShadow: "Text shadow", offset: "Offset", glow: "Glow",
        size: "Size", tracking: "Tracking", uppercase: "UPPERCASE",
        accent: "Accent", makeAccent: "Mark as accent", selectCaption: "Select a caption",
        accentedCount: "Accented", tilt: "Tilt", ownColor: "Custom color",
        styles: "STYLES", animations: "ANIMATIONS", entrance: "In", exit: "Out",
        toggleAllAnimations: "Turn all animations on or off",
        dragStart: "Drag to change the start", dragEnd: "Drag to change the end",
        clickToEdit: "Click again to edit the text", empty: "—",
        recognising: "The Mac is recognising speech (%@)…",
        transcribeDone: "Done: %@ captions.",
        renderingVideo: "Rendering video…", savedTo: "Saved: %@",
        loadedCues: "Loaded %@ captions", needVideoAndCues: "A video and captions are required.",
        waitForCurrent: "Wait for the current operation to finish.",
        operationStopped: "Operation stopped. Log: Portable/Logs/analysis.log",
        noSpeech: "No speech recognised — check the sound and the speech language.",
        cannotRun: "Could not run %@.", installFFmpeg: "Install it with: brew install ffmpeg-full",
        noDuration: "Could not read the file's duration — the format may be unsupported.",
        noVideoTrack: "The file has no video track.",
        noFrameSize: "Could not determine the frame size.",
        saveProjectAs: "Save Project As…", projectOpened: "Opened project %@",
        projectUpdated: "Project updated by Claude — ⌘Z to undo",
        projectSaveFailed: "Could not save the project: %@",
        animHints: [
            "none": "The caption simply appears", "pop": "Scales up as it appears",
            "fade": "Fades in smoothly", "slideUp": "Slides up into place",
            "bounce": "Springs in with an overshoot", "zoomOut": "Shrinks into place",
            "shake": "A light wobble", "typewriter": "Letters arrive one by one",
            "wave": "Letters rise in a cascade", "glitch": "Glitch: RGB split and slices"],
        outroHints: [
            "none": "The caption simply disappears", "fade": "Fades out smoothly",
            "shrink": "Shrinks away", "grow": "Grows and dissolves",
            "slideDown": "Slides down", "riseUp": "Rises away", "blurOut": "Blurs away",
            "spin": "Spins and vanishes", "particles": "Breaks into particles",
            "glitchOut": "Falls apart with a glitch"],
        splitTitles: ["word": "1 word", "pair": "2 words", "lines": "2 lines"],
        alignHints: ["left": "Align left", "center": "Align centre", "right": "Align right"],
        socialTitles: ["off": "No frame", "tiktok": "TikTok", "reels": "Instagram Reels"],
        animTitles: ["none": "NO ANIMATION", "pop": "POP", "fade": "FADE", "slideUp": "SLIDE UP",
                     "bounce": "BOUNCE", "zoomOut": "ZOOM OUT", "shake": "SHAKE",
                     "typewriter": "TYPEWRITER", "wave": "WAVE", "glitch": "GLITCH"],
        outroTitles: ["none": "NO OUTRO", "fade": "FADE OUT", "shrink": "SHRINK",
                      "grow": "GROW", "slideDown": "SLIDE DOWN", "riseUp": "RISE UP",
                      "blurOut": "BLUR OUT", "spin": "SPIN OUT", "particles": "PARTICLES",
                      "glitchOut": "GLITCH OUT"])
    static let fr = Strings(
        uploadVideo: "IMPORTER UNE VIDÉO", processing: "TRAITEMENT",
        loadExistingSRT: "Charger un SRT existant",
        project: "PROJET", untitled: "Sans titre", cuesShort: "sous-titres",
        undo: "Annuler", redo: "Rétablir", saveSRT: "Enregistrer le SRT…",
        exportVideo: "Exporter la vidéo…", openVideo: "Ouvrir une vidéo…",
        importSRT: "Importer un SRT…", language: "Langue",
        undoHint: "Annuler (⌘Z)", redoHint: "Rétablir (⇧⌘Z)",
        saveHint: "Enregistrer le SRT (⌘S)", exportHint: "Exporter la vidéo avec sous-titres (⌘E)",
        prevCue: "Sous-titre précédent", nextCue: "Sous-titre suivant",
        play: "Lecture", pause: "Pause", previewAs: "Aperçu comme",
        dragCaption: "Faire glisser pour déplacer",
        settings: "RÉGLAGES", typography: "Typographie", split: "Découpage",
        position: "Position", dragInPlayer: "Faites glisser le sous-titre dans le lecteur", reset: "Réinitialiser",
        colorSection: "Couleur", textColor: "Texte", fillBackground: "Fond",
        fillShadow: "Ombre du fond", outline: "Contour", thickness: "Épaisseur",
        textShadow: "Ombre du texte", offset: "Décalage", glow: "Halo",
        size: "Taille", tracking: "Interlettrage", uppercase: "MAJUSCULES",
        accent: "Accent", makeAccent: "Marquer comme accent", selectCaption: "Sélectionnez un sous-titre",
        accentedCount: "Accentués", tilt: "Inclinaison", ownColor: "Couleur personnalisée",
        styles: "STYLES", animations: "ANIMATIONS", entrance: "Entrée", exit: "Sortie",
        toggleAllAnimations: "Activer ou désactiver toutes les animations",
        dragStart: "Faire glisser pour changer le début", dragEnd: "Faire glisser pour changer la fin",
        clickToEdit: "Cliquez encore pour modifier le texte", empty: "—",
        recognising: "Le Mac reconnaît la parole (%@)…",
        transcribeDone: "Terminé : %@ sous-titres.",
        renderingVideo: "Rendu de la vidéo…", savedTo: "Enregistré : %@",
        loadedCues: "%@ sous-titres chargés", needVideoAndCues: "Une vidéo et des sous-titres sont nécessaires.",
        waitForCurrent: "Attendez la fin de l’opération en cours.",
        operationStopped: "Opération interrompue. Journal : Portable/Logs/analysis.log",
        noSpeech: "Aucune parole reconnue — vérifiez le son et la langue de la parole.",
        cannotRun: "Impossible de lancer %@.", installFFmpeg: "Installez-le avec : brew install ffmpeg-full",
        noDuration: "Impossible de lire la durée du fichier — le format n’est peut-être pas pris en charge.",
        noVideoTrack: "Le fichier n’a pas de piste vidéo.",
        noFrameSize: "Impossible de déterminer la taille de l’image.",
        saveProjectAs: "Enregistrer le projet sous…", projectOpened: "Projet %@ ouvert",
        projectUpdated: "Projet mis à jour par Claude — ⌘Z pour annuler",
        projectSaveFailed: "Impossible d’enregistrer le projet : %@",
        animHints: [
            "none": "Le sous-titre apparaît simplement", "pop": "Grandit en apparaissant",
            "fade": "Apparaît en fondu", "slideUp": "Glisse vers le haut jusqu’à sa place",
            "bounce": "Arrive avec un rebond", "zoomOut": "Rétrécit jusqu’à sa place",
            "shake": "Une légère secousse", "typewriter": "Les lettres arrivent une à une",
            "wave": "Les lettres montent en cascade", "glitch": "Glitch : séparation RVB et tranches"],
        outroHints: [
            "none": "Le sous-titre disparaît simplement", "fade": "Disparaît en fondu",
            "shrink": "Rétrécit et s’efface", "grow": "Grandit et se dissout",
            "slideDown": "Glisse vers le bas", "riseUp": "S’élève et s’efface", "blurOut": "Se floute et s’efface",
            "spin": "Tourne et disparaît", "particles": "Éclate en particules",
            "glitchOut": "Se désagrège en glitch"],
        splitTitles: ["word": "1 mot", "pair": "2 mots", "lines": "2 lignes"],
        alignHints: ["left": "Aligner à gauche", "center": "Centrer", "right": "Aligner à droite"],
        socialTitles: ["off": "Sans cadre", "tiktok": "TikTok", "reels": "Instagram Reels"],
        animTitles: ["none": "SANS ANIMATION", "pop": "POP", "fade": "FONDU", "slideUp": "GLISSER VERS LE HAUT",
                     "bounce": "REBOND", "zoomOut": "ZOOM ARRIÈRE", "shake": "SECOUSSE",
                     "typewriter": "MACHINE À ÉCRIRE", "wave": "VAGUE", "glitch": "GLITCH"],
        outroTitles: ["none": "SANS SORTIE", "fade": "FONDU SORTANT", "shrink": "RÉTRÉCIR",
                      "grow": "GRANDIR", "slideDown": "GLISSER VERS LE BAS", "riseUp": "S’ÉLEVER",
                      "blurOut": "FLOU SORTANT", "spin": "TOURNOYER", "particles": "PARTICULES",
                      "glitchOut": "GLITCH SORTANT"])
}

/// `String(format:)` with one substitution, kept readable at the call sites.
func fill(_ template: String, _ value: String) -> String {
    template.replacingOccurrences(of: "%@", with: value)
}
