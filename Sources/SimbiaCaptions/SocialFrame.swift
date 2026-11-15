import SwiftUI

/// A translucent mock of TikTok / Reels chrome over the player.
///
/// The point is not decoration: both apps cover the bottom and right of the frame with their
/// own UI, and a caption placed there is unreadable in the feed even though it looks fine in
/// an editor. The shaded bands mark what the platform will sit on top of.
struct SocialFrame: View {
    let mode: SocialOverlay
    /// The 9:16 area of the video — what a phone actually shows.
    let rect: CGRect

    var body: some View {
        let height = rect.height
        let width = min(rect.width, height * 9 / 16)
        let frame = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)

        ZStack {
            if mode == .tiktok { tiktok(frame) } else { reels(frame) }

            Rectangle()
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: width, height: height)
                .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: TikTok

    private func tiktok(_ f: CGRect) -> some View {
        let s = f.height / 812      // laid out against a 375×812 phone
        return ZStack(alignment: .topLeading) {
            unsafeBands(f, bottom: 0.20, right: 0.17)

            HStack(spacing: 18 * s) {
                label(tr("Подписки", "Following", "Abonnements"), size: 15 * s, dim: true)
                VStack(spacing: 3 * s) {
                    label(tr("Для вас", "For You", "Pour toi"), size: 15 * s, weight: .semibold)
                    Rectangle().fill(Color.white.opacity(0.85)).frame(width: 26 * s, height: 2 * s)
                }
            }
            .position(x: f.midX, y: f.minY + 54 * s)

            glyph("magnifyingglass", 20 * s).position(x: f.maxX - 26 * s, y: f.minY + 54 * s)

            // right-hand action rail
            VStack(spacing: 20 * s) {
                Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.5 * s).frame(width: 42 * s, height: 42 * s)
                rail("heart.fill", "328.5K", s)
                rail("bubble.right.fill", "1 204", s)
                rail("bookmark.fill", "9 871", s)
                rail("arrowshape.turn.up.right.fill", "3 402", s)
                Circle().fill(Color.white.opacity(0.28)).frame(width: 40 * s, height: 40 * s)
                    .overlay(glyph("music.note", 16 * s))
            }
            .position(x: f.maxX - 34 * s, y: f.minY + 505 * s)

            VStack(alignment: .leading, spacing: 7 * s) {
                label("@simbia.captions", size: 15 * s, weight: .semibold)
                label(tr("Смотри до конца 👀 #reels #edit", "Watch till the end 👀 #reels #edit", "Regarde jusqu’à la fin 👀 #reels #edit"), size: 13 * s)
                HStack(spacing: 5 * s) {
                    glyph("music.note", 11 * s)
                    label(tr("оригинальный звук — simbia", "original sound — simbia", "son original — simbia"), size: 12 * s)
                }
            }
            .frame(width: f.width * 0.68, alignment: .leading)
            .position(x: f.minX + f.width * 0.34 + 14 * s, y: f.maxY - 132 * s)

            HStack(spacing: 30 * s) {
                ForEach(["house.fill", "person.2.fill", "plus.app.fill", "message.fill", "person.fill"], id: \.self) {
                    glyph($0, 21 * s)
                }
            }
            .position(x: f.midX, y: f.maxY - 34 * s)
        }
    }

    // MARK: Instagram Reels

    private func reels(_ f: CGRect) -> some View {
        let s = f.height / 812
        return ZStack(alignment: .topLeading) {
            unsafeBands(f, bottom: 0.17, right: 0.15)

            HStack {
                label("Reels", size: 20 * s, weight: .bold)
                Spacer()
                glyph("camera", 20 * s)
            }
            .frame(width: f.width - 36 * s)
            .position(x: f.midX, y: f.minY + 58 * s)

            VStack(spacing: 22 * s) {
                rail("heart", "184K", s)
                rail("bubble.right", "927", s)
                rail("paperplane", "2 118", s)
                glyph("ellipsis", 19 * s)
                RoundedRectangle(cornerRadius: 5 * s)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1.5 * s)
                    .frame(width: 26 * s, height: 26 * s)
            }
            .position(x: f.maxX - 30 * s, y: f.minY + 520 * s)

            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 8 * s) {
                    Circle().stroke(Color.white.opacity(0.75), lineWidth: 1.5 * s)
                        .frame(width: 28 * s, height: 28 * s)
                    label("simbia.captions", size: 14 * s, weight: .semibold)
                    RoundedRectangle(cornerRadius: 4 * s)
                        .stroke(Color.white.opacity(0.7), lineWidth: 1 * s)
                        .frame(width: 68 * s, height: 24 * s)
                        .overlay(label(tr("Подписаться", "Follow", "Suivre"), size: 11 * s))
                }
                label(tr("Как это снято — в описании", "How this was shot — in the description", "Comment c’est filmé — en description"), size: 13 * s)
                HStack(spacing: 5 * s) {
                    glyph("music.note", 11 * s)
                    label(tr("simbia · оригинальный звук", "simbia · original sound", "simbia · son original"), size: 12 * s)
                }
            }
            .frame(width: f.width * 0.7, alignment: .leading)
            .position(x: f.minX + f.width * 0.35 + 14 * s, y: f.maxY - 110 * s)

            HStack(spacing: 34 * s) {
                ForEach(["house", "magnifyingglass", "plus.app", "play.square", "person"], id: \.self) {
                    glyph($0, 21 * s)
                }
            }
            .position(x: f.midX, y: f.maxY - 30 * s)
        }
    }

    // MARK: Pieces

    /// Shading over the regions the platform's own UI occupies.
    private func unsafeBands(_ f: CGRect, bottom: CGFloat, right: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: f.width, height: f.height * bottom)
                .position(x: f.midX, y: f.maxY - f.height * bottom / 2)

            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.35)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: f.width * right, height: f.height * 0.5)
                .position(x: f.maxX - f.width * right / 2, y: f.minY + f.height * 0.62)
        }
    }

    private func rail(_ symbol: String, _ count: String, _ s: CGFloat) -> some View {
        VStack(spacing: 4 * s) {
            glyph(symbol, 26 * s)
            label(count, size: 11 * s, weight: .semibold)
        }
    }

    private func glyph(_ symbol: String, _ size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: max(4, size)))
            .foregroundStyle(Color.white.opacity(0.82))
            .shadow(color: .black.opacity(0.5), radius: 2)
    }

    private func label(_ text: String, size: CGFloat, weight: Font.Weight = .regular,
                       dim: Bool = false) -> some View {
        Text(text)
            .font(.system(size: max(4, size), weight: weight))
            .foregroundStyle(Color.white.opacity(dim ? 0.55 : 0.85))
            .lineLimit(1)
            .shadow(color: .black.opacity(0.55), radius: 2)
    }
}
