import SwiftUI

// Design tokens for the dark, glass-on-black editor look.
enum Theme {
    static let bg = Color.black

    // Cards: a soft white wash over black, brighter at the top edge.
    static let cardTop = Color.white.opacity(0.145)
    static let cardBottom = Color.white.opacity(0.055)
    static let cardStroke = Color.white.opacity(0.24)

    // Inset pane (the ANIMATIONS column) sits lighter than the card it lives in.
    static let paneFill = Color.white.opacity(0.10)
    static let paneStroke = Color.white.opacity(0.16)

    // Row buttons: animation presets, caption chips.
    static let rowFill = Color.white.opacity(0.14)
    static let rowStroke = Color.white.opacity(0.26)
    /// A shot marked "something is wrong" for Claude.
    static let flag = Color(red: 1, green: 0.42, blue: 0.36)
    static let rowActiveTop = Color.white.opacity(0.58)
    static let rowActiveBottom = Color.white.opacity(0.36)

    // Light-on-dark input fields, as in the reference design.
    static let fieldFill = Color.white.opacity(0.80)
    static let fieldText = Color.black.opacity(0.86)

    static let text = Color.white
    static let muted = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.40)

    /// One springy vocabulary for the whole app: things settle with a little overshoot
    /// instead of stopping dead.
    static let bounce = Animation.spring(response: 0.34, dampingFraction: 0.58)
    static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.72)
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.70)

    static let cardRadius: CGFloat = 24
    static let paneRadius: CGFloat = 22
    static let rowRadius: CGFloat = 18
    static let fieldRadius: CGFloat = 6
}

extension View {
    /// The main surface: gradient wash, hairline stroke, deep drop shadow.
    /// `outlined: false` — the big sections of the editor, whose edge is the shade alone.
    func card(_ radius: CGFloat = Theme.cardRadius, outlined: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(
            LinearGradient(colors: [Theme.cardTop, Theme.cardBottom], startPoint: .top, endPoint: .bottom),
            in: shape
        )
        .overlay(shape.stroke(outlined ? Theme.cardStroke : .clear, lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 18, y: 10)
    }

    /// Frosted floating surface — the video transport bar.
    @ViewBuilder func glassBar(_ radius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.30), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        }
    }
}

/// Capsule button used on the welcome screen.
struct GlassButtonStyle: ButtonStyle {
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .padding(.horizontal, 18).padding(.vertical, 11)
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(Theme.bounce, value: configuration.isPressed)
        } else {
            configuration.label
                .padding(.horizontal, 18).padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Color.white.opacity(configuration.isPressed ? 0.34 : 0.26), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(Theme.bounce, value: configuration.isPressed)
        }
    }
}

/// Thin-stroked glyph button: the top-right toolbar and the transport bar.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .light))
            .frame(width: size + 18, height: size + 10)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(Theme.bounce, value: configuration.isPressed)
    }
}

/// Section heading: SF Symbol + title, used down the settings column.
struct SectionLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label {
            Text(title).font(.system(size: 17, weight: .regular))
        } icon: {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 20)
        }
        .foregroundStyle(Theme.text)
    }
}

/// Small muted caption above a control.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted)
    }
}

struct HairlineDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.42)).frame(height: 1) }
}


/// Rows and chips: press in with a little give, release with a small overshoot.
struct BouncyButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.965
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(Theme.bounce, value: configuration.isPressed)
    }
}
