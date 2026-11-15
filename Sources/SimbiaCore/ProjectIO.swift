import Foundation

extension Project {
    // MARK: File

    public static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Project.self, from: data)
        } catch let error as DecodingError {
            throw ProjectError.unreadable(url.lastPathComponent, Self.describe(error))
        }
    }

    /// The file as it would be written: keys sorted and times rounded to the millisecond, so the
    /// same edit always produces the same bytes and a diff shows only what changed.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(normalized())
    }

    /// Writes through a temporary file and a rename, so a reader never sees half a project.
    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    /// Times to 1 ms, gains to 1/1000 — float noise must not make two equal edits differ on disk.
    public func normalized() -> Project {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        var p = self
        p.duration = r(duration)
        p.shots = shots.map { var s = $0; s.start = r(s.start); s.end = r(s.end); s.inPoint = r(s.inPoint); return s }
        p.layers = layers.map { var s = $0; s.start = r(s.start); s.end = r(s.end); s.inPoint = r(s.inPoint); return s }
        p.audio = audio.map {
            var a = $0; a.start = r(a.start); a.inPoint = r(a.inPoint); a.duration = a.duration.map(r)
            a.gain = r(a.gain); a.fadeIn = r(a.fadeIn); a.fadeOut = r(a.fadeOut); return a
        }
        p.overlays = overlays.map { var o = $0; o.start = r(o.start); o.duration = o.duration.map(r); return o }
        p.captions.chunks = captions.chunks.map { chunk in
            var c = chunk; c.start = r(c.start); c.end = r(c.end)
            c.words = chunk.words.map { var w = $0; w.start = r(w.start); w.end = r(w.end); return w }
            return c
        }
        p.titles = titles.map { var t = $0; t.start = r(t.start); t.duration = r(t.duration); return t }
        return p
    }

    // MARK: Paths

    /// A path from the project as a file URL: absolute, `~/…`, or relative to the project's folder.
    public static func resolve(_ path: String, relativeTo projectURL: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || projectURL == nil { return URL(fileURLWithPath: expanded) }
        return projectURL!.deletingLastPathComponent().appending(path: expanded)
    }

    // MARK: Lookup

    public func shot(at time: Double) -> Shot? {
        shots.first { time >= $0.start && time < $0.end } ?? (time >= duration ? shots.last : nil)
    }

    public func chunk(at time: Double) -> Chunk? {
        captions.chunks.first { time >= $0.start && time < $0.end }
    }

    public func titles(at time: Double) -> [TitleItem] {
        titles.filter { time >= $0.start && time < $0.end }
    }

    // MARK: Checks

    /// Everything that would make the edit render wrongly, in plain words.
    public func problems(relativeTo projectURL: URL?) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        func missing(_ path: String) -> Bool { !fm.fileExists(atPath: Self.resolve(path, relativeTo: projectURL).path) }

        if duration <= 0 { out.append("duration is \(duration)") }
        if canvas.width <= 0 || canvas.height <= 0 || canvas.fps <= 0 { out.append("bad canvas \(canvas)") }

        let ordered = shots.sorted { $0.start < $1.start }
        if ordered != shots { out.append("shots are not in time order") }
        for (i, s) in ordered.enumerated() {
            if s.end - s.start < 0.02 { out.append("shot \(s.id) is \(Int((s.end - s.start) * 1000)) ms long") }
            if missing(s.src) { out.append("shot \(s.id): file not found: \(s.src)") }
            if i == 0, s.start > 0.001 { out.append("gap before the first shot (\(s.start) s)") }
            if i > 0 {
                let gap = s.start - ordered[i - 1].end
                if abs(gap) > 0.001 { out.append(gap > 0 ? "gap of \(fmt3(gap)) s before shot \(s.id)" : "shot \(s.id) overlaps the previous one by \(fmt3(-gap)) s") }
            }
        }
        if let last = ordered.last, last.end < duration - 0.001 { out.append("picture ends at \(fmt3(last.end)) s, edit at \(fmt3(duration)) s") }

        for a in audio where missing(a.src) { out.append("audio \(a.id): file not found: \(a.src)") }
        for a in audio where a.start < 0 { out.append("audio \(a.id) starts before 0 (\(fmt3(a.start)) s) — its head is cut") }
        for t in titles where t.start < 0 { out.append("title \(t.id) starts before 0") }
        for o in overlays where missing(o.src) { out.append("overlay \(o.id): not found: \(o.src)") }
        for v in layers where missing(v.src) { out.append("layer \(v.id): file not found: \(v.src)") }

        if CaptionStyle(id: captions.style) == nil, captions.style != "legacy" { out.append("unknown caption style \(captions.style)") }
        for (i, c) in captions.chunks.enumerated() {
            if c.words.isEmpty { out.append("caption \(c.id) has no words") }
            if c.end <= c.start { out.append("caption \(c.id) ends before it starts") }
            if i > 0, c.start < captions.chunks[i - 1].end - 0.001 { out.append("caption \(c.id) overlaps the previous one") }
            for w in c.words where w.start < c.start - 0.001 || w.start > c.end + 0.001 {
                out.append("caption \(c.id): word \"\(w.text)\" starts outside the caption")
            }
        }
        for t in titles where TitleStyle(id: t.style) == nil { out.append("title \(t.id): unknown style \(t.style)") }
        return out
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "missing \"\(key.stringValue)\" at \(path(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(path(ctx))"
        @unknown default: return error.localizedDescription
        }
    }
}

public enum ProjectError: LocalizedError {
    case unreadable(String, String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let file, let why): return "\(file): \(why)"
        }
    }
}

func fmt3(_ value: Double) -> String { String(format: "%.3f", value) }
