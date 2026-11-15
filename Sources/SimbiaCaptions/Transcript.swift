import AppKit
import SwiftUI

/// The video's whole text as paragraphs of captions. Every word is its own target: it grows under the
/// pointer, and a click opens its tools (edit it, make it the accent, a break or a paragraph before it).
/// ⇧ / ⌘ with a click select captions instead; the paragraph's number selects the whole paragraph.
struct TranscriptPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        let paragraphs = job.paragraphs
        VStack(alignment: .leading, spacing: 10) {
            if job.selectedCues.count > 1 { SelectionBar(job: job) } else { toolbar }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(paragraphs.enumerated()), id: \.element[0].id) { n, paragraph in
                            ParagraphRow(job: job, number: n + 1, cues: paragraph)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: job.selected) { _, id in
                    // keep the caption picked elsewhere (timeline, player) in view
                    guard let id, let p = paragraphs.first(where: { $0.contains { $0.id == id } }) else { return }
                    withAnimation(Theme.snappy) { proxy.scrollTo(p[0].id) }
                }
            }
        }
    }

    private var toolbar: some View {
        let anchorStarts: Bool = {
            let (ordered, starts) = job.orderedAndStarts
            guard let id = job.selected, let k = ordered.firstIndex(where: { $0.id == id }), k > 0 else { return false }
            return starts[k]
        }()
        // the text tools first (each opens a window), then what is done to the selected captions, delete last
        return PillGrid(columns: 6) {
            tool(job.t("Найти", "Find", "Rechercher"), "magnifyingglass", job.t("Найти и заменить — тайминг слов сохраняется", "Find and replace — word timing is kept", "Rechercher et remplacer — le timing des mots est conservé"), .find) {
                FindReplacePanel(job: job)
            }
            tool(job.t("Словарь", "Glossary", "Glossaire"), "character.book.closed", job.t("Словарь: как всегда писать бренд и имена", "Glossary: how the brand and names are always spelt", "Glossaire : l’orthographe fixe de la marque et des noms"), .glossary) {
                GlossaryPanel(job: job)
            }
            Pill(job.t("Объединить", "Join", "Joindre"), icon: "arrow.right.to.line") { job.mergeSelection() }
                .help(job.t("Объединить выделенные субтитры (или со следующим) · M", "Join the selected captions (or with the next one) · M", "Fusionner les sous-titres sélectionnés (ou avec le suivant) · M"))
            Pill(job.t("Разделить", "Split", "Scinder"), icon: "scissors") { job.splitAtPlayhead() }
                .help(job.t("Разрезать субтитр под курсором воспроизведения · S", "Split the caption under the playhead · S", "Scinder le sous-titre sous la tête de lecture · S"))
            Pill(anchorStarts ? job.t("Слить абзацы", "Join paragraphs", "Fusionner les paragraphes") : job.t("Новый абзац", "New paragraph", "Nouveau paragraphe"), icon: "paragraphsign") {
                if let id = job.selected { job.toggleParagraph(at: id) }
            }
            .help(job.t("Абзац начинается с выделенного субтитра — или соединяется с предыдущим · ↩", "A paragraph starts at the selected caption — or joins the one before · ↩", "Un paragraphe commence au sous-titre sélectionné — ou rejoint le précédent · ↩"))
            Pill(job.t("Удалить", "Delete", "Supprimer"), icon: "trash", destructive: true) { job.deleteSelection() }
                .help(job.t("Удалить выделенные субтитры · ⌫", "Delete the selected captions · ⌫", "Supprimer les sous-titres sélectionnés · ⌫"))
        }
        .disabled(job.cues.isEmpty)
    }

    /// A button that opens one of the text tools in a window under it.
    private func tool<Panel: View>(_ title: String, _ symbol: String, _ hint: String, _ panel: ToolPanel, @ViewBuilder content: @escaping () -> Panel) -> some View {
        Pill(title, icon: symbol) { job.toolPanel = panel }
            .help(hint)
            .popover(isPresented: Binding(get: { job.toolPanel == panel }, set: { if !$0, job.toolPanel == panel { job.toolPanel = nil } }),
                     arrowEdge: .bottom) { content().preferredColorScheme(.dark) }
    }
}

private struct ParagraphRow: View {
    @ObservedObject var job: Job
    let number: Int
    let cues: [Cue]

    var body: some View {
        let whole = job.focus == .caption && cues.allSatisfy { job.selection.contains($0.id) }
        HStack(alignment: .top, spacing: 10) {
            Button { job.selectParagraph(containing: cues[0].id) } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("¶ \(number)").font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(whole ? Theme.text : Color(red: 0.95, green: 0.78, blue: 0.42))
                    Text(clock(cues[0].start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.t("Выделить весь абзац", "Select the whole paragraph", "Sélectionner tout le paragraphe"))

            WrapStack(spacing: 6) {
                ForEach(cues) { cue in CaptionChip(job: job, marker: job.playingCue, cue: cue) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(whole ? Color.white.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(whole ? Color.white.opacity(0.5) : .clear, lineWidth: 1))
    }
}

/// One caption in the text, its words laid out one by one; the one under the playhead outlined.
private struct CaptionChip: View {
    @ObservedObject var job: Job
    @ObservedObject var marker: PlayingCue
    let cue: Cue

    var body: some View {
        let selected = job.focus == .caption && job.selection.contains(cue.id)
        let anchor = selected && job.selected == cue.id
        let playing = marker.id == cue.id
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        WrapStack(spacing: 1) {
            ForEach(Array(job.timedWords(of: cue).enumerated()), id: \.offset) { index, word in
                WordView(job: job, cue: cue, index: index, word: word, onLight: selected)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(selected ? AnyShapeStyle(selectableFill(true)) : AnyShapeStyle(Theme.rowFill.opacity(0.5)), in: shape)
        .overlay(shape.stroke(anchor ? Color.white : playing ? Color(red: 0.95, green: 0.78, blue: 0.42) : Theme.rowStroke.opacity(0.4),
                              lineWidth: anchor || playing ? 1.5 : 1))
        .contentShape(shape)
        // the padding around the words still selects the caption
        .onTapGesture { job.clickWord(cue, nil) }
        .contextMenu { CaptionMenu(job: job, cue: cue) }
        .help("\(clock(cue.start)) – \(clock(cue.end))")
    }
}

/// A word that grows under the pointer and opens its tools on a click.
private struct WordView: View {
    @ObservedObject var job: Job
    let cue: Cue
    let index: Int
    let word: Word
    /// The caption is selected: dark text on the light fill.
    let onLight: Bool
    @State private var hover = false

    var body: some View {
        let gold = onLight ? Color(red: 0.54, green: 0.35, blue: 0.0) : Color(red: 0.95, green: 0.78, blue: 0.42)
        let ref = WordRef(cue: cue.id, index: index)
        let open = job.editingWord == ref
        // with the accents switched off the video draws every word alike: the mark stays, faint
        let shown = word.accent && (job.project?.captions.accents ?? true)
        Text(word.text)
            .font(.system(size: 13.5, weight: shown ? .heavy : .medium))
            .foregroundStyle(shown ? gold : onLight ? Color.black.opacity(0.86) : Theme.text)
            .underline(word.accent && !shown, color: gold.opacity(0.6))
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(hover || open ? (onLight ? Color.black.opacity(0.12) : Color.white.opacity(0.2)) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .scaleEffect(hover || open ? 1.25 : 1)
            .zIndex(hover || open ? 1 : 0)
            .animation(Theme.snappy, value: hover || open)
            .onHover { hover = $0 }
            .contentShape(Rectangle())
            .onTapGesture { job.clickWord(cue, index) }
            .popover(isPresented: Binding(get: { job.editingWord == ref },
                                          set: { if !$0, job.editingWord == ref { job.editingWord = nil } }),
                     arrowEdge: .bottom) {
                WordTools(job: job, cueID: cue.id, index: index)
                    .preferredColorScheme(.dark)
            }
            .pointerStyle(.link)
    }
}

extension Job {
    /// A click in the text panel: ⇧ adds the range, ⌘ adds or removes the caption; a plain click on a
    /// word selects its caption, moves the playhead to the word and opens the word's tools.
    func clickWord(_ cue: Cue, _ word: Int?) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) || flags.contains(.command) {
            click(cue, extend: flags.contains(.shift), toggle: flags.contains(.command))
            return
        }
        select(cue)
        guard let word else { return }
        let words = timedWords(of: cue)
        if words.indices.contains(word) { seek(words[word].start) }
        editingWord = WordRef(cue: cue.id, index: word)
    }
}

// MARK: - The picked captions

/// Under the captions track, a click on a caption: only the picked ones — not the whole text. Each one a row as in the
/// text (¶ and its time, then its words), the cell running the full width over the very stretch of voice it is said
/// on: a click on a word opens its tools, a word dragged moves where it starts, the cell dragged moves the whole caption
/// (the neighbour before ends where it now starts, the one after starts where it now ends). Then when it starts and ends
/// and what can be done to it.
struct CaptionEditor: View {
    @ObservedObject var job: Job

    var body: some View {
        let picked = job.orderedCues.filter { job.selection.contains($0.id) || $0.id == job.selected }
        VStack(alignment: .leading, spacing: 10) {
            if picked.count > 1 { SelectionBar(job: job) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(picked) { cue in row(cue) }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func row(_ cue: Cue) -> some View {
        let (ordered, starts) = job.orderedAndStarts
        let k = ordered.firstIndex { $0.id == cue.id } ?? 0
        let paragraph = (job.paragraphs.firstIndex { p in p.contains { $0.id == cue.id } } ?? 0) + 1
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("¶ \(paragraph)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                Text(clock(cue.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .frame(width: 52, alignment: .trailing)
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                CueTimeline(job: job, cue: cue)
                HStack(spacing: 10) {
                    FieldLabel(job.t("Начало", "Start", "Début"))
                    TimeField(job: job, value: cue.start) { job.pushHistory(); job.retime(cue.id, start: $0) }.frame(width: 96)
                    Nudge(job: job) { job.nudge(cue.id, start: $0) }
                    FieldLabel(job.t("Конец", "End", "Fin"))
                    TimeField(job: job, value: cue.end) { job.pushHistory(); job.retime(cue.id, end: $0) }.frame(width: 96)
                    Nudge(job: job) { job.nudge(cue.id, end: $0) }
                    Spacer(minLength: 0)
                }
                PillGrid(columns: 5) {
                    Pill(job.t("С предыдущим", "With previous", "Avec le précédent"), icon: "arrow.left.to.line") { job.mergeWithPrevious(cue.id) }
                        .disabled(k == 0).help(job.t("Объединить с предыдущим субтитром", "Join with the previous caption", "Joindre au sous-titre précédent"))
                    Pill(job.t("Со следующим", "With next", "Avec le suivant"), icon: "arrow.right.to.line") { job.mergeWithNext(cue.id) }
                        .disabled(k + 1 >= ordered.count).help(job.t("Объединить со следующим субтитром · M", "Join with the next caption · M", "Joindre au sous-titre suivant · M"))
                    Pill(job.t("Разделить", "Split", "Scinder"), icon: "scissors") { job.splitAtPlayhead() }
                        .help(job.t("Разрезать по курсору воспроизведения · S", "Split at the playhead · S", "Scinder à la tête de lecture · S"))
                    Pill(starts.indices.contains(k) && starts[k] && k > 0 ? job.t("Слить абзацы", "Join paragraphs", "Fusionner les paragraphes") : job.t("Новый абзац", "New paragraph", "Nouveau paragraphe"),
                         icon: "paragraphsign") { job.toggleParagraph(at: cue.id) }
                        .disabled(k == 0)
                    Pill(job.t("Удалить", "Delete", "Supprimer"), icon: "trash", destructive: true) { job.select(cue); job.deleteSelection() }
                }
            }
        }
    }
}

/// The caption's own little timeline: time marks over its cell and the playhead through both — the main timeline's
/// own line, moving with it. A click or a drag on the marks moves the playhead (the main one with it); S cuts the
/// caption there (`Job.splitAtPlayhead`).
private struct CueTimeline: View {
    @ObservedObject var job: Job
    let cue: Cue

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let scale = scale(proxy.size.width)
                CueRuler(scale: scale, fps: job.project?.canvas.fps ?? 30)
                    .padding(.horizontal, 10)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // inside the caption, short of its end: S there cuts this caption, not the next one
                            let frame = 1 / max(job.project?.canvas.fps ?? 30, 1)
                            job.player.pause()
                            job.seek(min(max(scale.time(at: Double(value.location.x) - 10), cue.start), cue.end - frame))
                        })
            }
            .frame(height: 22)
            .help(job.t("Клик или протяжка — курсор воспроизведения сюда; S — разрезать субтитр здесь",
                        "Click or drag to move the playhead here; S cuts the caption here", "Cliquez ou faites glisser pour amener la tête de lecture ici ; S coupe le sous-titre ici"))
            VoiceCell(job: job, cue: cue)
        }
        .overlay {
            GeometryReader { proxy in
                Playhead(clock: job.clock, scale: scale(proxy.size.width), pinned: false)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The cell's own seconds-to-points: its width less the 10 pt the words keep from each side.
    private func scale(_ width: CGFloat) -> TimeScale {
        TimeScale(start: cue.start, span: max(0.05, cue.end - cue.start), width: max(1, Double(width) - 20))
    }
}

/// Time marks over a caption: timecodes as in its Start and End fields, a tick on every frame when there is room.
private struct CueRuler: View {
    let scale: TimeScale
    let fps: Double

    private static let ladder: [Double] = [0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10]

    var body: some View {
        Canvas { context, size in
            let w = Double(size.width), h = Double(size.height), perSecond = w / scale.span, end = scale.start + scale.span
            func tick(_ x: Double, _ length: Double, _ opacity: Double) {
                context.stroke(Path { $0.move(to: .init(x: x, y: h - length)); $0.addLine(to: .init(x: x, y: h)) },
                               with: .color(.white.opacity(opacity)), lineWidth: 1)
            }
            let major = Self.ladder.first { $0 * perSecond >= 64 } ?? Self.ladder.last!
            let frame = 1 / max(fps, 1)
            let minor = frame * perSecond >= 5 ? frame : major / 5
            for k in stride(from: (scale.start / minor).rounded(.up), through: (end / minor).rounded(.down), by: 1) {
                tick(scale.x(k * minor), 4, 0.3)
            }
            for k in stride(from: (scale.start / major).rounded(.up), through: (end / major).rounded(.down), by: 1) {
                let x = scale.x(k * major)
                tick(x, 8, 0.7)
                let text = context.resolve(Text(clock(k * major)).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75)))
                let half = Double(text.measure(in: size).width) / 2
                context.draw(text, at: CGPoint(x: min(max(x, half), w - half), y: 0), anchor: .top)
            }
            context.stroke(Path { $0.move(to: .init(x: 0, y: h - 0.5)); $0.addLine(to: .init(x: w, y: h - 0.5)) },
                           with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
    }
}

/// One caption the full width over the voice it is said on: the voice drawn behind as bars, each word at the place it
/// is said — a click opens its tools, a drag moves where it starts; the cell dragged moves the whole caption (`Job.slide`).
private struct VoiceCell: View {
    @ObservedObject var job: Job
    let cue: Cue
    @ObservedObject private var media = MediaCache.shared
    @State private var drag: (start: Double, base: [Cue])?
    @State private var wordDrag: (index: Int, start: Double, base: [Word])?

    var body: some View {
        let words = job.timedWords(of: cue)
        let on = job.selection.contains(cue.id) || job.selected == cue.id
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        GeometryReader { proxy in
            let scale = TimeScale(start: cue.start, span: max(0.05, cue.end - cue.start), width: max(1, Double(proxy.size.width) - 20))
            ZStack(alignment: .leading) {
                voice(scale, onLight: on).padding(.horizontal, 10)
                TimedRow(xs: words.map { scale.x($0.start) }) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        WordView(job: job, cue: cue, index: index, word: word, onLight: on)
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)   // the word moves under the pointer
                                .onChanged { value in
                                    guard index > 0 else { return }                         // the first word starts with the caption
                                    if wordDrag?.index != index { wordDrag = (index, word.start, words); job.pushHistory() }
                                    guard let wordDrag else { return }
                                    // the words before it squeeze or stretch to make way
                                    job.pushWord(cue.id, word: index, to: wordDrag.start + Double(value.translation.width) * scale.secondsPerPoint,
                                                 base: wordDrag.base)
                                }
                                .onEnded { _ in wordDrag = nil })
                            .help(job.t("Клик — инструменты слова; тяните — сдвинуть, слова перед ним сожмутся или растянутся",
                                        "Click for the word's tools; drag to move it, the words before it squeeze or stretch", "Cliquez pour les outils du mot ; faites-le glisser pour le déplacer, les mots précédents se compriment ou s’étirent"))
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if drag == nil { drag = (cue.start, job.cues); job.pushHistory(); job.selected = cue.id }
                    guard let drag else { return }
                    job.slide(cue.id, to: drag.start + Double(value.translation.width) * scale.secondsPerPoint, base: drag.base)
                }
                .onEnded { _ in drag = nil })
        }
        .frame(height: 52)
        .background(on ? AnyShapeStyle(selectableFill(true)) : AnyShapeStyle(Theme.rowFill.opacity(0.5)), in: shape)
        .overlay(shape.stroke(on ? Color.white : Theme.rowStroke.opacity(0.4), lineWidth: on ? 1.5 : 1))
        .clipShape(shape)
        .pointerStyle(.grabIdle)
        .help(job.t("Тяните ячейку — весь субтитр: соседний слева сожмётся или растянется до него, справа — от него",
                    "Drag the cell — the whole caption: the neighbour before shrinks or grows to it, the one after from it", "Faites glisser la cellule — tout le sous-titre : le voisin précédent se réduit ou s’allonge jusqu’à lui, le suivant à partir de lui"))
    }

    /// The voice under the caption, as bars across the cell.
    private func voice(_ scale: TimeScale, onLight: Bool) -> some View {
        let clips = (job.project?.audio ?? []).filter { $0.role == .voice }
        return Canvas { context, size in
            for clip in clips {
                guard let values = media.envelope(clip, projectURL: job.projectURL), !values.isEmpty else { continue }
                let peak = max(values.max() ?? 1, 0.0001)
                let end = clip.start + (clip.duration ?? .infinity)
                var x = 0.0
                while x < Double(size.width) {
                    let t = scale.time(at: x)
                    let k = Int(clip.source(at: t) * 50)
                    if t >= clip.start, t < end, k >= 0, k < values.count {
                        let h = max(1, min(1, Double(values[k] / peak)) * Double(size.height - 10))
                        context.fill(Path(CGRect(x: x, y: (Double(size.height) - h) / 2, width: 2, height: h)),
                                     with: .color(onLight ? Color.black.opacity(0.16) : Color.white.opacity(0.18)))
                    }
                    x += 3
                }
            }
        }
    }
}

/// Words along a caption at the places they are said, pushed right where they would run into each other.
private struct TimedRow: Layout {
    let xs: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var right = -Double.infinity
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let x = max(i < xs.count ? xs[i] : 0, right + 2)
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            right = x + Double(size.width)
        }
    }
}
