import Foundation

/// Something to look at before the video goes out, and the change that fixes it: captions too fast to
/// read or shrunk to fit, Whisper's repeats, a misspelt brand, captions off the voice, flicker next to a
/// cut or between captions, titles too short to read, missing files. The app lists them over the
/// export button; `simbia check` prints them.
public struct Issue: Identifiable, Equatable, Sendable {
    /// In the order "fix all" applies them: the words first, then the timing — each can change what the next finds.
    public enum Kind: String, CaseIterable, Sendable {
        case overlap, repeated, brand, small, voice, nearCut, gap, fast, shortTitle, hiddenCut, missing
    }

    public var kind: Kind
    /// Where it is on the edit's clock.
    public var time: Double
    /// The caption (chunk id), title or clip it is about.
    public var target: String
    /// Seconds, frames or percent, by kind (for a hidden cut: where in its clip).
    public var value = 0.0
    /// The caption's or title's text; for a spelling the word and its correction; for a file its name.
    public var text = ""
    /// False when the change that fixes this kind cannot be made here (a clip with no clean stretch long enough).
    public var canFix = true

    public var fixable: Bool { kind != .missing && canFix }
    public var id: String { "\(kind.rawValue)|\(target)|\(text)|\(time)" }

    /// One line for `simbia check`.
    public var detail: String {
        let v = String(format: "%.2f", value)
        switch kind {
        case .overlap: return "overlaps the next caption by \(v) s"
        case .repeated: return "repeated: \"\(text)\""
        case .brand: return "spelling: \(text)"
        case .voice: return "\"\(text)\" is off the voice by \(v) s"
        case .nearCut: return "\"\(text)\" changes \(Int(value)) frame(s) from a cut"
        case .gap: return "\(v) s blank after \"\(text)\" (flicker)"
        case .fast: return "\"\(text)\" is on screen \(v) s — too fast to read"
        case .small: return "\"\(text)\" is shrunk to \(Int(value))% to fit"
        case .shortTitle: return "title \"\(text)\" is on screen \(v) s (under 2 s)"
        case .hiddenCut: return "shot \"\(text)\": its clip cuts to another picture at \(v) s, inside the shot"
            + (canFix ? "" : " — no clean stretch long enough nearby: replace the clip")
        case .missing: return "file not found: \(text)"
        }
    }
}

extension Project {
    /// Everything worth fixing, in time order within each kind.
    public func issues(voice: VoiceActivity?, glossary: Glossary, projectURL: URL?) -> [Issue] {
        Issue.Kind.allCases.flatMap { issues($0, voice: voice, glossary: glossary, projectURL: projectURL) }
    }

    public func issues(_ kind: Issue.Kind, voice: VoiceActivity?, glossary: Glossary, projectURL: URL?) -> [Issue] {
        let chunks = captions.chunks.sorted { $0.start < $1.start }
        var out: [Issue] = []
        func add(_ time: Double, _ target: String, _ value: Double = 0, _ text: String) {
            out.append(Issue(kind: kind, time: time, target: target, value: value, text: text))
        }
        switch kind {
        case .overlap:
            for k in chunks.indices.dropFirst() where chunks[k].start < chunks[k - 1].end - 0.001 {
                add(chunks[k].start, chunks[k - 1].id, chunks[k - 1].end - chunks[k].start, chunks[k - 1].text)
            }
        case .repeated:
            for k in chunks.indices {
                if k > 0, Self.same(chunks[k], chunks[k - 1]) {
                    add(chunks[k].start, chunks[k].id, 0, chunks[k].text)
                } else if let run = Self.stutter(chunks[k].words) {
                    add(chunks[k].words[run.lowerBound].start, chunks[k].id, 0, chunks[k].words[run].map(\.text).joined(separator: " "))
                }
            }
        case .brand:
            for c in chunks {
                for w in c.words { if let right = glossary.correction(for: w.text) { add(w.start, c.id, 0, "\(w.text) → \(right)") } }
            }
        case .voice:
            guard let voice else { break }
            for k in chunks.indices {
                guard let t = voiceTimes(chunks, k, voice) else { continue }
                add(chunks[k].start, chunks[k].id, max(abs(t.start - chunks[k].start), abs(t.end - chunks[k].end)), chunks[k].text)
            }
        case .nearCut:
            for (k, c) in chunks.enumerated() {
                // a change between two captions is one edge: reported with the second
                let joined = k + 1 < chunks.count && abs(chunks[k + 1].start - c.end) < 0.001
                if let edge = ([c.start] + (joined ? [] : [c.end])).first(where: { cut(near: $0) != nil }) {
                    add(cut(near: edge)!, c.id, max(1, (abs(edge - cut(near: edge)!) / frame).rounded()), c.text)
                }
            }
            for t in titles {
                if let edge = [t.start, t.end].first(where: { cut(near: $0) != nil }) {
                    add(cut(near: edge)!, t.id, max(1, (abs(edge - cut(near: edge)!) / frame).rounded()), t.text)
                }
            }
        case .gap:
            for k in chunks.indices.dropLast() {
                let gap = chunks[k + 1].start - chunks[k].end
                if gap > 0.001, gap < Self.bridged { add(chunks[k].end, chunks[k].id, gap, chunks[k].text) }
            }
        case .fast:
            for c in chunks where tooFast(c) { add(c.start, c.id, c.end - c.start, c.text) }
        case .small:
            // film subtitles keep one size and wrap instead of shrinking
            guard let style = CaptionStyle(id: captions.style), !style.look.isFilm else { break }
            for c in chunks where c.words.count > 1 {
                let scale = style.textScale(c, options: captions.options)
                if scale < Self.smallest { add(c.start, c.id, (scale * 100).rounded(), c.text) }
            }
        case .shortTitle:
            for t in titles where t.duration < 2 - 0.001 { add(t.start, t.id, t.duration, t.text) }
        case .hiddenCut:
            for s in shots {
                guard let cut = hiddenCuts(s, projectURL: projectURL).first else { continue }
                add(s.start + (cut - s.inPoint) / s.speed, s.id, cut, s.label ?? ((s.src as NSString).lastPathComponent as NSString).deletingPathExtension)
                out[out.count - 1].canFix = cleanSpot(s, projectURL: projectURL) != nil
            }
        case .missing:
            var seen = Set<String>()
            let files = (shots + layers).map { ($0.start, $0.id, $0.src) } + audio.map { ($0.start, $0.id, $0.src) }
                + overlays.map { ($0.start, $0.id, $0.src) }
            for (time, id, src) in files where seen.insert(src).inserted
                && !FileManager.default.fileExists(atPath: Self.resolve(src, relativeTo: projectURL).path) {
                add(max(0, time), id, 0, (src as NSString).lastPathComponent)
            }
        }
        return out
    }

    /// The project with one kind of issue fixed — every one, or only those about `targets`.
    public func fixing(_ kind: Issue.Kind, only targets: Set<String>? = nil, voice: VoiceActivity?, glossary: Glossary,
                       projectURL: URL? = nil) -> Project {
        var p = self
        var chunks = captions.chunks.sorted { $0.start < $1.start }
        func wanted(_ id: String) -> Bool { targets?.contains(id) ?? true }
        switch kind {
        case .overlap:
            for k in chunks.indices.dropFirst() where wanted(chunks[k - 1].id) && chunks[k].start < chunks[k - 1].end - 0.001 {
                chunks[k - 1].end = max(chunks[k - 1].start + 0.05, chunks[k].start)
                chunks[k].start = max(chunks[k].start, chunks[k - 1].end)
                Self.fit(&chunks[k - 1]); Self.fit(&chunks[k])
            }
        case .repeated:
            for k in chunks.indices where wanted(chunks[k].id) {
                guard let run = Self.stutter(chunks[k].words) else { continue }
                chunks[k].words[run.lowerBound].end = chunks[k].words[run.upperBound - 1].end
                chunks[k].words.removeSubrange(run.lowerBound + 1..<run.upperBound)
            }
            var k = 1
            while k < chunks.count {
                guard wanted(chunks[k].id), Self.same(chunks[k], chunks[k - 1]) else { k += 1; continue }
                chunks[k - 1].end = max(chunks[k - 1].end, chunks[k].end)
                if chunks[k].paragraph, k + 1 < chunks.count { chunks[k + 1].paragraph = true }
                chunks.remove(at: k)
            }
        case .brand:
            for k in chunks.indices where wanted(chunks[k].id) {
                for i in chunks[k].words.indices {
                    if let right = glossary.correction(for: chunks[k].words[i].text) { chunks[k].words[i].text = right }
                }
            }
        case .voice:
            guard let voice else { break }
            let before = chunks
            for k in before.indices where wanted(before[k].id) {
                guard let t = voiceTimes(before, k, voice) else { continue }
                if abs(t.start - before[k].start) > 0.0005 {
                    if k > 0, abs(chunks[k - 1].end - before[k].start) < 0.001 {
                        // the one before stays up until this one comes — unless that is a long silence away
                        var end = t.start
                        if let spoken = voice.stop(before: t.start, after: chunks[k - 1].start), t.start - spoken > Self.lingering {
                            end = spoken + 0.3
                        }
                        chunks[k - 1].end = max(chunks[k - 1].start + 0.05, end)
                        Self.fit(&chunks[k - 1])
                    }
                    chunks[k].start = t.start
                    chunks[k].words[0].start = t.start          // the first word appears with its caption
                }
                if abs(t.end - before[k].end) > 0.0005 {
                    chunks[k].end = t.end
                    let last = chunks[k].words.count - 1
                    chunks[k].words[last].end = min(chunks[k].words[last].end, t.end)
                }
                Self.fit(&chunks[k])
            }
        case .nearCut:
            for k in chunks.indices where wanted(chunks[k].id) {
                if let at = cut(near: chunks[k].start) {
                    if k > 0, abs(chunks[k - 1].end - chunks[k].start) < 0.001 { chunks[k - 1].end = at; Self.fit(&chunks[k - 1]) }
                    chunks[k].start = at
                    if !chunks[k].words.isEmpty { chunks[k].words[0].start = at }
                }
                if let at = cut(near: chunks[k].end) {
                    if k + 1 < chunks.count, abs(chunks[k + 1].start - chunks[k].end) < 0.001 {
                        chunks[k + 1].start = at
                        if !chunks[k + 1].words.isEmpty { chunks[k + 1].words[0].start = at }
                        Self.fit(&chunks[k + 1])
                    }
                    chunks[k].end = at
                }
                Self.fit(&chunks[k])
            }
            for i in p.titles.indices where wanted(p.titles[i].id) {
                if let at = cut(near: p.titles[i].start) { p.titles[i].duration = p.titles[i].end - at; p.titles[i].start = at }
                if let at = cut(near: p.titles[i].end) { p.titles[i].duration = at - p.titles[i].start }
            }
        case .gap:
            for k in chunks.indices.dropLast() where wanted(chunks[k].id) {
                let gap = chunks[k + 1].start - chunks[k].end
                if gap > 0.001, gap < Self.bridged { chunks[k].end = chunks[k + 1].start }
            }
        case .fast:
            var k = 0
            while k < chunks.count {
                defer { k += 1 }
                guard wanted(chunks[k].id), tooFast(chunks[k]) else { continue }
                // longer into the blank after it, as far as reading needs; failing that, one caption with a neighbour
                let room = k + 1 < chunks.count ? chunks[k + 1].start : duration
                chunks[k].end = max(chunks[k].end, min(room, chunks[k].start + needed(chunks[k])))
                guard tooFast(chunks[k]) else { continue }
                let starts = Self.paragraphStarts(chunks)
                if k + 1 < chunks.count, !starts[k + 1] { Self.join(&chunks, k) }
                else if k > 0, !starts[k] { Self.join(&chunks, k - 1); k -= 1 }
            }
        case .small:
            guard let style = CaptionStyle(id: captions.style), !style.look.isFilm else { break }
            var k = 0
            while k < chunks.count {
                guard wanted(chunks[k].id), chunks[k].words.count > 1, style.textScale(chunks[k], options: captions.options) < Self.smallest else { k += 1; continue }
                // two captions, split where the letters balance
                let words = chunks[k].words
                let total = words.reduce(0) { $0 + $1.text.count }
                var split = 1, best = Int.max, running = 0
                for i in 1..<words.count {
                    running += words[i - 1].text.count
                    if abs(total - 2 * running) < best { best = abs(total - 2 * running); split = i }
                }
                var tail = chunks[k]
                tail.id = Project.newID("c")
                tail.words = Array(words[split...])
                tail.start = words[split].start
                tail.paragraph = false
                chunks[k].words = Array(words[..<split])
                chunks[k].end = tail.start
                Self.fit(&chunks[k]); Self.fit(&tail)
                chunks.insert(tail, at: k + 1)
                k += 2
            }
        case .shortTitle:
            for i in p.titles.indices where wanted(p.titles[i].id) && p.titles[i].duration < 2 - 0.001 {
                p.titles[i].duration = 2
                if p.titles[i].end > p.duration { p.titles[i].start = max(0, p.duration - 2) }
            }
        case .hiddenCut:
            for i in p.shots.indices where wanted(p.shots[i].id) {
                if let spot = cleanSpot(p.shots[i], projectURL: projectURL) { p.shots[i].inPoint = spot }
            }
        case .missing:
            break
        }
        p.captions.chunks = chunks
        return p
    }

    /// Where a shot with a cut inside can start in its clip instead: the nearest clean stretch long enough — between
    /// the whole clip's cuts once they are known (until then between the cuts its own stretch showed) — and no more
    /// than a second away, since further on the clip shows something else (a fast-cut clip moved 4.6 s landed on
    /// a woman talking into a microphone). nil when there is none, or nothing to fix.
    func cleanSpot(_ shot: Shot, projectURL: URL?) -> Double? {
        guard !hiddenCuts(shot, projectURL: projectURL).isEmpty, let own = SourceCuts.known(for: shot, projectURL: projectURL) else { return nil }
        let cuts = (SourceCuts.wholeClip(of: shot, projectURL: projectURL)?.cuts ?? own.cuts).sorted()
        let edges = [-frame] + cuts + [own.length + frame]
        var best: Double?
        for (a, b) in zip(edges, edges.dropFirst()) {
            let low = max(0, a + frame), high = b - frame - shot.footage
            guard high >= low else { continue }
            let spot = min(max(shot.inPoint, low), high)
            if best.map({ abs(spot - shot.inPoint) < abs($0 - shot.inPoint) }) ?? true { best = spot }
        }
        return best.flatMap { abs($0 - shot.inPoint) <= 1 ? $0 : nil }
    }

    /// Cuts of the shot's clip inside the stretch it shows — more than 2 frames from either end (one at an end
    /// is just the edit's own cut). Empty until the stretch has been looked at, and for the speaker's own
    /// picture, whose cuts are hers.
    func hiddenCuts(_ shot: Shot, projectURL: URL?) -> [Double] {
        guard !speaker(shot) else { return [] }
        return (SourceCuts.known(for: shot, projectURL: projectURL)?.cuts ?? [])
            .filter { $0 > shot.inPoint + 2 * frame && $0 < shot.inPoint + shot.footage - 2 * frame }
    }

    /// Every kind fixed, in turn — twice, since a split caption can land next to a cut and a joined one run long.
    public func fixingAll(voice: VoiceActivity?, glossary: Glossary, projectURL: URL? = nil) -> Project {
        (Issue.Kind.allCases + Issue.Kind.allCases).reduce(self) { $0.fixing($1, voice: voice, glossary: glossary, projectURL: projectURL) }
    }

    // MARK: Rules

    /// Captions further apart than a blink are a pause; closer, they flicker.
    static let bridged = 0.3
    /// Text drawn at less than this share of its normal size is too long for one caption.
    static let smallest = 0.7
    /// A caption still up this long after its voice has stopped is hanging over a silence.
    static let lingering = 0.9

    var frame: Double { 1 / max(canvas.fps, 1) }

    /// The shortest a caption may be on screen: 0.3 s, 0.6 s for the two-line styles.
    var minimumCaption: Double { CaptionStyle(id: captions.style)?.twoLine == true ? 0.6 : 0.3 }

    /// Reading speed: at most 25 letters a second, and never under the minimum.
    func tooFast(_ c: Chunk) -> Bool {
        let d = c.end - c.start
        return d < minimumCaption - 0.001 || Double(Self.letters(c)) / max(d, 0.01) > 25
    }

    /// How long the caption needs: 20 letters a second, comfortably under the limit.
    func needed(_ c: Chunk) -> Double { max(minimumCaption, Double(Self.letters(c)) / 20) }

    static func letters(_ c: Chunk) -> Int { c.words.reduce(0) { $0 + $1.text.count } }

    /// The cut nearest `time`, when it is a hair away: 1–3 frames, where a caption changing reads as a flicker.
    func cut(near time: Double) -> Double? {
        let reach = 3 * frame + 0.0005
        let cuts = shots.map(\.start).filter { $0 > 0.001 && $0 < duration - 0.001 }
        guard let nearest = cuts.min(by: { abs($0 - time) < abs($1 - time) }) else { return nil }
        let d = abs(nearest - time)
        return d > 0.001 && d <= reach ? nearest : nil
    }

    /// Where caption k belongs by the voice. One that comes up in silence moves to where the voice starts
    /// inside it (Whisper stretches a word over a pause before it); one that comes up as the voice speaks
    /// moves back to where it started, if that was a moment before. An end before a pause goes to where the
    /// voice stops, plus 0.3 s to finish reading — also one joined to the next caption across a silence longer
    /// than `lingering`. nil when both edges are within 0.1 s already. An edge on a cut stays there unless the
    /// voice is more than 4 frames away.
    func voiceTimes(_ chunks: [Chunk], _ k: Int, _ voice: VoiceActivity) -> (start: Double, end: Double)? {
        let c = chunks[k]
        guard let first = c.words.first, let last = c.words.last else { return nil }
        let cuts = Set(shots.map { ($0.start * 1000).rounded() })
        func onCut(_ t: Double) -> Bool { cuts.contains((t * 1000).rounded()) }
        let stay = 4 * frame + 0.0005
        var start = c.start, end = c.end
        let previousSpeech = k > 0 ? (chunks[k - 1].words.last?.end ?? chunks[k - 1].start) : 0
        let onset = voice.speaking(at: c.start) ? voice.onset(near: first.start, reach: 0.35)
                                                : voice.start(after: c.start, before: c.end - 0.1)
        if let onset, onset >= min(previousSpeech, c.start), onset < c.end - 0.1, !(onCut(c.start) && abs(onset - c.start) <= stay) {
            start = onset
        }
        let next = k + 1 < chunks.count ? chunks[k + 1].start : duration
        let joined = k + 1 < chunks.count && next <= c.end + 0.02
        let offset = voice.speaking(at: c.end - 0.01) ? (joined ? nil : voice.offset(near: last.end, reach: 0.35))
                                                     : voice.stop(before: c.end, after: start)
        if let offset, offset > start + 0.05, !joined || c.end - offset > Self.lingering {
            // joined to the next caption it stays so, unless it would hang on over a long silence
            let target = min(next, max(offset + 0.3, start + minimumCaption))
            if !(onCut(c.end) && abs(target - c.end) <= stay) { end = target }
        }
        guard abs(start - c.start) >= 0.1 || abs(end - c.end) >= 0.1 else { return nil }
        return (start, end)
    }

    // MARK: Helpers

    static func plain(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func same(_ a: Chunk, _ b: Chunk) -> Bool {
        !a.words.isEmpty && a.words.map { plain($0.text) } == b.words.map { plain($0.text) }
    }

    /// Four or more of the same word in a row — Whisper stuck on a word, not "no, no, no".
    static func stutter(_ words: [ChunkWord]) -> Range<Int>? {
        var i = 0
        while i < words.count {
            var j = i + 1
            while j < words.count, plain(words[j].text) == plain(words[i].text), !plain(words[i].text).isEmpty { j += 1 }
            if j - i >= 4 { return i..<j }
            i = j
        }
        return nil
    }

    /// Keeps a caption's words inside it after an edge moved, in order.
    static func fit(_ c: inout Chunk) {
        c.end = max(c.end, c.start + 0.05)
        var floor = c.start
        for i in c.words.indices {
            c.words[i].start = min(max(c.words[i].start, floor), c.end - 0.02)
            c.words[i].end = max(c.words[i].end, c.words[i].start)
            floor = c.words[i].start
        }
    }

    /// Caption k and the next become one.
    static func join(_ chunks: inout [Chunk], _ k: Int) {
        chunks[k].words += chunks[k + 1].words
        chunks[k].end = max(chunks[k].end, chunks[k + 1].end)
        chunks[k].emphasis = chunks[k].emphasis || chunks[k + 1].emphasis
        chunks.remove(at: k + 1)
    }

    /// Which captions open a paragraph: the marked ones, or with none marked, those after a sentence or a pause.
    static func paragraphStarts(_ chunks: [Chunk]) -> [Bool] {
        if chunks.contains(where: \.paragraph) { return chunks.indices.map { $0 == 0 || chunks[$0].paragraph } }
        return chunks.indices.map { k in
            guard k > 0, let last = chunks[k - 1].words.last, let first = chunks[k].words.first else { return true }
            return CaptionGrouping.startsParagraph(after: last.text, end: last.end, nextStart: first.start)
        }
    }
}

extension CaptionStyle {
    /// The caption's text size as a share of the style's normal size: under 1 when it had to shrink to fit.
    public func textScale(_ chunk: Chunk, options: CaptionOptions = CaptionOptions()) -> Double {
        CaptionPainter.layout(chunk, style: self, options: options).size / CaptionPainter.base
    }
}
