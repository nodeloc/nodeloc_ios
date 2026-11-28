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
    /// Decides the ‹ and whether this page brings its own navigation stack.
    var navigation: PageNavigation = .standalone
    let onClose: () -> Void
    @Environment(AppState.self) private var app
    @State private var store = PublicProfileStore()

    /// One sheet, chosen by value. Several `.sheet(isPresented:)` on the same
    /// view silently collapse to whichever was applied last — this screen had
    /// two, so 最近访问 was opening the badge list.
    @State private var activeSheet: ProfileSheet?
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    /// Scroll-derived banner pull and title reveal, observed only by the
    /// views that draw them — see `BannerScrollChrome`.
    @State private var chrome = BannerScrollChrome(revealStart: 60, revealLength: 80)
    @State private var pullToRefresh = SilentPullToRefresh()
    /// This person's public custom feeds — the ones they set `show_on_profile`
    /// on. Loaded here rather than in `PublicProfileStore` because it is one
    /// independent request that shouldn't be able to fail the whole profile.
    @State private var publicFeeds: [CustomFeed] = []
    /// 屏蔽 / 取消屏蔽 asks first: blocking hides every post of theirs.
    @State private var isConfirmingBlock = false

    private enum ProfileSheet: String, Identifiable {
        case badges, nodes, showcase
        var id: String { rawValue }
    }

    var body: some View {
        page
            .toolbar { toolbarContent }
            .bannerPageNavigationBar(bannerIsUnderBar: chrome.bannerIsUnderBar)
            .inPageNavigation(navigation)
    }

    private var page: some View {
        ZStack(alignment: .top) {
            ScrollView {
                // Switched outside the lazy stack, for the same reason as on
                // 我的: a lazy stack can keep a stale branch on screen.
                switch store.phase {
                case .loading:
                    ProfileSkeleton(
                        topInset: UIApplication.topSafeAreaInset + headerRowHeight,
                        bannerHeight: bannerHeight
                    )
                    .id("public-skeleton")
                case .failed(let message):
                    ProfileLoadFailedView(message: message) {
                        Task { await store.loadPage(target: target, force: true) }
                    }
                    .id("public-failed")
                case .loaded:
                    LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                        profileHero
                        ownedNodesRow
                        customFeedsRow

                        Section {
                            tabContent
                                .padding(.bottom, 34)
                        } header: {
                            tabBar
                        }
                    }
                    .id("public-loaded")
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            // Pull-to-refresh is in the scroll handler below. `force` is
            // required or a profile still inside its cache window returns
            // immediately, and the tab is reloaded explicitly.
            // Raw, not clamped: a negative offset is the pull that stretches
            // the banner. `chrome` clamps the reveal itself.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                chrome.update(offset: newValue)
                // Pull-to-refresh with no spinner — see `SilentPullToRefresh`.
                pullToRefresh.track(offset: newValue) {
                    await store.loadPage(target: target, force: true)
                    await store.loadTab(selectedTab)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: target.id) { await store.loadPage(target: target) }
        // The feeds this person chose to show. Only public ones come back, so
        // an empty result is the normal case and the row simply doesn't appear.
        .task(id: target.username) {
            publicFeeds = (try? await DiscourseClient().customFeeds(username: target.username))?
                .customFeeds ?? []
        }
        // 15 s ceiling: a tab that never answers shows 重试, not endless rows.
        .task(id: "\(store.username)-\(selectedTab.rawValue)-\(store.actionItems[selectedTab] == nil)") {
            let tab = selectedTab
            // Their ledger and saves are not ours to read; see `isOwnerOnly`.
            guard !tab.isOwnerOnly else { return }
            let finished = await withTimeout(seconds: 15) { await store.loadTab(tab) }
            if !finished, store.actionItems[tab] == nil { store.failedTabs.insert(tab) }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .showcase:
                AchievementShowcaseSheet(
                    name: store.displayName,
                    count: store.achievementCount,
                    items: store.showcase
                )
            case .badges: badgeSheet
            case .nodes: nodesSheet
            }
        }
        .alert(
            store.isBlocked ? AppString("取消屏蔽 @\(store.username)？") : AppString("屏蔽 @\(store.username)？"),
            isPresented: $isConfirmingBlock
        ) {
            if store.isBlocked {
                Button(AppString("取消屏蔽")) { Task { await store.setBlocked(false) } }
            } else {
                Button(AppString("屏蔽"), role: .destructive) { Task { await store.setBlocked(true) } }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(store.isBlocked
                ? AppString("会重新看到他的帖子和回复，他也可以再给你发消息。")
                : AppString("将隐藏他的帖子和回复，不再收到他的通知和消息。"))
        }
    }

    // MARK: Toolbar

    // The name in the bar is revealed 0 → 1 as the banner scrolls away
    // (`chrome.reveal`, from 60 over 80pt).

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if navigation.drawsBackButton {
            ToolbarItem(placement: .topBarLeading) {
                PageBackButton(action: onClose)
            }
        }
        ToolbarItem(placement: .principal) {
            BannerRevealView(chrome: chrome, gatesHitTesting: false) {
                userTitle
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                userMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("更多")
        }
    }

    /// Avatar + name as the bar's title, once the banner has scrolled away.
    private var userTitle: some View {
        HStack(spacing: 6) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 24
            )
            Text(store.displayName)
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
    }

    /// Android v1's order (通知方式, 举报, 屏蔽) with 聊天 ahead, as the header
    /// button has it (`/api/v1/messages/{u}`). 举报 is left out: Android's sends
    /// a direct message to a user named `moderators`, which the v1 backend
    /// looks up as an account and doesn't have, and there is no route that
    /// reports a person (only posts and nodes).
    @ViewBuilder
    private var userMenuContent: some View {
        if canInteract {
            Button { openChat() } label: {
                Label(AppString("聊天"), systemImage: "bubble.left.and.bubble.right")
            }
            notificationMenu
            Button(role: store.isBlocked ? nil : .destructive) {
                isConfirmingBlock = true
            } label: {
                Label(
                    store.isBlocked ? AppString("取消屏蔽") : AppString("屏蔽"),
                    systemImage: store.isBlocked ? "eye" : "eye.slash"
                )
            }
            .disabled(store.isUpdatingBlock)
        } else {
            Button {} label: { Label("暂无可用操作", systemImage: "nosign") }
                .disabled(true)
        }
    }

    /// 通知方式, with the current level checked. Android offers 常规 / 免打扰 /
    /// 忽略, but the v1 backend keeps one bit per person — anything but 常规 is
    /// `PUT /api/v1/users/{u}/block` — so 免打扰 couldn't be told apart from
    /// 忽略 or shown as current; the two real states are offered. 忽略 goes
    /// through the same confirmation as 屏蔽, since that is what it does, and
    /// that dialog says what it hides.
    private var notificationMenu: some View {
        Menu {
            Picker(AppString("通知方式"), selection: Binding(
                get: { store.isBlocked },
                set: { ignore in
                    if ignore {
                        isConfirmingBlock = true
                    } else {
                        Task { await store.setBlocked(false) }
                    }
                }
            )) {
                Label(AppString("常规"), systemImage: "bell").tag(false)
                Label(AppString("忽略"), systemImage: "bell.slash").tag(true)
            }
        } label: {
            Label(AppString("通知方式"), systemImage: store.isBlocked ? "bell.slash" : "bell")
        }
        .disabled(store.isUpdatingBlock)
    }

    /// 聊天: straight into the direct conversation. The chat tab resolves the
    /// channel (`ChatView.openRequestedChatIfNeeded`); this page has to get out
    /// of the way first — it may be on the page stack's full-screen cover,
    /// which would otherwise sit over the tab it just switched to.
    private func openChat() {
        guard store.canMessage else {
            ToastCenter.shared.show(store.messageNote ?? AppString("对方暂不接收消息"))
            return
        }
        let username = store.username
        if app.pageStack.isEmpty {
            onClose()
        } else {
            app.pageStack.removeAll()
        }
        app.openDirectMessage(username: username)
    }

    /// Signed in, and this is somebody else.
    private var canInteract: Bool {
        DiscourseAuth.shared.isAuthenticated
            && !store.username.isEmpty
            && store.username.caseInsensitiveCompare(DiscourseAuth.shared.username ?? "") != .orderedSame
    }

    /// About the navigation bar's height: the banner reaches this far under it.
    private let headerRowHeight: CGFloat = 56
    private let avatarSize: CGFloat = 72

    /// The banner below the bar's row.
    private let bannerHeight: CGFloat = 64

    private var profileHero: some View {
        VStack(spacing: 0) {
            // Runs to the very top, behind the status bar and the navigation
            // bar; grows with a pull past the top and stays pinned there.
            BannerPullView(chrome: chrome) { pullStretch in
                let height = bannerTotalHeight(pull: pullStretch)
                profileBanner(height: height)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .offset(y: -pullStretch)
                    .padding(.bottom, -pullStretch)
            }
            identityBlock
        }
    }

    /// Fixed-height banner: a tall image is aspect-filled then cropped to
    /// `bannerHeight` rather than pushing the content below it down.
    @ViewBuilder
    private func profileBanner(height: CGFloat) -> some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
            } placeholder: {
                profileBannerFallback(height: height)
            }
        } else {
            profileBannerFallback(height: height)
        }
    }

    private func profileBannerFallback(height: CGFloat) -> some View {
        Theme.profileBanner
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    /// Status bar + header row + the visible banner, plus any overscroll
    /// (`chrome.pull`: extra height while pulled down past the top; 0 otherwise).
    private func bannerTotalHeight(pull: CGFloat) -> CGFloat {
        UIApplication.topSafeAreaInset + headerRowHeight + bannerHeight + pull
    }

    /// 关注 / 已关注, backed by the discourse-follow endpoints.
    private var followButton: some View {
        Button {
            Task { await store.toggleFollow() }
        } label: {
            CapsuleActionLabel(
                title: store.isFollowing ? AppString("已关注") : AppString(key: "profile.follow", default: "关注"),
                style: store.isFollowing ? .neutral : .filled,
                isBusy: store.isTogglingFollow
            )
        }
        .buttonStyle(.pressable)
        .disabled(store.isTogglingFollow)
    }

    /// Avatar and actions, name and chips, handle, bio, meta, then the stats
    /// and the two collection cards — the same layout as 我的.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pulled up 32pt over the banner; the buttons drop 42pt so they
            // sit under the banner, beside the avatar's lower half.
            HStack(alignment: .top, spacing: 8) {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: avatarSize
                )
                .background(Theme.bg, in: Circle())
                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if canInteract {
                        Button { openChat() } label: {
                            CapsuleActionLabel(title: AppString("聊天"))
                                .opacity(store.canMessage ? 1 : 0.5)
                        }
                        .buttonStyle(.pressable)
                    }
                    if store.canFollow {
                        followButton
                    }
                }
                .padding(.top, 42)
            }
            .padding(.top, -32)

            FlowLayout(spacing: 6) {
                Text(store.displayName)
                    .font(Theme.heading(22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .frame(minHeight: 29)
                nameChips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            Text(store.joined.isEmpty ? "u/\(store.username)" : "u/\(store.username) · \(store.joined)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)

            if !store.bio.isEmpty {
                // Raw bio text: its `:shortcode:`s become the site's emoji.
                EmojiShortcodeText(text: store.bio.collapsingBlankLines, pointSize: 14)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            ProfileStatsCard(items: statItems)
                .padding(.top, 12)

            collectionCards
                .padding(.top, 8)

            // No inline spinner: the phase handles first loads, and a refresh
            // shows the system's own. A spinner row here appeared mid-page on
            // pull-to-refresh and shoved everything below it down a frame.
            if !store.isLoading, let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// The 段位 (`tier_name`); absent when they hide their level.
    private var tierName: String? {
        guard let name = store.tierName, !name.isEmpty else { return nil }
        return name
    }

    /// The 头衔 (`title`), unless it only repeats the tier.
    private var shownTitle: String? {
        guard let title = store.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              title != tierName
        else { return nil }
        return title
    }

    /// Tier, then the 头衔 when it isn't the tier, then roles and flair.
    @ViewBuilder
    private var nameChips: some View {
        if let tierName {
            ProfileNameChip(kind: .tier) { TierLabel(name: tierName, size: 12) }
                .padding(.vertical, 2.5)
        }
        if let shownTitle {
            UserTitleChip(title: shownTitle, style: store.titleStyle)
                .padding(.vertical, 2)
        }
        ForEach(store.roles) { role in
            ProfileNameChip(kind: .role) { Text(role.label) }
                .padding(.vertical, 2)
        }
        if let flair = store.flair {
            FlairBadge(flair: flair)
                .padding(.vertical, 4)
        }
    }

    /// 声望 / 能量 / 贡献 / 关注者, Android's four. 声望 comes from the
    /// achievements showcase and is absent when they turned off 显示等级与声望;
    /// 能量 from the board or the hover card (`userEnergy`), and opens the
    /// board only when they are on it.
    private var statItems: [ProfileStatsCard.Item] {
        var items: [ProfileStatsCard.Item] = []
        if let reputation = store.reputation {
            items.append(.init(value: "\(reputation)", label: AppString("声望")))
        }
        if let energy = store.energy {
            items.append(.init(
                value: Self.compactCount(energy.balance),
                label: AppString("能量"),
                action: energy.rank == nil ? nil : { app.pushPage(.leaderboard) }
            ))
        }
        if let contribution = store.contribution {
            items.append(.init(value: Self.compactCount(contribution), label: AppString("贡献")))
        }
        if let followers = store.followerCount {
            items.append(.init(value: "\(followers)", label: AppString("关注者")))
        }
        return items
    }

    /// "12.4k" past a thousand, so four figures fit one row.
    private static func compactCount(_ value: Int) -> String {
        if abs(value) >= 1_000_000 { return String(format: "%.1fm", Double(value) / 1_000_000) }
        if abs(value) >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    /// 成就 and 常去节点 side by side; each opens its sheet.
    @ViewBuilder
    private var collectionCards: some View {
        let achievementCount = max(store.achievementCount ?? 0, store.showcase.count)
        if achievementCount > 0 || !store.badges.isEmpty || !store.topCategories.isEmpty {
            let visible = ProfileCollectionCard<EmptyView>.visibleCount
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                if achievementCount > 0 {
                    let shown = Array(store.showcase.prefix(visible))
                    ProfileCollectionCard(
                        title: AppString("成就"),
                        count: "\(achievementCount)",
                        // Nothing picked to show: a lone "+N" reads as a
                        // glitch, so one neutral rosette stands in and the
                        // count in the corner says how many.
                        overflow: shown.isEmpty ? 0 : max(achievementCount - shown.count, 0),
                        action: { activeSheet = .showcase }
                    ) {
                        if shown.isEmpty {
                            Image(systemName: "rosette")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 40, height: 40)
                                .background(Theme.chip, in: Circle())
                                .overlapRing()
                        } else {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                                AchievementMedal(item: item, size: 40)
                                    .overlapRing(index: index)
                            }
                        }
                    }
                } else if !store.badges.isEmpty {
                    let shown = Array(store.badgeDetails.prefix(visible))
                    ProfileCollectionCard(
                        title: AppString("成就"),
                        count: "\(store.badges.count)",
                        overflow: max(store.badges.count - shown.count, 0),
                        action: { activeSheet = .badges }
                    ) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, badge in
                            ProfileBadgeIcon(badge: badge, size: 40)
                                .background(Theme.bg)
                                .overlapRing(index: index)
                        }
                    }
                }
                if !store.topCategories.isEmpty {
                    let shown = Array(store.topCategories.prefix(visible))
                    ProfileCollectionCard(
                        title: AppString("常去节点"),
                        count: AppString("\(store.topCategories.count) 个"),
                        overflow: max(store.topCategories.count - shown.count, 0),
                        action: { activeSheet = .nodes }
                    ) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                            nodeCircle(node, size: 40)
                                .overlapRing(index: index)
                        }
                    }
                }
            }
        }
    }

    /// A node's logo in a circle, or its letter on its colour without one.
    @ViewBuilder
    private func nodeCircle(_ node: SidebarNodeSummary, size: CGFloat) -> some View {
        NodeSummaryIcon(node: node, size: size, cornerRadius: size / 2)
            .background(Theme.bg, in: Circle())
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
                                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
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
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, 12)
                                .padding(.vertical, 7)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
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
        // On the page stack the feed simply pushes on top of this profile;
        // only the pinned-column copy has to make way first.
        if app.pageStack.isEmpty { onClose() }
        app.openCustomFeed(username: username, slug: feed.slug, name: feed.name)
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.badgeDetails) { item in
                        HStack(spacing: 12) {
                            ProfileBadgeIcon(badge: item, size: 44, cornerRadius: Theme.cornerMedium)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.textMuted)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
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
                        Button {
                            activeSheet = nil
                            app.openNode(slug: node.slug)
                        } label: {
                            HStack(spacing: 12) {
                                NodeSummaryIcon(node: node, size: 44, cornerRadius: Theme.cornerMedium)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.name)
                                        .font(Theme.body(15, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    if !node.description.isEmpty {
                                        Text(node.description)
                                            .font(Theme.body(12))
                                            .foregroundStyle(Theme.textMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if !node.memberCount.isEmpty {
                                    Text(node.memberCount)
                                        .font(Theme.body(11, weight: .semibold))
                                        .foregroundStyle(Theme.textFaint)
                                }
                            }
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                                    .strokeBorder(Theme.divider, lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                        }
                        .buttonStyle(.pressable)
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

    /// 管理的节点 — the public nodes this person owns, busiest first and at
    /// most eight, the same set the web's profile lists. Chips in the post
    /// reader's node-chip style, logo from `NodeCatalog`. Takes no space when
    /// they own none.
    @ViewBuilder
    private var ownedNodesRow: some View {
        if !store.ownedNodeSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppString("管理的节点"))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.ownedNodeSummaries, id: \.slug) { node in
                            Button {
                                app.openNode(slug: node.slug)
                            } label: {
                                HStack(spacing: 6) {
                                    nodeCircle(node, size: 24)
                                        .clipShape(Circle())
                                    Text("n/\(node.slug)")
                                        .font(Theme.body(13, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 12)
                                .frame(height: 32)
                                .background(Theme.chip, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(node.name)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// The system segmented control (the glass one on iOS 26).
    private var tabBar: some View {
        Picker(AppString("内容"), selection: Binding(
            get: { selectedTab },
            set: { tab in withAnimation(.quick) { selectedTab = tab } }
        )) {
            ForEach(ProfileStore.ProfileTab.publicDisplayOrder, id: \.value) { item in
                Text(item.label).tag(item.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var tabContent: some View {
        // Only 帖子 and 评论 are offered here (`publicDisplayOrder`).
        if store.actionItems[selectedTab] == nil, !store.failedTabs.contains(selectedTab) {
            // Not loaded yet (nil, not empty): rows, not "还没有…".
            ProfileRowsSkeleton()
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
            emptyTab(icon: "tray", text: AppString("还没有\(selectedTab.displayLabel)"))
        }
    }

    private var failedTab: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            Text("加载失败")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
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
        EmptyStateView(icon: icon, message: text, iconSize: 26)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        ProfileActivityRow(item: item) { openTopic(item) }
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
        // On the page stack, the post goes on top and ‹ comes back here.
        // Elsewhere (the pinned-sidebar column) the old hand-off stands.
        if !app.pageStack.isEmpty {
            app.openTopicPage(
                id: topicID,
                postNumber: item.postNumber,
                nodeSlug: item.categoryId.flatMap { NodelocAdapterState.shared.nodeSlug(forID: $0) }
            )
            return
        }
        onClose()
        app.openTopic(id: topicID, postNumber: item.postNumber)
    }

}
