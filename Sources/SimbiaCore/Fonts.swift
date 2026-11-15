import CoreText
import Foundation

/// The fonts the caption and title styles are drawn with, loaded from the bundled files — the same
/// files the web reference uses — so a weight-800 Montserrat here is the web's weight-800 Montserrat.
public enum FontLibrary {
    /// One face of a bundled file: the file plus the variation axes CSS would set.
    public struct Face: Hashable, Sendable {
        public let file: String
        public let weight: Double?
        public init(_ file: String, weight: Double? = nil) { self.file = file; self.weight = weight }

        public static let montserrat800 = Face("Montserrat[wght].ttf", weight: 800)
        public static let playfairItalic800 = Face("PlayfairDisplay-Italic[wght].ttf", weight: 800)
        public static let archivoBlack = Face("ArchivoBlack-Regular.ttf")
        public static let dmSans700 = Face("DMSans[opsz,wght].ttf", weight: 700)
        public static let dmSerifItalic = Face("DMSerifDisplay-Italic.ttf")
        public static let poppins700 = Face("Poppins-Bold.ttf")
        public static let caveat700 = Face("Caveat[wght].ttf", weight: 700)
        public static let interTight800 = Face("InterTight[wght].ttf", weight: 800)
        public static let frauncesItalic700 = Face("Fraunces-Italic[SOFT,WONK,opsz,wght].ttf", weight: 700)
        public static let inter400 = Face("Inter-Regular.otf")
        public static let inter600 = Face("Inter-SemiBold.otf")
        public static let inter700 = Face("Inter-Bold.otf")
    }

    /// Where the bundled files are: the app's Resources/Fonts, the app next to the CLI, or the source tree.
    public static let directory: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: "Fonts")) }
        // the executable's real place — argv[0] is only "simbia" when it is run from the PATH
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appending(path: "../Simbia Captions.app/Contents/Resources/Fonts"))
        candidates.append(exe.appending(path: "../../../Assets/Fonts"))                    // .build/<config>/simbia
        candidates.append(URL(fileURLWithPath: #filePath).appending(path: "../../../Assets/Fonts"))
        return candidates.map(\.standardizedFileURL).first { FileManager.default.fileExists(atPath: $0.appending(path: "Poppins-Bold.ttf").path) }
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: CTFontDescriptor] = [:]

    /// The face at `size` px. Variable fonts get CSS's instance: the weight, and `opsz` = the size
    /// (font-optical-sizing: auto), clamped by the font to its own range.
    public static func font(_ face: Face, size: Double) -> CTFont {
        guard let base = descriptor(face.file) else { return CTFontCreateWithName("Helvetica" as CFString, size, nil) }
        var axes: [NSNumber: NSNumber] = [:]
        if let weight = face.weight { axes[NSNumber(value: tag("wght"))] = NSNumber(value: weight) }
        if face.file.contains("opsz") { axes[NSNumber(value: tag("opsz"))] = NSNumber(value: size) }
        let descriptor = axes.isEmpty ? base
            : CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontVariationAttribute: axes] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func descriptor(_ file: String) -> CTFontDescriptor? {
        lock.lock(); defer { lock.unlock() }
        if let d = descriptors[file] { return d }
        guard let url = directory?.appending(path: file),
              let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = list.first else { return nil }
        descriptors[file] = first
        return first
    }

    static func tag(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// The EMS Allure single-line script the lipstick writes with (an SVG font).
    public static var allureURL: URL? { directory?.appending(path: "EMSAllure.svg") }
}
