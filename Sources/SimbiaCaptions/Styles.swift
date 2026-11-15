import Foundation

/// A ready-made caption look. Picking one writes into `Look`, which the settings column
/// can then adjust — the preset is a starting point, not a lock.
struct StylePreset: Identifiable, Equatable {
    let id: String
    let title: String
    let font: String
    var bold = true
    var italic = false
    var uppercase = false
    var tracking = 0.0

    var text = "#FFFFFF"

    var fillOn = false
    var fill = "#0030D0"
    var fillShadow = false

    var outlineOn = true
    var outline = "#000000"
    var outlineWidth = 0.09

    var shadowOn = false
    var shadow = "#000000"
    var shadowDepth = 0.06

    var glow = 0.0

    func write(into look: inout Look) {
        look.font = font
        look.bold = bold
        look.italic = italic
        look.uppercase = uppercase
        look.tracking = tracking
        look.textColor = text
        look.fillOn = fillOn
        look.fillColor = fill
        look.fillShadow = fillShadow
        look.outlineOn = outlineOn
        look.outlineColor = outline
        look.outlineWidth = outlineWidth
        look.shadowOn = shadowOn
        look.shadowColor = shadow
        look.shadowDepth = shadowDepth
        look.glow = glow
    }

    /// Ten looks drawn from what short-form video actually uses. Every font ships with macOS.
    static let catalog: [StylePreset] = [
        StylePreset(id: "plate", title: "PLATE", font: "Helvetica Neue",
                    text: "#FFFFFF",
                    fillOn: true, fill: "#0030D0", fillShadow: true,
                    outlineOn: false),

        StylePreset(id: "hormozi", title: "HORMOZI", font: "Impact",
                    uppercase: true, text: "#FFE10A",
                    outlineOn: true, outline: "#000000", outlineWidth: 0.13,
                    shadowOn: true, shadow: "#000000", shadowDepth: 0.07),

        StylePreset(id: "beast", title: "BEAST", font: "Arial Black",
                    uppercase: true, tracking: 0.01, text: "#FFFFFF",
                    outlineOn: true, outline: "#000000", outlineWidth: 0.14,
                    shadowOn: true, shadow: "#000000", shadowDepth: 0.09),

        StylePreset(id: "clean", title: "CLEAN", font: "Helvetica Neue",
                    text: "#FFFFFF",
                    outlineOn: false,
                    shadowOn: true, shadow: "#000000", shadowDepth: 0.05),

        StylePreset(id: "neon", title: "NEON", font: "Futura",
                    uppercase: true, tracking: 0.04, text: "#EAFFFF",
                    outlineOn: true, outline: "#00E5FF", outlineWidth: 0.07,
                    shadowOn: true, shadow: "#0066FF", shadowDepth: 0.03,
                    glow: 5),

        StylePreset(id: "poster", title: "POSTER", font: "Phosphate",
                    uppercase: true, text: "#FFFFFF",
                    outlineOn: true, outline: "#111111", outlineWidth: 0.11),

        StylePreset(id: "retro", title: "RETRO", font: "Georgia",
                    italic: true, text: "#FFF3D6",
                    outlineOn: true, outline: "#7A1E12", outlineWidth: 0.08,
                    shadowOn: true, shadow: "#7A1E12", shadowDepth: 0.08),

        StylePreset(id: "mono", title: "MONO", font: "Menlo",
                    uppercase: true, tracking: 0.03, text: "#F2F2F2",
                    outlineOn: true, outline: "#000000", outlineWidth: 0.06),

        StylePreset(id: "highlight", title: "HIGHLIGHT", font: "Avenir Next",
                    uppercase: true, text: "#111111",
                    fillOn: true, fill: "#FFE10A",
                    outlineOn: false),

        // \blur softens the glyph itself, not just a halo, so SOFT leans on the shadow instead.
        StylePreset(id: "soft", title: "SOFT", font: "Avenir Next",
                    text: "#FFFFFF",
                    outlineOn: false,
                    shadowOn: true, shadow: "#000000", shadowDepth: 0.13),
    ]

    static func named(_ id: String) -> StylePreset { catalog.first { $0.id == id } ?? catalog[0] }
}
