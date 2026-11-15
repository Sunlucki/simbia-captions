import Foundation

/// A customer review for the Trustpilot card (title style T8).
public struct Review: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var date: String
    public var text: String
    /// The reviewer's photo: a path in the library's folder (`av/…`) or anywhere; none draws her initials.
    public var avatar: String?
    public var id: String { name + "|" + date + "|" + text.prefix(24) }

    public init(name: String, date: String, text: String, avatar: String? = nil) {
        self.name = name; self.date = date; self.text = text; self.avatar = avatar
    }
}

/// The reviews to put on screen: `reviews.json` in `_ASSETS/TRUSTPILOT` next to the footage library, the
/// reviewers' photos in `av/` beside it.
public struct ReviewLibrary: Sendable {
    /// A photo in `av/`, with the name its file carries ("00_Rebecca_Kurdy.png" → "Rebecca Kurdy").
    public struct Photo: Identifiable, Sendable {
        public let name: String
        public let url: URL
        public var id: String { url.path }
    }

    public let folder: URL
    public private(set) var reviews: [Review]
    public let photos: [Photo]

    public static let file = "reviews.json"

    /// `_ASSETS/TRUSTPILOT` in the project's folder or any folder above it — where the footage library sits.
    public static func find(near projectURL: URL?) -> URL? {
        var folder = projectURL?.deletingLastPathComponent()
        while let dir = folder, dir.path != "/" {
            for candidate in [dir.appending(path: "_ASSETS/TRUSTPILOT"), dir.appending(path: "TRUSTPILOT")]
            where FileManager.default.fileExists(atPath: candidate.appending(path: file).path) {
                return candidate
            }
            folder = dir.deletingLastPathComponent()
        }
        return nil
    }

    public static func load(_ folder: URL) throws -> ReviewLibrary {
        let reviews = try JSONDecoder().decode([Review].self, from: Data(contentsOf: folder.appending(path: file)))
        let av = folder.appending(path: "av")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: av.path)) ?? []
        let photos = names.filter { !$0.hasPrefix(".") && ["png", "jpg", "jpeg", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Photo(name: photoName($0), url: av.appending(path: $0)) }
        return ReviewLibrary(folder: folder, reviews: reviews, photos: photos)
    }

    /// The name a photo's file carries ("00_Rebecca_Kurdy.png" → "Rebecca Kurdy").
    public static func photoName(_ path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem.split(separator: "_").drop { $0.allSatisfy(\.isNumber) }.joined(separator: " ")
    }

    /// The review's photo on disk, if it has one.
    public func photo(of review: Review) -> URL? {
        guard let avatar = review.avatar, !avatar.isEmpty else { return nil }
        return avatar.hasPrefix("/") ? URL(fileURLWithPath: avatar) : folder.appending(path: avatar)
    }

    /// Adds a review (replacing one by the same person on the same date) and writes the file.
    public mutating func save(_ review: Review) throws {
        var review = review
        if let avatar = review.avatar, avatar.hasPrefix(folder.path + "/") { review.avatar = String(avatar.dropFirst(folder.path.count + 1)) }
        if let i = reviews.firstIndex(where: { $0.name == review.name && $0.date == review.date }) { reviews[i] = review } else { reviews.append(review) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(reviews).write(to: folder.appending(path: Self.file), options: .atomic)
    }
}

extension TitleItem {
    /// A Trustpilot card's reviewer and date, kept in the line underneath as "name|date".
    public var reviewer: (name: String, date: String) {
        let parts = (kicker ?? "").split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}

extension TitleItem {
    /// A Trustpilot graphic (T8–T10): on the Graphics track and in the Graphics tab, not with the titles.
    public var isGraphic: Bool { (TitleStyle(id: style)?.number ?? 0) >= 8 }
}
