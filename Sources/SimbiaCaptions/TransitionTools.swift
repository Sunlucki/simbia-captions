import SimbiaCore
import SwiftUI

// MARK: - Editing transitions

extension Job {
    var transitions: [TransitionClip] { project?.transitions ?? [] }

    func transitionClip(_ id: String) -> TransitionClip? { transitions.first { $0.id == id } }

    /// The transition on the cut after a shot.
    func transition(after shotID: String) -> TransitionClip? { transitions.first { $0.after == shotID } }

    /// A dissolve on the cut after `shotID`, picked and shown in the Transitions tab.
    func addTransition(after shotID: String) {
        guard var p = project, transition(after: shotID) == nil else { return }
        pushHistory()
        let clip = TransitionClip(id: Project.newID("x"), after: shotID)
        p.transitions.append(clip)
        project = p
        focus = .transition(clip.id)
        libraryTab = .transitions
    }

    func updateTransition(_ id: String, undoable: Bool = true, _ change: (inout TransitionClip) -> Void) {
        guard var p = project, let i = p.transitions.firstIndex(where: { $0.id == id }) else { return }
        if undoable { pushHistory() }
        change(&p.transitions[i])
        p.transitions[i].duration = min(3, max(0.1, p.transitions[i].duration))
        project = p
    }

    func deleteTransition(_ id: String) {
        guard var p = project else { return }
        pushHistory()
        let after = p.transitions.first { $0.id == id }?.after
        p.transitions.removeAll { $0.id == id }
        project = p
        focus = after.map { .shot($0) } ?? .caption
    }
}

extension TransitionClip.Kind {
    var symbol: String {
        switch self {
        case .dissolve: return "square.on.square"
        case .black: return "moon.fill"
        case .white: return "sun.max.fill"
        case .whip: return "wind"
        case .zoom: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .blur: return "drop.fill"
        case .slide: return "rectangle.portrait.and.arrow.right"
        }
    }

    @MainActor func name(_ job: Job) -> String {
        switch self {
        case .dissolve: return job.t("Растворение", "Dissolve", "Fondu enchaîné")
        case .black: return job.t("Через чёрное", "Through black", "Par le noir")
        case .white: return job.t("Вспышка", "Flash")
        case .whip: return job.t("Рывок", "Whip", "Filé")
        case .zoom: return job.t("Зум внутрь", "Zoom in", "Zoom avant")
        case .zoomOut: return job.t("Зум наружу", "Zoom out", "Zoom arrière")
        case .blur: return job.t("Через размытие", "Through blur", "Par le flou")
        case .slide: return job.t("Сдвиг", "Push", "Poussée")
        }
    }
}

// MARK: - The Transitions tab

/// The Transitions tab: the kind, length and direction of the transition picked on the timeline.
struct TransitionsPanel: View {
    @ObservedObject var job: Job

    var body: some View {
        if case .transition(let id) = job.focus, let clip = job.transitionClip(id) {
            TransitionSettings(job: job, clip: clip)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(job.t("Переход на склейке", "A transition on a cut", "Une transition sur une coupe")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(job.t("Выберите шот на таймлайне — на его склейках появится средний пивот «+». Нажмите его, и здесь откроются настройки перехода. Склейка с переходом показывает его иконку всегда.",
                           "Pick a shot on the timeline — its cuts get a middle «+» knob. Press it and the transition's settings open here. A cut with a transition always shows its icon.", "Choisissez un plan dans la timeline — ses coupes reçoivent un bouton central «+». Appuyez dessus et les réglages de la transition s’ouvrent ici. Une coupe avec transition affiche toujours son icône."))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                if !job.transitions.isEmpty {
                    Text(job.t("Переходов в ролике: ", "Transitions in the video: ", "Transitions dans la vidéo : ") + "\(job.transitions.count)")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
        }
    }
}

private struct TransitionSettings: View {
    @ObservedObject var job: Job
    let clip: TransitionClip

    var body: some View {
        let cut = job.shot(clip.after)?.end ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(job.t("Переход · склейка ", "Transition · cut at ", "Transition · coupe à ") + clock(cut))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                ForEach(TransitionClip.Kind.allCases, id: \.self) { kind in
                    let on = clip.kind == kind
                    Button { job.updateTransition(clip.id) { $0.kind = kind } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbol).font(.system(size: 17, weight: .semibold))
                            Text(kind.name(job)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .foregroundStyle(on ? .black : Theme.text)
                        .background(on ? Color.white : Theme.rowFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                }
            }
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        FieldLabel(job.t("Длительность", "Length", "Durée"))
                        Spacer()
                        Text(String(format: "%.1f ", clip.duration) + job.t("с", "s"))
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    }
                    // the player is rebuilt once, when the knob is let go
                    Slider(value: Binding(get: { clip.duration }, set: { v in job.updateTransition(clip.id, undoable: false) { $0.duration = (v * 10).rounded() / 10 } }),
                           in: 0.1...2, onEditingChanged: { began in
                               if began { job.pushHistory(); job.sync.holdRebuild = true }
                               else { job.sync.holdRebuild = false; job.rebuildIfPictureChanged() }
                           })
                        .tint(.white).controlSize(.small)
                }
                if clip.kind == .whip || clip.kind == .slide {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(job.t("Куда уходит кадр", "Which way it goes", "Sens du mouvement"))
                        HStack(spacing: 4) {
                            ForEach(TransitionClip.Direction.allCases, id: \.self) { d in
                                let on = clip.direction == d
                                Button { job.updateTransition(clip.id) { $0.direction = d } } label: {
                                    Image(systemName: "arrow.\(d.rawValue)").font(.system(size: 12, weight: .bold))
                                        .frame(width: 34, height: 28)
                                        .foregroundStyle(on ? .black : Theme.text)
                                        .background(on ? Color.white : Theme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(BouncyButtonStyle())
                            }
                        }
                    }
                }
            }
            Text(job.t("Переход берёт кадры, которые есть в файлах за склейкой; если их не хватает — держит крайний кадр.",
                       "The transition uses footage the files have past the cut; where they run out it holds the edge frame.", "La transition utilise les images des fichiers au-delà de la coupe ; s’il en manque, elle fige l’image du bord."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                Pill(job.t("Удалить переход · ⌫", "Delete transition · ⌫", "Supprimer la transition · ⌫"), icon: "trash", destructive: true) { job.deleteTransition(clip.id) }
            }
        }
    }
}
