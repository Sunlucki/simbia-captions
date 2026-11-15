import Foundation

/// Turns timed words into caption chunks the way each family of styles shows them.
public enum CaptionGrouping {
    static let clauseEnd = CharacterSet(charactersIn: ".,:?!")
    static let sentenceEnd = CharacterSet(charactersIn: ".?!:")
    static let paragraphEnd = CharacterSet(charactersIn: ".?!…")

    static func ends(_ word: String, with set: CharacterSet) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”“’)»"))
        return trimmed.unicodeScalars.last.map(set.contains) ?? false
    }

    /// Where a paragraph starts when the captions mark none: after a sentence, or after a pause.
    public static func startsParagraph(after word: String, end: Double, nextStart: Double) -> Bool {
        ends(word, with: paragraphEnd) || nextStart - end >= 0.7
    }

    /// One-line styles (s1–s5): at most three words, split at punctuation — the rules the house
    /// renders used (V2–V5), so a regrouped project matches them.
    public static func oneLine(_ words: [ChunkWord]) -> [Chunk] {
        timed(oneLineGroups(words), minimum: 0.3, mergeShort: true)
    }

    /// Two-line styles (s6–s10): a sentence at a time, at most ten words, broken at commas when longer.
    public static func twoLine(_ words: [ChunkWord]) -> [Chunk] {
        timed(twoLineGroups(words), minimum: 0.6, mergeShort: false)
    }

    /// Regroups paragraph by paragraph, so no chunk spans two paragraphs. With `mark`, the first chunk
    /// of each paragraph is marked as its start.
    public static func regroup(_ paragraphs: [[ChunkWord]], twoLine: Bool, mark: Bool) -> [Chunk] {
        var groups: [[ChunkWord]] = [], starts: Set<Int> = []
        for words in paragraphs where !words.isEmpty {
            starts.insert(groups.count)
            groups += twoLine ? twoLineGroups(words) : oneLineGroups(words)
        }
        var chunks = timed(groups, minimum: twoLine ? 0.6 : 0.3, mergeShort: !twoLine, starts: starts)
        if !mark { for i in chunks.indices { chunks[i].paragraph = false } }
        return chunks
    }

    static func oneLineGroups(_ words: [ChunkWord]) -> [[ChunkWord]] {
        var clauses: [[ChunkWord]] = [], current: [ChunkWord] = []
        for w in words {
            current.append(w)
            if ends(w.text, with: clauseEnd) { clauses.append(current); current = [] }
        }
        if !current.isEmpty { clauses.append(current) }

        var merged: [[ChunkWord]] = [], carry: [ChunkWord] = []
        for clause in clauses {
            let c = carry + clause
            carry = []
            if c.count == 1, !ends(c[0].text, with: sentenceEnd) { carry = c; continue }
            merged.append(c)
        }
        if !carry.isEmpty {
            if merged.isEmpty { merged.append(carry) } else { merged[merged.count - 1] += carry }
        }

        var groups: [[ChunkWord]] = []
        for c in merged {
            let n = c.count
            let k = n == 4 ? 2 : (n + 2) / 3
            var i = 0
            for part in 0..<k {
                let size = n / k + (part < n % k ? 1 : 0)
                groups.append(Array(c[i..<i + size]))
                i += size
            }
        }
        return groups
    }

    static func twoLineGroups(_ words: [ChunkWord]) -> [[ChunkWord]] {
        var sentences: [[ChunkWord]] = [], current: [ChunkWord] = []
        for (i, w) in words.enumerated() {
            if let last = current.last, w.start - last.end > 0.7 { sentences.append(current); current = [] }
            current.append(w)
            if ends(w.text, with: sentenceEnd) || i == words.count - 1 { sentences.append(current); current = [] }
        }
        if !current.isEmpty { sentences.append(current) }

        var groups: [[ChunkWord]] = []
        for s in sentences {
            var rest = s
            while rest.count > 10 {
                let window = rest.prefix(10)
                let comma = window.indices.reversed().first { $0 >= 3 && ends(rest[$0].text, with: CharacterSet(charactersIn: ",;")) }
                // no comma: equal pieces of at most ten words (11 → 6 + 5, 21 → 7 + 7 + 7)
                let pieces = (rest.count + 9) / 10
                let cut = comma.map { $0 + 1 } ?? (rest.count + pieces - 1) / pieces
                groups.append(Array(rest[..<cut]))
                rest = Array(rest[cut...])
            }
            if !rest.isEmpty { groups.append(rest) }
        }
        return groups
    }

    /// On screen from the first word to the next chunk (or the last word + 0.4 s, at most + 0.6 s).
    /// A too-short chunk never merges into one that starts a paragraph (`starts`, by group index).
    static func timed(_ groups: [[ChunkWord]], minimum: Double, mergeShort: Bool, starts: Set<Int> = []) -> [Chunk] {
        var out: [Chunk] = []
        for (k, g) in groups.enumerated() where !g.isEmpty {
            let next = k + 1 < groups.count ? groups[k + 1].first?.start : nil
            let end = min(next ?? (g.last!.end + 0.4), g.last!.end + 0.6)
            out.append(Chunk(id: "c\(out.count + 1)", start: g[0].start, end: max(end, g[0].start + 0.05), words: g,
                             paragraph: starts.contains(k)))
        }
        var k = 0
        while k < out.count - 1 {
            if out[k].end - out[k].start < minimum {
                let text = out[k].text + " " + out[k + 1].text
                if mergeShort, !out[k + 1].paragraph, out[k].words.count + out[k + 1].words.count <= 4, text.count <= 24,
                   !ends(out[k].words.last!.text, with: sentenceEnd) {
                    out[k + 1] = Chunk(id: out[k + 1].id, start: out[k].start, end: out[k + 1].end,
                                       words: out[k].words + out[k + 1].words, paragraph: out[k].paragraph)
                    out.remove(at: k)
                    continue
                }
                // longer, but never past the next chunk's first word: pushing it would add up into drift
                let next = out[k + 1].words.first?.start ?? out[k + 1].start
                out[k].end = max(out[k].end, min(out[k].start + minimum, next))
                out[k + 1].start = max(out[k + 1].start, out[k].end)
            }
            k += 1
        }
        // the last chunk is never visited above: a start pushed past its end must not leave it inside out
        if let last = out.indices.last, out[last].end < out[last].start + 0.05 { out[last].end = out[last].start + minimum }
        for i in out.indices { out[i].id = "c\(i + 1)" }
        return out
    }
}
