//
//  PublicProfileOverlay.swift
//  nodeloc
//
//  Another user's profile.
//

import SwiftUI

// MARK: - Public profile

struct PublicProfileOverlay: View {
    let target: UserProfileTarget
    let onClose: () -> Void
    @Environment(AppState.self) private var app
    @State private var store = PublicProfileStore()

    /// One sheet, chosen by value. Several `.sheet(isPresented:)` on the same
    /// view silently collapse to whichever was applied last — this screen had
    /// two, so 最近访问 was opening the badge list.
    @State private var activeSheet: ProfileSheet?
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    @State private var scrollOffset: CGFloat = 0
    /// This person's public custom feeds — the ones they set `show_on_profile`
    /// on. Loaded here rather than in `PublicProfileStore` because it is one
    /// independent request that shouldn't be able to fail the whole profile.
    @State private var publicFeeds: [CustomFeed] = []

    private enum ProfileSheet: String, Identifiable {
        case badges, nodes, privateMessage
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                    profileHero
                    statsRow
                    customFeedsRow

                    Section {
                        tabContent
                            .padding(.top, 6)
                            .padding(.bottom, 34)
                    } header: {
                        tabBar
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            // This screen had no refresh at all. `force` is required or a
            // profile still inside its cache window returns immediately, and
            // the tab is reloaded explicitly because its task id (username +
            // tab) doesn't change across a refresh.
            .refreshable {
                await store.load(target: target, force: true)
                await store.loadTab(selectedTab)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y)
            } action: { _, newValue in
                scrollOffset = newValue
            }

            floatingHeader
                .frame(maxWidth: .infinity, alignment: .top)
                .zIndex(10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: target.id) { await store.load(target: target) }
        // The feeds this person chose to show. Only public ones come back, so
        // an empty result is the normal case and the row simply doesn't appear.
        .task(id: target.username) {
            publicFeeds = (try? await DiscourseClient().customFeeds(username: target.username))?
                .customFeeds ?? []
        }
        .task(id: "\(store.username)-\(selectedTab.rawValue)") { await store.loadTab(selectedTab) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .badges: badgeSheet
            case .nodes: nodesSheet
            case .privateMessage:
                PrivateMessageSheet(recipient: store.displayName) { title, body in
                    await store.sendPrivateMessage(title: title, body: body)
                }
            }
        }
    }

    // MARK: Floating header (matches the post reader's chrome)

    // Read from the shared metrics rather than redeclared: local copies are
    // what let this header drift out of step with every other screen's.
    private let headerControlHeight = FloatingHeader.controlHeight
    private let headerHorizontalInset = FloatingHeader.horizontalInset

    /// 0 → 1 as the banner scrolls away, revealing the inline user pill.
    private var userRevealProgress: CGFloat {
        min(max((scrollOffset - 60) / 80, 0), 1)
    }

    private var floatingHeader: some View {
        HStack(spacing: 8) {
            FloatingHeaderButton(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: headerControlHeight, height: headerControlHeight)
            }

            userPill
                .opacity(userRevealProgress)
                .offset(y: (1 - userRevealProgress) * -4)

            Spacer(minLength: 8)

            headerTools
        }
        .padding(.horizontal, headerHorizontalInset)
        .padding(.top, 8)
    }

    /// Avatar + username, revealed between the back button and the tool pill.
    private var userPill: some View {
        FloatingHeaderButton(borderShape: .capsule, action: {}) {
            HStack(spacing: 6) {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: 22
                )
                Text(store.displayName)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: headerControlHeight)
        }
        .allowsHitTesting(false)
    }

    /// 更多, as a single round glass button — the same construction the
    /// browser's ⋯ uses, so it can't drift from the back button beside it. A
    /// capsule sized around one 28pt-wide icon read as a vertical oval; letting
    /// the native button style shape itself avoids that arithmetic entirely.
    ///
    /// The previous version layered `.plain` buttons over a capsule marked
    /// `allowsHitTesting(false)`, so nothing in it could ever respond — and its
    /// 搜索 / 分享 icons had no actions behind them at all.
    private var headerTools: some View {
        Menu {
            userMenuContent
        } label: {
            FloatingHeaderIcon(systemName: "ellipsis")
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .accessibilityLabel("更多")
    }

    /// 私信 / 聊天 / 通知方式. All three need an account, and none of them makes
    /// sense pointed at yourself.
    @ViewBuilder
    private var userMenuContent: some View {
        if canInteract {
            Button {
                activeSheet = .privateMessage
            } label: {
                Label("私信", systemImage: "envelope")
            }

            Button {
                app.openDirectMessage(username: store.username)
                onClose()
            } label: {
                Label("聊天", systemImage: "bubble.left.and.bubble.right")
            }

            Divider()

            Menu {
                Picker("通知方式", selection: Binding(
                    get: { store.notificationLevel },
                    set: { level in Task { await store.setNotificationLevel(level) } }
                )) {
                    ForEach(UserNotificationLevel.allCases) { level in
                        Label(level.label, systemImage: level.icon).tag(level)
                    }
                }
            } label: {
                Label("通知方式", systemImage: store.notificationLevel.icon)
            }
        } else {
            Button {} label: { Label("暂无可用操作", systemImage: "nosign") }
                .disabled(true)
        }
    }

    /// Signed in, and this is somebody else.
    private var canInteract: Bool {
        DiscourseAuth.shared.isAuthenticated
            && !store.username.isEmpty
            && store.username.caseInsensitiveCompare(DiscourseAuth.shared.username ?? "") != .orderedSame
    }

    /// Banner height, including the area behind the status bar.
    private var bannerHeight: CGFloat { 188 + UIApplication.topSafeAreaInset }

    private var profileHero: some View {
        VStack(spacing: 0) {
            // Runs to the very top, behind the status bar and floating header.
            profileBanner

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -58)
                .padding(.bottom, -58)
        }
    }


    /// Fixed-height banner: a tall image is aspect-filled then cropped to
    /// `bannerHeight` rather than pushing the content below it down.
    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: bannerHeight)
                    .clipped()
            } placeholder: {
                profileBannerFallback
            }
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        ZStack {
            Theme.surface
            Image(systemName: "at")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Theme.muted(0.08))
        }
        .frame(maxWidth: .infinity)
        .frame(height: bannerHeight)
    }

    /// 关注 / 取关 toggle backed by the discourse-follow endpoints.
    private var followButton: some View {
        Button {
            Task { await store.toggleFollow() }
        } label: {
            HStack(spacing: 4) {
                if store.isTogglingFollow {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(store.isFollowing ? Theme.text : .white)
                } else {
                    Image(systemName: store.isFollowing ? "checkmark" : "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(store.isFollowing ? AppString("已关注") : AppString("关注"))
                    .font(Theme.body(12, weight: .semibold))
            }
            .foregroundStyle(store.isFollowing ? Theme.text : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(store.isFollowing ? Theme.surface : Theme.accent, in: Capsule())
            .overlay {
                if store.isFollowing {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.pressable)
        .disabled(store.isTogglingFollow)
    }

    private var profileCard: some View {
        VStack(spacing: 12) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 96
            )
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
            .offset(y: -44)
            .padding(.bottom, -36)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.displayName)
                        .font(Theme.heading(24, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let title = store.title, !title.isEmpty {
                        titleBadge(title)
                    }
                }

                HStack(spacing: 6) {
                    Text("@\(store.username)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.62))

                    if let flair = store.flair {
                        FlairBadge(flair: flair)
                    }

                    if let followers = store.followerCount {
                        Text("·")
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.38))
                        Text("\(followers) 粉丝")
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.62))
                    }

                    if store.canFollow {
                        followButton
                    }
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, dot: true)
                profilePill(store.joined)
            }

            if !store.roles.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    ForEach(store.roles) { role in
                        profileChip(role.label, color: roleColor(role))
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.badges.isEmpty || !store.topCategories.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    if !store.badges.isEmpty { achievementsLink }
                    if !store.topCategories.isEmpty { nodesLink }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            profileMeta

            if store.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 2)
            } else if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    /// 头衔 with its admin-designed style, beside the display name. Plain text —
    /// the style itself (color + effect) carries the emphasis, no chrome.
    @ViewBuilder
    private func titleBadge(_ title: String) -> some View {
        if let style = store.titleStyle {
            StyledTitleText(text: title, style: style)
                .lineLimit(1)
        } else {
            Text(title)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
    }

    private var achievementsLink: some View {
        Button { activeSheet = .badges } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.badgeDetails.prefix(3)) { badge in
                        ProfileBadgeIcon(badge: badge)
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.badges.count) 项徽章")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    /// The person's public custom feeds, as a scrolling row of chips.
    @ViewBuilder
    private var customFeedsRow: some View {
        if !publicFeeds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionKicker(text: AppString("Custom Feed"))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(publicFeeds) { feed in
                            Button {
                                openCustomFeed(feed)
                            } label: {
                                HStack(spacing: 7) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(nodeAccentColor(feed.color ?? "009966"))
                                        .frame(width: 20, height: 20)
                                        .overlay {
                                            Image(systemName: "line.3.horizontal.decrease")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(feed.name)
                                            .font(Theme.body(13, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                        Text(AppString("\(feed.nodeCount ?? 0) 个节点"))
                                            .font(Theme.body(11))
                                            .foregroundStyle(Theme.muted(0.55))
                                    }
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, 12)
                                .padding(.vertical, 7)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(Theme.divider, lineWidth: 1)
                                }
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Same handoff as `openTopic`: this profile is inside a cover, and the
    /// feed page is presented at the root, so the screen goes back first.
    private func openCustomFeed(_ feed: CustomFeed) {
        // The by-user payload always names the owner, but fall back to the
        // profile being viewed rather than doing nothing.
        let username = feed.username ?? target.username
        guard !username.isEmpty else { return }
        onClose()
        app.openCustomFeed(username: username, slug: feed.slug, name: feed.name)
    }

    private var nodesLink: some View {
        Button { activeSheet = .nodes } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.topCategories.prefix(3)) { node in
                        // The node's own logo, like 我的 page — an initial on an
                        // accent disc looked the same for every node.
                        NodeAvatar(node: node, size: 22, cornerRadius: 11)
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.topCategories.count) 个节点")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.badgeDetails) { item in
                        HStack(spacing: 12) {
                            ProfileBadgeIcon(badge: item, size: 44, cornerRadius: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("徽章")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
    }

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.topCategories) { node in
                        HStack(spacing: 12) {
                            NodeSummaryIcon(node: node, size: 44, cornerRadius: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                if !node.description.isEmpty {
                                    Text(node.description)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if !node.memberCount.isEmpty {
                                Text(node.memberCount)
                                    .font(Theme.body(11, weight: .semibold))
                                    .foregroundStyle(Theme.muted(0.48))
                            }
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("常去节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
    }

    @ViewBuilder
    private var profileMeta: some View {
        HStack(spacing: 14) {
            if let location = store.location, !location.isEmpty {
                metaItem(icon: "mappin.and.ellipse", text: location) {
                    openInMaps(location)
                }
            }
            if let website = store.website, !website.isEmpty {
                metaItem(icon: "link", text: website) {
                    openProfileWebsite(url: store.websiteURL, displayText: website)
                }
            }
        }
    }

    /// 位置 opens Maps, 网址 opens the in-app browser. Both were plain text
    /// before, which read like links and did nothing.
    private func metaItem(
        icon: String,
        text: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                Text(text)
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.muted(0.62))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Reddit-style stat row, matching the 我的 page.
    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.stats.enumerated()), id: \.offset) { index, stat in
                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(Theme.heading(17, weight: .bold))
                        .foregroundStyle(stat.isAccented ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(Theme.body(10, weight: .medium))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)

                if index < store.stats.count - 1 {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1, height: 26)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(ProfileStore.ProfileTab.allCases) { tab in
                    Button {
                        withAnimation(.quick) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 7) {
                            Text(tab.label)
                                .font(Theme.body(14, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? Theme.text : Theme.muted(0.5))
                            Rectangle()
                                .fill(selectedTab == tab ? Theme.accent : Color.clear)
                                .frame(height: 2)
                                .clipShape(Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == .energy {
            if store.loadingTab == .energy && store.pointsHistory.isEmpty {
                loadingRow
            } else if store.pointsHistory.isEmpty {
                emptyTab(icon: "bolt.slash", text: AppString("暂无能量历史记录"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.pointsHistory) { pointsRow($0) }
                }
            }
        } else if store.loadingTab == selectedTab && (store.actionItems[selectedTab]?.isEmpty ?? true) {
            loadingRow
        } else if let items = store.actionItems[selectedTab], !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { activityRow($0) }

                if store.tabsWithMore.contains(selectedTab) {
                    HStack {
                        ProgressView().tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        guard visible else { return }
                        Task { await store.loadMore(selectedTab) }
                    }
                }
            }
        } else if store.failedTabs.contains(selectedTab) {
            // A failed request is not an empty tab. Saying "还没有…" about one
            // that a rate limit ate is both wrong and a dead end.
            failedTab
        } else {
            emptyTab(icon: "tray", text: AppString("还没有\(selectedTab.label)"))
        }
    }

    private var failedTab: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.muted(0.4))
            Text("加载失败")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.55))
            Button {
                let tab = selectedTab
                Task { await store.loadTab(tab) }
            } label: {
                Text("重试")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var loadingRow: some View {
        ProgressView()
            .tint(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
    }

    private func emptyTab(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        Button {
            openTopic(item)
        } label: {
            activityRowLabel(item)
        }
        .buttonStyle(.pressable)
        // Every row names a topic, and this list had no way into any of them.
        .disabled(item.topicId == nil)
    }

    /// Opens the topic this activity refers to, at the exact reply when the
    /// item carries one — a 赞 or a 帖子 row means a post, not just its topic.
    private func openTopic(_ item: UserActionItem) {
        guard let topicID = item.topicId else { return }
        // Through `app` rather than a local presentation: this profile is
        // already inside a cover, and `openTopic` is what the reader's own
        // routing uses. `onClose` hands the screen back first so the reader
        // isn't opened underneath this page.
        onClose()
        app.openTopic(id: topicID, postNumber: item.postNumber)
    }

    private func activityRowLabel(_ item: UserActionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title ?? AppString("无标题"))
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            let excerpt = DiscourseFormat.plainText(item.excerpt ?? "")
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Text(DiscourseFormat.relative(item.createdAt))
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.muted(0.45))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func pointsRow(_ entry: PointsHistoryEntry) -> some View {
        let points = entry.points ?? 0
        let positive = entry.isPositive ?? (points > 0)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.description ?? AppString("能量变动"))
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.date.map { String($0.prefix(10)) } ?? DiscourseFormat.relative(entry.createdAt))
                    .font(Theme.body(11, weight: .medium))
                    .foregroundStyle(Theme.muted(0.45))
            }
            Spacer(minLength: 8)
            Text(positive ? "+\(points)" : "\(points)")
                .font(Theme.heading(16, weight: .bold))
                .foregroundStyle(positive ? Theme.accent : Theme.danger)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func profilePill(_ text: String, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(Theme.muted(0.32))
                    .frame(width: 8, height: 8)
            }
            Text(text)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.hover, in: Capsule())
    }

    private func profileChip(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    /// Keyed on the role's kind, never on its label — the label is translated.
    private func roleColor(_ role: ProfileRole) -> Color {
        switch role.kind {
        case .admin, .moderator: return Theme.danger
        case .trustLevel(let level) where level >= 3:
            return Color(light: 0x8A36D6, dark: 0xC99BFF)
        default: return Color(light: 0x2F6DF6, dark: 0x7EA7FF)
        }
    }
}

// MARK: - 私信

/// Composes a private message to one person. Native controls throughout, and
/// deliberately minimal: Discourse needs a title and a body, nothing else.
private struct PrivateMessageSheet: View {
    let recipient: String
    /// Returns whether it sent — a failure keeps the draft on screen.
    let send: (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message = ""
    @State private var isSending = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("这条私信的主题", text: $title)
                        .submitLabel(.next)
                        .onSubmit { bodyFocused = true }
                }

                Section("内容") {
                    TextField("想说的话…", text: $message, axis: .vertical)
                        .lineLimit(6...12)
                        .focused($bodyFocused)
                }
            }
            .navigationTitle("发给 \(recipient)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发送") { submit() }
                        .disabled(!canSend)
                }
            }
            .disabled(isSending)
        }
        .standardSheet([.large])
    }

    /// Discourse rejects short titles and bodies outright, so the button stays
    /// disabled rather than sending something the server will refuse.
    private var canSend: Bool {
        !isSending
            && title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private func submit() {
        guard canSend else { return }
        isSending = true
        Task {
            let sent = await send(
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            isSending = false
            if sent {
                ToastCenter.shared.show(AppString("私信已发送"))
                dismiss()
            }
        }
    }
}
