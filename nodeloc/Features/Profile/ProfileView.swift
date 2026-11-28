//
//  ProfileView.swift
//  nodeloc
//

import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    /// Shared so switching tabs doesn't discard the loaded profile.
    private var store = ProfileStore.shared
    /// Which sheet is up. A single `.sheet(item:)` rather than one modifier
    /// per sheet: several `.sheet` on the same view silently collapse to
    /// whichever was applied last, which is why the badge and upgrade sheets
    /// never opened.
    @State private var activeSheet: ProfileSheet?

    private enum ProfileSheet: String, Identifiable {
        case badges, nodes, upgrade, editProfile
        var id: String { rawValue }
    }
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    /// Scroll-derived banner pull and title reveal, observed only by the
    /// views that draw them — see `BannerScrollChrome`.
    @State private var chrome = BannerScrollChrome(revealStart: 110, revealLength: 40)
    @State private var pullToRefresh = SilentPullToRefresh()
    /// Set while 编辑资料 is up, so dismissing it knows to reload.
    @State private var editedProfile = false
    /// The reader's achievements from `GET /api/v1/achievements`. The profile
    /// summary's badge list is always empty on this backend.
    @State private var achievements: NLAchievementList?

    /// Anchor for the scroll-to-top the identity capsule performs.
    private let topAnchor = "profile-top"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Nothing pins: the tab bar scrolls with the content. Sticking
                // it required a top safe-area inset, and that inset is what
                // stopped the banner reaching the top of the screen.
                // The phase is switched *outside* the lazy stack. Inside it,
                // every branch carried the same `.id(topAnchor)`, and the lazy
                // stack kept showing the skeleton it had already built for that
                // id after the store had moved on — the view logged "loaded"
                // while the screen stayed on the skeleton.
                switch store.phase {
                case .loading:
                    profileSkeleton
                        .id("profile-skeleton")
                case .failed(let message):
                    ProfileLoadFailedView(message: message) {
                        Task { await store.loadPage(isAppAuthed: app.authed, force: true) }
                    }
                    .id("profile-failed")
                case .loaded:
                    LazyVStack(spacing: 0) {
                        profileHero
                            .id(topAnchor)

                        tabBar
                        tabContent
                            .padding(.bottom, 112)
                    }
                    .id("profile-loaded")
                }
            }
            .scrollIndicators(.hidden)
            // The scroll view extends under the status bar so the banner fills
            // it. `.ignoresSafeArea` has to be here, not on the banner: a child
            // cannot escape the scroll view's own safe-area inset.
            .ignoresSafeArea(edges: .top)
            .background(Theme.bg)
            // Raw offset, not clamped: pulling down gives a negative value,
            // which is what stretches the banner.
            .tabBarFollowsScrollDirection()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                chrome.update(offset: newValue)
                // Pull-to-refresh with no spinner — see `SilentPullToRefresh`.
                pullToRefresh.track(offset: newValue) {
                    await store.loadPage(isAppAuthed: app.authed, force: true)
                    await store.loadTab(selectedTab)
                }
            }
            // The system bar, sitting on the banner. Inside the reader's
            // closure because the identity title scrolls back to the top.
            .toolbar {
                SidebarToolbarItem(sidebarIsPinned: sidebarIsPinned)
                // Not on iPad: the top tab bar owns the centre of that row.
                if !usesTopTabBar {
                    ToolbarItem(placement: .principal) {
                        // Not tappable while invisible. Its own view so the
                        // scroll re-renders only the title.
                        BannerRevealView(chrome: chrome) {
                            identityTitle(scrollProxy: proxy)
                        }
                    }
                }
                // 签到 and 设置 share one capsule, check-in first. Editing the
                // profile lives in 设置 › 个人资料.
                if !store.isGuest {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        CheckInBarButton(
                            isCheckedIn: store.hasCheckedInToday,
                            isBusy: store.isCheckingIn
                        ) {
                            if store.hasCheckedInToday {
                                ToastCenter.shared.show(AppString("今天已签到，明天再来"))
                            } else {
                                Task { await store.checkIn() }
                            }
                        }
                        Button {
                            app.pushPage(.settings)
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(Theme.text)
                        }
                        .accessibilityLabel(AppString("设置"))
                    }
                } else {
                    // Guests: 设置 has their display settings (appearance,
                    // language) and 登录. No 签到 without an account.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            app.pushPage(.settings)
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(Theme.text)
                        }
                        .accessibilityLabel(AppString("设置"))
                    }
                }
            }
            .bannerPageNavigationBar(bannerIsUnderBar: chrome.bannerIsUnderBar)
            // Inside the closure: this is where `proxy` exists.
            .onChange(of: app.scrollToTopRequests) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(topAnchor, anchor: .top)
                }
            }
        }
        .task(id: app.authed) { await store.loadPage(isAppAuthed: app.authed) }
        // 签到 is per day and per account: re-read it when the day turns over
        // with the app open, when the app comes back, and on an account switch.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            // Posted off the main thread; the store is the main actor's.
            Task { @MainActor in store.refreshCheckInDay() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshCheckInDay() }
        }
        .onChange(of: DiscourseAuth.shared.username) { _, _ in store.refreshCheckInDay() }
        .task(id: store.username) {
            guard !store.username.isEmpty, !store.isGuest else {
                achievements = nil
                return
            }
            if let list = try? await DiscourseClient().achievementList() {
                achievements = list
            }
        }
        // The stream only sends this to someone with a queue, so it stays 0
        // for everyone else — the same source settings uses.
        // 15 s ceiling: a tab that never answers shows 重试, not endless rows.
        .task(id: tabTaskKey) {
            let tab = selectedTab
            let finished = await withTimeout(seconds: 15) { await store.loadTab(tab) }
            if !finished, store.actionItems[tab] == nil { store.failedTabs.insert(tab) }
        }
        // The tab has to be reloaded explicitly. `force` clears `actionItems`,
        // but `tabTaskKey` is username + tab — neither changes on a refresh, so
        // the `.task(id:)` above never re-runs and the list was left empty.
        // 编辑资料 changes what this page shows, so closing it reloads.
        .sheet(item: $activeSheet, onDismiss: {
            guard editedProfile else { return }
            editedProfile = false
            Task { await store.loadPage(isAppAuthed: app.authed, force: true) }
        }) { sheet in
            switch sheet {
            case .editProfile:
                ProfileEditPage(onClose: { activeSheet = nil })
                    .onAppear { editedProfile = true }
            case .badges: badgeSheet
            case .nodes: nodesSheet
            case .upgrade:
                if let progress = store.upgradeProgress {
                    UpgradeProgressSheet(report: progress)
                }
            }
        }
    }

    /// Re-run tab loading when either the selected tab or the loaded user changes.
    ///
    /// Also keyed on whether the tab's list is empty-because-unloaded: when
    /// the store resets its lists (a new user seeded, a refresh), the key
    /// changes and the tab loads again. Without it the first page could
    /// arrive, get cleared by that reset, and never be asked for again — the
    /// rows stayed on their skeleton.
    private var tabTaskKey: String {
        "\(store.username)-\(selectedTab.rawValue)-\(store.actionItems[selectedTab] == nil)"
    }

    /// The banner runs under the navigation bar and then `bannerHeight` more,
    /// so the avatar overlapping its bottom edge clears the bar.
    private let bannerHeight: CGFloat = 64
    /// About the navigation bar's height: the banner reaches this far under it.
    private let headerRowHeight: CGFloat = 56
    private let avatarSize: CGFloat = 72

    private var profileHero: some View {
        VStack(spacing: 0) {
            // The banner runs to the very top — behind the status bar and the
            // navigation bar — and then `bannerHeight` more, so the part
            // below the buttons is unchanged. Pulled down past the top it
            // grows by the overscroll and stays pinned there: no gap opens
            // above it.
            BannerPullView(chrome: chrome) { pullStretch in
                profileBanner
                    .frame(height: UIApplication.topSafeAreaInset + headerRowHeight + bannerHeight + pullStretch)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .offset(y: -pullStretch)
                    .padding(.bottom, -pullStretch)
            }

            identityBlock
        }
    }

    // MARK: Skeleton

    /// The first open of an account, when there is no snapshot to draw instead.
    ///
    /// Shaped like `profileHero` + `redditStatsRow` + `tabBar` rather than being
    /// a generic shimmer, so the real page lands roughly where the placeholders
    /// were instead of shoving everything down when it arrives. One pulse on
    /// the container keeps every piece in phase, as on the feed.
    ///
    /// This replaces a screenful of `--`: `ProfileStat.placeholders` and the
    /// seeded initial used to be what a cold start showed, which reads as data
    /// that failed rather than data that is coming.
    private var profileSkeleton: some View {
        ProfileSkeleton(
            topInset: UIApplication.topSafeAreaInset + headerRowHeight,
            bannerHeight: bannerHeight
        )
        .padding(.bottom, 112)
    }

    /// Avatar + name as the bar's title, shown once the big card is out of
    /// view. Tapping returns to the top, the usual gesture for a collapsed
    /// title.
    private func identityTitle(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy.scrollTo(topAnchor, anchor: .top)
            }
        } label: {
            HStack(spacing: 8) {
                if store.isGuest {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 24, height: 24)
                } else {
                    RemoteAvatar(
                        url: store.avatarURL,
                        letter: store.initial,
                        variant: abs(store.username.hashValue),
                        size: 24
                    )
                }
                Text(store.displayName)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppString("回到顶部"))
    }

    // The title fades in as the display name slides behind the bar (reveal
    // from 110 over 40pt, in `chrome`). The name sits about 140pt below the
    // safe-area top (bar, banner, the avatar's lower half), so it passes
    // under the bar at a scroll of ≈ 90. The banner's pull stretch is
    // `chrome.pull`: zero at rest and when scrolling up, so it only ever
    // grows the image.

    /// Banner artwork. Scales to *cover* whatever height the hero gives it —
    /// enlarging a small image or shrinking a large one — then crops the
    /// overflow. It must not carry its own fixed height: the container is
    /// `bannerHeight` plus the status bar, so a hard-coded `bannerHeight` left
    /// the image short by the status bar, with gaps above and below.
    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                profileBannerFallback
            }
            // Fills the frame the hero sets, then trims the excess. Without the
            // clip a filled image reports its scaled size and widens the page.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        Theme.profileBanner
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Avatar and actions, name and chips, handle, bio, meta, then the stats
    /// and the two collection cards.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pulled up 32pt over the banner; the buttons drop 42pt so they
            // sit under the banner, beside the avatar's lower half.
            HStack(alignment: .top, spacing: 8) {
                profileAvatar
                Spacer(minLength: 8)
                identityActions
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

            Text(handleLine)
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

            if store.isGuest {
                // No stats or cards follow, so the bio would otherwise sit
                // right on the tab strip.
                Spacer().frame(height: 12)
            } else {
                ProfileStatsCard(items: statItems)
                    .padding(.top, 12)
            }

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

    @ViewBuilder
    private var profileAvatar: some View {
        Group {
            if store.isGuest {
                // The generic guest avatar, same as the post reader's.
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Theme.bg, in: Circle())
            } else {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: avatarSize
                )
            }
        }
        .background(Theme.bg, in: Circle())
        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
    }

    /// Guests get the login button here; a signed-in reader's 签到 is in
    /// the top bar and editing is in 设置 › 个人资料.
    @ViewBuilder
    private var identityActions: some View {
        if store.isGuest {
            guestLoginAction
        }
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
        // A guest's only role is GUEST, which the name already says.
        if !store.isGuest {
            ForEach(store.roles) { role in
                ProfileNameChip(kind: .role) { Text(role.label) }
                    .padding(.vertical, 2)
            }
        }
        if let flair = store.flair {
            FlairBadge(flair: flair)
                .padding(.vertical, 4)
        }
    }

    /// "u/username · 2024年3月 加入"; guests see their mode instead.
    private var handleLine: String {
        if store.isGuest { return store.lastSeen }
        return store.joined.isEmpty ? "u/\(store.username)" : "u/\(store.username) · \(store.joined)"
    }

    /// 声望 / 能量 / 关注者 — the ones the store has. `ProfileStat.row` puts 能量
    /// first and 声望 second.
    private var statItems: [ProfileStatsCard.Item] {
        var items: [ProfileStatsCard.Item] = []
        // "--" is the store's not-loaded placeholder; leave those out.
        if store.stats.count > 1, store.stats[1].value != "--" {
            items.append(.init(
                value: store.stats[1].value,
                label: AppString("声望"),
                action: { app.pushPage(.reputation) }
            ))
        }
        if let energy = store.stats.first, energy.value != "--" {
            items.append(.init(
                value: energy.value,
                label: AppString("能量"),
                action: { app.pushPage(.energy) }
            ))
        }
        if let followers = store.followerCount {
            items.append(.init(value: "\(followers)", label: AppString("关注者")))
        }
        // 升级进度 as the fourth cell; tapping opens the requirements.
        if let report = store.upgradeProgress, report.hasConditions {
            items.append(.init(
                value: "\(report.satisfiedCount)/\(report.allConditions.count)",
                label: AppString("升级进度"),
                action: { activeSheet = .upgrade }
            ))
        }
        return items
    }

    /// 成就 and 常去节点 side by side; each opens its sheet.
    @ViewBuilder
    private var collectionCards: some View {
        if achievements != nil || !store.badges.isEmpty || !store.recentNodes.isEmpty {
            let visible = ProfileCollectionCard<EmptyView>.visibleCount
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                if let list = achievements {
                    // Most recently earned first.
                    let unlocked = list.achievements
                        .filter { $0.isUnlocked && $0.off != true }
                        .sorted { ($0.lastAt ?? $0.unlockedAt ?? "") > ($1.lastAt ?? $1.unlockedAt ?? "") }
                    let count = list.unlockedCount ?? unlocked.count
                    let shown = Array(unlocked.prefix(visible))
                    ProfileCollectionCard(
                        title: AppString("成就"),
                        count: list.total.map { "\(count) / \($0)" } ?? "\(count)",
                        overflow: max(count - shown.count, 0),
                        action: { app.pushPage(.reputation) }
                    ) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            AchievementMedal(item: item, size: 40)
                                .overlapRing(index: index)
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
                if !store.recentNodes.isEmpty {
                    let shown = Array(store.recentNodes.prefix(visible))
                    ProfileCollectionCard(
                        title: AppString("常去节点"),
                        count: AppString("\(store.recentNodes.count) 个"),
                        overflow: max(store.recentNodes.count - shown.count, 0),
                        action: { activeSheet = .nodes }
                    ) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, node in
                            // The shared node icon: logo, else the node's glyph on its colour.
                            NodeSummaryIcon(node: node, size: 40, cornerRadius: 20)
                                .background(Theme.bg, in: Circle())
                                .overlapRing(index: index)
                        }
                    }
                }
            }
        }
    }

    /// Guests still need a way into the login flow — the same auth flow as
    /// the 登录 in the other tabs' bars, as a glass capsule of its own here.
    private var guestLoginAction: some View {
        Button {
            presentAuth(app)
        } label: {
            Text("登录")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.headerText)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(height: FloatingHeader.controlHeight)
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .capsule)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
    }

    // MARK: Sheets

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.recentNodes) { node in
                        Button {
                            activeSheet = nil
                            app.openNode(slug: node.slug)
                        } label: {
                            ProfileNodeRow(node: node)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeSheet = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet()
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeSheet = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet()
    }


    // MARK: Activity tabs

    /// The system segmented control (the glass one on iOS 26).
    private var tabBar: some View {
        Picker(AppString("内容"), selection: Binding(
            get: { selectedTab },
            set: { tab in withAnimation(.quick) { selectedTab = tab } }
        )) {
            ForEach(ProfileStore.ProfileTab.displayOrder, id: \.value) { item in
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
        if selectedTab == .energy {
            energyContent
        } else if !store.isGuest, store.actionItems[selectedTab] == nil, !store.failedTabs.contains(selectedTab) {
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
            // A failed request is not an empty tab; offer the retry instead of
            // claiming there is nothing here.
            failedTab
        } else {
            emptyTab
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

    /// 能量 history from the discourse-points-service plugin.
    @ViewBuilder
    private var energyContent: some View {
        if !store.isGuest && !store.pointsLoaded && store.pointsHistory.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
        } else if store.pointsHistory.isEmpty {
            EmptyStateView(
                icon: "bolt.slash",
                message: store.isGuest ? AppString("登录后查看你的能量历史") : AppString("暂无能量历史记录"),
                iconSize: 26
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            LazyVStack(spacing: 0) {
                leaderboardRow
                ForEach(store.pointsHistory) { pointsRow($0) }
            }
        }
    }

    /// 当前能量 with the 财富榜 place and 全部明细 (the energy page), as the
    /// artboard heads this tab.
    private var leaderboardRow: some View {
        EnergyTabHeader(balance: store.pointsTotal)
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
                Text(pointsDate(entry))
                    .font(Theme.body(11, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
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

    /// Prefers the event's own date; falls back to the created timestamp.
    private func pointsDate(_ entry: PointsHistoryEntry) -> String {
        if let date = entry.date, !date.isEmpty {
            return String(date.prefix(10))
        }
        return DiscourseFormat.relative(entry.createdAt)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        ProfileActivityRow(item: item) { openAction(item) }
    }

    private var emptyTab: some View {
        EmptyStateView(
            icon: "tray",
            message: store.isGuest ? AppString("登录后查看你的\(selectedTab.displayLabel)") : AppString("还没有\(selectedTab.displayLabel)"),
            iconSize: 26
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func openAction(_ item: UserActionItem) {
        guard let topicId = item.topicId else { return }
        let author = item.name?.isEmpty == false ? item.name! : (item.username ?? "?")
        // At the reply itself for a 帖子 row, as the public profile does.
        let slug = item.categoryId.flatMap { NodelocAdapterState.shared.nodeSlug(forID: $0) }
        app.openReader(Post(
            id: topicId,
            node: slug.map { "n/\($0)" } ?? "",
            avatarLetter: String(author.prefix(1)).uppercased(),
            variant: abs(author.hashValue) % 2,
            time: DiscourseFormat.relative(item.createdAt),
            title: item.title ?? "",
            excerpt: DiscourseFormat.plainText(item.excerpt ?? ""),
            baseVotes: 0,
            comments: 0,
            hasImage: false,
            authorUsername: item.username,
            authorName: item.name
        ), postNumber: item.postNumber)
    }

}

/// Node accent color from a Discourse category hex string.
private func profileNodeColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
    return Color(hex: value)
}

/// Row in the "最近访问" sheet.
private struct ProfileNodeRow: View {
    let node: SidebarNodeSummary

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(node.description)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Text(node.memberCount)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var icon: some View {
        NodeSummaryIcon(node: node, size: 44, cornerRadius: Theme.cornerMedium)
    }

    private var letter: String { String(node.name.prefix(1)) }
}

#Preview {
    let app = AppState()
    app.authed = true
    app.onboardingDone = true
    return ProfileView()
        .environment(app)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
}

// MARK: - 升级进度 (discourse-upgrade-process)

/// The full requirement list behind the banner's progress track.
private struct UpgradeProgressSheet: View {
    let report: UpgradeProgressReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary

                    if !statuses.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(statuses) { statusRow($0) }
                        }
                    }

                    if !metrics.isEmpty {
                        LazyVGrid(columns: metricColumns, spacing: 10) {
                            ForEach(metrics) { metricCard($0) }
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("升级进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .standardSheet()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(Theme.heading(18, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text(report.isRetention
                 ? AppString("维持要求 \(report.satisfiedCount)/\(report.totalConditions ?? report.allConditions.count) 项达标")
                 : AppString("已满足 \(report.satisfiedCount)/\(report.totalConditions ?? report.allConditions.count) 项要求"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)

            // At the top level the requirements are upkeep: falling behind
            // matters, so say so rather than implying there's nothing to do.
            if report.isRetention, !report.allMet {
                Label("有维持要求未达标", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }

            ProgressView(value: report.fraction)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
    }

    private var headline: String {
        if report.isRetention {
            // Already at the top: this panel is about holding the level.
            if let level = report.currentLevelName {
                return AppString("\(level) · 维持中")
            }
            return AppString("等级维持")
        }
        if let next = report.nextLevelName {
            return AppString("距离 \(next) 还差一步")
        }
        return AppString("升级进度")
    }

    // MARK: Requirements

    private var metricColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    /// Yes/no requirements read as a list; everything countable is a card, two
    /// to a row — the same split the plugin's own panel makes.
    private var statuses: [UpgradeCondition] { ordered.filter(\.isStatus) }
    private var metrics: [UpgradeCondition] { ordered.filter { !$0.isStatus } }

    /// Unmet first: those are what the user opened this for. Sorted on the
    /// index as a tiebreak, since `sorted(by:)` gives no stability guarantee.
    private var ordered: [UpgradeCondition] {
        report.allConditions.enumerated()
            .sorted { lhs, rhs in
                let left = (lhs.element.met == true ? 1 : 0, lhs.offset)
                let right = (rhs.element.met == true ? 1 : 0, rhs.offset)
                return left < right
            }
            .map(\.element)
    }

    private func statusRow(_ condition: UpgradeCondition) -> some View {
        HStack(spacing: 10) {
            Image(systemName: condition.met == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(condition.met == true ? Theme.success : Theme.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text(condition.displayName)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)

                if let scope = condition.scope, !scope.isEmpty {
                    Text(scope)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func metricCard(_ condition: UpgradeCondition) -> some View {
        let met = condition.met == true
        let tint = met ? Theme.success : Theme.accent

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Text(condition.displayName)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    // Reserved so both cards in a row are the same height even
                    // when one name wraps.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(met ? Theme.success : Theme.textFaint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(condition.value ?? 0))
                    .font(Theme.heading(19, weight: .bold))
                    .foregroundStyle(Theme.text)

                if let target = condition.target {
                    Text(condition.isLimit ? AppString("上限 \(number(target))") : AppString("目标 \(number(target))"))
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer(minLength: 0)
            }

            ProgressView(value: condition.fraction)
                .tint(tint)

            Text(hint(for: condition))
                .font(Theme.body(10, weight: .medium))
                .foregroundStyle(met ? Theme.success : Theme.textMuted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    /// The plugin's own wording, so the app and the site agree.
    private func hint(for condition: UpgradeCondition) -> String {
        if condition.met == true {
            return condition.isLimit ? AppString("未超限") : AppString("已达标")
        }
        let remaining = number(condition.shortfall)
        return condition.isLimit
            ? AppString("超出 \(remaining)")
            : AppString("还差 \(remaining)")
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}


/// 签到 in the profile's top bar, beside 设置 in one capsule. Lucide's
/// calendar-heart (ISC, see NOTICE.md) on its 24 grid, drawn the size of the
/// settings symbol: a small orange dot until today's check-in, grey once
/// done, a spinner while it runs.
struct CheckInBarButton: View {
    let isCheckedIn: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                if isBusy {
                    ProgressView()
                        .frame(width: 22, height: 22)
                } else {
                    Image("LucideCalendarHeart")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 23, height: 23)
                        // Done for today: greyed, dimmer than 设置 beside it.
                        .foregroundStyle(isCheckedIn ? Color(.secondaryLabel) : Theme.text)
                        .contentTransition(.symbolEffect(.replace))
                }
                if !isCheckedIn, !isBusy {
                    Circle()
                        .fill(KnotDrawing.nodeOrange)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -1)
                }
            }
        }
        .disabled(isBusy)
        .accessibilityLabel(isCheckedIn ? AppString("今日已签到") : AppString("签到"))
    }
}
