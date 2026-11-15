import SimbiaCore
import SwiftUI

/// The editor: the video on the left at full height; on the right the header, one panel with the
/// text and all the styles, and the multi-track timeline across the bottom. Tools for a word or a
/// shot open over it on a click.
struct WorkspaceView: View {
    @ObservedObject var job: Job

    var body: some View {
        GeometryReader { proxy in
            let stage = stageSize(proxy.size)
            // the timeline takes the column under the header; with no drawer open its tracks grow into the room
            let timeline = max(MultiTimeline.usualHeight, proxy.size.height - 18 - 24 - 64 - 16)
            let drawer = job.drawer.map { $0.drawerHeight + 6 } ?? 0
            let _ = (MultiTimeline.stretch = min(1.7, max(1, 1 + (timeline - MultiTimeline.usualHeight - drawer) / MultiTimeline.clipTracks)))
            HStack(spacing: 24) {
                VideoStage(job: job)
                    .frame(width: stage.width, height: stage.height)
                    .frame(maxHeight: .infinity)
                    .animation(Theme.settle, value: stage)

                VStack(spacing: 16) {
                    HeaderBar(job: job).frame(height: 64)
                    MultiTimeline(job: job, stretch: MultiTimeline.stretch).frame(height: timeline)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .background(KeyCommands(job: job))
        .overlay {
            if job.galleryOpen { FootageGallery(job: job).transition(.opacity) }
            if job.musicOpen { MusicLibraryView(job: job).transition(.opacity) }
            if job.clipsOpen { ProjectClipsView(job: job).transition(.opacity) }
            if job.browserOpen { ProjectBrowser(job: job).transition(.opacity) }
            if job.briefOpen { ProjectBriefView(job: job).transition(.opacity) }
        }
    }

    /// The tallest frame with the footage's proportions that leaves the right column usable.
    private func stageSize(_ size: CGSize) -> CGSize {
        let aspect = job.aspect
        let height = max(300, size.height - 42)
        let width = min(size.width * (aspect < 1 ? 0.36 : 0.40), height * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var job: Job
    /// The pointer over the grid button (it opens every project) or over the name (it opens this project's brief):
    /// the line over the name says which.
    @State private var hovering: Hover?
    private enum Hover { case projects, brief }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 12) {
                // the way to all the projects, before the name
                Button { job.openBrowser() } label: {
                    let on = hovering == .projects
                    Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? .black : Theme.text)
                        .frame(width: 44, height: 44)
                        .background(on ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
                        .opacity(job.projectURL == nil ? 0.35 : 1)
                }
                .buttonStyle(BouncyButtonStyle())
                .disabled(job.projectURL == nil)
                .onHover { inside in hover(.projects, inside) }
                .help(job.t("Все проекты: статусы, что сделано и что предстоит, журнал правок", "All projects: status, done and to do, the edit journal", "Tous les projets : statut, fait et à faire, journal des modifications"))

                Button { job.openBrief() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(hovering == .projects ? job.t("ОТКРЫТЬ ПРОЕКТЫ", "OPEN PROJECTS", "OUVRIR LES PROJETS")
                                 : hovering == .brief ? job.t("ОТКРЫТЬ БРИФ И ЗАДАЧИ", "OPEN BRIEF AND TASKS", "OUVRIR LE BRIEF ET LES TÂCHES") : job.s.project)
                                .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                                .foregroundStyle(hovering == nil ? Theme.muted : Theme.text)
                            if job.projectURL != nil {
                                let status = ProjectStatus(job.project?.status)
                                HStack(spacing: 4) {
                                    Circle().fill(status.colour).frame(width: 6, height: 6)
                                    Text(status.title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                                }
                                .foregroundStyle(status.colour)
                            }
                        }
                        Text(job.displayName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .underline(hovering == .brief, color: Theme.text.opacity(0.5))
                            .lineLimit(1).truncationMode(.middle)
                        Text(meta)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(job.project == nil)
                .onHover { inside in hover(.brief, inside) }
                .help(job.t("Бриф проекта: над чем работаем, что требуется, что сделано, что проверить и что осталось", "The brief: what we make, what is asked, what is done, to check and left", "Le brief : ce qu’on fait, ce qui est demandé, ce qui est fait, à vérifier et restant")
                      + "\n" + meta)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SyncPill(job: job).fixedSize()

            HStack(spacing: 4) {
                Button(action: job.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!job.canUndo).help(job.s.undoHint)
                Button(action: job.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!job.canRedo).help(job.s.redoHint)
                divider
                Button(action: job.saveSRT) { Text("SRT").font(.system(size: 13, weight: .semibold)).tracking(0.6) }
                    .disabled(job.cues.isEmpty).help(job.s.saveHint)
                ChecksButton(job: job)
                divider
                Button { job.export() } label: {
                    Label(job.t("Экспорт", "Export", "Exporter"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.horizontal, 16).frame(height: 36)
                        .foregroundStyle(.black)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(BouncyButtonStyle())
                .disabled(!job.canExport || job.busy)
                .help(job.s.exportHint)
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .card(22)
            .fixedSize()             // the project's name gives way, never the buttons
        }
    }

    private func hover(_ what: Hover, _ inside: Bool) {
        withAnimation(Theme.snappy) {
            if inside, job.project != nil { hovering = what } else if hovering == what { hovering = nil }
        }
    }

    /// Between the groups of the header's buttons: history, the checks, the export.
    private var divider: some View {
        Rectangle().fill(Theme.rowStroke).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    private var meta: String {
        let total = Int(job.duration.rounded())
        // the usual 1080×1920 goes unsaid: the line has room for the counts that matter
        let size = job.videoSize == CGSize(width: 1080, height: 1920) ? [] : ["\(Int(job.videoSize.width))×\(Int(job.videoSize.height))"]
        var parts = size + [String(format: "%d:%02d", total / 60, total % 60)]
        let shots = job.shots.count, paragraphs = job.paragraphs.count, titles = job.titles.count
        if shots > 1 { parts.append(job.t(ruPlural(shots, "шот", "шота", "шотов"), "\(shots) shots", "\(shots) plans")) }
        parts.append(captionCount(job, job.cues.count))
        if paragraphs > 1 { parts.append(job.t(ruPlural(paragraphs, "абзац", "абзаца", "абзацев"), "\(paragraphs) paragraphs", "\(paragraphs) paragraphes")) }
        if titles > 0 { parts.append(job.t(ruPlural(titles, "заголовок", "заголовка", "заголовков"), titles == 1 ? "1 title" : "\(titles) titles", titles == 1 ? "1 titre" : "\(titles) titres")) }
        return parts.joined(separator: " · ")
    }
}

/// Whether the editor and the project file agree — and whether Claude just changed it.
private struct SyncPill: View {
    @ObservedObject var job: Job

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if job.projectURL != nil, let status = job.syncStatus {
                let fresh = status.announce && context.date.timeIntervalSince(status.at) < 12
                pill(color: fresh ? Color(red: 1, green: 0.72, blue: 0.25) : Color(red: 0.2, green: 0.78, blue: 0.35),
                     title: fresh ? job.t("Обновлено Claude", "Updated by Claude", "Mis à jour par Claude") : job.t("Claude · синхронизировано", "Claude · in sync", "Claude · synchronisé"),
                     detail: "\(job.t("ревизия", "revision", "révision")) \(status.revision) · \(ago(status.at, now: context.date))"
                        + (fresh ? " · ⌘Z" : ""))
            } else {
                Button(action: job.saveProjectAs) {
                    pill(color: Color.white.opacity(0.45), title: job.t("Не связано с Claude", "Not linked to Claude", "Non lié à Claude"),
                         detail: job.t("Сохранить как проект…", "Save as project…", "Enregistrer comme projet…"))
                }
                .buttonStyle(BouncyButtonStyle())
                .disabled(!job.editorReady)
            }
        }
        .animation(Theme.snappy, value: job.syncStatus)
    }

    private func pill(color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
    }

    private func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 10 { return job.t("только что", "just now", "à l’instant") }
        if s < 60 { return job.t("\(s) с назад", "\(s) s ago", "il y a \(s) s") }
        return job.t("\(s / 60) мин назад", "\(s / 60) min ago", "il y a \(s / 60) min")
    }
}

// MARK: - Keys

/// Space plays and pauses, J / K / L play backwards, stop and play forwards (faster on each press), arrows
/// step a frame, S splits at the playhead, M joins, ↩ starts or joins a paragraph, ⌫ deletes, Esc and ⌘A
/// set the selection — unless a text field has the keyboard.
/// Keys are matched by position, so they work with the Russian layout too.
private struct KeyCommands: NSViewRepresentable {
    let job: Job

    func makeNSView(context: Context) -> KeyView { KeyView(job: job) }
    func updateNSView(_ view: KeyView, context: Context) { view.job = job }

    final class KeyView: NSView {
        var job: Job
        private var monitor: Any?

        init(job: Job) { self.job = job; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      !(self.window?.firstResponder is NSTextView) else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                let handled = MainActor.assumeIsolated { self.handle(event.keyCode, modifiers) }
                return handled ? nil : event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        @MainActor private func handle(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            if job.galleryOpen || job.musicOpen || job.clipsOpen || job.browserOpen || job.briefOpen {        // the library covers the editor
                if key == 53 { job.closeGallery(); if job.musicOpen { job.closeMusic() }; job.closeClips(); job.closeBrowser(); job.closeBrief(); return true }   // Esc
                return false
            }
            if job.coverShot != nil, key == 53 { job.coverShot = nil; return true }        // Esc closes «Закрыть текст»
            if key == 53, job.drawer != nil, job.cropShot == nil, job.selection.count < 2 { job.openDrawer(nil); return true }   // Esc folds the drawer
            guard job.editorReady, job.cropShot == nil, job.coverShot == nil else { return false }   // cropping: ↩ and Esc go to its buttons
            if modifiers == .command {
                guard key == 0 else { return false }                                         // ⌘A
                job.selectAllCaptions(); return true
            }
            guard modifiers.isEmpty else { return false }
            let frame = 1 / max(job.project?.canvas.fps ?? 30, 1)
            let captions = job.focus == .caption
            switch key {
            case 49: job.isPlaying ? job.player.pause() : job.play()                       // space
            case 123: job.player.pause(); job.seek(job.currentTime - frame)                  // ←
            case 124: job.player.pause(); job.seek(job.currentTime + frame)                  // →
            case 1: job.splitAtPlayhead()                                                    // S
            case 38: job.shuttle(-1)                                                         // J
            case 40: job.shuttle(0)                                                          // K
            case 37: job.shuttle(1)                                                          // L
            case 46 where captions: job.mergeSelection()                                     // M
            case 36 where captions, 76 where captions:                                       // ↩
                if let id = job.selected { job.toggleParagraph(at: id) }
            case 51, 117:                                                                     // ⌫
                if case .title(let id) = job.focus, let s = job.sticker, s.title == id { job.removeSticker(id, s.index) }
                else if case .title(let id) = job.focus { job.deleteTitle(id) }
                else if case .overlay(let id) = job.focus { job.deleteOverlay(id) }
                else if case .audio(let id) = job.focus { job.deleteAudio(id) }
                else if case .filter(let id) = job.focus { job.deleteFilter(id) }
                else if case .transition(let id) = job.focus { job.deleteTransition(id) }
                else if case .shot(let id) = job.focus { job.isLayer(id) ? job.deleteLayer(id) : job.deleteShot(id) }
                else if captions { job.deleteSelection() } else { return false }
            case 53 where captions: job.collapseSelection()                                  // Esc
            default: return false
            }
            return true
        }
    }
}
