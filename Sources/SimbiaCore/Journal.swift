import Foundation

/// The shared journal of a projects folder (`_journal.jsonl`, one JSON line per stretch of edits): who changed which
/// project and what, in plain words. Bogdan sees in the project browser what Claude did; Claude reads what Bogdan
/// changed in the editor.
public struct JournalEntry: Codable, Equatable, Sendable {
    public var at: Date
    /// The project's file name.
    public var project: String
    public var revision: Int
    /// "app" (Bogdan, in the editor) or "claude".
    public var by: String
    public var changes: [String]

    public init(at: Date = Date(), project: String, revision: Int, by: String, changes: [String]) {
        self.at = at; self.project = project; self.revision = revision; self.by = by; self.changes = changes
    }
}

public enum Journal {
    public static func url(inFolder folder: URL) -> URL { folder.appending(path: "_journal.jsonl") }

    public static func append(_ entry: JournalEntry, inFolder folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let url = url(inFolder: folder)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// The newest entries first; only those for `project` when it is given.
    public static func read(inFolder folder: URL, project: String? = nil, limit: Int = 50) -> [JournalEntry] {
        guard let text = try? String(contentsOf: url(inFolder: folder), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [JournalEntry] = []
        for line in text.split(separator: "\n").reversed() {
            guard let entry = try? decoder.decode(JournalEntry.self, from: Data(line.utf8)) else { continue }
            if let project, entry.project != project { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}

public enum ProjectStatus: String, CaseIterable, Sendable {
    case new, review, done

    public init(_ raw: String?) { self = raw.flatMap(ProjectStatus.init(rawValue:)) ?? .new }

    public var name: String {
        switch self {
        case .new: "Новый"
        case .review: "На проверке"
        case .done: "Готово"
        }
    }
}

extension Project {
    /// What changed from `old` to this, in plain words. A ripple edit moves everything after it, so moves alone are
    /// not listed — what got longer or shorter, appeared, went or was retyped is.
    public func changes(from old: Project) -> [String] {
        var out: [String] = []
        func s2(_ x: Double) -> String { String(format: "%.2f", x) }
        func file(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        func quote(_ text: String) -> String { "«" + (text.count > 40 ? text.prefix(38) + "…" : text) + "»" }

        if ProjectStatus(old.status) != ProjectStatus(status) { out.append("статус: \(ProjectStatus(old.status).name) → \(ProjectStatus(status).name)") }
        let oldTasks = old.tasks ?? [], newTasks = tasks ?? []
        for t in newTasks {
            if let o = oldTasks.first(where: { $0.text == t.text }) {
                if !o.done, t.done { out.append("✓ \(quote(t.text))") } else if o.done, !t.done { out.append("снова в работе \(quote(t.text))") }
            } else { out.append("+ задача \(quote(t.text))") }
        }
        for t in oldTasks where !newTasks.contains(where: { $0.text == t.text }) { out.append("− задача \(quote(t.text))") }
        if old.brief != brief { out.append(old.brief == nil ? "+ бриф" : "бриф обновлён") }

        // shots
        let order = shots.sorted { $0.start < $1.start }
        let before = Dictionary(old.shots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func shotName(_ s: Shot) -> String { "шот \((order.firstIndex { $0.id == s.id } ?? 0) + 1) " + quote(s.label ?? file(s.src)) }
        for s in order {
            guard let o = before[s.id] else { out.append("+ " + shotName(s)); continue }
            guard o != s else { continue }
            var what: [String] = []
            if o.src != s.src { what.append("другой клип " + quote(file(s.src))) }
            if abs(o.duration - s.duration) > 0.005 { what.append("длина \(s2(o.duration)) → \(s2(s.duration)) с") }
            if abs(o.inPoint - s.inPoint) > 0.005, o.src == s.src { what.append("с \(s2(o.inPoint)) → \(s2(s.inPoint)) с клипа") }
            if abs(o.speed - s.speed) > 0.0005 { what.append("скорость ×\(String(format: "%.2f", o.speed)) → ×\(String(format: "%.2f", s.speed))") }
            if o.grade != s.grade { what.append("цвет") }
            if o.scale != s.scale || o.panX != s.panX || o.panY != s.panY || o.rotation != s.rotation || o.keys != s.keys || o.zoom != s.zoom || o.flip != s.flip {
                what.append("кадр")
            }
            if !what.isEmpty { out.append(shotName(s) + ": " + what.joined(separator: ", ")) }
        }
        for s in old.shots where !shots.contains(where: { $0.id == s.id }) { out.append("− шот " + quote(s.label ?? file(s.src))) }
        let ids = order.map(\.id).filter { before[$0] != nil }
        let oldIDs = old.shots.sorted { $0.start < $1.start }.map(\.id).filter { id in shots.contains { $0.id == id } }
        if ids != oldIDs { out.append("порядок шотов") }
        for l in layers where !old.layers.contains(where: { $0.id == l.id }) { out.append("+ наложение " + quote(l.label ?? file(l.src))) }
        for l in old.layers where !layers.contains(where: { $0.id == l.id }) { out.append("− наложение " + quote(l.label ?? file(l.src))) }
        for l in layers { if let o = old.layers.first(where: { $0.id == l.id }), o != l, o.src != l.src || abs(o.duration - l.duration) > 0.005 { out.append("наложение " + quote(l.label ?? file(l.src))) } }

        // sound: a ripple edit splits clips, so a file counts as added or gone only as a whole
        let files = Set(audio.map(\.src)), oldFiles = Set(old.audio.map(\.src))
        for a in audio where !oldFiles.contains(a.src) { out.append("+ звук " + quote(a.label ?? file(a.src))) }
        for a in old.audio where !files.contains(a.src) { out.append("− звук " + quote(a.label ?? file(a.src))) }
        for a in audio {
            guard let o = old.audio.first(where: { $0.id == a.id }) else { continue }
            if abs(o.gain - a.gain) > 0.0005 { out.append("громкость " + quote(a.label ?? file(a.src)) + ": \(String(format: "%.3f", o.gain)) → \(String(format: "%.3f", a.gain))") }
            if a.role == .music, abs(o.start - a.start) > 0.005 || o.inPoint != a.inPoint { out.append("музыка сдвинута") }
        }

        // captions
        if old.captions.style != captions.style { out.append("стиль субтитров \(old.captions.style) → \(captions.style)") }
        if old.captions.uppercase != captions.uppercase || old.captions.italic != captions.italic || old.captions.accents != captions.accents
            || old.captions.lineSpacing != captions.lineSpacing || old.captions.entrance != captions.entrance {
            out.append("настройки субтитров")
        }
        let chunks = Dictionary(old.captions.chunks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var retimed = 0, moved = 0
        for c in captions.chunks {
            guard let o = chunks[c.id] else { out.append("+ субтитр " + quote(c.text)); continue }
            if o.text != c.text { out.append("субтитр " + quote(o.text) + " → " + quote(c.text)) }
            if o.x != c.x || o.y != c.y { moved += 1 }
            if abs((o.end - o.start) - (c.end - c.start)) > 0.02 || zip(o.words, c.words).contains(where: { abs(($0.start - o.start) - ($1.start - c.start)) > 0.02 }) { retimed += 1 }
        }
        for c in old.captions.chunks where !captions.chunks.contains(where: { $0.id == c.id }) { out.append("− субтитр " + quote(c.text)) }
        if moved > 0 { out.append("место субтитров: \(moved)") }
        if retimed > 0 { out.append("время субтитров: \(retimed)") }

        // titles, graphics, colour, transitions
        for t in titles {
            guard let o = old.titles.first(where: { $0.id == t.id }) else { out.append("+ заголовок " + quote(t.text)); continue }
            if o.text != t.text { out.append("заголовок " + quote(o.text) + " → " + quote(t.text)) }
            if abs(o.duration - t.duration) > 0.01 { out.append("заголовок " + quote(t.text) + ": \(s2(o.duration)) → \(s2(t.duration)) с") }
            if o.x != t.x || o.y != t.y { out.append("заголовок " + quote(t.text) + ": место") }
            if o.style != t.style || o.kicker != t.kicker || o.reviews != t.reviews || o.stickers != t.stickers { out.append("заголовок " + quote(t.text) + ": оформление") }
        }
        for t in old.titles where !titles.contains(where: { $0.id == t.id }) { out.append("− заголовок " + quote(t.text)) }
        for m in overlays where !old.overlays.contains(where: { $0.id == m.id }) { out.append("+ графика " + quote(m.label ?? file(m.src))) }
        for m in old.overlays where !overlays.contains(where: { $0.id == m.id }) { out.append("− графика " + quote(m.label ?? file(m.src))) }
        for f in filters {
            guard let o = old.filters.first(where: { $0.id == f.id }) else { out.append("+ фильтр " + quote(f.label ?? "")); continue }
            if o.grade != f.grade || abs(o.duration - f.duration) > 0.01 { out.append("фильтр " + quote(f.label ?? "")) }
        }
        for f in old.filters where !filters.contains(where: { $0.id == f.id }) { out.append("− фильтр " + quote(f.label ?? "")) }
        if old.look != look { out.append(look == nil ? "− общий фильтр" : "общий фильтр") }
        if old.transitions != transitions { out.append("переходы: \(old.transitions.count) → \(transitions.count)") }
        if old.master != master { out.append("мастер звука") }
        if abs(old.duration - duration) > 0.01 { out.append("длина ролика \(s2(old.duration)) → \(s2(duration)) с") }
        return out
    }
}
