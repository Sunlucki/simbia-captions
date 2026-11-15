import Foundation

/// Words that must always be spelt one way — the brand first. Whisper is told them before it listens,
/// and a word it still hears slightly differently ("Symbia" for "Simbia") is put right. One word or phrase per line in
/// ~/Library/Application Support/Simbia Captions/Glossary.txt, shared by the app and `simbia`.
public struct Glossary: Equatable, Sendable {
    public var words: [String]

    public init(words: [String]) { self.words = words }

    /// Without the file: the brand's name (Brand.json), if there is one.
    public static var defaults: [String] { Brand.current.name.isEmpty ? [] : [Brand.current.name] }

    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Simbia Captions/Glossary.txt")
    }

    public static func load() -> Glossary {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Glossary(words: defaults) }
        return Glossary(words: text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (words.joined(separator: "\n") + "\n").write(to: Self.file, atomically: true, encoding: .utf8)
    }

    /// What whisper is primed with, so it spells these words this way from the start.
    public var prompt: String { words.isEmpty ? "" : words.joined(separator: ", ") + "." }

    /// The glossary's spelling for a word heard slightly differently — punctuation and a possessive kept —
    /// or nil when the word is right or nothing like any entry.
    public func correction(for word: String) -> String? {
        let edges = CharacterSet.punctuationCharacters.union(.symbols)
        var core = word.trimmingCharacters(in: edges)
        guard !core.isEmpty, let range = word.range(of: core) else { return nil }
        var suffix = String(word[range.upperBound...])
        for possessive in ["'s", "’s"] where core.lowercased().hasSuffix(possessive) {
            core = String(core.dropLast(2))
            suffix = possessive + suffix
        }
        guard !words.contains(core) else { return nil }
        let prefix = String(word[..<range.lowerBound])
        let heard = core.lowercased()
        for entry in words where !entry.contains(" ") {
            let right = entry.lowercased()
            let close = heard == right
                || (heard.count >= 5 && Self.distance(heard, right) <= (right.count >= 7 ? 2 : 1))
            if close { return prefix + entry + suffix }
        }
        return nil
    }

    /// Edits (insert, delete, change a letter) from one word to the other.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
