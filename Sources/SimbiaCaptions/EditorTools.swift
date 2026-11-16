import AppKit
import SimbiaCore

/// The popover that is open over the text panel or the timeline, if any.
enum ToolPanel: Equatable { case find, glossary, pauses }

/// How far reading the footage library's index got.
enum FootageState: Equatable { case idle, loading, missing, ready, failed(String) }

// The checks before export, the glossary and find & replace, pause removal, word timing, J/K/L and
// footage suggestions — the work itself is SimbiaCore's (Checks, Glossary, Pauses, Footage, Voice).
extension Job {
    // MARK: Checks

    func refreshIssues() {
        issues = document().issues(voice: sync.voice, glossary: glossary, projectURL: projectURL)
    }

    /// The voice's loudness, worked out again when the voice clips change; the checks follow it.
    func loadVoice() {
        guard let project, project.audio.contains(where: { $0.role == .voice }) else { sync.voice = nil; sync.voiceKey = nil; return }
        let key = project.audio.filter { $0.role == .voice }
            .map { "\($0.src)|\($0.start)|\($0.inPoint)|\($0.duration ?? -1)|\($0.gain)|\($0.speed)" }.joined(separator: ";") + "|\(project.duration)"
        guard key != sync.voiceKey else { return }
        sync.voiceKey = key
        let url = projectURL
        Task { [weak self] in
            let voice = await VoiceActivity.of(project, projectURL: url)
            guard let self, self.sync.voiceKey == key else { return }
            self.sync.voice = voice
            self.refreshIssues()
        }
    }

    /// The voice as the checks hear it — straight away when it is known.
    func voiceActivity() async -> VoiceActivity? {
        if let voice = sync.voice { return voice }
        return await VoiceActivity.of(document(), projectURL: projectURL)
    }

    /// The chosen issues fixed, as one undo step.
    func fix(_ chosen: [Issue]) {
        let kinds = Issue.Kind.allCases.filter { kind in chosen.contains { $0.kind == kind && $0.fixable } }
        guard !kinds.isEmpty else { return }
        ensureProject()
        let doc = kinds.reduce(document()) { doc, kind in
            doc.fixing(kind, only: Set(chosen.filter { $0.kind == kind }.map(\.target)), voice: sync.voice, glossary: glossary,
                       projectURL: projectURL)
        }
        replaceDocument(doc)
    }

    func fixAll() {
        ensureProject()
        replaceDocument(document().fixingAll(voice: sync.voice, glossary: glossary, projectURL: projectURL))
    }

    /// The shots' stretches of their clips looked at for cuts in the background (once each, kept between
    /// launches); the checks follow.
    func loadCuts() {
        guard let project else { return }
        guard !sync.scanningCuts else { sync.scanCutsAgain = true; return }
        sync.scanningCuts = true
        let url = projectURL
        Task { [weak self] in
            let added = await SourceCuts.scan(project, projectURL: url)
            guard let self else { return }
            self.sync.scanningCuts = false
            if added { self.refreshIssues() }
            if self.sync.scanCutsAgain { self.sync.scanCutsAgain = false; self.loadCuts() }
        }
    }

    /// Plays from the issue's place and selects what it is about.
    func jump(to issue: Issue) {
        if let cue = cues.first(where: { $0.chunkID == issue.target }) {
            select(cue)
        } else if title(issue.target) != nil {
            focus = .title(issue.target)
        } else if shot(issue.target) != nil {
            focus = .shot(issue.target)
        }
        seek(issue.time)
    }

    func kindName(_ kind: Issue.Kind) -> String {
        switch kind {
        case .overlap: return t("Субтитры наложились", "Overlapping captions", "Sous-titres superposés")
        case .repeated: return t("Повторы распознавания", "Recogniser repeats", "Répétitions de la reconnaissance")
        case .brand: return t("Написание", "Spelling", "Orthographe")
        case .small: return t("Слишком длинные — текст мелкий", "Too long — the text shrinks", "Trop long — le texte rétrécit")
        case .voice: return t("Не по голосу", "Off the voice", "Décalé de la voix")
        case .nearCut: return t("Мигание у склейки", "Flicker at a cut", "Scintillement à une coupe")
        case .gap: return t("Мигание между субтитрами", "Flicker between captions", "Scintillement entre sous-titres")
        case .fast: return t("Не успеть прочитать", "Too fast to read", "Trop rapide à lire")
        case .shortTitle: return t("Заголовок меньше 2 с", "Titles under 2 s", "Titres de moins de 2 s")
        case .hiddenCut: return t("Склейка внутри шота", "A cut inside a shot", "Coupe à l’intérieur d’un plan")
        case .missing: return t("Нет файла", "Missing files", "Fichiers manquants")
        }
    }

    func describe(_ issue: Issue) -> String {
        let v = String(format: "%.2f", issue.value).replacingOccurrences(of: ".", with: language == .en ? "." : ",")
        let text = issue.text.count > 46 ? String(issue.text.prefix(44)) + "…" : issue.text
        let q = language == .en ? "“\(text)”" : language == .fr ? "« \(text) »" : "«\(text)»"
        switch issue.kind {
        case .overlap: return t("\(q) заходит на следующий на \(v) с", "\(q) runs \(v) s into the next one", "\(q) empiète de \(v) s sur le suivant")
        case .repeated: return q
        case .brand, .missing: return issue.text
        case .small: return t("\(q) — \(Int(issue.value))% обычного размера", "\(q) — \(Int(issue.value))% of the normal size", "\(q) — \(Int(issue.value))% de la taille normale")
        case .voice: return t("\(q) — расходится с голосом на \(v) с", "\(q) — \(v) s off the voice", "\(q) — \(v) s de décalage avec la voix")
        case .nearCut:
            let n = Int(issue.value)
            return t("\(q) меняется за \(ruPlural(n, "кадр", "кадра", "кадров")) до склейки или после", "\(q) changes \(n) frame\(n == 1 ? "" : "s") from a cut", "\(q) change à \(n) image\(n == 1 ? "" : "s") d’une coupe")
        case .gap: return t("пустой экран \(v) с после \(q)", "\(v) s of blank screen after \(q)", "\(v) s d’écran vide après \(q)")
        case .fast: return t("\(q) — всего \(v) с на экране", "\(q) — only \(v) s on screen", "\(q) — seulement \(v) s à l’écran")
        case .shortTitle: return t("\(q) — \(v) с, нужно 2", "\(q) — \(v) s, needs 2", "\(q) — \(v) s, il en faut 2")
        case .hiddenCut:
            let name = issue.text.replacingOccurrences(of: #"_ArelSignLips_[0-9a-f_]+$"#, with: "", options: .regularExpression)
            return issue.canFix ? t("\(name): в клипе склейка на \(v) с — мелькнёт другой кадр", "\(name): the clip cuts at \(v) s — another picture flashes", "\(name) : le clip a une coupe à \(v) s — une autre image apparaît un instant")
                                : t("\(name): в клипе склейка на \(v) с, а чистого куска нужной длины рядом нет — замените клип",
                                    "\(name): the clip cuts at \(v) s and has no clean stretch long enough nearby — replace the clip", "\(name) : le clip a une coupe à \(v) s et aucun passage propre assez long à proximité — remplacer le clip")
        }
    }

    // MARK: Caption settings

    /// A caption setting for the whole video — capitals, italic, how plain captions come in — as one undo step.
    func setCaptions(_ change: (inout CaptionTrack) -> Void) {
        ensureProject()
        guard var p = project else { return }
        pushHistory()
        change(&p.captions)
        project = p
    }

    // MARK: Glossary, find and replace

    func addToGlossary(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !glossary.words.contains(w) else { return }
        glossary.words.append(w)
        saveGlossary()
    }

    func removeFromGlossary(_ word: String) {
        glossary.words.removeAll { $0 == word }
        saveGlossary()
    }

    private func saveGlossary() {
        do { try glossary.save() } catch { show(error.localizedDescription, isError: true) }
    }

    private func finder(_ find: String, wholeWords: Bool) -> NSRegularExpression? {
        let needle = NSRegularExpression.escapedPattern(for: find.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: wholeWords ? "(?<![\\p{L}\\p{N}])\(needle)(?![\\p{L}\\p{N}])" : needle,
                                        options: [.caseInsensitive])
    }

    func matches(_ find: String, wholeWords: Bool) -> Int {
        guard let regex = finder(find, wholeWords: wholeWords) else { return 0 }
        return cues.reduce(0) { $0 + regex.numberOfMatches(in: $1.text, range: NSRange($1.text.startIndex..., in: $1.text)) }
    }

    /// Every occurrence replaced, as one undo step; the words around keep their timing. How many there were.
    @discardableResult func replaceAll(_ find: String, with replacement: String, wholeWords: Bool) -> Int {
        guard let regex = finder(find, wholeWords: wholeWords) else { return 0 }
        let template = NSRegularExpression.escapedTemplate(for: replacement.trimmingCharacters(in: .whitespaces))
        var changes: [(Cue.ID, String)] = [], count = 0
        for cue in cues {
            let range = NSRange(cue.text.startIndex..., in: cue.text)
            let n = regex.numberOfMatches(in: cue.text, range: range)
            guard n > 0 else { continue }
            count += n
            let text = regex.stringByReplacingMatches(in: cue.text, range: range, withTemplate: template)
            changes.append((cue.id, text.split(whereSeparator: \.isWhitespace).joined(separator: " ")))
        }
        guard count > 0 else { return 0 }
        pushHistory()
        for (id, text) in changes { updateText(of: id, to: text) }
        return count
    }

    // MARK: Pauses

    /// The pauses taken out as one undo step: the speaker's picture and the voice jump-cut, the rest moved up.
    func removePauses(_ ranges: [ClosedRange<Double>]) {
        guard !ranges.isEmpty else { return }
        ensureProject()
        let before = duration
        replaceDocument(document().removing(ranges))
        show(t("Вырезано: \(ruPlural(ranges.count, "пауза", "паузы", "пауз")), видео короче на \(seconds(before - duration)) с",
               "Removed \(ranges.count) pause\(ranges.count == 1 ? "" : "s"), \(seconds(before - duration)) s shorter", "Supprimé : \(ranges.count) pause\(ranges.count == 1 ? "" : "s"), \(seconds(before - duration)) s de moins"), isError: false)
    }

    // MARK: Word timing

    var frameStep: Double { 1 / max(project?.canvas.fps ?? 30, 1) }

    /// The boundary before word `index` dragged to `time`: the word starts there (on a frame), the one before
    /// ends there at the latest.
    func moveWordStart(_ id: Cue.ID, word index: Int, to time: Double) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        var words = timedWords(of: cues[i])
        guard index > 0, index < words.count else { return }
        let low = words[index - 1].start + 0.03
        let high = (index + 1 < words.count ? words[index + 1].start : cues[i].end) - 0.03
        guard low < high else { return }
        let t = min(high, max(low, (time / frameStep).rounded() * frameStep))
        words[index].start = t
        words[index].end = max(words[index].end, t + 0.02)
        words[index].voice = nil                                          // placed by hand
        words[index - 1].end = min(words[index - 1].end, t)
        cues[i].words = words
    }

    /// A word dragged in the captions drawer: it starts at `time` (on a frame) and pushes the words before it — they
    /// come in proportionally faster (dragged left) or slower (right) between the caption's start and it; the words
    /// after it stay. `base` = the caption's words as the drag found them.
    func pushWord(_ id: Cue.ID, word index: Int, to time: Double, base: [Word]) {
        guard let i = cues.firstIndex(where: { $0.id == id }), index > 0, index < base.count else { return }
        let start = cues[i].start, old = base[index].start
        let low = start + 0.03 * Double(index)                                 // each word before keeps a sliver
        let high = (index + 1 < base.count ? base[index + 1].start : cues[i].end) - 0.03
        guard low < high, old - start > 0.001 else { return }
        let t = min(high, max(low, (time / frameStep).rounded() * frameStep))
        let k = (t - start) / (old - start)
        var words = base
        for j in 0..<index {
            words[j].start = start + (base[j].start - start) * k
            words[j].end = min(t, start + (base[j].end - start) * k)
            words[j].voice = nil                                              // placed by hand
        }
        words[index].start = t
        words[index].end = max(base[index].end, t + 0.02)
        words[index].voice = nil
        cues[i].words = words
    }

    /// A word's start or end one frame earlier or later; the first word's start moves its caption's with it.
    func nudgeWord(_ id: Cue.ID, word index: Int, start: Bool, frames: Double) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        var words = timedWords(of: cues[i])
        guard words.indices.contains(index) else { return }
        let delta = frames * frameStep
        pushHistory()
        words[index].voice = nil                                          // placed by hand
        if start, index == 0 {
            retime(id, start: min(cues[i].start + delta, (words.count > 1 ? words[1].start : cues[i].end) - 0.03))
            words[0].start = cues[i].start
        } else if start {
            let high = (index + 1 < words.count ? words[index + 1].start : cues[i].end) - 0.03
            words[index].start = min(high, max(words[index - 1].start + 0.03, words[index].start + delta))
            words[index - 1].end = min(words[index - 1].end, words[index].start)
        } else {
            let high = index + 1 < words.count ? words[index + 1].start : cues[i].end
            words[index].end = min(high, max(words[index].start + 0.02, words[index].end + delta))
        }
        words[index].end = max(words[index].end, words[index].start + 0.02)
        cues[i].words = words
    }

    // MARK: J / K / L

    /// L plays forward, faster with each press (1×, 2×, 4×); J backwards the same way; K stops.
    func shuttle(_ direction: Int) {
        let rate = player.rate
        if direction == 0 {
            player.pause()
        } else if direction > 0 {
            if currentTime >= duration - 0.08 { seek(0) }
            player.rate = rate > 0 ? min(rate * 2, 4) : 1
        } else if player.currentItem?.canPlayReverse == true {
            player.rate = rate < 0 ? max(rate * 2, -4) : -1
        } else {
            player.pause()
            seek(currentTime - 1)
        }
    }

    // MARK: Footage

    /// Reads the library's index once: the folder picked before, or `_ASSETS/_index` above the project — looked
    /// for again while none is found, since another project may sit next to it.
    func loadFootage() {
        guard footageState == .idle || footageState == .missing else { return }
        let picked = UserDefaults.standard.string(forKey: "footageIndex").map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "clips").path) ? $0 : nil }
        let ownIndex = workspace.map(\.footageIndex).flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "clips").path) ? $0 : nil }
        guard let folder = ownIndex ?? picked ?? FootageIndex.find(near: projectURL) else { footageState = .missing; return }
        footageState = .loading
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Result { try FootageIndex.load(folder) } }.value
            guard let self else { return }
            switch loaded {
            case .success(let index):
                self.footage = index
                self.sync.moments = nil
                self.footageState = .ready
                self.appendLog("Footage index: \(index.clips.count) clips from \(folder.path)")
            case .failure(let error):
                self.footageState = .failed(error.localizedDescription)
            }
        }
    }

    func chooseFootageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = t("Папка _index библиотеки клипов (в ней clips/*.json)", "The footage library's _index folder (it holds clips/*.json)", "Dossier _index de la bibliothèque de rushes (contient clips/*.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "footageIndex")
        footage = nil
        footageState = .idle
        loadFootage()
    }

    /// The library's best moments for what is said over the shot.
    func suggestions(for shot: Shot) -> [FootageIndex.Suggestion] {
        guard let footage else { return [] }
        let said = orderedCues.flatMap { timedWords(of: $0) }
            .filter { $0.start >= shot.start - 0.05 && $0.start < shot.end }.map(\.text).joined(separator: " ")
        let taken = Set(shots.filter { $0.id != shot.id }.map { Project.resolve($0.src, relativeTo: projectURL).path })
        return footage.suggest(for: said, length: shot.duration, taken: taken)
    }

    func useFootage(_ suggestion: FootageIndex.Suggestion, for id: String) {
        updateShot(id) {
            $0.src = suggestion.file.path
            $0.inPoint = suggestion.from
            $0.label = suggestion.clip
        }
    }
}
