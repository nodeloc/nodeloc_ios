//
//  PinnedTopics.swift
//  nodeloc
//
//  The pinned strip shared by the node page (its pinned topics) and the home
//  feed (the site announcements): one tinted card that pages through them
//  (design 「节点置顶轮播」, iOS 日常 7).
//

import SwiftUI

/// One slide of the pinned card: a topic pinned in its node, or a site
/// announcement from `GET /api/v1/announcements/home`.
enum PinnedItem: Identifiable {
    case topic(Post)
    case announcement(NLHomeAnnouncements.Announcement)

    var id: String {
        switch self {
        case .topic(let post): "t\(post.id)"
        case .announcement(let announcement): "a\(announcement.id)"
        }
    }

    var title: String {
        switch self {
        case .topic(let post): post.title
        case .announcement(let announcement): announcement.title
        }
    }

    var hasImage: Bool {
        switch self {
        case .topic(let post): !post.media.isEmpty
        case .announcement(let announcement): announcement.coverURL != nil
        }
    }
}

extension NLHomeAnnouncements.Announcement {
    /// The cover as an absolute URL; the server already makes it one.
    var coverURL: URL? {
        guard let coverUrl, !coverUrl.isEmpty else { return nil }
        return URL(string: coverUrl)
    }

    /// The chip's label: the kind as the server words it in the reader's
    /// language, else plain 公告.
    var chipLabel: String {
        if let kindName, !kindName.isEmpty { return kindName }
        return AppString("公告")
    }

    /// One icon per kind the admin can publish (公告/活动/维护通知/规则更新).
    var chipSymbol: String {
        switch kind {
        case "event": "gift"
        case "maintenance": "wrench.adjustable"
        case "rules": "doc.text"
        default: "megaphone"
        }
    }
}

/// Pinned topics — or the home page's announcements — as a paged card above
/// a list: one item per slide — the 置顶 (or 公告) chip, author and time, a
/// two-line title, a 72pt thumbnail when there is an image — and the current
/// slide's votes and comments (a topic) or excerpt and close button (an
/// announcement) with the page dots underneath. Advances by itself every 6 s
/// (not under Reduce Motion), swipes by hand, and takes no space when there
/// is nothing to show.
struct PinnedTopicsSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let items: [PinnedItem]
    private let onOpen: (PinnedItem) -> Void
    private let onDismiss: ((NLHomeAnnouncements.Announcement) -> Void)?
    private let outerPadding: EdgeInsets

    @State private var page = 0

    /// Topics pinned in a node (the node page).
    init(posts: [Post], onOpen: @escaping (Post) -> Void) {
        self.items = posts.map(PinnedItem.topic)
        self.onOpen = { item in
            if case .topic(let post) = item { onOpen(post) }
        }
        self.onDismiss = nil
        self.outerPadding = EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12)
    }

    /// The home page's announcements. `onDismiss` puts a close button under
    /// any the server marks dismissible.
    init(
        announcements: [NLHomeAnnouncements.Announcement],
        topPadding: CGFloat = 12,
        bottomPadding: CGFloat = 8,
        onOpen: @escaping (NLHomeAnnouncements.Announcement) -> Void,
        onDismiss: ((NLHomeAnnouncements.Announcement) -> Void)? = nil
    ) {
        self.items = announcements.map(PinnedItem.announcement)
        self.onOpen = { item in
            if case .announcement(let announcement) = item { onOpen(announcement) }
        }
        self.onDismiss = onDismiss
        self.outerPadding = EdgeInsets(top: topPadding, leading: 12, bottom: bottomPadding, trailing: 12)
    }

    /// Slide padding (12) + chip row (20) + gap (6) + two title lines.
    private static let textHeight: CGFloat = 12 + 20 + 6 + 42
    /// Slide padding (12) + thumbnail (72).
    private static let thumbHeight: CGFloat = 12 + 72

    private var isAnnouncements: Bool {
        if case .announcement = items.first { return true }
        return false
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        slide(item, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: items.contains(where: \.hasImage) ? Self.thumbHeight : Self.textHeight)

                footer
            }
            .background(Theme.pinnedCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .padding(outerPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isAnnouncements ? AppString("站点公告") : AppString("置顶"))
            .onChange(of: items.count) { _, count in
                if page >= count { page = max(count - 1, 0) }
            }
            // Restarts on every page change, so a swipe by hand resets the clock.
            .task(id: autoplayKey) {
                guard items.count > 1, !reduceMotion, scenePhase == .active else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)) {
                    page = (page + 1) % items.count
                }
            }
        }
    }

    private var autoplayKey: String {
        "\(page)-\(items.count)-\(reduceMotion)-\(scenePhase == .active)"
    }

    // MARK: Slide

    private func slide(_ item: PinnedItem, index: Int) -> some View {
        Button { onOpen(item) } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    meta(item)
                    Text(item.title)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(15 * 0.4 - 3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let url = thumbnailURL(item) {
                    CachedRemoteImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.neutral300
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(slideLabel(item, index: index))
    }

    private func thumbnailURL(_ item: PinnedItem) -> URL? {
        switch item {
        case .topic(let post):
            post.media.first?.bestURL(forWidth: 72, scale: displayScale)
        case .announcement(let announcement):
            announcement.coverURL
        }
    }

    private func slideLabel(_ item: PinnedItem, index: Int) -> String {
        switch item {
        case .topic(let post):
            AppString("置顶 \(index + 1) / \(items.count)：\(post.title)")
        case .announcement(let announcement):
            AppString("公告 \(index + 1) / \(items.count)：\(announcement.title)")
        }
    }

    @ViewBuilder
    private func meta(_ item: PinnedItem) -> some View {
        HStack(spacing: 6) {
            switch item {
            case .topic(let post):
                chip {
                    PinnedGlyph.pin
                        .stroke(style: StrokeStyle(lineWidth: 2.4 / 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                } label: {
                    AppString("置顶")
                }

                HStack(spacing: 5) {
                    RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 18)
                    Text("u/\(post.authorUsername ?? post.authorName ?? post.node)")
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(-1)

                Text("·").accessibilityHidden(true)
                Text(post.time)
                    .lineLimit(1)
                    .fixedSize()

            case .announcement(let announcement):
                chip {
                    Image(systemName: announcement.chipSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 12)
                } label: {
                    announcement.chipLabel
                }

                let time = DiscourseFormat.relative(announcement.publishedAt)
                if !time.isEmpty {
                    Text(time)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.body(12))
        .foregroundStyle(Theme.textMuted)
        .frame(height: 20)
    }

    private func chip<Icon: View>(@ViewBuilder icon: () -> Icon, label: () -> String) -> some View {
        HStack(spacing: 3) {
            icon()
            Text(label())
                .font(Theme.body(12, weight: .bold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Theme.pinnedChip, in: Capsule())
        .fixedSize()
    }

    // MARK: Footer

    private var footer: some View {
        let item = items[min(page, items.count - 1)]
        return HStack(spacing: 10) {
            switch item {
            case .topic(let post):
                let votes = app.voteScore(for: post) ?? post.baseVotes
                HStack(spacing: 4) {
                    PinnedGlyph.upvote
                        .stroke(style: StrokeStyle(lineWidth: 2 * 14 / 24, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                    Text(AppString("\(votes) 赞同"))
                }
                HStack(spacing: 4) {
                    PinnedGlyph.comment
                        .stroke(style: StrokeStyle(lineWidth: 2 * 14 / 24, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                    Text(AppString("\(post.comments) 条评论"))
                }
            case .announcement(let announcement):
                // No votes or comments on an announcement: its excerpt instead.
                Text(announcement.excerpt ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if items.count > 1 {
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        Button {
                            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)) { page = index }
                        } label: {
                            Capsule()
                                .fill(Theme.text.opacity(index == page ? 0.85 : 0.25))
                                .frame(width: index == page ? 16 : 6, height: 6)
                                .frame(width: 22, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(dotLabel(index))
                        .accessibilityAddTraits(index == page ? .isSelected : [])
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: page)
            }
            if case .announcement(let announcement) = item,
               let onDismiss, announcement.dismissible ?? true {
                Button { onDismiss(announcement) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressableIcon)
                .accessibilityLabel(AppString("关闭这条公告"))
            }
        }
        .font(Theme.body(12))
        .monospacedDigit()
        .foregroundStyle(Theme.textMuted)
        .frame(minHeight: items.count > 1 || onDismiss != nil ? 28 : nil)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func dotLabel(_ index: Int) -> String {
        switch items[index] {
        case .topic(let post): AppString("第 \(index + 1) 条置顶：\(post.title)")
        case .announcement(let announcement): AppString("第 \(index + 1) 条公告：\(announcement.title)")
        }
    }
}

/// The design's stroke icons, drawn on its 24-unit grid and scaled to fit.
private struct PinnedGlyph: Shape {
    enum Kind { case pin, upvote, comment }
    let kind: Kind

    static let pin = PinnedGlyph(kind: .pin)
    static let upvote = PinnedGlyph(kind: .upvote)
    static let comment = PinnedGlyph(kind: .comment)

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .pin:
            // M12 17v5 M8 3h8l-1 7 3 4H6l3-4z
            p.move(to: CGPoint(x: 12, y: 17)); p.addLine(to: CGPoint(x: 12, y: 22))
            p.addLines([CGPoint(x: 8, y: 3), CGPoint(x: 16, y: 3), CGPoint(x: 15, y: 10),
                        CGPoint(x: 18, y: 14), CGPoint(x: 6, y: 14), CGPoint(x: 9, y: 10)])
        case .upvote:
            // M12 4l7 8h-4v8H9v-8H5z
            p.addLines([CGPoint(x: 12, y: 4), CGPoint(x: 19, y: 12), CGPoint(x: 15, y: 12),
                        CGPoint(x: 15, y: 20), CGPoint(x: 9, y: 20), CGPoint(x: 9, y: 12), CGPoint(x: 5, y: 12)])
        case .comment:
            // M4 5h16v11H10l-6 4z
            p.addLines([CGPoint(x: 4, y: 5), CGPoint(x: 20, y: 5), CGPoint(x: 20, y: 16),
                        CGPoint(x: 10, y: 16), CGPoint(x: 4, y: 20)])
        }
        p.closeSubpath()
        let scale = min(rect.width, rect.height) / 24
        return p.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}
