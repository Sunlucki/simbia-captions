import SimbiaCore
import SwiftUI

/// The title window's emoji: which animated pack the project plays, the title's emoji (click = pick it: handles on the
/// picture, size and turn here), and the picker that adds one. On the picture an emoji is dragged to move it, its corner
/// handle turns and scales it, a double click puts it back above the title upright, ⌫ removes the picked one.
struct TitleEmoji: View {
    @ObservedObject var job: Job
    let item: TitleItem
    @State private var picking = false

    var body: some View {
        let list = item.stickers ?? []
        let picked = job.sticker.flatMap { $0.title == item.id && list.indices.contains($0.index) ? $0.index : nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FieldLabel(job.t("Эмодзи", "Emoji"))
                Spacer()
                ForEach(AnimatedEmoji.packs, id: \.self) { pack in
                    let on = job.emojiPack == pack
                    Button { job.setEmojiPack(pack) } label: {
                        Text(packName(pack)).font(.system(size: 12, weight: on ? .bold : .medium))
                            .padding(.horizontal, 10).frame(height: 26)
                            .foregroundStyle(on ? .black : Theme.text)
                            .background(on ? Color.white : Theme.rowFill, in: Capsule())
                            .overlay(Capsule().stroke(on ? .clear : Theme.rowStroke, lineWidth: 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(packHelp(pack))
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { k, s in
                    Button { job.sticker = picked == k ? nil : StickerRef(title: item.id, index: k) } label: {
                        Text(s.emoji).font(.system(size: 24)).frame(width: 40, height: 40)
                            .background(picked == k ? Color.white.opacity(0.28) : Theme.rowFill,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(picked == k ? Color.white : Theme.rowStroke, lineWidth: picked == k ? 2 : 1))
                    }
                    .buttonStyle(BouncyButtonStyle())
                    .help(job.t("Выбрать — на видео появятся ручки: тянуть за эмодзи — двигать, за кружок в углу — вращать и менять размер",
                                "Pick it: handles show on the picture — drag the emoji to move it, the corner knob to turn and scale it", "Sélectionner : des poignées apparaissent sur l’image — faire glisser l’emoji pour le déplacer, la poignée d’angle pour le faire pivoter et le redimensionner"))
                }
                Button { picking = true } label: {
                    Label(job.t("Эмодзи", "Emoji"), systemImage: "plus").font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 40)
                        .foregroundStyle(Theme.text)
                        .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.rowStroke, lineWidth: 1))
                }
                .buttonStyle(BouncyButtonStyle())
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    EmojiPicker(job: job) { emoji in job.addSticker(emoji, to: item.id) }
                }
            }
            if let k = picked {
                let s = list[k]
                HStack(spacing: 14) {
                    slider(job.t("Размер", "Size", "Taille"), "\(Int(s.size)) px", value: s.size, range: 30...900) { v in
                        job.updateSticker(item.id, k, undoable: false) { $0.size = v.rounded() }
                    }
                    slider(job.t("Поворот", "Turn", "Rotation"), "\(Int(s.rotation.rounded()))°", value: s.rotation, range: -180...180) { v in
                        job.updateSticker(item.id, k, undoable: false) { $0.rotation = abs(v) < 3 ? 0 : v.rounded() }
                    }
                    Pill(job.t("Удалить", "Remove", "Supprimer"), destructive: true) { job.removeSticker(item.id, k) }.fixedSize()
                }
            }
        }
    }

    private func slider(_ label: String, _ value: String, value v: Double, range: ClosedRange<Double>,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                FieldLabel(label)
                Spacer()
                Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, v)) }, set: set), in: range,
                   onEditingChanged: { began in if began { job.pushHistory() } })
        }
    }

    private func packName(_ pack: String) -> String {
        switch pack {
        case "noto": return "Noto"
        case "telegram": return "Telegram"
        default: return pack.capitalized
        }
    }

    private func packHelp(_ pack: String) -> String {
        switch pack {
        case "noto": return job.t("Google Noto Animated Emoji — CC BY 4.0, можно в рекламе (с указанием автора)",
                                  "Google Noto Animated Emoji — CC BY 4.0, fine for ads (with credit)", "Google Noto Animated Emoji — CC BY 4.0, utilisable en publicité (avec crédit)")
        case "telegram": return job.t("Анимированные эмодзи Telegram — только для личного использования, не для платной рекламы",
                                      "Telegram animated emoji — personal use only, not for paid ads", "Emoji animés Telegram — usage personnel uniquement, pas pour la publicité payante")
        default: return pack
        }
    }
}

/// All the emoji of the project's pack, by category, with a search; a click adds one to the title.
private struct EmojiPicker: View {
    @ObservedObject var job: Job
    let pick: (String) -> Void
    @State private var query = ""
    @State private var category: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let all = AnimatedEmoji.index(job.emojiPack)
        let categories = all.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = all.filter { (category == nil || $0.category == category) && (q.isEmpty || $0.name.lowercased().contains(q) || $0.emoji == q) }
        VStack(alignment: .leading, spacing: 10) {
            TextField(job.t("Поиск: sleep, cactus, heart…", "Search: sleep, cactus, heart…", "Rechercher : sleep, cactus, heart…"), text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(job.t("Все", "All", "Tous"), on: category == nil) { category = nil }
                    ForEach(categories, id: \.self) { c in chip(c, on: category == c) { category = c } }
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 9), spacing: 4) {
                    ForEach(shown, id: \.self) { e in
                        Button { pick(e.emoji); dismiss() } label: {
                            Text(e.emoji).font(.system(size: 28)).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .help(e.name)
                    }
                }
            }
            .frame(height: 300)
            Text(job.t("\(shown.count) из \(all.count) · пак \(job.emojiPack)", "\(shown.count) of \(all.count) · \(job.emojiPack) pack", "\(shown.count) sur \(all.count) · pack \(job.emojiPack)"))
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(width: 460)
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: on ? .bold : .medium))
                .padding(.horizontal, 9).frame(height: 24)
                .foregroundStyle(on ? .black : Theme.text)
                .background(on ? Color.white : Theme.rowFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
