import Foundation
import SimbiaCore

/// «Пересчитать по словам». A caption word remembers where its voice says it (`VoiceAnchor`), taken while it still
/// sat on its voice — before a ripple trim squeezes it, and after a re-timing. Such a word goes back to wherever
/// that stretch of the file plays now, to the frame. A word without one is found by the Mac's speech recognition
/// (`MacSpeech`); a word whose stretch was cut out is spread between its neighbours.
extension Job {
    /// The captions `ids` (nil = all) back on the words of their voice. One undo step.
    func syncToVoice(_ ids: Set<Cue.ID>?) {
        work { [self] in
            guard let project else { return }
            let all = orderedCues.map { c in var c = c; c.words = timedWords(of: c); return c }
            let chosen = all.filter { ids?.contains($0.id) ?? true }
            guard !chosen.isEmpty else { return }
            let used = Set(project.audio.filter { $0.role == .voice }.map(\.src))
            let unplaced = chosen.filter { $0.words.contains { w in w.voice.map { !used.contains($0.src) } ?? true } }
            let heard = unplaced.isEmpty ? [] : try await heardWords(under: unplaced, in: project)
            let synced = Dictionary(uniqueKeysWithValues: Self.anchoringVoice(Self.syncedToVoice(chosen, audio: project.audio, heard: heard),
                                                                              to: project.audio).map { ($0.id, $0) })
            pushHistory()
            var list = all.map { synced[$0.id] ?? $0 }
            // a re-timed caption and the one after it: no overlap, and no blink shorter than 0.3 s
            for k in list.indices.dropLast() where synced[list[k].id] != nil || synced[list[k + 1].id] != nil {
                let next = list[k + 1].start
                guard list[k].end > next || (synced[list[k].id] != nil && next - list[k].end < 0.3) else { continue }
                list[k].end = max(list[k].start + 0.05, next)
                list[k].words = list[k].words.map { var w = $0; w.end = min(w.end, list[k].end); w.start = min(w.start, w.end); return w }
            }
            cues = list
            status = t("Пересчитано по словам: \(synced.count)", "Re-timed to the words: \(synced.count)", "Recalés sur les mots : \(synced.count)")
        }
    }

    /// «Создать субтитры по звуку» on a voice clip: the Mac listens to what of its file plays, and the words become
    /// the captions over the clip, each anchored to its place in the file. The captions that were over it go. One undo step.
    func captionsFromVoice(_ id: String) {
        work { [self] in
            guard let clip = audioClip(id) else { return }
            status = fill(s.recognising, MacSpeech.name(MacSpeech.locale, in: language.rawValue))
            progress = 2
            let (made, end) = try await heardCaptions(clip) { [weak self] p in self?.progress = 2 + Int(p * 95) }
            guard !made.isEmpty else { throw NSError(domain: "Simbia", code: 3, userInfo: [NSLocalizedDescriptionKey: s.noSpeech]) }
            place(made) { Self.over($0, clip.start, end) }
        }
    }

    /// «Создать субтитры» over the timeline: every voice clip in turn, each a paragraph of its own. One undo step.
    func captionsFromAllVoice() {
        work { [self] in
            guard let project else { return }
            let voice = project.audio.filter { $0.role == .voice }.sorted { $0.start < $1.start }
            status = fill(s.recognising, MacSpeech.name(MacSpeech.locale, in: language.rawValue))
            progress = 2
            var made: [Cue] = []
            for (k, clip) in voice.enumerated() {
                made += try await heardCaptions(clip) { [weak self] p in self?.progress = 2 + Int((Double(k) + p) / Double(voice.count) * 95) }.made
            }
            guard !made.isEmpty else { throw NSError(domain: "Simbia", code: 3, userInfo: [NSLocalizedDescriptionKey: s.noSpeech]) }
            place(made) { _ in true }
        }
    }

    /// What the Mac hears in the part of a voice clip's file that plays, as captions on the edit's clock (the first one
    /// starting a paragraph), each word anchored to its place in the file; and where the clip ends.
    private func heardCaptions(_ clip: AudioClip, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> (made: [Cue], end: Double) {
        let url = Project.resolve(clip.src, relativeTo: projectURL)
        let from = clip.inPoint
        var to = from
        if let duration = clip.duration { to += duration * clip.speed } else { to = try await SpeechAudio.length(of: url) }
        let heard = try await MacSpeech.words(in: url, from: from, to: to, hints: glossary.words, work: temp,
                                              downloading: { [weak self] in self?.status = self?.t("Mac загружает язык распознавания…", "The Mac is downloading the speech language…", "Le Mac télécharge la langue de la parole…") ?? "" },
                                              progress: progress)
        var made = group(words: heard.map { w in
            Word(start: clip.start + (w.start - from) / clip.speed, end: clip.start + (min(w.end, to) - from) / clip.speed,
                 text: glossary.correction(for: w.text) ?? w.text, voice: VoiceAnchor(src: clip.src, from: w.start, to: min(w.end, to)))
        })
        if !made.isEmpty { made[0].paragraph = true }
        return (made, clip.start + (to - from) / clip.speed)
    }

    /// «+ Субтитры по голосу» on an empty stretch `from…to` of the captions track: the Mac listens to the voice there and
    /// its words become captions there only, anchored to their voice. One undo step.
    func captionsFromVoice(in from: Double, _ to: Double) {
        work { [self] in
            guard let project else { return }
            status = fill(s.recognising, MacSpeech.name(MacSpeech.locale, in: language.rawValue))
            progress = 2
            var words: [Word] = []
            for clip in project.audio where clip.role == .voice && clip.start < to && clip.start + (clip.duration ?? .infinity) > from {
                let url = Project.resolve(clip.src, relativeTo: projectURL)
                let a = clip.source(at: max(from, clip.start))
                let b = clip.source(at: min(to, clip.start + (clip.duration ?? .infinity)))
                guard b - a > 0.2 else { continue }
                let heard = try await MacSpeech.words(in: url, from: a, to: b, hints: glossary.words, work: temp)
                words += heard.map { w in
                    Word(start: clip.start + (w.start - clip.inPoint) / clip.speed, end: clip.start + (min(w.end, b) - clip.inPoint) / clip.speed,
                         text: glossary.correction(for: w.text) ?? w.text, voice: VoiceAnchor(src: clip.src, from: w.start, to: min(w.end, b)))
                }
            }
            let made = group(words: words.filter { ($0.start + $0.end) / 2 >= from && ($0.start + $0.end) / 2 < to }.sorted { $0.start < $1.start })
            guard !made.isEmpty else { throw NSError(domain: "Simbia", code: 3, userInfo: [NSLocalizedDescriptionKey: s.noSpeech]) }
            place(made) { _ in false }
        }
    }

    /// New captions in, the ones `replaced` out, no overlap left; one undo step, the first new one picked.
    private func place(_ made: [Cue], replacing replaced: (Cue) -> Bool) {
        pushHistory()
        var list = (orderedCues.filter { !replaced($0) } + made).sorted { $0.start < $1.start }
        for k in list.indices.dropLast() where list[k].end > list[k + 1].start {
            list[k].end = max(list[k].start + 0.05, list[k + 1].start)
            list[k].words = list[k].words.map { var w = $0; w.end = min(w.end, list[k].end); w.start = min(w.start, w.end); return w }
        }
        cues = list
        select(made[0])
        progress = 100
        status = t("Субтитры по звуку: \(made.count) · ⌘Z вернёт как было", "Captions from the sound: \(made.count) · ⌘Z undoes", "Sous-titres depuis le son : \(made.count) · ⌘Z annule")
    }

    /// A caption is over a clip `start…end` when its middle is.
    static func over(_ c: Cue, _ start: Double, _ end: Double) -> Bool {
        let mid = (c.start + c.end) / 2
        return mid >= start && mid < end
    }

    /// Words without an anchor, or with one in a file the voice no longer uses, take it from where they are now:
    /// the voice clip under the word's middle (where two clips overlap at a cut, the one the word is mostly in).
    static func anchoringVoice(_ cues: [Cue], to audio: [AudioClip]) -> [Cue] {
        let voice = audio.filter { $0.role == .voice }
        let used = Set(voice.map(\.src))
        return cues.map { c in
            var c = c
            c.words = c.words.map { w in
                if let anchor = w.voice, used.contains(anchor.src) { return w }
                var w = w
                let mid = (w.start + w.end) / 2
                w.voice = voice.first { $0.start <= mid && mid < $0.start + ($0.duration ?? .infinity) }.map {
                    VoiceAnchor(src: $0.src, from: $0.source(at: w.start), to: $0.source(at: w.end))
                }
                return w
            }
            return c
        }
    }

    /// Each word where its anchor's stretch plays now (the nearest place when the file plays it twice). The words
    /// left are matched in order to what the Mac heard between their placed neighbours — a caption already about
    /// on them stays put, the recogniser being less exact than that — and the rest go evenly between the
    /// placed ones, or at their own pace past the first or last. A caption keeps the lead and tail round its words.
    static func syncedToVoice(_ cues: [Cue], audio: [AudioClip], heard: [Word]) -> [Cue] {
        let voice = audio.filter { $0.role == .voice }
        let words = cues.flatMap(\.words), n = words.count
        var times = [(start: Double, end: Double)?](repeating: nil, count: n)
        var last = -Double.infinity
        for (i, w) in words.enumerated() {
            guard let a = w.voice else { continue }
            let places = voice.filter { $0.src == a.src && $0.inPoint - 0.001 <= a.from && a.from < $0.inPoint + ($0.duration ?? .infinity) * $0.speed - 0.001 }
                .map { clip in (start: clip.start + (a.from - clip.inPoint) / clip.speed,
                                end: clip.start + (min(a.to, clip.inPoint + (clip.duration ?? .infinity) * clip.speed) - clip.inPoint) / clip.speed) }
            guard let place = places.min(by: { abs($0.start - w.start) < abs($1.start - w.start) }), place.start >= last - 0.01 else { continue }
            times[i] = (place.start, max(place.start + 0.02, place.end))
            last = place.start
        }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "colour", with: "color").filter { $0.isLetter || $0.isNumber } }
        let cueOf = cues.indices.flatMap { c in Array(repeating: c, count: cues[c].words.count) }
        var match: [Int: Word] = [:]
        var k = 0
        while k < n, !heard.isEmpty {
            guard times[k] == nil else { k += 1; continue }
            var e = k
            while e < n, times[e] == nil { e += 1 }
            let lo = k > 0 ? times[k - 1]!.end - 0.05 : -Double.infinity, hi = e < n ? times[e]!.start + 0.05 : .infinity
            let pool = heard.filter { $0.start >= lo && $0.start <= hi }
            for (x, y) in matches(Array(words[k..<e]), pool, norm) { match[k + x] = pool[y] }
            k = e
        }
        // by caption: one on its voice as far as the recogniser can tell (half its words within 0.5 s — its own
        // error runs to 0.3–0.45 s on some voices) stays as it is; one that is off takes the heard times
        for c in cues.indices {
            let mine = (0..<n).filter { cueOf[$0] == c && times[$0] == nil }
            let offsets = mine.compactMap { i in match[i].map { $0.start - words[i].start } }.sorted()
            guard !offsets.isEmpty else { continue }
            let onVoice = abs(offsets[offsets.count / 2]) <= 0.5
            for i in mine {
                if onVoice { times[i] = (words[i].start, words[i].end) }
                else if let h = match[i] { times[i] = (h.start, max(h.start + 0.02, h.end)) }
            }
        }
        // never out of order: a word placed before the one before it is spread like the unplaced ones
        last = -Double.infinity
        for i in 0..<n {
            guard let t = times[i] else { continue }
            if t.start < last - 0.01 { times[i] = nil } else { last = t.start }
        }
        guard times.contains(where: { $0 != nil }) else { return cues }
        k = 0
        while k < n {
            guard times[k] == nil else { k += 1; continue }
            var e = k
            while e < n, times[e] == nil { e += 1 }
            let own = (k..<e).map { max(0.08, words[$0].end - words[$0].start) }
            if k > 0, e < n, let lo = times[k - 1]?.end, let hi = times[e]?.start {
                let from = min(lo, hi), step = max(0, hi - from) / Double(e - k)
                for x in k..<e { times[x] = (from + step * Double(x - k), from + step * Double(x - k + 1)) }
            } else if k > 0, let lo = times[k - 1]?.end {
                var t = lo
                for x in k..<e { times[x] = (t, t + own[x - k]); t += own[x - k] }
            } else if e < n, let hi = times[e]?.start {
                var t = hi
                for x in (k..<e).reversed() { times[x] = (max(0, t - own[x - k]), t); t -= own[x - k] }
            }
            k = e
        }
        var out: [Cue] = [], at = 0
        for c in cues {
            var c = c
            guard let first = c.words.first, let lastWord = c.words.last else { out.append(c); continue }
            let lead = max(0, first.start - c.start), tail = max(0, c.end - lastWord.end)
            c.words = c.words.indices.map { x in
                var w = c.words[x]
                if let t = times[at + x] { w.start = t.start; w.end = t.end }
                return w
            }
            at += c.words.count
            c.start = max(0, c.words[0].start - lead)
            c.end = max(c.start + 0.05, c.words[c.words.count - 1].end + tail)
            out.append(c)
        }
        return out
    }

    /// The longest run of the same words in order (within 6 s of each other): pairs of indices into `a` and `b`.
    private static func matches(_ a: [Word], _ b: [Word], _ norm: (String) -> String) -> [(Int, Int)] {
        let x = a.map { norm($0.text) }, y = b.map { norm($0.text) }, n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        func same(_ i: Int, _ j: Int) -> Bool { !x[i].isEmpty && x[i] == y[j] && abs(a[i].start - b[j].start) < 6 }
        var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * (m + 1) + j] = same(i, j) ? dp[(i + 1) * (m + 1) + j + 1] + 1 : max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1])
            }
        }
        var out: [(Int, Int)] = [], i = 0, j = 0
        while i < n, j < m {
            if same(i, j), dp[i * (m + 1) + j] == dp[(i + 1) * (m + 1) + j + 1] + 1 { out.append((i, j)); i += 1; j += 1 }
            else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// What the Mac hears in the voice clips under these captions, on the edit's clock.
    private func heardWords(under cues: [Cue], in project: Project) async throws -> [Word] {
        let clips = project.audio.filter { clip in
            clip.role == .voice && cues.contains { $0.end > clip.start - 0.5 && $0.start < clip.start + (clip.duration ?? .infinity) + 0.5 }
        }
        status = t("Слушаю голос…", "Listening to the voice…", "Écoute de la voix…")
        var out: [Word] = []
        for clip in clips {
            let url = Project.resolve(clip.src, relativeTo: projectURL)
            let from = clip.inPoint
            var to = from
            if let duration = clip.duration { to += duration * clip.speed } else { to = try await SpeechAudio.length(of: url) }
            let key = "\(url.path)|\(from)|\(to)"
            let words: [Word]
            if let known = Self.heardCache[key] { words = known } else {
                words = try await MacSpeech.words(in: url, from: from, to: to, hints: glossary.words, work: temp)
                    .map { Word(start: $0.start, end: $0.end, text: $0.text) }
                Self.heardCache[key] = words
            }
            out += words.map { Word(start: clip.start + ($0.start - from) / clip.speed, end: clip.start + ($0.end - from) / clip.speed, text: $0.text) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// What was heard in a stretch of a file, while the app runs.
    @MainActor private static var heardCache: [String: [Word]] = [:]
}
