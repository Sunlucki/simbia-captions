import Foundation

/// Captions from the voice without the window, for `simbia captions` and the MCP server: what the Mac hears in the
/// voice clips becomes captions on the edit's clock, every word anchored to its place in the file (as the app's
/// «Создать субтитры» on a voice clip does), one paragraph per clip, grouped for the caption style. Given the
/// script, the captions are exactly its words, timed by what is heard.
public enum VoiceCaptions {
    /// Where a voice clip sits on the edit's clock, for a file of `length` seconds when the clip runs to its end.
    public static func span(of clip: AudioClip, length: Double? = nil) -> ClosedRange<Double> {
        let end = clip.duration.map { clip.start + $0 } ?? clip.start + max(0, (length ?? clip.inPoint) - clip.inPoint) / clip.speed
        return clip.start...max(clip.start, end)
    }

    /// The words the part of a voice clip that plays says, on the edit's clock, each anchored to its file.
    public static func heard(_ clip: AudioClip, projectURL: URL, locale: Locale, hints: [String], work: URL) async throws -> [ChunkWord] {
        let url = Project.resolve(clip.src, relativeTo: projectURL)
        let from = clip.inPoint
        var to = from
        if let duration = clip.duration { to += duration * clip.speed } else { to = try await SpeechAudio.length(of: url) }
        let words = try await MacSpeech.words(in: url, from: from, to: to, locale: locale, hints: hints, work: work)
        return words.map { w in
            ChunkWord(text: w.text, start: clip.start + (w.start - from) / clip.speed, end: clip.start + (min(w.end, to) - from) / clip.speed,
                      voice: VoiceAnchor(src: clip.src, from: w.start, to: min(w.end, to)))
        }
    }

    /// The script's words in order, timed by the heard ones: the longest run of the same words in order gives a word
    /// its heard time and anchor; the rest share the time between their timed neighbours (0.3 s a word past the
    /// first or last). `missing` are the script's words the voice was not heard saying.
    public static func timed(script: [String], by heard: [ChunkWord]) -> (words: [ChunkWord], missing: [String]) {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "colour", with: "color").filter { $0.isLetter || $0.isNumber } }
        let x = script.map(norm), y = heard.map { norm($0.text) }, n = x.count, m = y.count
        var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * (m + 1) + j] = !x[i].isEmpty && x[i] == y[j] ? dp[(i + 1) * (m + 1) + j + 1] + 1
                                                                   : max(dp[(i + 1) * (m + 1) + j], dp[i * (m + 1) + j + 1])
            }
        }
        var match = [Int?](repeating: nil, count: n), i = 0, j = 0
        while i < n, j < m {
            if !x[i].isEmpty, x[i] == y[j], dp[i * (m + 1) + j] == dp[(i + 1) * (m + 1) + j + 1] + 1 { match[i] = j; i += 1; j += 1 }
            else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] { i += 1 } else { j += 1 }
        }
        var out = script.indices.map { k in
            match[k].map { var w = heard[$0]; w.text = script[k]; return w } ?? ChunkWord(text: script[k], start: 0, end: 0)
        }
        var k = 0
        while k < n {
            guard match[k] == nil else { k += 1; continue }
            var e = k
            while e < n, match[e] == nil { e += 1 }
            if k > 0, e < n {
                let from = out[k - 1].end, step = max(0, out[e].start - from) / Double(e - k)
                for t in k..<e { out[t].start = from + step * Double(t - k); out[t].end = from + step * Double(t - k + 1) }
            } else if k > 0 {
                for t in k..<e { out[t].start = out[t - 1].end; out[t].end = out[t].start + 0.3 }
            } else if e < n {
                for t in (k..<e).reversed() { out[t].end = out[t + 1].start; out[t].start = max(0, out[t].end - 0.3) }
            }
            k = e
        }
        return (out, script.indices.filter { match[$0] == nil }.map { script[$0] })
    }

    /// Caption chunks for `style`, a paragraph per list, with ids that can't clash with the captions kept.
    public static func chunks(_ paragraphs: [[ChunkWord]], style: String) -> [Chunk] {
        CaptionGrouping.regroup(paragraphs, twoLine: CaptionStyle(id: style)?.twoLine ?? false, mark: true).map {
            var c = $0
            c.id = "c" + UUID().uuidString.prefix(8).lowercased()
            return c
        }
    }

    /// `made` in, the captions whose middle is over one of `spans` out (all of them when nil), no overlap left.
    public static func placing(_ made: [Chunk], into existing: [Chunk], replacing spans: [ClosedRange<Double>]?) -> [Chunk] {
        let kept = existing.filter { c in spans.map { s in !s.contains { $0.contains((c.start + c.end) / 2) } } ?? false }
        var list = (kept + made).sorted { $0.start < $1.start }
        for k in list.indices.dropLast() where list[k].end > list[k + 1].start {
            list[k].end = max(list[k].start + 0.05, list[k + 1].start)
            list[k].words = list[k].words.map { var w = $0; w.end = min(w.end, list[k].end); w.start = min(w.start, w.end); return w }
        }
        return list
    }
}
