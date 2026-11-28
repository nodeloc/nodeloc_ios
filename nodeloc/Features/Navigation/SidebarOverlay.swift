//
//  SidebarOverlay.swift
//  nodeloc
//
//  The drawer (App-iOS-Sidebar, -Sidebar2): structured like Reddit's, with our
//  own content, icons and colours, in a floating glass panel.
//
//  Order: the account, then 首页 / 财富榜 (热门 is the home page's own tab; 创建节点 is the + on 我的节点 and 节点广场), 小游戏和应用,
//  最近访问, 收藏的节点, 我管理的节点 (审核队列 and 管理台 live here),
//  我加入的节点, 我的, 关于. A divider between sections; every titled section
//  but 最近访问 folds, and remembers it on the device. Nodes carry a favourite
//  star at the right; lit ones are what 收藏的节点 lists.
//
//  It opens instantly: everything is drawn from the last snapshot kept on the
//  device and refreshed underneath.
//

import SwiftUI

extension EnvironmentValues {
    /// True while the sidebar is a permanent column rather than a drawer.
    ///
    /// Decided in one place (`MainView`) and read from here, so the layout and
    /// the menu button can't disagree. Checking the size class at each site
    /// instead would get this wrong: an iPhone Max in landscape reports a
    /// *regular* horizontal size class, so `horizontalSizeClass` alone would
    /// hide the menu button on a phone that still needs it.
    @Entry var sidebarIsPinned: Bool = false
    /// Whether the tab bar is drawn at the top of the content, so a screen's
    /// own controls belong in its toolbar row rather than in a floating header
    /// of their own.
    ///
    /// Distinct from `sidebarIsPinned`, which answers a different question —
    /// whether the sidebar is a permanent column. One flag was doing both, and
    /// they disagree on iPad portrait: the drawer is still a drawer there, but
    /// the tab bar is still at the top, so the floating header ended up as a
    /// second row underneath it.
    @Entry var usesTopTabBar: Bool = false
}

/// The width of the sidebar when it's pinned open beside the content.
///
/// Fixed rather than a fraction: as a permanent column it should stay put while
/// the window resizes, and the drawer's 86%-of-width would be absurd on iPad.
let pinnedSidebarWidth: CGFloat = 320

// MARK: - Recent nodes

/// 最近访问, kept on the device: the server doesn't record it. Most recent
/// first, a few at most.
enum RecentNodes {
    private static let key = "sidebar.recentNodes"
    static let cap = 10
    static let didChange = Notification.Name("NodelocRecentNodesDidChange")

    static var slugs: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ slug: String) {
        let cleaned = slug.lowercased()
        guard !cleaned.isEmpty else { return }
        var list = slugs.filter { $0 != cleaned }
        list.insert(cleaned, at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - Model

/// What the drawer lists, cached on the device per account so it draws at
/// once, and refreshed in the background each time it opens.
@MainActor
@Observable
final class SidebarModel {
    static let shared = SidebarModel()

    struct NodeRow: Codable, Hashable, Identifiable {
        let slug: String
        let name: String
        let colorHex: String
        /// What waits in the node's queue, for a node the reader manages.
        var pending: Int?
        var id: String { slug }
    }

    struct FeedRow: Codable, Hashable, Identifiable {
        let username: String
        let slug: String
        let name: String
        /// Optional so snapshots cached before they existed still decode.
        var feedID: Int? = nil
        var color: String? = nil
        var canEdit: Bool? = nil
        var id: String { "\(username)/\(slug)" }
    }

    struct Snapshot: Codable {
        var managed: [NodeRow] = []
        var joined: [NodeRow] = []
        var favorites: [NodeRow] = []
        var feeds: [FeedRow] = []
        var draftCount: Int?
        var isStaff = false
        var canCreateNode = false
    }

    private(set) var snapshot = Snapshot()
    /// The last feed load failed: the section says so and offers 重试,
    /// rather than passing an error off as "no feeds".
    private(set) var feedsFailed = false
    /// The feeds as the server sent them, for 编辑 (not cached).
    private(set) var feedObjects: [Int: CustomFeed] = [:]
    private(set) var recent: [String] = RecentNodes.slugs
    private var loadedKey: String?
    private var refreshing = false

    private let client = DiscourseClient()

    private var accountKey: String {
        "sidebar.snapshot.v2.\(DiscourseAuth.shared.username?.lowercased() ?? "guest")"
    }

    /// Lit stars, by slug.
    var favoriteSlugs: Set<String> { Set(snapshot.favorites.map(\.slug)) }

    /// Swaps in the account's cached snapshot when the account changed.
    func prepare() {
        recent = RecentNodes.slugs
        let key = accountKey
        guard loadedKey != key else { return }
        loadedKey = key
        if let data = UserDefaults.standard.data(forKey: key),
           let cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = cached
        } else {
            snapshot = Snapshot()
        }
    }

    func refresh(isSignedIn: Bool) async {
        prepare()
        guard isSignedIn, DiscourseAuth.shared.isAuthenticated, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        async let nodesCall = try? client.myNodes()
        async let feedsCall: CustomFeedsResponse? = { [client] in
            do { return try await client.customFeeds() } catch { return nil }
        }()
        async let draftsCall = try? client.drafts()
        let (mine, feeds, drafts) = await (nodesCall, feedsCall, draftsCall)

        var next = snapshot
        next.isStaff = DiscourseAuth.shared.isStaff
        if let mine {
            func row(_ slug: String, _ name: String?, _ color: String?, pending: Int? = nil) -> NodeRow {
                NodeRow(slug: slug, name: name ?? slug, colorHex: color ?? "007A52", pending: pending)
            }
            let managed = mine.joined.filter { $0.pending != nil || $0.owner == true || $0.role == "moderator" }
            let managedSlugs = Set(managed.map(\.slug))
            next.managed = managed.map { node in
                let pending = node.pending.map { ($0.reports ?? 0) + ($0.queued ?? 0) + ($0.joinRequests ?? 0) }
                return row(node.slug, node.name, node.color, pending: pending)
            }
            next.joined = mine.joined.filter { !managedSlugs.contains($0.slug) }.map { row($0.slug, $0.name, $0.color) }
            next.favorites = (mine.favorites ?? []).map { row($0.slug, $0.name, $0.color) }
        }
        feedsFailed = feeds == nil
        if let feeds {
            next.feeds = feeds.customFeeds.compactMap { feed in
                guard let username = feed.username else { return nil }
                return FeedRow(username: username, slug: feed.slug, name: feed.name,
                               feedID: feed.id, color: feed.color, canEdit: feed.canEdit ?? true)
            }
            feedObjects = Dictionary(feeds.customFeeds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let drafts { next.draftCount = drafts.drafts.count }
        apply(next)
    }

    /// Drops a deleted feed at once, before the next refresh.
    func removeFeed(id: Int) {
        var next = snapshot
        next.feeds.removeAll { $0.feedID == id }
        feedObjects[id] = nil
        apply(next)
    }

    private func apply(_ next: Snapshot) {
        snapshot = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: accountKey)
        }
    }

    /// Lights or clears a node's star: at once on screen, then on the server;
    /// put back if the server says no.
    func toggleFavorite(slug: String, name: String, colorHex: String) {
        let before = snapshot
        var next = snapshot
        let on = !favoriteSlugs.contains(slug)
        if on {
            next.favorites.append(NodeRow(slug: slug, name: name, colorHex: colorHex))
        } else {
            next.favorites.removeAll { $0.slug == slug }
        }
        apply(next)
        Task {
            do {
                try await client.setNodeFavorite(slug: slug, favorite: on)
                ToastCenter.shared.show(on ? AppString("已收藏 n/\(slug)") : AppString("已取消收藏 n/\(slug)"))
            } catch {
                apply(before)
                ToastCenter.shared.showError(error)
            }
        }
    }

    func recentRows() -> [NodeRow] {
        recent.map { slug in
            let cached = NodeCatalog.shared.cachedNode(slug: slug)
            return NodeRow(slug: slug, name: cached?.name ?? slug, colorHex: cached?.colorHex ?? "007A52")
        }
    }
}

// MARK: - Sidebar

struct SidebarOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    let panelWidth: CGFloat?
    /// Pinned beside the content instead of floating over it.
    let isPinned: Bool

    @State private var model = SidebarModel.shared
    @State private var profile = ProfileStore.shared
    @State private var pendingReview = NodelocRealtime.shared.pendingReview ?? 0
    @State private var pendingByNode = NodelocRealtime.shared.pendingReviewByNode
    @State private var collapsed: Set<String> = SidebarOverlay.loadCollapsed()
    @State private var showsAllRecent = false
    /// 创建信息流 / 编辑, and the feed waiting on 删除's confirmation.
    @State private var feedForm: CustomFeedFormSheet.Mode?
    @State private var feedToDelete: SidebarModel.FeedRow?
    /// Long sections opened past their first five; kept on the device.
    @State private var expanded: Set<String> = SidebarOverlay.loadExpanded()

    init(panelWidth: CGFloat? = nil, isPinned: Bool = false) {
        self.panelWidth = panelWidth
        self.isPinned = isPinned
    }

    var body: some View {
        GeometryReader { proxy in
            let width = panelWidth ?? min(proxy.size.width * 0.86, 330)
            // The window's own insets: the tab bar's inset would otherwise
            // stop the floating panel short of the bottom edge.
            panel(
                width: width,
                topInset: isPinned ? proxy.safeAreaInsets.top : UIApplication.topSafeAreaInset,
                bottomInset: isPinned ? proxy.safeAreaInsets.bottom : UIApplication.bottomSafeAreaInset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: isPinned ? [] : .vertical)
        .onAppear {
            model.prepare()
            RecentAppsStore.shared.prepare()
        }
        .sheet(item: $feedForm) { mode in
            CustomFeedFormSheet(mode: mode) { saved in
                await model.refresh(isSignedIn: isSignedIn)
                // A new feed opens, so its nodes can be added straight away.
                if case .create = mode, let username = saved.username {
                    perform { app.openCustomFeed(username: username, slug: saved.slug, name: saved.name) }
                }
            }
        }
        .alert(
            AppString("删除这个信息流？"),
            isPresented: Binding(get: { feedToDelete != nil }, set: { if !$0 { feedToDelete = nil } })
        ) {
            Button(AppString("删除"), role: .destructive) {
                if let feed = feedToDelete { deleteFeed(feed) }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(feedToDelete.map { AppString("「\($0.name)」会被删除，订阅它的人也看不到了。") } ?? "")
        }
        .task { await model.refresh(isSignedIn: isSignedIn) }
        // The header's 能量 and 段位 come from the profile; loaded once in
        // the background when nothing has loaded it yet.
        .task {
            guard isSignedIn, profile.pointsTotal == nil || profile.username.isEmpty else { return }
            await profile.load(isAppAuthed: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NodeMembership.didChange)) { _ in
            Task { await model.refresh(isSignedIn: isSignedIn) }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecentNodes.didChange)) { _ in
            model.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: NodelocRealtime.pendingReviewDidChange)) { _ in
            pendingReview = NodelocRealtime.shared.pendingReview ?? 0
            pendingByNode = NodelocRealtime.shared.pendingReviewByNode
        }
    }

    // MARK: Panel

    @ViewBuilder
    private func panel(width: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountHeader
                    .padding(.bottom, 10)
                mainNavigation
                divider
                recentApps
                sections
            }
            .padding(.horizontal, 10)
            .padding(.top, isPinned ? topInset + 12 : 18)
            .padding(.bottom, isPinned ? bottomInset + 24 : 22)
        }
        .scrollIndicators(.hidden)

        if isPinned {
            content
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Theme.bg)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
                .ignoresSafeArea(edges: .vertical)
        } else {
            // The floating glass panel: inset from the screen's edges, its
            // own rounded shape, over the dimmed content.
            content
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .glassSurface(tint: Theme.bg.opacity(0.55), in: .rounded(34))
                .shadow(color: .black.opacity(0.18), radius: 30, x: 8, y: 0)
                .padding(.leading, 8)
                .padding(.top, max(topInset - 4, 8))
                .padding(.bottom, max(bottomInset - 14, 8))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.horizontal, -10)
            .padding(.vertical, 6)
    }

    // MARK: Account

    @ViewBuilder
    private var accountHeader: some View {
        if isSignedIn {
            Button {
                perform { app.tab = .profile }
            } label: {
                HStack(spacing: 12) {
                    accountAvatar
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(accountName)
                                .font(Theme.body(18, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if let role = roleBadge {
                                Label(role, systemImage: "checkmark.shield")
                                    .font(Theme.body(11, weight: .bold))
                                    .labelStyle(SidebarBadgeLabelStyle())
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .frame(height: 20)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }
                        if let line = accountLine {
                            Text(line)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        } else {
            Button {
                // The header row is an invitation, so it asks with the
                // shared prompt (登录 / 注册新账号) rather than jumping in.
                perform { requestLogin(app, .generic) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppString("登录 / 注册"))
                            .font(Theme.body(17, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(AppString("加入节点、收藏和发帖"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    private var accountAvatar: some View {
        Group {
            if let url = profile.avatarURL {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialAvatar
                }
            } else {
                initialAvatar
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private var initialAvatar: some View {
        Circle()
            .fill(Theme.accent)
            .overlay {
                Text(String(accountName.prefix(1)).uppercased())
                    .font(Theme.body(18, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private var accountName: String {
        let display = profile.displayName.trimmingCharacters(in: .whitespaces)
        if !display.isEmpty { return display }
        if !profile.username.isEmpty { return profile.username }
        return DiscourseAuth.shared.username ?? ""
    }

    /// 站务 for staff, 版主 for someone who manages a node.
    private var roleBadge: String? {
        if model.snapshot.isStaff || DiscourseAuth.shared.isStaff { return AppString("站务") }
        return model.snapshot.managed.isEmpty ? nil : AppString("版主")
    }

    /// 14,770 能量 · 钻石
    private var accountLine: String? {
        var parts: [String] = []
        if let points = profile.pointsTotal {
            parts.append(AppString("\(points.formatted()) 能量"))
        }
        if let tier = profile.tierName, !tier.isEmpty { parts.append(tier) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Main navigation

    private var mainNavigation: some View {
        VStack(spacing: 2) {
            navRow(AppString("首页"), icon: "house", selected: app.tab == .home && app.pageStack.isEmpty) {
                perform { app.tab = .home }
            }
            navRow(AppString("财富榜"), icon: "trophy") {
                perform { app.pushPage(.leaderboard) }
            }
        }
    }

    /// 最近玩过: the last few games and apps opened here, with 小游戏和应用
    /// as the section's "more" row. Without any, just that row as before.
    @ViewBuilder
    private var recentApps: some View {
        let recent = Array(RecentAppsStore.shared.items.prefix(4))
        if recent.isEmpty {
            appsRow
        } else {
            foldingSection(AppString("最近玩过"), key: "recentApps") {
                ForEach(recent) { item in
                    Button {
                        perform {
                            app.autoStartAppSlug = item.slug
                            app.openApp(slug: item.slug)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            RecentAppIcon(app: item)
                            Text(item.name)
                                .font(Theme.body(16))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
                appsRow
            }
        }
    }

    private var appsRow: some View {
        navRow(AppString("小游戏和应用"), icon: "gamecontroller", chevron: true) {
            perform { app.openAppsDirectory() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var sections: some View {
        let recent = model.recentRows()
        if !recent.isEmpty {
            divider
            sectionHeader(AppString("最近访问"), key: "recent", trailing: recent.count > 3 ? (showsAllRecent ? AppString("收起") : AppString("全部查看")) : nil) {
                withAnimation(.snappy) { showsAllRecent.toggle() }
            }
            ForEach(showsAllRecent ? recent : Array(recent.prefix(3))) { node in
                nodeRow(node)
            }
        }

        if isSignedIn {
            if !model.snapshot.favorites.isEmpty {
                divider
                foldingSection(AppString("收藏的节点"), key: "favorites") {
                    ForEach(model.snapshot.favorites) { node in nodeRow(node) }
                }
            }

            // Own section, after 收藏的节点 (the iOS sidebar frames have
            // none; feeds used to trail 我加入的节点 as "· 信息流" rows).
            divider
            foldingSection(AppString("自定义信息流"), key: "feeds") {
                let feeds = model.snapshot.feeds
                ForEach(expanded.contains("feeds") ? feeds : Array(feeds.prefix(Self.sectionCap))) { feed in
                    feedRow(feed)
                }
                if model.feedsFailed {
                    navRow(AppString("信息流没有加载出来，点这里重试"), icon: "arrow.clockwise") {
                        Task { await model.refresh(isSignedIn: isSignedIn) }
                    }
                }
                expandRow(total: feeds.count, key: "feeds")
                navRow(AppString("创建信息流"), icon: "plus") {
                    feedForm = .create
                }
            }

            if hasManagement {
                divider
                foldingSection(AppString("我管理的节点"), key: "managed") {
                    navRow(AppString("审核队列"), icon: "tray", count: queueCount) {
                        perform { app.pushPage(.reviewQueue(node: managementScope, item: nil)) }
                    }
                    navRow(AppString("管理台"), icon: "slider.horizontal.3") {
                        perform { app.pushPage(.moderationDashboard(node: managementScope)) }
                    }
                    let managed = orderedManaged
                    ForEach(capped(managed, key: "managed")) { node in
                        nodeRow(node, count: pendingByNode[node.slug] ?? node.pending)
                    }
                    expandRow(total: managed.count, key: "managed")
                }
            }

            if !model.snapshot.joined.isEmpty {
                divider
                foldingSection(AppString("我加入的节点"), key: "joined") {
                    let joined = orderedJoined
                    ForEach(capped(joined, key: "joined")) { node in nodeRow(node) }
                    expandRow(total: joined.count, key: "joined")
                    navRow(AppString("我的节点"), icon: "square.grid.2x2", chevron: true) {
                        perform { app.pushPage(.myNodes) }
                    }
                }
            }

            divider
            foldingSection(AppString("我的"), key: "mine") {
                navRow(AppString("邀请好友"), icon: "person.2") {
                    perform { app.pushPage(.invite) }
                }
                navRow(
                    AppString("草稿箱"),
                    icon: "doc.text",
                    detail: (model.snapshot.draftCount ?? 0) > 0 ? AppString("\(model.snapshot.draftCount ?? 0) 篇") : nil
                ) {
                    perform { app.pushPage(.drafts) }
                }
                navRow(AppString("我的收藏"), icon: "bookmark") {
                    perform { app.pushPage(.saved) }
                }
                navRow(AppString("浏览记录"), icon: "clock.arrow.circlepath") {
                    perform { app.pushPage(.history) }
                }
                navRow(AppString("我的交易"), icon: "arrow.left.arrow.right") {
                    perform { app.pushPage(.trades) }
                }
                navRow(AppString("账号状态"), icon: "checkmark.shield") {
                    perform { app.pushPage(.accountStatus) }
                }
            }
        }

        divider
        foldingSection(AppString("关于"), key: "about") {
            if isSignedIn {
                navRow(AppString("新人指引"), icon: "sparkles") {
                    perform { app.pushPage(.onboardingGuide) }
                }
            }
            navRow(AppString("社区规范"), icon: "doc.plaintext") {
                openSitePath("/guidelines")
            }
        }
    }

    // MARK: Long lists

    /// How many nodes a long section shows before 全部查看.
    private static let sectionCap = 5

    /// Nodes with something waiting first, then the ones visited lately,
    /// then the server's order.
    private var orderedManaged: [SidebarModel.NodeRow] {
        let recentIndex = Dictionary(model.recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return model.snapshot.managed.enumerated().sorted { lhs, rhs in
            let lp = pendingByNode[lhs.element.slug] ?? lhs.element.pending ?? 0
            let rp = pendingByNode[rhs.element.slug] ?? rhs.element.pending ?? 0
            if (lp > 0) != (rp > 0) { return lp > 0 }
            if lp != rp { return lp > rp }
            let lr = recentIndex[lhs.element.slug] ?? Int.max
            let rr = recentIndex[rhs.element.slug] ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var orderedJoined: [SidebarModel.NodeRow] {
        let recentIndex = Dictionary(model.recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return model.snapshot.joined.enumerated().sorted { lhs, rhs in
            let lr = recentIndex[lhs.element.slug] ?? Int.max
            let rr = recentIndex[rhs.element.slug] ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func capped(_ rows: [SidebarModel.NodeRow], key: String) -> [SidebarModel.NodeRow] {
        expanded.contains(key) ? rows : Array(rows.prefix(Self.sectionCap))
    }

    @ViewBuilder
    private func expandRow(total: Int, key: String) -> some View {
        if total > Self.sectionCap {
            let isExpanded = expanded.contains(key)
            Button {
                withAnimation(.snappy) {
                    if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
                }
                Self.saveExpanded(expanded)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isExpanded ? "chevron.up" : "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 26)
                    Text(isExpanded ? AppString("收起") : AppString("全部查看 · \(total)"))
                        .font(Theme.body(15, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }

    private var hasManagement: Bool {
        model.snapshot.isStaff || DiscourseAuth.shared.isStaff || !model.snapshot.managed.isEmpty
    }

    /// Staff work the site's queue; someone who only manages nodes, the
    /// first of theirs (the page switches between them).
    private var managementScope: String? {
        if model.snapshot.isStaff || DiscourseAuth.shared.isStaff { return nil }
        return model.snapshot.managed.first?.slug
    }

    private var queueCount: Int? {
        if model.snapshot.isStaff || DiscourseAuth.shared.isStaff {
            return pendingReview > 0 ? pendingReview : nil
        }
        let total = model.snapshot.managed.reduce(0) { $0 + (pendingByNode[$1.slug] ?? $1.pending ?? 0) }
        return total > 0 ? total : nil
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String, key: String, trailing: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func foldingSection<Content: View>(_ title: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy) {
                    if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
                }
                Self.saveCollapsed(collapsed)
            } label: {
                HStack {
                    Text(title)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isCollapsed ? AppString("已收起") : AppString("已展开"))

            if !isCollapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func navRow(
        _ title: String,
        icon: String,
        detail: String? = nil,
        count: Int? = nil,
        chevron: Bool = false,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                    .frame(width: 26)
                (Text(title).foregroundColor(selected ? Theme.accent : Theme.text)
                    + Text(detail.map { " · \($0)" } ?? "").foregroundColor(Theme.textMuted).font(Theme.body(14)))
                    .font(Theme.body(16, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count, count > 0 {
                    countPill(count)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(
                selected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    /// A feed: its colour tile, its name; 编辑 / 删除 on a long press for the
    /// owner (`PUT` / `DELETE /api/v1/custom-feeds/{id}`).
    private func feedRow(_ feed: SidebarModel.FeedRow) -> some View {
        Button {
            perform { app.openCustomFeed(username: feed.username, slug: feed.slug, name: feed.name) }
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(nodeAccentColor(feed.color ?? "009966"))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Text(feed.name)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .contextMenu {
            if feed.canEdit != false, let id = feed.feedID {
                if let object = model.feedObjects[id] {
                    Button { feedForm = .edit(object) } label: { Label(AppString("编辑"), systemImage: "pencil") }
                }
                Button(role: .destructive) { feedToDelete = feed } label: { Label(AppString("删除"), systemImage: "trash") }
            }
        }
    }

    private func deleteFeed(_ feed: SidebarModel.FeedRow) {
        guard let id = feed.feedID else { return }
        Task {
            do {
                try await DiscourseClient().deleteCustomFeed(id: id)
                model.removeFeed(id: id)
                ToastCenter.shared.show(AppString("已删除"))
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    private func nodeRow(_ node: SidebarModel.NodeRow, count: Int? = nil) -> some View {
        let isFavorite = model.favoriteSlugs.contains(node.slug)
        return HStack(spacing: 0) {
            Button {
                perform { app.openNode(slug: node.slug) }
            } label: {
                HStack(spacing: 12) {
                    SidebarNodeIcon(row: node)
                    Text("n/\(node.slug)")
                        .font(Theme.body(16))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let count, count > 0 {
                        countPill(count)
                    }
                }
                .padding(.leading, 12)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(node.name)

            if isSignedIn {
                Button {
                    model.toggleFavorite(slug: node.slug, name: node.name, colorHex: node.colorHex)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isFavorite ? Color(hex: 0xE8A100) : Theme.textFaint)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? AppString("取消收藏") : AppString("收藏"))
            }
        }
        .padding(.trailing, 2)
    }

    private func countPill(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Theme.body(13, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(AdminTone.amber.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(AdminTone.amber.fill, in: Capsule())
    }

    // MARK: Actions

    private var isSignedIn: Bool {
        return app.authed || DiscourseAuth.shared.isAuthenticated
    }

    /// Closes the drawer, then does the thing.
    private func perform(_ action: () -> Void) {
        withAnimation(.quick) {
            if !isPinned { app.overlay = nil }
            action()
        }
    }

    private func openSitePath(_ path: String) {
        guard let url = nodelocSiteURL(path) else { return }
        if !isPinned { app.overlay = nil }
        openURL(url)
    }

    // MARK: Folding memory

    private static let collapsedKey = "sidebar.collapsedSections"

    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }

    private static func saveCollapsed(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: collapsedKey)
    }

    private static let expandedKey = "sidebar.expandedSections"

    private static func loadExpanded() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? [])
    }

    private static func saveExpanded(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: expandedKey)
    }
}

/// The badge's shield sits close to its word.
private struct SidebarBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}

/// A node's round mark: its logo or glyph when the catalog has it, otherwise
/// its first letter on its colour.
private struct SidebarNodeIcon: View {
    let row: SidebarModel.NodeRow

    var body: some View {
        if let node = NodeCatalog.shared.cachedNode(slug: row.slug) {
            NodeAvatar(node: node, size: 30, cornerRadius: 15)
        } else {
            Circle()
                .fill(nodeAccentColor(row.colorHex))
                .frame(width: 30, height: 30)
                .overlay {
                    Text(String(row.name.prefix(1)))
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }
}


/// A recent app's logo in a circle, its first letter until (or without) one.
private struct RecentAppIcon: View {
    let app: RecentApp

    var body: some View {
        Group {
            if let url = NodeSummaryFactory.resolvedURL(app.logoUrl) {
                CachedRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    letter
                }
            } else {
                letter
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 0.5))
    }

    private var letter: some View {
        Text(String(app.name.prefix(1)).uppercased())
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
    }
}
