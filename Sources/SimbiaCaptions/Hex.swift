import AppKit
import SwiftUI

extension String {
    private var hexDigits: String? {
        let raw = trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "#", with: "")
        guard raw.count == 6 || raw.count == 3, raw.allSatisfy(\.isHexDigit) else { return nil }
        guard raw.count == 3 else { return raw }
        return raw.map { "\($0)\($0)" }.joined()
    }

    /// (r, g, b) in 0...255, or nil when the string is not a hex colour.
    var rgb255: (Int, Int, Int)? {
        guard let digits = hexDigits, let value = Int(digits, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    var color: Color? {
        guard let (r, g, b) = rgb255 else { return nil }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var normalizedHex: String { hexDigits.map { "#\($0)" } ?? self }

    /// ASS stores colour as &HAABBGGRR — byte-reversed from RGB, alpha 00 = opaque.
    var assColor: String? {
        guard let (r, g, b) = rgb255 else { return nil }
        return String(format: "&H00%02X%02X%02X", b, g, r)
    }
}

extension Color {
    /// "#RRGGBB" in sRGB.
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    var isLight: Bool {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return false }
        let luma = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return luma > 0.62
    }
}

/// Backplate geometry, as multiples of the font size. Shared by the preview and the burn-in
/// so what you see in the player is what libass draws.
enum Plate {
    static let padX = 0.34
    static let padY = 0.22
    static let radius = 0.30
}
