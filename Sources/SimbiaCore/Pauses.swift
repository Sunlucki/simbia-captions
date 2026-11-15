import Foundation

extension Project {
    /// Silences longer than `minimum`, less `padding` beside the speech, that can be taken out — found in the
    /// sound itself, since Whisper stretches a word over the silence after it (by the words' gaps only when
    /// there is no voice to listen to). The silence at the start goes too; the one at the end only under the
    /// speaker's own picture, where it is not an end card.
    public func pauses(minimum: Double = 0.4, padding: Double = 0.08, voice: VoiceActivity?) -> [ClosedRange<Double>] {
        var silences: [(Double, Double)] = []
        if let voice {
            silences = voice.silences(longer: minimum).map { ($0.lowerBound, min($0.upperBound, duration)) }
        } else {
            let words = captions.chunks.flatMap(\.words).sorted { $0.start < $1.start }
            guard let first = words.first else { return [] }
            silences.append((0, first.start))
            var spoken = first.end
            for w in words.dropFirst() {
                silences.append((spoken, w.start))
                spoken = max(spoken, w.end)
            }
            silences.append((spoken, duration))
        }
        return silences.compactMap { a, b in
            guard b - a > minimum else { return nil }
            let head = a <= 0.001, tail = b >= duration - 0.001
            if tail, !speakerOnly(from: a) { return nil }
            let from = head ? 0 : a + padding, to = tail ? duration : b - padding
            return to - from >= 0.1 ? from...to : nil
        }
    }

    /// The edit with `ranges` taken out and everything after them moved up. The speaker's own picture and
    /// the voice are cut (a jump cut); other footage only gets shorter, music keeps playing.
    public func removing(_ ranges: [ClosedRange<Double>]) -> Project {
        var cuts: [ClosedRange<Double>] = []
        for r in ranges.map({ max(0, $0.lowerBound)...min(duration, $0.upperBound) }).sorted(by: { $0.lowerBound < $1.lowerBound })
        where r.upperBound - r.lowerBound > 0.001 {
            if let last = cuts.last, r.lowerBound <= last.upperBound {
                cuts[cuts.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                cuts.append(r)
            }
        }
        guard !cuts.isEmpty else { return self }

        /// A time on the new clock; one inside a cut lands where the cut was.
        func map(_ t: Double) -> Double {
            var removed = 0.0
            for r in cuts {
                if t >= r.upperBound { removed += r.upperBound - r.lowerBound }
                else if t > r.lowerBound { return r.lowerBound - removed }
                else { break }
            }
            return t - removed
        }
        /// What is left of [a, b] on the old clock.
        func kept(_ a: Double, _ b: Double) -> [(from: Double, to: Double)] {
            var out: [(Double, Double)] = [], from = a
            for r in cuts where r.upperBound > a && r.lowerBound < b {
                if r.lowerBound > from { out.append((from, r.lowerBound)) }
                from = max(from, r.upperBound)
            }
            if b > from { out.append((from, b)) }
            return out.filter { $0.1 - $0.0 > 0.001 }
        }

        var p = self
        p.duration = map(duration)
        let ordered = captions.chunks.sorted { $0.start < $1.start }
        p.captions.chunks = ordered.map { chunk in
            var c = chunk
            c.start = map(c.start)
            c.end = max(map(c.end), c.start + 0.05)
            c.words = c.words.map { var w = $0; w.start = map(w.start); w.end = map(w.end); return w }
            return c
        }
        // a caption that stayed up into a pause now ends a hair before the next one: no blink between them
        for k in p.captions.chunks.indices.dropLast()
        where cuts.contains(where: { ordered[k].end > $0.lowerBound - 0.001 && ordered[k].end < $0.upperBound + 0.001 })
            && p.captions.chunks[k + 1].start - p.captions.chunks[k].end < Self.bridged {
            p.captions.chunks[k].end = max(p.captions.chunks[k].end, p.captions.chunks[k + 1].start)
        }
        p.titles = titles.map { var t = $0; t.start = max(0, min(map(t.start), p.duration - t.duration)); return t }
        p.overlays = overlays.map { var o = $0; o.start = map(o.start); return o }
        p.layers = layers.map { var v = $0; let d = v.duration; v.start = map(v.start); v.end = v.start + d; return v }

        p.shots = []
        for s in shots.sorted(by: { $0.start < $1.start }) {
            let pieces = kept(s.start, s.end)
            guard let head = pieces.first else { continue }
            if speaker(s) {
                for (n, piece) in pieces.enumerated() {
                    var x = s
                    if n > 0 { x.id = Project.newID("s") }
                    x.start = map(piece.from)
                    x.end = x.start + (piece.to - piece.from)
                    x.inPoint = s.source(at: piece.from)
                    p.shots.append(x)
                }
            } else {
                var x = s
                x.start = map(head.from)
                x.end = x.start + pieces.reduce(0) { $0 + $1.to - $1.from }
                p.shots.append(x)
            }
        }

        p.audio = []
        for clip in audio {
            guard clip.role == .voice else { var x = clip; x.start = map(clip.start); p.audio.append(x); continue }
            let end = min(clip.duration.map { clip.start + $0 } ?? duration, duration)
            let pieces = kept(clip.start, end)
            for (n, piece) in pieces.enumerated() {
                var x = clip
                if n > 0 { x.id = Project.newID("a") }
                x.start = map(piece.from)
                x.inPoint = clip.source(at: piece.from)
                let last = n == pieces.count - 1
                x.duration = last && clip.duration == nil ? nil : piece.to - piece.from
                // a hard cut in room tone clicks: 20 ms fades where a pause came out
                x.fadeIn = abs(piece.from - clip.start) < 0.001 ? clip.fadeIn : 0.02
                x.fadeOut = abs(piece.to - end) < 0.001 ? clip.fadeOut : 0.02
                p.audio.append(x)
            }
        }
        return p
    }

    /// The speaker's own picture: a shot of the very file the voice comes from, in sync with it (at its speed).
    func speaker(_ shot: Shot) -> Bool {
        audio.contains { $0.role == .voice && $0.src == shot.src && abs($0.speed - shot.speed) < 0.001 && abs($0.source(at: shot.start) - shot.inPoint) < 0.05 }
    }

    /// Nothing but the speaker after `time`: no other footage, title or graphics.
    func speakerOnly(from time: Double) -> Bool {
        shots.filter { $0.end > time }.allSatisfy(speaker) && !titles.contains { $0.end > time } && !overlays.contains { $0.start >= time }
    }
}
