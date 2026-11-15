import SwiftUI

// MARK: - Settings column

struct SettingsPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 15) {
                SectionLabel(title: job.s.typography, symbol: "textformat")
                VStack(alignment: .leading, spacing: 9) {
                    FontMenu(job: job)
                    HStack(spacing: 15) {
                        glyph("T", active: !job.look.bold && !job.look.italic, weight: .regular) {
                            job.edit { $0.look.bold = false; $0.look.italic = false }
                        }
                        glyph("B", active: job.look.bold, weight: .bold) { job.edit { $0.look.bold.toggle() } }
                        glyph("I", active: job.look.italic, weight: .regular, italic: true) {
                            job.edit { $0.look.italic.toggle() }
                        }
                        glyph("AA", active: job.look.uppercase, weight: .medium) {
                            job.edit { $0.look.uppercase.toggle() }
                        }
                        .help(job.s.uppercase)
                        Spacer()
                        ForEach(TextAlign.allCases) { option in
                            Button { job.edit { $0.look.alignment = option } } label: {
                                Image(systemName: option.symbol).font(.system(size: 14))
                                    .foregroundStyle(job.look.alignment == option ? Theme.text : Theme.faint)
                            }
                            .buttonStyle(.plain).help(job.s.alignHint(option))
                        }
                    }
                    FieldLabel(job.s.split).padding(.top, 5)
                    HStack(spacing: 16) {
                        ForEach(CaptionSplit.allCases) { option in
                            glyph(option.glyph, active: job.split == option, weight: .medium) {
                                job.edit { $0.split = option }
                            }
                            .help(job.s.splitTitle(option))
                        }
                    }
                }

                Stepped(title: job.s.size, symbol: "arrow.up.left.and.arrow.down.right",
                        value: $job.look.size, range: 18...200, unit: "px", job: job)

                Stepped(title: job.s.tracking, symbol: "arrow.left.and.right.text.vertical",
                        value: $job.look.tracking, range: 0...0.2, unit: "em", precision: 2, job: job)

                SectionLabel(title: job.s.position, symbol: "arrow.up.and.down.and.arrow.left.and.right")
                HStack(spacing: 8) {
                    FieldLabel(job.s.dragInPlayer)
                    Spacer()
                    Button(job.s.reset) { job.edit { $0.look.posX = 0.5; $0.look.posY = 0.72 } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }

                HairlineDivider()

                SectionLabel(title: job.s.colorSection, symbol: "paintpalette")
                FieldLabel(job.s.textColor)
                HexField(hex: $job.look.textColor, job: job) { job.pushHistory() }

                Toggled(title: job.s.fillBackground, isOn: $job.look.fillOn, job: job) {
                    HexField(hex: $job.look.fillColor, filled: true, job: job) { job.pushHistory() }
                    Check(job.s.fillShadow, isOn: $job.look.fillShadow, job: job)
                }

                Toggled(title: job.s.outline, isOn: $job.look.outlineOn, job: job) {
                    HexField(hex: $job.look.outlineColor, filled: true, job: job) { job.pushHistory() }
                    Ranged(value: $job.look.outlineWidth, range: 0...0.25, label: job.s.thickness, job: job)
                }

                Toggled(title: job.s.textShadow, isOn: $job.look.shadowOn, job: job) {
                    HexField(hex: $job.look.shadowColor, filled: true, job: job) { job.pushHistory() }
                    Ranged(value: $job.look.shadowDepth, range: 0...0.25, label: job.s.offset, job: job)
                }

                HairlineDivider()

                Ranged(value: $job.look.glow, range: 0...14, label: job.s.glow, job: job)

                HairlineDivider()

                SectionLabel(title: job.s.accent, symbol: "sparkles")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.selected == nil ? job.s.selectCaption : job.s.makeAccent)
                            .font(.system(size: 13))
                            .foregroundStyle(job.selected == nil ? Theme.faint : Theme.text)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { job.selectedCue?.accent ?? false },
                            set: { _ in if let id = job.selected { job.toggleAccent(id) } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.white)
                            .disabled(job.selected == nil)
                    }
                    if job.accentedCount > 0 {
                        FieldLabel("\(job.s.accentedCount): \(job.accentedCount)")
                    }
                    AccentFontMenu(job: job)
                    Ranged(value: $job.look.accentAngle, range: -15...15, label: job.s.tilt, job: job)
                    Ranged(value: $job.look.accentScale, range: 1...1.8, label: job.s.size, job: job)
                    Toggled(title: job.s.ownColor, isOn: $job.look.accentColorOn, job: job) {
                        HexField(hex: $job.look.accentColor, filled: true, job: job) { job.pushHistory() }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }

    private func glyph(_ label: String, active: Bool, weight: Font.Weight, italic: Bool = false,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label.count > 1 ? 13 : 17, weight: weight))
                .italic(italic)
                .foregroundStyle(active ? Theme.text : Theme.faint)
                .frame(minWidth: 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small controls

/// A section that can be switched off entirely — the background fill, outline and shadow.
private struct Toggled<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    let job: Job
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(isOn ? Theme.text : Theme.muted)
                Spacer()
                Toggle("", isOn: Binding(get: { isOn }, set: { new in job.pushHistory(); isOn = new }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.white)
            }
            if isOn { content }
        }
        .animation(Theme.settle, value: isOn)
    }
}

private struct Check: View {
    let title: String
    @Binding var isOn: Bool
    let job: Job
    init(_ title: String, isOn: Binding<Bool>, job: Job) {
        self.title = title; self._isOn = isOn; self.job = job
    }
    var body: some View {
        Button { job.pushHistory(); isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(isOn ? Theme.text : Theme.muted)
        }
        .buttonStyle(.plain)
    }
}

private struct Ranged: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let job: Job

    var body: some View {
        HStack(spacing: 8) {
            FieldLabel(label)
            Slider(value: $value, in: range) { editing in if editing { job.pushHistory() } }
                .tint(.white)
        }
    }
}

private struct Stepped: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var precision = 0
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(title: title, symbol: symbol)
                Spacer()
                Text(precision == 0 ? "\(Int(value)) \(unit)" : String(format: "%.2f %@", value, unit))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            Slider(value: $value, in: range) { editing in if editing { job.pushHistory() } }
                .tint(.white)
        }
    }
}

/// Light-on-dark dropdown that reads as the reference design's text field.
private struct FontMenu: View {
    @ObservedObject var job: Job

    var body: some View {
        Menu {
            ForEach(job.fonts, id: \.self) { name in
                Button(name) { job.edit { $0.look.font = name } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(job.look.font).font(.custom(job.look.font, size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .foregroundStyle(Theme.fieldText)
        .tint(Theme.fieldText)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
    }
}

private struct AccentFontMenu: View {
    @ObservedObject var job: Job

    var body: some View {
        Menu {
            ForEach(job.fonts, id: \.self) { name in
                Button(name) { job.edit { $0.look.accentFont = name } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(job.look.accentFont).font(.custom(job.look.accentFont, size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .foregroundStyle(Theme.fieldText)
        .tint(Theme.fieldText)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
    }
}

/// Hex colour entry. `filled` paints the field with the colour itself.
private struct HexField: View {
    @Binding var hex: String
    var filled = false
    var job: Job?
    let onCommit: () -> Void

    @State private var draft = ""
    /// What the binding held when the field took focus. If it has changed since — a style
    /// preset was applied, or the user hit undo — the half-typed draft is stale and must not
    /// be written back over the newer value on blur.
    @State private var baseline = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13).monospaced())
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                    .stroke(draft.color == nil ? Color.red.opacity(0.9) : Color.white.opacity(0.25), lineWidth: 1)
            )
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                job?.textEditing = isFocused
                if isFocused { baseline = hex } else { commit() }
            }
            .onAppear { draft = hex; baseline = hex }
            .onChange(of: hex) { _, value in if !focused { draft = value } }
            .onDisappear { if focused { job?.textEditing = false } }
    }

    private var background: Color {
        guard filled, let parsed = hex.color else { return Theme.fieldFill }
        return parsed
    }

    private var foreground: Color {
        guard filled, let parsed = hex.color else { return Theme.fieldText }
        return parsed.isLight ? Theme.fieldText : .white
    }

    private func commit() {
        // Something else changed the colour while we held focus — drop our draft, keep theirs.
        guard hex == baseline else { draft = hex; baseline = hex; return }
        guard draft.color != nil else { draft = hex; return }
        guard draft.normalizedHex != hex else { return }
        onCommit()
        hex = draft.normalizedHex
        draft = hex
        baseline = hex
    }
}

// MARK: - Styles + animations library

/// Style first, then the animation — the two tabs of the right-hand pane.
/// The Classic tab, laid into the style library like the other tabs: one row of choices — the presets, how a
/// caption comes in, how it goes, the settings — and under it the cards or the settings themselves.
struct ClassicPanel: View {
    @ObservedObject var job: Job
    @State private var pane = Pane.styles

    enum Pane: CaseIterable { case styles, entrance, exit, settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                ForEach(Pane.allCases, id: \.self) { option in
                    Button { withAnimation(Theme.snappy) { pane = option } } label: {
                        Text(title(option)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 30)
                            .foregroundStyle(pane == option ? Color.black : Theme.text)
                            .background(pane == option ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(pane == option ? .clear : Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
                Spacer(minLength: 8)
                if pane == .entrance || pane == .exit {
                    Text(job.t("Анимации", "Animations")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Toggle("", isOn: Binding(get: { job.look.animationsOn },
                                             set: { new in job.pushHistory(); job.look.animationsOn = new }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.white)
                        .help(job.s.toggleAllAnimations)
                }
            }

            switch pane {
            case .styles:
                grid {
                    ForEach(StylePreset.catalog) { preset in
                        StyleRow(job: job, preset: preset, selected: job.stylePreset == preset.id) { job.applyStyle(preset) }
                    }
                }
            case .entrance:
                grid {
                    ForEach(Anim.allCases) { option in
                        MotionRow(job: job, title: job.s.animTitle(option), subtitle: job.s.animHint(option),
                                  selected: job.animation == option, preview: .init(intro: option, outro: .none)) {
                            job.edit { $0.animation = option }
                        }
                    }
                }
                .opacity(job.look.animationsOn ? 1 : 0.4)
                .disabled(!job.look.animationsOn)
            case .exit:
                grid {
                    ForEach(Outro.allCases) { option in
                        MotionRow(job: job, title: job.s.outroTitle(option), subtitle: job.s.outroHint(option),
                                  selected: job.outro == option, preview: .init(intro: .none, outro: option)) {
                            job.edit { $0.outro = option }
                        }
                    }
                }
                .opacity(job.look.animationsOn ? 1 : 0.4)
                .disabled(!job.look.animationsOn)
            case .settings:
                SettingsPanel(job: job)
            }
        }
        .animation(Theme.settle, value: job.look.animationsOn)
    }

    private func title(_ pane: Pane) -> String {
        switch pane {
        case .styles: return job.t("Стили", "Styles")
        case .entrance: return job.s.entrance
        case .exit: return job.s.exit
        case .settings: return job.t("Настройки", "Settings", "Réglages")
        }
    }

    /// Cards two or three across, as in the Captions tab.
    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 9)], spacing: 9) { content() }
                .padding(.bottom, 4)
        }
    }
}

private let rowShape = RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)

private func rowFill(_ selected: Bool) -> LinearGradient {
    LinearGradient(colors: selected ? [Theme.rowActiveTop, Theme.rowActiveBottom]
                                    : [Theme.rowFill, Theme.rowFill],
                   startPoint: .top, endPoint: .bottom)
}

/// Shows the caption you are actually working on, rendered in the preset — the finished
/// result rather than a generic swatch.
private struct StyleRow: View {
    @ObservedObject var job: Job
    let preset: StylePreset
    let selected: Bool
    let action: () -> Void

    /// The preset applied over the user's current size and geometry.
    private var previewLook: Look {
        var look = job.look
        preset.write(into: &look)
        return look
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CaptionChrome(look: previewLook, animation: .none, outro: .none,
                              text: sampleCaption(job, uppercase: preset.uppercase),
                              progress: 0, scale: 15 / max(previewLook.size, 1))
                    .frame(width: 104, height: 42)
                    .clipped()
                labels(preset.title, preset.font, selected: selected)
            }
            .foregroundStyle(selected ? .black.opacity(0.86) : Theme.text)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 62)
            .background(rowFill(selected), in: rowShape)
            .overlay(rowShape.stroke(selected ? Color.white.opacity(0.9) : Theme.rowStroke, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

/// A row whose thumbnail is the real caption, in the user's current style, looping the preset
/// so the effect can be judged before it is applied.
private struct MotionRow: View {
    @ObservedObject var job: Job
    let title: String
    let subtitle: String
    let selected: Bool
    let preview: Pair
    let action: () -> Void

    struct Pair { let intro: Anim; let outro: Outro }

    private let cycle = 2.2

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let beat = Int(elapsed / cycle)
                    let phase = (elapsed - Double(beat) * cycle) / cycle
                    CaptionChrome(look: job.look, animation: preview.intro, outro: preview.outro,
                                  text: sample, progress: phase,
                                  scale: 15 / max(job.look.size, 1))
                        .id(beat)
                }
                .frame(width: 104, height: 42)
                .clipped()
                labels(title, subtitle, selected: selected)
            }
            .foregroundStyle(selected ? .black.opacity(0.86) : Theme.text)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 62)
            .background(rowFill(selected), in: rowShape)
            .overlay(rowShape.stroke(selected ? Color.white.opacity(0.9) : Theme.rowStroke, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(BouncyButtonStyle())
        .help(subtitle)
    }

    private var sample: String { sampleCaption(job, uppercase: job.look.uppercase) }
}

/// The selected caption's longest word, trimmed to what fits a card's thumbnail.
@MainActor private func sampleCaption(_ job: Job, uppercase: Bool) -> String {
    let text = job.selectedCue?.text ?? job.cues.first?.text ?? "Aa"
    let words = text.split(whereSeparator: \.isWhitespace)
    let word = words.max(by: { $0.count < $1.count }).map(String.init) ?? "Aa"
    let trimmed = String(word.prefix(10))
    return uppercase ? trimmed.uppercased() : trimmed
}

@MainActor @ViewBuilder private func labels(_ title: String, _ subtitle: String, selected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title)
            .font(.system(size: 14, weight: .semibold)).tracking(0.6)
            .lineLimit(1).minimumScaleFactor(0.75)
        Text(subtitle)
            .font(.system(size: 11)).lineLimit(1)
            .foregroundStyle(selected ? .black.opacity(0.55) : Theme.muted)
    }
    Spacer(minLength: 0)
}
