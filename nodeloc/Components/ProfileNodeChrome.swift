//
//  ProfileNodeChrome.swift
//  nodeloc
//
//  The pieces the profile pages (我的 and someone else's) and the node page
//  share in the community redesign: filled capsule actions, the name chips,
//  the stats card, the overlapping-circle cards and the capsule tab strip.
//

import SwiftUI

// MARK: - Capsule actions

/// A filled capsule action: 编辑资料 / 签到 / 私信 / 关注 on a profile, 加入 /
/// 管理 on a node. Only the label — callers wrap it in a `Button` so the
/// action and disabled state stay theirs.
struct CapsuleActionLabel: View {
    enum Style {
        /// #E5EBEE fill, ink text.
        case neutral
        /// Green fill, background-coloured text (white in light mode).
        case filled
        /// White fill with a 1pt ink border.
        case outlined
    }

    let title: String
    var systemImage: String?
    var style: Style = .neutral
    var height: CGFloat = 40
    /// 签到 keeps a minimum width so 签到 / 已签到 don't change its size.
    var minWidth: CGFloat?
    var isBusy = false

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(foreground)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
            }
            Text(title)
                .font(Theme.body(14, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, minWidth == nil ? 16 : 18)
        .frame(minWidth: minWidth)
        .frame(height: height)
        .background(background, in: Capsule())
        .overlay {
            if style == .outlined {
                Capsule().strokeBorder(Theme.text, lineWidth: 1)
            }
        }
        .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .neutral, .outlined: return Theme.text
        // Theme.bg, not .white: white on the dark-mode mint fails contrast.
        case .filled: return Theme.onAccent
        }
    }

    private var background: Color {
        switch style {
        case .neutral: return Theme.chip
        case .filled: return Theme.accentFill
        case .outlined: return Theme.bg
        }
    }
}

/// One capsule in a tab or sort strip: ink when selected, #E5EBEE otherwise.
struct CapsuleChipLabel: View {
    let title: String
    let isSelected: Bool
    var systemImage: String?
    var trailingSystemImage: String?
    /// The profile tabs are bold either way; the node's sort chips drop to
    /// medium when unselected.
    var unselectedWeight: Font.Weight = .bold

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(Theme.body(14, weight: isSelected ? .bold : unselectedWeight))
                .lineLimit(1)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(isSelected ? Theme.bg : Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(isSelected ? Theme.text : Theme.chip, in: Capsule())
        .contentShape(Capsule())
    }
}

/// A horizontally scrolling row of `CapsuleChipLabel`s with a hairline under
/// it — the profile tabs.
struct CapsuleTabStrip<Value: Hashable>: View {
    let items: [(value: Value, label: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    Button {
                        onSelect(item.value)
                    } label: {
                        CapsuleChipLabel(title: item.label, isSelected: item.value == selection)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

// MARK: - Name chips

/// The 24pt chips beside a profile's name: the member's tier, their 头衔,
/// then any role.
struct ProfileNameChip<Content: View>: View {
    enum Kind { case tier, title, role }

    let kind: Kind
    @ViewBuilder var content: Content

    private var text: Color {
        switch kind {
        case .tier: Theme.tierChipText
        case .title: Theme.titleChipText
        case .role: Theme.roleChipText
        }
    }

    private var fill: Color {
        switch kind {
        case .tier: Theme.tierChipFill
        case .title: Theme.titleChipFill
        case .role: Theme.roleChipFill
        }
    }

    /// The web's 头衔 pill has no outline; its fill stands in.
    private var border: Color {
        switch kind {
        case .tier: Theme.tierChipBorder
        case .title: Theme.titleChipFill
        case .role: Theme.roleChipBorder
        }
    }

    var body: some View {
        content
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(border, lineWidth: 1)
            }
    }
}

/// A 头衔 in the name row: the admin's design (`title_style` colour and
/// effect) when one is known, otherwise the web's plain amber pill.
struct UserTitleChip: View {
    let title: String
    var style: TitleStyle?
    /// Profile header (24pt chip) or a post's author line (compact).
    var compact = false

    var body: some View {
        if compact {
            Group {
                if let style {
                    StyledTitleText(text: title, style: style, font: Theme.body(11, weight: .semibold))
                } else {
                    Text(title)
                        .font(Theme.body(11, weight: .bold))
                        .foregroundStyle(Theme.titleChipText)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Theme.titleChipFill, in: Capsule())
        } else {
            ProfileNameChip(kind: .title) {
                if let style {
                    StyledTitleText(text: title, style: style, font: Theme.body(12, weight: .bold))
                } else {
                    Text(title)
                }
            }
        }
    }
}

// MARK: - Stats card

/// Value over label, left-aligned, in equal columns (four at most) on a
/// rounded surface card. A cell with an action opens something on tap.
struct ProfileStatsCard: View {
    struct Item {
        let value: String
        let label: String
        var action: (() -> Void)?
    }

    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
                count: min(max(items.count, 1), 4)
            )
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    if let action = item.action {
                        Button(action: action) { cell(item) }
                            .buttonStyle(.pressable)
                    } else {
                        cell(item)
                    }
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        }
    }

    private func cell(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.value)
                .font(Theme.heading(18, weight: .heavy))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(item.label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Overlapping-circle cards

/// 成就 / 常去节点: a title and count, then a row of overlapping 40pt circles
/// ending in "+N". Tapping opens the full list.
struct ProfileCollectionCard<Circles: View>: View {
    let title: String
    let count: String
    /// How many items didn't get a circle.
    let overflow: Int
    let action: () -> Void
    @ViewBuilder var circles: Circles

    static var circleSize: CGFloat { 40 }
    /// Three circles and the "+N" fit a half-width card on the smallest phone.
    static var visibleCount: Int { 3 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(count)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }

                HStack(spacing: -12) {
                    circles
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(Theme.body(13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: Self.circleSize, height: Self.circleSize)
                            .background(Theme.bg, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2.5))
                            .zIndex(-100)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}

extension View {
    /// The card-coloured ring that separates overlapping circles. `index`
    /// stacks earlier circles on top of later ones.
    func overlapRing(size: CGFloat = 40, index: Int = 0) -> some View {
        self
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2.5))
            .zIndex(Double(-index))
    }
}

// MARK: - Node letter circle

/// A node's first letter, white and bold on the node's colour.
struct NodeLetterCircle: View {
    let name: String
    let colorHex: String
    var size: CGFloat = 18

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(Theme.body(size * 0.4 < 10 ? 10 : size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(nodeAccentColor(colorHex), in: Circle())
    }
}

// MARK: - Vote pill

/// The #E5EBEE capsule a row's vote control sits in.
struct VotePill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Theme.chip, in: Capsule())
    }
}

// MARK: - Profile activity rows

/// One item in a profile's activity list. Topics read as a topic row (node,
/// time, title); replies read as a reply (node · topic, who replied, body).
/// Only what a user action carries — it has no vote or reply counts, so those
/// aren't drawn.
struct ProfileActivityRow: View {
    let item: UserActionItem
    let onOpen: () -> Void

    @State private var node: SidebarNodeSummary?

    private var isReply: Bool { (item.postNumber ?? 1) > 1 }

    private var time: String { DiscourseFormat.relative(item.createdAt) }

    private var excerpt: String { DiscourseFormat.plainText(item.excerpt ?? "") }

    private var author: String {
        if let name = item.name, !name.isEmpty { return name }
        return item.username ?? ""
    }

    private var shareURL: URL? {
        guard let topicId = item.topicId else { return nil }
        if let postNumber = item.postNumber, postNumber > 1 {
            return DiscourseConfig.baseURL.appending(path: "t/\(topicId)/\(postNumber)")
        }
        return DiscourseConfig.baseURL.appending(path: "t/\(topicId)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReply {
                replyContent
            } else {
                topicContent
            }
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .task(id: item.categoryId) {
            guard let id = item.categoryId else { return }
            node = await NodeCatalog.shared.node(id: id)
        }
    }

    private var topicContent: some View {
        HStack(alignment: .top, spacing: 12) {
            if let thumbnail = item.imageUrl.flatMap(URL.init(string:)) {
                CachedRemoteImage(url: thumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.chip
                }
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }
            topicText
        }
    }

    private var topicText: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let node {
                    NodeLetterCircle(name: node.name, colorHex: node.colorHex, size: 18)
                    Text(node.name)
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("·")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
                Text(time)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }

            Text(item.title ?? AppString("无标题"))
                .font(Theme.heading(16, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !excerpt.isEmpty {
                EmojiShortcodeText(text: excerpt, pointSize: 13)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var replyContent: some View {
        HStack(alignment: .top, spacing: 10) {
            if let node {
                NodeLetterCircle(name: node.name, colorHex: node.colorHex, size: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(contextLine)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                Text(AppString("\(author) 回复了话题 · \(time)"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)

                if !excerpt.isEmpty {
                    EmojiShortcodeText(text: excerpt, pointSize: 15)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.text)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "n/node · topic title", or just the title before the node resolves.
    private var contextLine: String {
        let title = item.title ?? AppString("无标题")
        guard let node else { return title }
        return "n/\(node.slug) · \(title)"
    }

    private var actions: some View {
        HStack(spacing: 18) {
            if let score = item.voteScore {
                HStack(spacing: 4) {
                    Image(VoteControl.assetName(for: .up, filled: false))
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                    Text("\(score)")
                        .font(Theme.body(13, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.chip, in: Capsule())
            }
            if let replies = item.replyCount {
                actionText(AppString("\(replies) 条评论"))
            }
            if isReply {
                Button(action: onOpen) {
                    actionText(AppString("回复"))
                }
                .buttonStyle(.pressable)
            }
            if let shareURL {
                ShareLink(item: shareURL) {
                    actionText(AppString("分享"))
                }
                .buttonStyle(.pressable)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionText(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(13, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
    }
}

// MARK: - Profile tab names

extension ProfileStore.ProfileTab {
    /// The redesign's names for the store's tabs: 主题 reads as 帖子, 帖子 (a
    /// member's replies) as 评论, and so on.
    var displayLabel: String {
        switch self {
        case .topics: return AppString("帖子")
        case .posts: return AppString("评论")
        case .energy: return AppString("能量记录")
        case .bookmarks: return AppString("收藏")
        case .likes: return AppString("赞同过")
        }
    }

    /// 帖子 / 评论 / 能量记录 / 收藏 / 赞同过 — short English for the
    /// segmented control, where five have to fit an iPhone's width.
    static var displayOrder: [(value: Self, label: String)] {
        // 能量记录 lives on the 能量 page and 收藏 on 我的收藏; 赞同过 has no
        // API (the website renders that tab server-side only).
        [.topics, .posts].map { ($0, $0.segmentLabel) }
    }

    var segmentLabel: String {
        switch self {
        case .energy: AppString(key: "profile.segment.energy", default: "能量记录")
        case .bookmarks: AppString(key: "profile.segment.saved", default: "收藏")
        case .likes: AppString(key: "profile.segment.upvoted", default: "赞同过")
        default: displayLabel
        }
    }

    /// Someone else's page: 帖子 and 评论 only. No 赞同过 (the backend serves
    /// it to the website alone), and no 能量记录 / 收藏 — those lists are
    /// owner-only (`isOwnerOnly`), so the tabs could only ever show a lock.
    static var publicDisplayOrder: [(value: Self, label: String)] {
        [.topics, .posts].map { ($0, $0.displayLabel) }
    }

    /// Lists only their owner can read (`/api/v1/points/history` and
    /// `/api/v1/saved` answer with the caller's own), shown on someone else's
    /// page as private rather than as the reader's list or an empty one.
    var isOwnerOnly: Bool { self == .energy || self == .bookmarks }
}

// MARK: - Filled button

/// The app's one filled call-to-action: a green capsule with a white label,
/// readable in both modes. Use it for any "green background, white text"
/// button rather than styling one by hand.
struct FilledButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    var block = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18)
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: height)
            .background(Theme.accentFill.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Profile skeleton

/// The profile's first load, shaped like the real page — header row space,
/// banner, avatar overlapping it, name / handle / bio lines, stats card, tab
/// chips and a few rows — so the page lands where the placeholders were.
/// Shared by 我的 and someone else's profile. Pulses as one, like the feed.
struct ProfileSkeleton: View {
    /// Status bar + header row; the floating header sits over this space and
    /// stays usable.
    var topInset: CGFloat
    var bannerHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner placeholder runs to the top, behind the header, like
            // the real banner.
            Rectangle()
                .fill(Theme.neutral300)
                .frame(height: topInset + bannerHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.neutral300)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Capsule().fill(Theme.neutral300).frame(width: 92, height: 40)
                        Capsule().fill(Theme.neutral300).frame(width: 84, height: 40)
                    }
                    .padding(.top, 42)
                }
                .padding(.top, -32)

                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(widthFraction: 0.45, height: 22)
                    SkeletonLine(widthFraction: 0.6)
                    SkeletonLine(widthFraction: 0.92)
                    SkeletonLine(widthFraction: 0.7)
                }
                .padding(.top, 10)

                // Stats card.
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonLine(widthFraction: 0.7, height: 18)
                            SkeletonLine(widthFraction: 0.5, height: 10)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.cornerMedium)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .padding(.top, 12)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 12)

            // Tab chips.
            HStack(spacing: 8) {
                ForEach([64, 64, 92, 64], id: \.self) { width in
                    Capsule().fill(Theme.neutral300).frame(width: CGFloat(width), height: 44)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }

            ProfileRowsSkeleton(pulses: false)
        }
        .skeletonPulsing()
        .accessibilityLabel(AppString("加载中"))
    }
}

/// Placeholder rows for a profile tab whose first page hasn't arrived, so
/// "还没有帖子" only ever means the list really is empty.
struct ProfileRowsSkeleton: View {
    var count = 4
    /// Off when nested in something that already pulses.
    var pulses = true

    var body: some View {
        let rows = VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.neutral300).frame(width: 18, height: 18)
                        SkeletonLine(widthFraction: 0.35, height: 10)
                    }
                    SkeletonLine(widthFraction: 0.88, height: 16)
                    SkeletonLine(widthFraction: 0.6)
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
        if pulses {
            rows.skeletonPulsing()
        } else {
            rows
        }
    }
}


/// A profile that couldn't be loaded: what went wrong and 重试, in place of
/// the page. Leaves room for the floating header, which stays usable.
struct ProfileLoadFailedView: View {
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            Text(message ?? AppString("加载失败"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                CapsuleActionLabel(title: AppString("重试"), style: .filled)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.top, UIApplication.topSafeAreaInset + 160)
        .padding(.bottom, 160)
    }
}

// MARK: - Scroll-driven banner chrome

/// The few values a banner page derives from its scroll offset, held apart
/// from the page so a scroll frame invalidates only the views that read them.
///
/// The pages used to keep the raw offset in `@State`, which re-ran the whole
/// page body — banner, identity block, every list row — on every frame of
/// every scroll, even far down the list where nothing visible depended on it.
/// Here each value is clamped and only written when it actually changes, so
/// mid-list scrolling writes nothing at all.
@MainActor
@Observable
final class BannerScrollChrome {
    /// Overscroll past the top, which stretches the banner. 0 at rest.
    private(set) var pull: CGFloat = 0
    /// 0 → 1 as the header scrolls away, revealing the title in the bar.
    private(set) var reveal: CGFloat = 0
    /// `reveal < 1`. Separate so the page itself, which needs only this
    /// for the bar style, re-renders only when it flips.
    private(set) var bannerIsUnderBar = true

    @ObservationIgnored private var revealStart: CGFloat
    @ObservationIgnored private var revealLength: CGFloat
    /// The last offset fed in, so a new reveal range applies at once.
    @ObservationIgnored private var lastOffset: CGFloat = 0
    /// Flip `bannerIsUnderBar` inside one spring, so everything keyed to it
    /// (the node page's bar) moves together instead of snapping.
    @ObservationIgnored private let animatesFlip: Bool

    init(revealStart: CGFloat, revealLength: CGFloat, animatesFlip: Bool = false) {
        self.revealStart = revealStart
        self.revealLength = revealLength
        self.animatesFlip = animatesFlip
    }

    /// Moves where the reveal happens, for a page whose header height is
    /// only known once laid out (the post reader's title).
    func setRevealRange(start: CGFloat, length: CGFloat) {
        let length = max(length, 1)
        guard start != revealStart || length != revealLength else { return }
        revealStart = start
        revealLength = length
        update(offset: lastOffset)
    }

    /// Feed it the raw offset (negative while pulled past the top).
    func update(offset: CGFloat) {
        lastOffset = offset
        let newPull = max(0, -offset)
        if newPull != pull { pull = newPull }
        // Hundredths: invisible as opacity, and it stops sub-point jitter
        // from writing the same reveal over and over.
        let raw = min(max((offset - revealStart) / revealLength, 0), 1)
        let newReveal = (raw * 100).rounded() / 100
        if newReveal != reveal { reveal = newReveal }
        let under = raw < 1
        if under != bannerIsUnderBar {
            if animatesFlip {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { bannerIsUnderBar = under }
            } else {
                bannerIsUnderBar = under
            }
        }
    }
}

/// Fades content in with `BannerScrollChrome.reveal`, tappable only once
/// nearly opaque. Its own view so only it re-renders while scrolling.
struct BannerRevealView<Content: View>: View {
    let chrome: BannerScrollChrome
    /// False leaves hit testing alone, for a title that was always tappable.
    var gatesHitTesting = true
    @ViewBuilder let content: Content

    var body: some View {
        content
            .allowsHitTesting(!gatesHitTesting || chrome.reveal > 0.9)
            .opacity(chrome.reveal)
    }
}

/// The n/slug capsule in the centre of a bar — the node page's and the post
/// reader's, one view so the two can't drift apart. 44pt glass, 17pt
/// semibold. Hidden at rest; fades in and settles 8pt down into place with
/// `BannerScrollChrome.reveal`, and takes taps only once nearly opaque.
/// Reads the reveal itself, so a scroll frame re-renders this capsule and
/// nothing around it.
struct BarNodeCapsule: View {
    let slug: String
    let chrome: BannerScrollChrome
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        let reveal = chrome.reveal
        Button(action: action) {
            Text(verbatim: "n/\(slug)")
                .font(Theme.body(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassSurface(tint: FloatingHeader.glassTint, interactive: true, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(reveal)
        .offset(y: 8 * (1 - reveal))
        .allowsHitTesting(reveal > 0.9)
        .accessibilityHidden(reveal < 0.5)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Builds content from the current pull stretch. Its own view so a pull
/// re-renders only the banner, not the page around it.
struct BannerPullView<Content: View>: View {
    let chrome: BannerScrollChrome
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(chrome.pull)
    }
}

// MARK: - Pull to refresh without a spinner

/// Pull-to-refresh for the profile pages, driven by the same overscroll that
/// stretches the banner. The system `.refreshable` drew its spinner over the
/// banner and inserted a content inset that made the stretch jump; this fires
/// once per pull past `threshold` with a haptic and nothing on screen — the
/// content stays and swaps in place as the reload answers.
@MainActor
@Observable
final class SilentPullToRefresh {
    var threshold: CGFloat = 80
    /// Written on every scroll frame; nothing renders from it.
    @ObservationIgnored private var armed = true
    private(set) var isRefreshing = false

    /// Feed it the raw scroll offset (negative while pulled past the top).
    func track(offset: CGFloat, refresh: @escaping @MainActor () async -> Void) {
        if offset >= 0 {
            // Back at rest: the next pull may fire again.
            armed = true
            return
        }
        guard armed, !isRefreshing, -offset >= threshold else { return }
        armed = false
        isRefreshing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            await refresh()
            isRefreshing = false
        }
    }
}

// MARK: - Text with site emoji

/// Plain text whose `:shortcode:`s are drawn as the site's emoji, inline.
///
/// A bio is stored raw (`bio_raw`), and activity excerpts arrive as plain
/// text, so neither goes through the post renderer — without this a bio like
/// ":prohibited: 此用户已被封禁" showed its codes as typed. A code the site's
/// catalogue doesn't know stays as text, as it would on the web; standard
/// emoji are typed as characters on this backend and need nothing.
struct EmojiShortcodeText: View {
    let text: String
    /// The point size of the surrounding font, so each emoji is one em.
    let pointSize: CGFloat

    @State private var catalog = EmojiCatalog.shared
    private let images = EmojiImageStore.shared

    private static let pattern = /:([A-Za-z0-9_+\-]+):/

    /// Standard shortcodes (`:horse_face:` → 🐴), from the backend's own
    /// table (internal/markup/emoji_names.txt: "name character" per line, `#`
    /// comments) when the app bundles it. Without the file standard codes
    /// simply stay as text; site emoji still render.
    private static let standard: [String: String] = {
        guard let url = Bundle.main.url(forResource: "emoji_names", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var table: [String: String] = [:]
        for line in raw.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            table[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return table
    }()

    var body: some View {
        composed
            // Loads start here rather than while composing: that runs during
            // a view update, where touching the store's state is not allowed.
            // The store's observable bump redraws the text as each arrives.
            .task(id: text) {
                guard hasShortcode else { return }
                await EmojiCatalog.shared.loadIfNeeded()
                for match in text.matches(of: Self.pattern) {
                    if let src = catalog.emoji(named: String(match.output.1))?.url, !src.isEmpty {
                        images.loadIfNeeded(src, pointSize: pointSize)
                    }
                }
            }
    }

    private var hasShortcode: Bool { text.contains(Self.pattern) }

    private var composed: Text {
        // One scan: the first match doubles as the "has any shortcode" test,
        // which used to be a separate pass over the text on every render.
        var rest = Substring(text)
        guard var next = rest.firstMatch(of: Self.pattern) else { return Text(verbatim: text) }
        var result = Text(verbatim: "")
        while true {
            let match = next
            result = result + Text(verbatim: String(rest[..<match.range.lowerBound]))
            let name = String(match.output.1)
            if let src = catalog.emoji(named: name)?.url, !src.isEmpty {
                if let image = images.image(for: src, pointSize: pointSize) {
                    result = result + Text(Image(uiImage: image)).baselineOffset(-pointSize * 0.12)
                } else {
                    result = result + Text(verbatim: String(rest[match.range]))
                }
            } else if let character = Self.standard[name.lowercased()] {
                result = result + Text(verbatim: character)
            } else {
                result = result + Text(verbatim: String(rest[match.range]))
            }
            rest = rest[match.range.upperBound...]
            guard let following = rest.firstMatch(of: Self.pattern) else { break }
            next = following
        }
        return result + Text(verbatim: String(rest))
    }
}

extension String {
    /// Runs of blank lines folded to one line break, for short bios shown
    /// under a line limit: a raw bio's paragraph gaps otherwise spend half
    /// the limit on empty lines.
    var collapsingBlankLines: String {
        replacing(/\n[ \t\u{00A0}\u{200C}]*(\n[ \t\u{00A0}\u{200C}]*)+/, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
