//
//  Stores.swift
//  nodeloc
//
//  Observable loaders for search, chat, notifications, and profile. Each falls
//  back to sample data (or a guest state) when unauthenticated or offline.
//

import Foundation
import UIKit

// MARK: - Sidebar

struct SidebarAppSummary: Identifiable {
    let id: Int
    let name: String
    let slug: String
    let logoURL: URL?
    let url: String?
}

struct SidebarFeedSummary: Identifiable {
    let id: Int
    let name: String
    /// Owner and slug, which is what addresses the feed — `/f/<username>/<slug>`.
    /// Carried so the drawer can open the native page instead of the web one.
    let username: String?
    let slug: String
    let description: String
    let colorHex: String
    let url: String?
    let nodeCount: Int?
}

struct SidebarNodeSummary: Identifiable, Codable {
    let id: Int
    let name: String
    let slug: String
    let description: String
    let memberCount: String
    let colorHex: String
    let logoURL: URL?
    let isCreator: Bool
    let isJoined: Bool
    let url: String?
    /// The site's own badge for a node without an uploaded logo: a Font Awesome
    /// or Lucide glyph name (`style_type: "icon"`), or an emoji shortcode
    /// (`style_type: "emoji"`). Optional so snapshots written before these
    /// existed still decode.
    var iconName: String? = nil
    var emoji: String? = nil
}

struct NodeGroupSummary: Identifiable, Codable {
    let id: Int
    let name: String
    let colorHex: String
    let totalCount: Int
    let hasMore: Bool
}

struct SidebarResourceSummary: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let icon: String
    let dividerAbove: Bool
}

enum NodeSummaryFactory {
    static func node(_ category: DiscourseCategory) -> SidebarNodeSummary {
        SidebarNodeSummary(
            id: category.id,
            name: category.name,
            slug: category.slug,
            description: cleanDescription(category.description ?? category.descriptionExcerpt) ?? "n/\(category.slug)",
            memberCount: compactCount(category.memberCount ?? category.topicCount),
            colorHex: category.color ?? "009966",
            logoURL: resolvedURL(category.uploadedLogo?.url ?? category.uploadedLogoDark?.url),
            isCreator: category.isCreator ?? false,
            isJoined: category.isJoined ?? false,
            url: category.url ?? "/n/\(category.slug)",
            iconName: category.styleType == "icon" ? category.icon : nil,
            emoji: category.styleType == "emoji" ? category.emoji : nil
        )
    }

    static func group(_ bucket: SidebarGroupedNodeBucket) -> NodeGroupSummary {
        NodeGroupSummary(
            id: bucket.category.id,
            name: bucket.category.name,
            colorHex: bucket.category.color ?? "009966",
            totalCount: bucket.totalCount ?? bucket.category.topicCount ?? 0,
            hasMore: bucket.hasMore ?? false
        )
    }

    static func compactCount(_ value: Int?) -> String {
        guard let value else { return "" }
        if value >= 1_000_000 { return String(format: "%.1fm", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    static func resolvedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: raw)
    }

    private static func cleanDescription(_ value: String?) -> String? {
        let text = DiscourseFormat.plainText(value)
        return text.isEmpty ? nil : text
    }
}

/// Caches the admin-designed title styles from discourse-custom-badge. Group and
/// badge styles are keyed by slugified name/title/full_name, matching how the
/// plugin's own initializer resolves a user's title to a style.
actor TitleStyleCatalog {
    static let shared = TitleStyleCatalog()

    private let client = DiscourseClient()
    private var styles: [String: TitleStyle] = [:]
    /// The in-flight (or finished) load, shared by every caller.
    ///
    /// Replaces a `loaded` flag that was set *before* the requests went out.
    /// That flag did coalesce, but badly on both counts: a second caller
    /// arriving mid-flight returned immediately with no styles instead of
    /// awaiting the answer, and if both requests failed — a flaky network, or
    /// the rate limit a profile screen can trip — the flag stayed set and every
    /// title in the session rendered unstyled with nothing to retry.
    ///
    /// `NodeCatalog` already does it this way; this is the same shape.
    private var loadTask: Task<Void, Never>?

    func style(forTitle title: String) async -> TitleStyle? {
        await loadIfNeeded()
        return styles[Self.slug(title)]
    }

    private func loadIfNeeded() async {
        if let loadTask { return await loadTask.value }

        let task = Task { await load() }
        loadTask = task
        await task.value
        // Let a failed load be retried rather than caching emptiness forever.
        if styles.isEmpty { loadTask = nil }
    }

    private func load() async {
        // Group titles take precedence, then badges used as titles.
        if let badges = try? await client.customBadgeStyles() {
            for badge in badges {
                guard let name = badge.name, let style = TitleStyle(badge.customStyle) else { continue }
                styles[Self.slug(name)] = style
            }
        }

        if let groups = try? await client.customGroupStyles() {
            for group in groups {
                guard let style = TitleStyle(group.customGroupStyle) else { continue }
                for key in [group.name, group.title, group.fullName].compactMap({ $0 }) where !key.isEmpty {
                    styles[Self.slug(key)] = style
                }
            }
        }
    }

    /// Mirrors the plugin's `className.replace(/\s+/g, "-").toLowerCase()`.
    private static func slug(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .lowercased()
    }
}

/// A small TTL cache for decoded API responses, shared across views.
///
/// Stores like `PublicProfileStore` and `NodeDetailStore` live in `@State`, so
/// they die when their view goes away — reopening the same profile or node
/// refetched everything (measured ~2s and ~2.2s respectively). This keeps the
/// decoded payload so a revisit paints immediately.
///
/// Deliberately memory-only: it exists to make back-navigation instant, not to
/// support offline reading, so nothing here needs to survive a launch.
@MainActor
final class ResponseCache<Value> {
    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let ttl: TimeInterval
    private let limit: Int

    init(ttl: TimeInterval, limit: Int) {
        self.ttl = ttl
        self.limit = limit
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.removeAll() }
        }
    }

    /// Cached value, or nil past its TTL.
    func value(forKey key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < ttl else {
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        return entry.value
    }

    /// Cached value regardless of age, plus whether it is stale.
    ///
    /// Lets a screen paint instantly from a stale copy while it refreshes —
    /// far better than a spinner over data we already have.
    func staleValue(forKey key: String) -> (value: Value, isStale: Bool)? {
        guard let entry = entries[key] else { return nil }
        return (entry.value, Date().timeIntervalSince(entry.storedAt) >= ttl)
    }

    func insert(_ value: Value, forKey key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(value: value, storedAt: Date())
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    func removeValue(forKey key: String) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

/// Shared cache for the site-wide endpoints every store needs.
///
/// `site.json` was being fetched from six separate call sites and
/// `categories.json` from three, several of them during the same launch. The
/// server sends `no-cache, no-store` with no `ETag`, so `URLCache` and
/// conditional requests can't help — the coalescing has to happen here.
///
/// `site.json` decodes to ~534 KB (≈57 KB gzipped on the wire), so the win is
/// mostly decode time and transient memory during launch, not bandwidth.
actor SiteResources {
    static let shared = SiteResources()

    private let client = DiscourseClient()

    private var site: SiteResponse?
    private var siteFetchedAt: Date?
    private var siteTask: Task<SiteResponse?, Never>?

    private var categories: CategoriesResponse?
    private var categoriesFetchedAt: Date?
    private var categoriesTask: Task<CategoriesResponse?, Never>?

    /// Categories and site settings change rarely; a session-length TTL keeps
    /// the app responsive to admin changes without refetching per screen.
    private let ttl: TimeInterval = 600

    func siteResponse() async -> SiteResponse? {
        if let site, isFresh(siteFetchedAt) { return site }
        if let siteTask { return await siteTask.value }

        let task = Task { [client] in try? await client.site() }
        siteTask = task
        let result = await task.value
        siteTask = nil
        if let result {
            site = result
            siteFetchedAt = Date()
        }
        return result ?? site
    }

    /// Always requests subcategories: they're the nodes people actually post
    /// in, and one superset response serves every caller.
    func categoriesResponse() async -> CategoriesResponse? {
        if let categories, isFresh(categoriesFetchedAt) { return categories }
        if let categoriesTask { return await categoriesTask.value }

        let task = Task { [client] in
            try? await client.categories(includeSubcategories: true)
        }
        categoriesTask = task
        let result = await task.value
        categoriesTask = nil
        if let result {
            categories = result
            categoriesFetchedAt = Date()
        }
        return result ?? categories
    }

    /// Drops the cached copies so the next read refetches. For pull-to-refresh.
    func invalidate() {
        site = nil
        siteFetchedAt = nil
        categories = nil
        categoriesFetchedAt = nil
    }

    private func isFresh(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < ttl
    }
}

/// Caches the site's categories so any screen can resolve a node's logo and
/// colour from its id or slug. `Post` only carries the `n/slug` string, so
/// without this the post detail has no way to draw a node avatar.
/// Main-actor rather than an `actor`: `NodeSummaryFactory` is main-actor
/// isolated, and the work here is a dictionary build around one awaited request.
@MainActor
final class NodeCatalog {
    static let shared = NodeCatalog()

    private let client = DiscourseClient()
    private var byID: [Int: SidebarNodeSummary] = [:]
    private var bySlug: [String: SidebarNodeSummary] = [:]
    /// Held so concurrent callers await the same request instead of each
    /// starting one — and so a caller arriving mid-flight doesn't sail past a
    /// bool guard and read an empty cache.
    private var loadTask: Task<Void, Never>?

    func node(id: Int) async -> SidebarNodeSummary? {
        await loadIfNeeded()
        return byID[id]
    }

    /// Nodes whose name or slug contains `term`, for the composer's `#`
    /// completion. Local: the catalog is already in memory, so a keystroke
    /// costs nothing.
    func matching(_ term: String, limit: Int = 5) async -> [SidebarNodeSummary] {
        await loadIfNeeded()
        let lowered = term.lowercased()
        let all = Array(bySlug.values)
        guard !lowered.isEmpty else {
            return Array(all.sorted { $0.name < $1.name }.prefix(limit))
        }
        // Prefix matches first: typing "vp" should offer "vps" before a node
        // that merely contains those letters somewhere.
        let prefixed = all.filter { $0.slug.lowercased().hasPrefix(lowered) || $0.name.lowercased().hasPrefix(lowered) }
        let prefixedIDs = Set(prefixed.map(\.id))
        let contained = all.filter { node in
            !prefixedIDs.contains(node.id)
                && (node.slug.lowercased().contains(lowered) || node.name.lowercased().contains(lowered))
        }
        return Array((prefixed.sorted { $0.name.count < $1.name.count } + contained).prefix(limit))
    }

    /// Accepts either a bare slug or the `n/slug` form used by `Post.node`.
    func node(slug: String) async -> SidebarNodeSummary? {
        await loadIfNeeded()
        let cleaned = slug.hasPrefix("n/") ? String(slug.dropFirst(2)) : slug
        return bySlug[cleaned.lowercased()]
    }

    private func loadIfNeeded() async {
        if let loadTask { return await loadTask.value }
        let task = Task {
            // Subcategories are the nodes people post in — the 11 top-level
            // entries are broad sections — and they're omitted unless asked for.
            guard let response = await SiteResources.shared.categoriesResponse() else { return }
            for category in Self.flattened(response.categoryList.categories) {
                let node = NodeSummaryFactory.node(category)
                byID[node.id] = node
                bySlug[node.slug.lowercased()] = node
            }
        }
        loadTask = task
        await task.value
        // Let a failed load be retried rather than caching emptiness forever.
        if byID.isEmpty { loadTask = nil }
    }

    /// Depth-first walk of `subcategory_list`, which nests arbitrarily.
    private static func flattened(_ categories: [DiscourseCategory]) -> [DiscourseCategory] {
        categories.flatMap { category in
            [category] + flattened(category.subcategoryList ?? [])
        }
    }
}

@MainActor
@Observable
final class SidebarStore {
    private let client = DiscourseClient()

    var apps: [SidebarAppSummary] = SidebarStore.fallbackApps
    var appsBrowseURL: String = "/apps"
    var customFeeds: [SidebarFeedSummary] = []
    var recentNodes: [SidebarNodeSummary] = SidebarStore.fallbackNodes
    var resources: [SidebarResourceSummary] = SidebarStore.defaultResources
    var canCreateNode = false
    var isLoading = false
    private var loaded = false

    init() {
        let currentSignedIn = DiscourseAuth.shared.isAuthenticated
        if let snapshot = Self.cachedSnapshot, snapshot.matches(isSignedIn: currentSignedIn), snapshot.isFresh {
            apply(snapshot)
        }
    }

    func load(isSignedIn: Bool) async {
        if let snapshot = Self.cachedSnapshot, snapshot.matches(isSignedIn: isSignedIn), snapshot.isFresh {
            apply(snapshot)
            loaded = true
            return
        }

        guard !loaded else { return }
        isLoading = true
        defer {
            isLoading = false
            loaded = true
        }

        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
        async let nodesCall: SidebarCommunitiesResponse? = try? (isSignedIn ? client.recentlyVisitedNodes() : client.sidebarNodes())
        async let currentUserCall: CurrentUserResponse? = isSignedIn ? (try? await client.currentUser()) : nil
        async let feedsCall: CustomFeedsResponse? = isSignedIn ? (try? await client.customFeeds()) : nil

        let site = await siteCall
        let currentUser = await currentUserCall
        let nodeResponse = await nodesCall
        let feeds = await feedsCall

        // One place records it: this load runs on every launch for a signed-in
        // user, and staff-gated actions elsewhere read the flag rather than
        // each fetching `current_user` again.
        if let user = currentUser?.currentUser {
            DiscourseAuth.shared.isStaff = (user.admin ?? false) || (user.moderator ?? false)
        }

        appsBrowseURL = site?.appsBrowseUrl ?? appsBrowseURL
        let recentApps = currentUser?.currentUser.recentApps ?? []
        let popularApps = site?.popularApps ?? []
        let appRows = recentApps.isEmpty ? popularApps : recentApps
        if !appRows.isEmpty {
            apps = appRows.prefix(5).map(map(app:))
        }

        canCreateNode = currentUser?.currentUser.canCreateCommunity ?? false
        NodeReadingModeStore.shared.applyAccountPreference(
            currentUser?.currentUser.userOption?.communityViewMode
        )
        customFeeds = (feeds?.customFeeds ?? []).map(map(feed:))

        let communities = nodeResponse?.communities ?? nodeResponse?.recommended ?? []
        recentNodes = communities.prefix(8).map(NodeSummaryFactory.node)

        if recentNodes.isEmpty {
            recentNodes = Self.fallbackNodes
        }

        Self.cachedSnapshot = snapshot(isSignedIn: isSignedIn)
    }

    private func apply(_ snapshot: SidebarCacheSnapshot) {
        apps = snapshot.apps
        appsBrowseURL = snapshot.appsBrowseURL
        customFeeds = snapshot.customFeeds
        recentNodes = snapshot.recentNodes
        resources = snapshot.resources
        canCreateNode = snapshot.canCreateNode
    }

    private func snapshot(isSignedIn: Bool) -> SidebarCacheSnapshot {
        SidebarCacheSnapshot(
            isSignedIn: isSignedIn,
            cachedAt: Date(),
            apps: apps,
            appsBrowseURL: appsBrowseURL,
            customFeeds: customFeeds,
            recentNodes: recentNodes,
            resources: resources,
            canCreateNode: canCreateNode
        )
    }

    private func map(app: SidebarDiscourseApp) -> SidebarAppSummary {
        SidebarAppSummary(
            id: app.id,
            name: app.name,
            slug: app.slug,
            logoURL: resolvedURL(app.logoUrl),
            url: app.url
        )
    }

    private func map(feed: CustomFeed) -> SidebarFeedSummary {
        SidebarFeedSummary(
            id: feed.id,
            name: feed.name,
            username: feed.username,
            slug: feed.slug,
            description: DiscourseFormat.plainText(feed.description).isEmpty ? AppString("\(feed.nodeCount ?? 0) 个节点") : DiscourseFormat.plainText(feed.description),
            colorHex: feed.color ?? "009966",
            url: feed.url ?? feed.username.map { "/f/\($0)/\(feed.slug)" },
            nodeCount: feed.nodeCount
        )
    }

    private func resolvedURL(_ raw: String?) -> URL? {
        NodeSummaryFactory.resolvedURL(raw)
    }

    private static let defaultResources: [SidebarResourceSummary] = [
        SidebarResourceSummary(title: AppString("关于"), url: "/about", icon: "circle-info", dividerAbove: false),
        SidebarResourceSummary(title: AppString("常见问题"), url: "/faq", icon: "questionmark.circle", dividerAbove: false),
        SidebarResourceSummary(title: AppString("服务条款"), url: "/tos", icon: "doc.text", dividerAbove: false),
        SidebarResourceSummary(title: AppString("隐私政策"), url: "/privacy", icon: "shield", dividerAbove: false),
        // OAuth 应用 and 支付应用 used to sit here. They are developer-facing
        // consoles on the website, not member features, and pointing at a
        // payment page from inside the app is exactly what guideline 3.1.1
        // treats as steering users to an external purchase.
        SidebarResourceSummary(title: AppString("广告合作"), url: "/t/topic/61119", icon: "megaphone", dividerAbove: true),
        SidebarResourceSummary(title: AppString("认证说明"), url: "/t/topic/51439", icon: "checkmark.seal", dividerAbove: false)
    ]

    static let fallbackNodes: [SidebarNodeSummary] = [
        SidebarNodeSummary(id: 31, name: "AI", slug: "ai", description: AppString("大模型、AI 应用与自动化"), memberCount: "3.5k", colorHex: "0088CC", logoURL: nil, isCreator: false, isJoined: false, url: "/n/ai"),
        SidebarNodeSummary(id: 83, name: AppString("杂谈"), slug: "chit-chat", description: AppString("海阔天空随便说"), memberCount: "1.5k", colorHex: "FFA500", logoURL: nil, isCreator: false, isJoined: false, url: "/n/chit-chat"),
        SidebarNodeSummary(id: 27, name: "VPS", slug: "vps", description: AppString("云服务器、线路和运维"), memberCount: "1.1k", colorHex: "E45735", logoURL: nil, isCreator: false, isJoined: false, url: "/n/vps"),
        SidebarNodeSummary(id: 12, name: AppString("抽奖"), slug: "lottery", description: AppString("站内抽奖和活动"), memberCount: "1.3k", colorHex: "C90D0D", logoURL: nil, isCreator: false, isJoined: false, url: "/n/lottery")
    ]

    private static let fallbackApps: [SidebarAppSummary] = [
        SidebarAppSummary(id: 8, name: "Tic-Tac-toe", slug: "tic-tac-toe", logoURL: nil, url: "/t/topic/103048/1"),
        SidebarAppSummary(id: 38, name: "果刃", slug: "fruit-blade", logoURL: nil, url: "/t/topic/104179/1"),
        SidebarAppSummary(id: 31, name: "Apex Drift", slug: "apex-drift", logoURL: nil, url: "/t/topic/103788/1")
    ]

    private static var cachedSnapshot: SidebarCacheSnapshot?
    private static let cacheDuration: TimeInterval = 300

    private struct SidebarCacheSnapshot {
        let isSignedIn: Bool
        let cachedAt: Date
        let apps: [SidebarAppSummary]
        let appsBrowseURL: String
        let customFeeds: [SidebarFeedSummary]
        let recentNodes: [SidebarNodeSummary]
        let resources: [SidebarResourceSummary]
        let canCreateNode: Bool

        var isFresh: Bool {
            Date().timeIntervalSince(cachedAt) < SidebarStore.cacheDuration
        }

        func matches(isSignedIn: Bool) -> Bool {
            self.isSignedIn == isSignedIn
        }
    }
}

// MARK: - Apps

/// The published app directory (discourse-apps plugin).
@MainActor
@Observable
final class AppsDirectoryStore {
    private let client = DiscourseClient()

    var apps: [DirectoryApp] = []
    var query = ""
    var isLoading = false
    var errorText: String?
    private var loaded = false

    /// app id → install id, resolved lazily and cached.
    private var installIDs: [Int: Int] = [:]

    var visibleApps: [DirectoryApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.slug.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func load() async {
        guard !loaded else { return }
        isLoading = true
        errorText = nil
        defer {
            isLoading = false
            loaded = true
        }

        do {
            apps = try await client.appsDirectory()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The install id needed by the webview endpoint. It isn't exposed by any
    /// API, so it's read from the host topic's cooked HTML
    /// (`<div class="discourse-app-embed" data-app-install="8">`).
    func installID(for app: DirectoryApp) async -> Int? {
        if let cached = installIDs[app.id] { return cached }
        guard let topicID = app.hostTopicID else { return nil }
        guard let topic = try? await client.topic(id: topicID) else { return nil }

        let cooked = topic.postStream.posts.first?.cooked ?? ""
        guard let resolved = Self.installID(inCooked: cooked) else { return nil }
        installIDs[app.id] = resolved
        return resolved
    }

    /// Parses `data-app-install="123"` out of cooked post HTML.
    static func installID(inCooked cooked: String) -> Int? {
        let marker = "data-app-install=\""
        guard let start = cooked.range(of: marker) else { return nil }
        let rest = cooked[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return Int(rest[..<end])
    }
}

/// Discourse category topic orderings (`/c/{path}/{id}/l/{sort}`).
enum NodeSort: String, CaseIterable, Identifiable {
    case latest
    case new
    case hot
    case featured
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latest: return AppString("最新")
        case .new: return AppString("新")
        case .hot: return AppString("热门")
        case .featured: return AppString("推荐")
        case .top: return AppString("热门榜")
        }
    }

    /// Tooltip text mirroring Discourse's own titles.
    var detail: String {
        switch self {
        case .latest: return AppString("有新帖子的话题")
        case .new: return AppString("最近几天创建或回复的话题")
        case .hot: return AppString("最近热门话题")
        case .featured: return AppString("查看推荐话题")
        case .top: return AppString("按点赞数排列的热门话题")
        }
    }

    var icon: String {
        switch self {
        case .latest: return "clock"
        case .new: return "sparkles"
        case .hot: return "flame"
        case .featured: return "star"
        case .top: return "chart.line.uptrend.xyaxis"
        }
    }

    /// `new` is only meaningful (and only permitted) for signed-in users.
    var requiresAuth: Bool { self == .new }
}

/// How the topic list renders inside a node.
enum NodeReadingMode: String, CaseIterable, Identifiable {
    case compact
    case expand
    case card

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return AppString("紧凑")
        case .expand: return AppString("展开")
        case .card: return AppString("卡片")
        }
    }

    var icon: String {
        switch self {
        case .compact: return "list.bullet"
        case .expand: return "list.bullet.rectangle"
        case .card: return "square.grid.2x2"
        }
    }
}

/// How much a node notifies you. Raw values are Discourse's own
/// `NotificationLevels.all` (lib/notification_levels.rb) — the same integers the
/// web dropdown sends as `data-level-id`, so they must not be renumbered.
enum NodeNotificationLevel: Int, CaseIterable, Identifiable {
    case muted = 0
    case regular = 1
    case tracking = 2
    case watching = 3
    case watchingFirstPost = 4

    var id: Int { rawValue }

    /// Ordered as the web dropdown presents them: most notifying first.
    static var menuOrder: [NodeNotificationLevel] {
        [.watching, .tracking, .watchingFirstPost, .regular, .muted]
    }

    var label: String {
        switch self {
        case .watching: return AppString("关注")
        case .tracking: return AppString("跟踪")
        case .watchingFirstPost: return AppString("关注第一个帖子")
        case .regular: return AppString("常规")
        case .muted: return AppString("已设为免打扰")
        }
    }

    var detail: String {
        switch self {
        case .watching:
            return AppString("您将自动关注此节点中的所有话题。您会收到每个话题中每个新帖子的通知，并且会显示新回复数量。")
        case .tracking:
            return AppString("您将自动跟踪此节点中的所有话题。您会在别人 @ 您或回复您时收到通知，并且会显示新回复数量。")
        case .watchingFirstPost:
            return AppString("您将收到此节点中新话题的通知，但不会收到话题回复。")
        case .regular:
            return AppString("您会在别人 @ 您或回复您时收到通知。")
        case .muted:
            return AppString("您不会收到有关此节点中新话题的任何通知，它们也不会出现在最新话题页面上。")
        }
    }

    /// Mirrors the web icons (bell-ring / bell-plus / bell-dot / bell / bell-off).
    var icon: String {
        switch self {
        case .watching: return "bell.badge.fill"
        case .tracking: return "bell.badge"
        case .watchingFirstPost: return "bell.and.waves.left.and.right"
        case .regular: return "bell"
        case .muted: return "bell.slash"
        }
    }
}

/// A chat channel's notification level — the three values
/// `notifications-settings/me` accepts.
enum ChatNotificationLevel: String, CaseIterable, Identifiable {
    case always
    case mention
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return AppString("全部消息")
        case .mention: return AppString("仅提及我时")
        case .never: return AppString("不通知")
        }
    }

    var icon: String {
        switch self {
        case .always: return "bell"
        case .mention: return "at"
        case .never: return "bell.slash"
        }
    }
}

/// 通知方式 for one *person*, as opposed to a node. Raw values are the three
/// strings `PUT /u/:username/notification_level` accepts, and the icons mirror
/// the site's own dropdown (bell / bell-slash / eye-slash).
enum UserNotificationLevel: String, CaseIterable, Identifiable {
    case normal
    case mute
    case ignore

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return AppString("常规")
        case .mute: return AppString("免打扰")
        case .ignore: return AppString("屏蔽")
        }
    }

    var detail: String {
        switch self {
        case .normal: return AppString("正常接收这个人的通知。")
        case .mute: return AppString("不再收到这个人的通知，但仍能看到他的内容。")
        case .ignore: return AppString("隐藏这个人的帖子和回复，也不再收到通知。")
        }
    }

    var icon: String {
        switch self {
        case .normal: return "bell"
        case .mute: return "bell.slash"
        case .ignore: return "eye.slash"
        }
    }

    /// Only 屏蔽 carries one: Discourse stores ignores with an expiry and parses
    /// the field unconditionally, so omitting it fails the request. A century
    /// out is this app's 永久, matching what the web UI's option means.
    var expiry: Date? {
        self == .ignore
            ? Calendar.current.date(byAdding: .year, value: 100, to: .now)
            : nil
    }

    /// What the user serializer's two flags mean together.
    init(ignored: Bool?, muted: Bool?) {
        if ignored == true { self = .ignore }
        else if muted == true { self = .mute }
        else { self = .normal }
    }
}

/// Remembers the reading mode across launches, mirroring the web plugin's
/// `community-view-mode` service so the app and the site agree on precedence:
///
/// 1. this device's own choice (the dropdown), then
/// 2. the account's saved preference (`user_option.community_view_mode`),
///    which only applies while signed in, then
/// 3. a default that depends on whether anyone is signed in: 卡片 for guests,
///    the plugin's own `COMPACT` for members.
///
/// The device wins deliberately: picking a mode on a phone shouldn't be undone
/// by a preference set on the desktop, which is the web service's rule too
/// (there, localStorage outranks the server value).
@MainActor
@Observable
final class NodeReadingModeStore {
    static let shared = NodeReadingModeStore()

    private static let defaultsKey = "communityViewMode"

    /// This device's own pick from the dropdown, `nil` until something is
    /// chosen here. Outranks everything below.
    private var deviceChoice: NodeReadingMode?

    /// `user_option.community_view_mode`, once the session reports it.
    private var accountPreference: NodeReadingMode?

    private init() {
        deviceChoice = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(NodeReadingMode.init(rawValue:))
    }

    /// Resolved on read rather than frozen at init, for two reasons: this
    /// singleton can be created before `DiscourseLogin.restore()` has run, so
    /// there is no reliable auth answer at init time; and reading
    /// `DiscourseAuth` (which is `@Observable`, with `isAuthenticated` derived
    /// from observable properties) means signing in or out redraws the list on
    /// its own.
    var mode: NodeReadingMode {
        if let deviceChoice { return deviceChoice }
        let isSignedIn = DiscourseAuth.shared.isAuthenticated
        // A saved account preference only means anything while there is an
        // account; after signing out it must stop applying, which falling
        // through to the guest default handles without a sign-out hook.
        if isSignedIn, let accountPreference { return accountPreference }
        // Signed out there is no preference to honour and nothing to sync, so
        // guests get the card list — the browsing-first view, and the one that
        // shows what the community posts rather than a dense list of titles.
        // Signed in, match the plugin's own fallback (`COMPACT` in
        // community-view-mode.js) until the account's value arrives.
        return isSignedIn ? .compact : .card
    }

    /// The reader picked a mode here; remember it and stop deferring to the account.
    func select(_ value: NodeReadingMode) {
        deviceChoice = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.defaultsKey)
    }

    /// Applies `user_option.community_view_mode` from the server. Precedence is
    /// settled in `mode`, so this only has to record it.
    func applyAccountPreference(_ raw: String?) {
        guard let raw, let value = NodeReadingMode(rawValue: raw) else { return }
        accountPreference = value
    }
}

/// A single node: header (banner/logo/members/join) plus its topic list.
@MainActor
@Observable
final class NodeDetailStore {
    private let client = DiscourseClient()

    var name = ""
    var slug = ""
    var descriptionText = ""
    var colorHex = "009966"
    var logoURL: URL?
    var backgroundURL: URL?
    var memberCount: Int?
    var topicCount: Int?
    var postCount: Int?
    var isJoined = false
    var isTogglingJoin = false
    /// Node moderators, for the about sheet.
    var moderators: [CategoryModerator] = []
    /// This user's notification setting. `regular` is Discourse's own default
    /// for a node nobody has changed.
    var notificationLevel: NodeNotificationLevel = .regular
    var isUpdatingNotificationLevel = false

    var posts: [Post] = []

    /// `posts` minus authors this reader has blocked — what a list should
    /// actually render. Blocking has to clear rows from the screen at once
    /// rather than at the next fetch, and reading the blocked set here is what
    /// makes SwiftUI redraw the list the moment it changes (guideline 1.2).
    var visiblePosts: [Post] { BlockedUsersStore.shared.visible(posts) }
    var isLoading = false
    var isLoadingMore = false
    var errorText: String?
    var sort: NodeSort = .latest

    /// `new` requires a session, so hide it for guests.
    var availableSorts: [NodeSort] {
        NodeSort.allCases.filter { !$0.requiresAuth || DiscourseAuth.shared.isAuthenticated }
    }

    private var categoryID = 0
    private var categoryPath: String?
    /// The node's own category, so mapped posts carry the right "n/slug".
    private var selfCategory: DiscourseCategory?
    private var page = 0
    private var hasMore = true
    private var loadedID: Int?

    func load(node: SidebarNodeSummary) async {
        // Seed from the summary so the header paints immediately.
        categoryID = node.id
        name = node.name
        slug = node.slug
        descriptionText = node.description
        colorHex = node.colorHex
        logoURL = node.logoURL
        isJoined = node.isJoined
        categoryPath = Self.categoryPath(from: node.url)

        guard loadedID != node.id else { return }
        loadedID = node.id
        posts = []
        page = 0
        hasMore = true

        // This store lives in `@State`, so leaving the node and coming back
        // builds a new one. Repaint from the last visit's first page instead of
        // showing a spinner over data we already had (~2.2s to refetch).
        let cached = Self.cache.staleValue(forKey: Self.cacheKey(nodeID: node.id, sort: sort))
        if let cached {
            posts = cached.value.posts
            hasMore = cached.value.hasMore
        }

        isLoading = cached == nil
        errorText = nil
        defer { isLoading = false }

        // site.json carries the banner + member count that nodes.json omits,
        // and is the only place the parent slug (needed for the topic path)
        // is available.
        if let site = await SiteResources.shared.siteResponse(), let categories = site.categories {
            if let match = categories.first(where: { $0.id == node.id }) {
                selfCategory = match
                applyCategory(match)
                if categoryPath == nil {
                    let parentSlug = match.parentCategoryId
                        .flatMap { id in categories.first(where: { $0.id == id })?.slug }
                    categoryPath = parentSlug.map { "\($0)/\(match.slug)" } ?? match.slug
                }
            }
        }

        // Fresh cache: keep what we painted, skip the request entirely.
        if let cached, !cached.isStale { return }
        await loadPage(reset: true)
    }

    /// First page per (node, ordering). Keyed by sort because switching the
    /// ordering is a genuinely different list.
    struct CachedNodePage {
        let posts: [Post]
        let hasMore: Bool
    }

    static let cache = ResponseCache<CachedNodePage>(ttl: 180, limit: 20)

    private static func cacheKey(nodeID: Int, sort: NodeSort) -> String {
        "\(nodeID)-\(sort.rawValue)"
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        await loadPage(reset: false)
    }

    /// Pull-to-refresh: reloads the current ordering from the first page.
    /// Drops the cached page first — a manual refresh must hit the network.
    func refresh() async {
        Self.cache.removeValue(forKey: Self.cacheKey(nodeID: categoryID, sort: sort))
        page = 0
        hasMore = true
        await loadPage(reset: true)
    }

    /// Switches ordering and reloads the list from the first page.
    func select(sort newSort: NodeSort) async {
        guard newSort != sort else { return }
        sort = newSort
        page = 0
        hasMore = true

        // Each ordering is cached separately, so toggling back to one you've
        // already seen is instant.
        let cached = Self.cache.staleValue(forKey: Self.cacheKey(nodeID: categoryID, sort: sort))
        posts = cached?.value.posts ?? []
        hasMore = cached?.value.hasMore ?? true

        isLoading = cached == nil
        errorText = nil
        defer { isLoading = false }
        if let cached, !cached.isStale { return }
        await loadPage(reset: true)
    }

    func toggleJoin() async {
        guard !isTogglingJoin, categoryID > 0 else { return }
        isTogglingJoin = true
        defer { isTogglingJoin = false }

        let wasJoined = isJoined
        isJoined = !wasJoined
        memberCount = (memberCount ?? 0) + (wasJoined ? -1 : 1)

        do {
            let response = wasJoined
                ? try await client.leaveNode(categoryID: categoryID)
                : try await client.joinNode(categoryID: categoryID)
            if let joined = response.joined { isJoined = joined }
        } catch {
            isJoined = wasJoined
            memberCount = (memberCount ?? 0) + (wasJoined ? 1 : -1)
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Changes how much this node notifies the user. Applied locally first so
    /// the menu closes on the new value, and rolled back if the server refuses.
    func setNotificationLevel(_ level: NodeNotificationLevel) async {
        guard !isUpdatingNotificationLevel, categoryID > 0, level != notificationLevel else { return }
        isUpdatingNotificationLevel = true
        defer { isUpdatingNotificationLevel = false }

        let previous = notificationLevel
        notificationLevel = level

        do {
            try await client.setCategoryNotification(categoryID: categoryID, level: level.rawValue)
        } catch {
            notificationLevel = previous
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyCategory(_ category: DiscourseCategory) {
        if let count = category.memberCount { memberCount = count }
        if let count = category.topicCount { topicCount = count }
        if let count = category.postCount { postCount = count }
        if let moderators = category.moderators { self.moderators = moderators }
        // Only meaningful when signed in — an anonymous fetch reports the site
        // default for everyone, which would show a level the user never chose.
        if DiscourseAuth.shared.isAuthenticated,
           let level = category.notificationLevel.flatMap(NodeNotificationLevel.init(rawValue:)) {
            notificationLevel = level
        }
        if descriptionText.isEmpty {
            descriptionText = DiscourseFormat.plainText(category.description ?? category.descriptionExcerpt)
        }
        backgroundURL = NodeSummaryFactory.resolvedURL(category.uploadedBackground?.url)
        if logoURL == nil { logoURL = NodeSummaryFactory.resolvedURL(category.uploadedLogo?.url) }
        if categoryPath == nil { categoryPath = Self.categoryPath(from: category.url) }
    }

    private func loadPage(reset: Bool) async {
        guard let path = categoryPath else {
            if reset { errorText = AppString("无法打开该节点") }
            return
        }
        do {
            let response = try await client.nodeTopics(
                path: path,
                categoryID: categoryID,
                sort: sort.rawValue,
                page: page
            )
            let topics = response.topicList?.topics ?? []
            let usersByID = Dictionary(
                (response.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let mapped = topics.map {
                FeedMapper.post(topic: $0, usersByID: usersByID, client: client, category: selfCategory)
            }
            if reset { posts = mapped } else { posts.append(contentsOf: mapped) }
            hasMore = !topics.isEmpty
            // Only the first page is cached; later pages are cheap to re-fetch
            // and caching them all would hold an unbounded list per node.
            if reset {
                Self.cache.insert(
                    CachedNodePage(posts: mapped, hasMore: hasMore),
                    forKey: Self.cacheKey(nodeID: categoryID, sort: sort)
                )
            }
        } catch {
            hasMore = false
            // Don't blank a list we already painted from cache.
            if reset, posts.isEmpty {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Discourse reports "/c/technology/ai/31"; the topic endpoint needs the
    /// "technology/ai" middle segment (a bare slug 301-redirects).
    private static func categoryPath(from url: String?) -> String? {
        guard let url, let range = url.range(of: "/c/") else { return nil }
        let tail = url[range.upperBound...]
        let parts = tail.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return parts.first }
        return parts.dropLast().joined(separator: "/")
    }
}

@MainActor
@Observable
final class NodeBrowseStore {
    private let client = DiscourseClient()

    var recommended: [SidebarNodeSummary] = SidebarStore.fallbackNodes
    var groups: [NodeGroupSummary] = []
    var selectedGroup: NodeGroupSummary?
    var groupNodes: [SidebarNodeSummary] = []
    var groupPreviews: [Int: [SidebarNodeSummary]] = [:]
    var isLoading = false
    var isLoadingGroup = false
    var errorText: String?
    private var loaded = false
    private var hydratedFromCache = false

    /// True once there's real data to show (from cache or the network), so the
    /// view knows to skip the skeleton.
    var hasContent: Bool { !groups.isEmpty }

    func load() async {
        // Node data barely changes, so show the last cached copy instantly and
        // refresh it quietly behind the scenes — the skeleton only appears on a
        // truly cold first launch.
        if !hydratedFromCache {
            hydratedFromCache = true
            if let snapshot = NodeBrowseCache.load(), !snapshot.groups.isEmpty {
                recommended = snapshot.recommended
                groups = snapshot.groups
                groupPreviews = snapshot.groupPreviews
            }
        }

        guard !loaded else { return }
        let hadData = !groups.isEmpty
        if !hadData { isLoading = true }
        errorText = nil
        defer { isLoading = false }

        do {
            let response = try await client.sidebarNodes()
            let nodes = response.recommended ?? response.communities ?? []
            if !nodes.isEmpty {
                recommended = nodes.map(NodeSummaryFactory.node)
            }
            groups = (response.grouped ?? [:])
                .map { NodeSummaryFactory.group($0.value) }
                .sorted { lhs, rhs in
                    if lhs.totalCount == rhs.totalCount {
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.totalCount > rhs.totalCount
                }
            // Overwrite (not guard) so cached previews get refreshed too.
            for group in groups.prefix(6) {
                if let response = try? await client.nodeBrowse(parentCategoryID: group.id, perPage: 4) {
                    groupPreviews[group.id] = (response.communities ?? response.recommended ?? [])
                        .map(NodeSummaryFactory.node)
                }
            }
            loaded = true
            NodeBrowseCache.save(
                .init(recommended: recommended, groups: groups, groupPreviews: groupPreviews)
            )
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if recommended.isEmpty { recommended = SidebarStore.fallbackNodes }
        }
    }

    func previewNodes(for group: NodeGroupSummary) -> [SidebarNodeSummary] {
        groupPreviews[group.id] ?? []
    }

    func loadGroupPreview(_ group: NodeGroupSummary) async {
        guard groupPreviews[group.id] == nil else { return }

        do {
            let response = try await client.nodeBrowse(parentCategoryID: group.id, perPage: 4)
            groupPreviews[group.id] = (response.communities ?? response.recommended ?? []).map(NodeSummaryFactory.node)
        } catch {
            if groupPreviews[group.id] == nil {
                groupPreviews[group.id] = []
            }
        }
    }

    func loadGroup(_ group: NodeGroupSummary) async {
        if selectedGroup?.id == group.id && !groupNodes.isEmpty { return }
        selectedGroup = group
        groupNodes = []
        isLoadingGroup = true
        errorText = nil
        defer { isLoadingGroup = false }

        do {
            let response = try await client.nodeBrowse(parentCategoryID: group.id)
            groupNodes = (response.communities ?? response.recommended ?? []).map(NodeSummaryFactory.node)
            groupPreviews[group.id] = Array(groupNodes.prefix(4))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearGroup() {
        selectedGroup = nil
        groupNodes = []
    }
}

/// A tiny on-disk cache for the node directory, which changes rarely. Stored as
/// one JSON blob in the caches directory (no database, per the app's design).
private enum NodeBrowseCache {
    struct Snapshot: Codable {
        let recommended: [SidebarNodeSummary]
        let groups: [NodeGroupSummary]
        let groupPreviews: [Int: [SidebarNodeSummary]]
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("node-browse.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
@Observable
final class CreateNodeStore {
    static let availableColors = [
        "009966", "0088CC", "6F42C1", "E45735", "FFA500", "C90D0D", "577590", "2D9CDB"
    ]

    private let client = DiscourseClient()

    var parentCategories: [DiscourseCategory] = []
    var selectedParentID: Int?
    var isLoadingParents = false
    var isSubmitting = false
    var errorText: String?
    var createdNode: SidebarNodeSummary?

    func loadParents() async {
        guard parentCategories.isEmpty else { return }
        isLoadingParents = true
        errorText = nil
        defer { isLoadingParents = false }

        async let categoriesCall = SiteResources.shared.categoriesResponse()
        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
        let response = await categoriesCall
        let site = await siteCall
        let source = site?.categories ?? response?.categoryList.categories ?? []
        guard !source.isEmpty else {
            errorText = AppString("无法加载上级节点，请稍后重试。")
            return
        }
        parentCategories = source
            .filter { $0.parentCategoryId == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedParentID = selectedParentID ?? parentCategories.first?.id
    }

    func create(
        name: String,
        slug: String,
        description: String,
        colorHex: String,
        parentCategoryID: Int?
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscourseAuth.shared.isAuthenticated else {
            errorText = AppString("请先登录再创建节点。")
            return false
        }
        guard let parentCategoryID, !trimmedName.isEmpty, !trimmedSlug.isEmpty else { return false }

        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }

        do {
            let response = try await client.createNode(
                name: trimmedName,
                slug: trimmedSlug,
                description: trimmedDescription,
                colorHex: colorHex,
                parentCategoryID: parentCategoryID
            )
            createdNode = response.category.map(NodeSummaryFactory.node)
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}

// MARK: - Compose

/// One selectable node in the composer picker, plus the reason it was ranked
/// where it was (mirrors the web plugin's three picker tiers).
struct ComposeNodeOption: Identifiable {
    enum Reason { case recentPost, joined, none }

    let node: SidebarNodeSummary
    let reason: Reason

    var id: Int { node.id }

    var reasonText: String? {
        switch reason {
        case .recentPost: AppString("最近发布")
        case .joined: AppString("已加入")
        case .none: nil
        }
    }
}

/// Serializes composer uploads and keeps them under the site's upload rate
/// limit. `uploads.json` takes one file per request, and Discourse's
/// `max_uploads_per_minute` defaults to 10, so firing a 9-photo batch in
/// parallel would trip a 429 partway through.
actor ComposeUploadQueue {
    static let shared = ComposeUploadQueue()

    /// Leave one slot of headroom under the default limit for an edit re-upload.
    private let limitPerWindow = 9
    private let window: TimeInterval = 60
    private var recentUploads: [Date] = []
    /// Tail of the chain of queued uploads. Actor isolation alone would NOT
    /// serialize these: the actor is reentrant, so it lets the next caller in
    /// the moment `work()` suspends on the network. Chaining each task onto its
    /// predecessor is what actually keeps one upload in flight at a time.
    private var tail: Task<Void, Never>?

    /// Runs `work` after all previously queued uploads finish and once a
    /// rate-limit token is free. Preserves submission order.
    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let predecessor = tail
        let task = Task { () -> Result<T, Error> in
            await predecessor?.value
            await self.reserveSlot()
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        // Successors wait on this one; the erased task never throws.
        tail = Task { _ = await task.value }
        return try await task.value.get()
    }

    /// Blocks until the rolling window has room, then records the slot.
    private func reserveSlot() async {
        while true {
            let cutoff = Date().addingTimeInterval(-window)
            recentUploads.removeAll { $0 < cutoff }
            if recentUploads.count < limitPerWindow { break }
            guard let oldest = recentUploads.first else { break }

            let wait = window - Date().timeIntervalSince(oldest)
            guard wait > 0 else { continue }
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { break }
        }
        recentUploads.append(Date())
    }
}

@MainActor
@Observable
final class ComposeStore {
    private let client = DiscourseClient()

    var nodeOptions: [ComposeNodeOption] = []
    var isLoadingCommunities = false
    var isSubmitting = false
    /// Counted rather than a Bool: with several uploads in flight, the first one
    /// to finish would otherwise clear the flag for all of them.
    private(set) var pendingUploadCount = 0
    var isUploadingMedia: Bool { pendingUploadCount > 0 }
    var errorText: String?
    private var loadedCommunities = false

    // Plugin capabilities, read from site.json / current user.
    var canCreatePoll = true
    var pollMaximumOptions = 20
    var isRedEnvelopeEnabled = true
    var redEnvelopeLimits = RedEnvelopeLimits.default
    var isLotteryEnabled = true
    var lotteryLimits = LotteryLimits.default
    var trustLevelNames: [Int: String] = ComposeStore.fallbackTrustLevels
    var userPoints: Int?
    /// Set when the topic posted but a follow-up record didn't, so the composer
    /// can retry instead of silently dropping it.
    var pendingRedEnvelopeTopicID: Int?
    var pendingLotteryPostID: Int?
    /// True once a topic has been created. Guards against a second 发帖 tap
    /// after a follow-up failure, which would duplicate the topic and re-charge
    /// the red envelope.
    private(set) var hasPublished = false

    static let fallbackTrustLevels: [Int: String] = [
        0: AppString("新用户"), 1: AppString("基本用户"), 2: AppString("成员"), 3: AppString("活跃用户"), 4: AppString("领导者"),
    ]

    /// Mirrors discourse-community's composer picker: nodes are the
    /// sub-categories from `site.json` (which the plugin augments with
    /// `member_count`/`is_joined`), ranked by the current user's
    /// `recent_post_category_ids`, then joined nodes, then everything else.
    func loadCommunities() async {
        guard !isLoadingCommunities, !loadedCommunities else { return }
        isLoadingCommunities = true
        defer { isLoadingCommunities = false }

        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
        async let currentUserCall: CurrentUserResponse? = DiscourseAuth.shared.isAuthenticated
            ? (try? await client.currentUser())
            : nil

        let site = await siteCall
        var categories = site?.categories?.filter { $0.parentCategoryId != nil } ?? []
        if categories.isEmpty {
            let response = try? await client.sidebarNodes()
            categories = response?.communities ?? response?.recommended ?? []
        }

        let currentUser = (await currentUserCall)?.currentUser
        applyCapabilities(site: site, currentUser: currentUser)

        guard !categories.isEmpty else { return }

        let recent = currentUser?.recentPostCategoryIds ?? []
        let recentRank = Dictionary(
            recent.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        nodeOptions = categories
            .map { category -> ComposeNodeOption in
                let reason: ComposeNodeOption.Reason
                if recentRank[category.id] != nil {
                    reason = .recentPost
                } else if category.isJoined == true {
                    reason = .joined
                } else {
                    reason = .none
                }
                return ComposeNodeOption(node: NodeSummaryFactory.node(category), reason: reason)
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank(lhs.element, recentRank: recentRank, tiers: recent.count)
                let rhsRank = rank(rhs.element, recentRank: recentRank, tiers: recent.count)
                // Stable: ties keep the site's own category order.
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)

        loadedCommunities = true
    }

    private func rank(_ option: ComposeNodeOption, recentRank: [Int: Int], tiers: Int) -> Int {
        if let index = recentRank[option.id] { return index }
        return option.reason == .joined ? tiers : tiers + 1
    }

    /// Reads plugin limits from the site so the composer enforces the same rules
    /// the server will. Missing keys keep the plugin defaults.
    private func applyCapabilities(site: SiteResponse?, currentUser: CurrentUser?) {
        let settings = site?.siteSettings

        if let enabled = settings?.pollEnabled, !enabled {
            canCreatePoll = false
        } else if let allowed = currentUser?.canCreatePoll {
            canCreatePoll = allowed
        }
        if let maximum = settings?.pollMaximumOptions { pollMaximumOptions = maximum }

        isRedEnvelopeEnabled = settings?.redEnvelopeEnabled ?? true
        redEnvelopeLimits = RedEnvelopeLimits(
            minPoints: settings?.redEnvelopeMinPoints ?? RedEnvelopeLimits.default.minPoints,
            minAveragePoints: settings?.redEnvelopeMinAvgPoints ?? RedEnvelopeLimits.default.minAveragePoints,
            minCount: settings?.redEnvelopeMinCount ?? RedEnvelopeLimits.default.minCount,
            maxCount: settings?.redEnvelopeMaxCount ?? RedEnvelopeLimits.default.maxCount
        )

        // Both gates: the site setting, and the review kill switch that lets
        // 抽奖 be withdrawn server-side without shipping a build.
        isLotteryEnabled = (settings?.lotteryEnabled ?? true) && FeatureFlags.shared.lotteryEnabled
        lotteryLimits = LotteryLimits(
            minTrustLevel: settings?.lotteryMinTrustLevel ?? LotteryLimits.default.minTrustLevel,
            minTicketsPerUser: settings?.lotteryMinTicketsPerUser ?? LotteryLimits.default.minTicketsPerUser,
            maxTicketsPerUser: settings?.lotteryMaxTicketsPerUser ?? LotteryLimits.default.maxTicketsPerUser,
            maxDrawDays: settings?.lotteryMaxDrawDays ?? LotteryLimits.default.maxDrawDays
        )
        // `site.json` gives machine names ("newuser", "basic"), not display
        // names, so the localized fallback wins wherever it has an entry. Only
        // levels the fallback doesn't know about come from the server.
        if let levels = site?.trustLevels, !levels.isEmpty {
            trustLevelNames = levels.namesByLevel.merging(
                ComposeStore.fallbackTrustLevels,
                uniquingKeysWith: { _, localized in localized }
            )
        }

        userPoints = currentUser?.gamificationScore
    }

    /// Result of posting. `.postedWithFollowUpFailure` means the topic is live
    /// but a follow-up record (red envelope / lottery) failed — the post is
    /// never rolled back, so the composer offers a retry rather than pretending
    /// everything worked.
    enum SubmitOutcome: Equatable {
        case failed
        case posted
        case postedWithFollowUpFailure(String)
    }

    func submit(
        title: String,
        body: String,
        node: SidebarNodeSummary?,
        redEnvelope: RedEnvelopeDraft?,
        lottery: LotteryDraft?
    ) async -> SubmitOutcome {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let community = node else { return .failed }
        guard DiscourseAuth.shared.isAuthenticated else {
            errorText = AppString("请先登录再发帖。")
            return .failed
        }

        // Posting twice would create a second topic and, worse, charge the red
        // envelope again. Once a topic is live this store is spent.
        guard !hasPublished else {
            errorText = AppString("这篇帖子已经发布过了。")
            return .failed
        }

        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }

        let created: CreatePostResponse
        do {
            created = try await client.createTopic(
                title: trimmedTitle,
                raw: trimmedBody.isEmpty ? trimmedTitle : trimmedBody,
                categoryID: community.id
            )
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed
        }
        hasPublished = true

        // The topic exists from here on; nothing below may report `.failed`.
        // Both records attach to what was just created — the envelope by topic
        // id, the lottery by *post* id — and each can fail independently.
        pendingRedEnvelopeTopicID = redEnvelope == nil ? nil : created.topicId
        pendingLotteryPostID = lottery == nil ? nil : created.id

        var failures: [String] = []

        if let redEnvelope, redEnvelope.points != nil {
            if created.topicId == nil {
                failures.append(AppString("没有拿到主题 ID，红包未创建。"))
            } else if let failure = await createRedEnvelope(redEnvelope) {
                failures.append(failure)
            }
        }

        if let lottery {
            if created.id == nil {
                failures.append(AppString("没有拿到帖子 ID，抽奖未创建。"))
            } else if let failure = await createLottery(lottery) {
                failures.append(failure)
            }
        }

        guard failures.isEmpty else {
            return .postedWithFollowUpFailure(AppString("帖子已发布，但：\n") + failures.joined(separator: "\n"))
        }
        return .posted
    }

    /// Returns nil on success, or a reason on failure. Clears the pending id so
    /// a retry only re-runs what actually failed.
    private func createRedEnvelope(_ draft: RedEnvelopeDraft) async -> String? {
        guard let topicID = pendingRedEnvelopeTopicID,
              let points = draft.points,
              let count = draft.count
        else { return nil }

        do {
            let response = try await client.createRedEnvelope(
                topicID: topicID,
                totalPoints: points,
                totalCount: count
            )
            if response.success == false {
                return AppString("红包创建失败：\(response.error ?? "未知错误")")
            }
            pendingRedEnvelopeTopicID = nil
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AppString("红包创建失败：\(reason)")
        }
    }

    private func createLottery(_ draft: LotteryDraft) async -> String? {
        guard let postID = pendingLotteryPostID else { return nil }

        do {
            let response = try await client.createLottery(postID: postID, draft: draft)
            if response.success == false {
                return AppString("抽奖创建失败：\(response.error ?? "未知错误")")
            }
            pendingLotteryPostID = nil
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AppString("抽奖创建失败：\(reason)")
        }
    }

    /// Re-runs whichever follow-ups are still outstanding on the published post.
    func retryFollowUps(redEnvelope: RedEnvelopeDraft?, lottery: LotteryDraft?) async -> Bool {
        var failures: [String] = []
        if let redEnvelope, pendingRedEnvelopeTopicID != nil,
           let failure = await createRedEnvelope(redEnvelope) {
            failures.append(failure)
        }
        if let lottery, pendingLotteryPostID != nil,
           let failure = await createLottery(lottery) {
            failures.append(failure)
        }
        guard failures.isEmpty else {
            errorText = failures.joined(separator: "\n")
            return false
        }
        return true
    }

    /// Uploads one file through the shared rate-limited queue. Throws so callers
    /// can record a per-attachment failure; `errorText` is only set for problems
    /// that aren't already visible on an attachment tile.
    func uploadMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        guard DiscourseAuth.shared.isAuthenticated else {
            throw ComposeUploadError.notAuthenticated
        }

        pendingUploadCount += 1
        defer { pendingUploadCount = max(0, pendingUploadCount - 1) }

        let client = self.client
        return try await ComposeUploadQueue.shared.run { [data, fileName, mimeType] in
            try await client.uploadComposerMedia(data: data, fileName: fileName, mimeType: mimeType)
        }
    }

    /// Uploads a video poster frame. Named after the video's SHA1 because
    /// Discourse links the two by filename, not by markdown.
    func uploadVideoPoster(data: Data, videoSHA1: String) async throws -> DiscourseUpload {
        guard DiscourseAuth.shared.isAuthenticated else {
            throw ComposeUploadError.notAuthenticated
        }

        pendingUploadCount += 1
        defer { pendingUploadCount = max(0, pendingUploadCount - 1) }

        let client = self.client
        return try await ComposeUploadQueue.shared.run { [data, videoSHA1] in
            try await client.uploadVideoPoster(data: data, videoSHA1: videoSHA1)
        }
    }

    /// Human-readable text for an upload failure shown on an attachment tile.
    func uploadFailureText(_ error: Error) -> String {
        if let composeError = error as? ComposeUploadError { return composeError.message }
        if case DiscourseError.badResponse(let status, _) = error {
            switch status {
            case 429: return AppString("上传太频繁，请稍后重试。")
            case 413: return AppString("图片太大，站点拒绝了上传。")
            case 401, 403: return AppString("没有上传权限，请重新登录。")
            default: return AppString("上传失败（\(status)）。")
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum ComposeUploadError: LocalizedError {
    case notAuthenticated
    case encodingFailed

    var message: String {
        switch self {
        case .notAuthenticated: AppString("请先登录再上传图片。")
        case .encodingFailed: AppString("无法读取这张图片。")
        }
    }

    var errorDescription: String? { message }
}

// MARK: - Search

/// Recent search terms, kept on the device.
///
/// Shared rather than per-view: the search overlay and the full history screen
/// both read it, and a term recorded in one has to show up in the other without
/// a reload.
@MainActor
@Observable
final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private static let defaultsKey = "searchHistory"
    /// Enough to fill the history screen without letting the list grow forever.
    private static let limit = 50

    private(set) var entries: [String] = []

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// The few shown under 最近 on the search screen itself.
    func recent(_ count: Int = 4) -> [String] {
        Array(entries.prefix(count))
    }

    /// Records a term the user actually searched for. Most recent first, with
    /// any earlier occurrence removed so repeating a search moves it up instead
    /// of duplicating it.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.limit {
            entries = Array(entries.prefix(Self.limit))
        }
        persist()
    }

    func remove(_ term: String) {
        entries.removeAll { $0 == term }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(entries, forKey: Self.defaultsKey)
    }
}

/// One user row in search results.
struct SearchUserResult: Identifiable {
    let id: Int
    let username: String
    let displayName: String?
    let avatarURL: URL?
}

/// One node row in search results.
struct SearchNodeResult: Identifiable {
    let id: Int
    let slug: String
    let name: String
    let desc: String
    let logoURL: URL?
}

@MainActor
@Observable
final class SearchStore {
    private let client = DiscourseClient()

    var communities: [Community] = []
    var results: [Post] = []
    /// Topics that contain images (the 媒体 scope), kept apart from `results`
    /// so switching scopes doesn't discard the other list.
    var mediaResults: [Post] = []
    var userResults: [SearchUserResult] = []
    var nodeResults: [SearchNodeResult] = []
    var appResults: [DirectoryApp] = []
    var isSearching = false
    private var loadedCategories = false
    private var categoriesByID: [Int: DiscourseCategory] = [:]
    /// The apps directory, fetched once and filtered locally per query.
    private var appsDirectory: [DirectoryApp]?
    /// Identifies the in-flight search so a stale response can't overwrite a
    /// newer one when the term or scope changes mid-request.
    private var currentRequestID: UUID?

    func loadCategories() async {
        guard !loadedCategories else { return }
        async let responseCall = SiteResources.shared.categoriesResponse()
        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
        let response = await responseCall
        let site = await siteCall

        guard let listed = response?.categoryList.categories, !listed.isEmpty else {
            return
        }
        categoriesByID = Dictionary(
            (site?.categories ?? listed).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let top = listed
            .filter { $0.parentCategoryId == nil }
            .sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }
            .prefix(8)
        communities = top.enumerated().map { index, category in
            Community(
                id: category.id,
                name: "n/\(category.slug)",
                letter: String(category.name.prefix(1)).uppercased(),
                variant: index % 2,
                members: compactCount(category.topicCount),
                desc: DiscourseFormat.plainText(category.descriptionExcerpt)
            )
        }
        loadedCategories = true
    }

    /// Scope-aware search. Each scope has to use the endpoint that can
    /// actually answer it: `/search.json` reports **zero** users and (for most
    /// terms) zero categories, so people come from `/u/search/users.json` and
    /// nodes are matched locally against the full category list site.json
    /// already gave us. Only posts and media really come from search.json.
    func search(_ query: String, scope: SearchScope = .all) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            clearResults()
            return
        }

        // Drop results from a previous term/scope so a slow response can't
        // land on top of a newer one.
        let requestID = UUID()
        currentRequestID = requestID
        isSearching = true
        await loadCategories()

        switch scope {
        case .all:
            // The mixed view: nodes and people alongside the topics.
            async let postsCall = topics(term: term)
            async let usersCall = users(term: term)
            let nodes = matchingNodes(term)
            let posts = await postsCall
            let people = await usersCall
            guard currentRequestID == requestID else { return }
            results = posts
            userResults = people
            nodeResults = nodes
            appResults = []

        case .posts:
            let posts = await topics(term: term)
            guard currentRequestID == requestID else { return }
            results = posts

        case .media:
            // Discourse's own operator, rather than filtering what came back.
            let posts = await topics(term: term, filters: "with:images")
            guard currentRequestID == requestID else { return }
            mediaResults = posts

        case .users:
            let people = await users(term: term)
            guard currentRequestID == requestID else { return }
            userResults = people

        case .nodes:
            // Local: instant, and complete — site.json carries every node.
            nodeResults = matchingNodes(term)

        case .apps:
            let apps = await matchingApps(term)
            guard currentRequestID == requestID else { return }
            appResults = apps
        }

        if currentRequestID == requestID {
            isSearching = false
        }
    }

    private func clearResults() {
        results = []
        mediaResults = []
        userResults = []
        nodeResults = []
        appResults = []
        isSearching = false
    }

    /// Topics, joined to the matching post for the excerpt and author —
    /// search topics carry neither (no `excerpt`, no `image_url`, no posters).
    private func topics(term: String, filters: String? = nil) async -> [Post] {
        guard let response = try? await client.search(term, filters: filters) else { return [] }
        let postsByTopic = Dictionary(
            (response.posts ?? []).map { ($0.topicId ?? 0, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return (response.topics ?? []).map { topic in
            let category = topic.categoryId.flatMap { categoriesByID[$0] }
            let match = postsByTopic[topic.id]
            let author = match?.username
            return Post(
                id: topic.id,
                node: category.map { "n/\($0.slug)" } ?? "n/nodeloc",
                avatarLetter: String((author ?? category?.name ?? topic.title).prefix(1)).uppercased(),
                variant: topic.id % 2,
                time: DiscourseFormat.relative(topic.createdAt),
                title: topic.title.breakingLongTokens(),
                excerpt: DiscourseFormat.plainText(match?.blurb),
                // All three are the first post's count: search pairs the first
                // post, and `op_like_count` is the list serializer's own.
                baseVotes: match?.likeCount ?? topic.opLikeCount ?? topic.likeCount ?? 0,
                voteScore: topic.opVoteScore,
                voteDirection: topic.opVoteDirection ?? .none,
                canVoteDown: topic.opCanVoteDown ?? false,
                opPostID: topic.opPostId,
                notificationLevel: topic.notificationLevel,
                isBookmarked: topic.bookmarked ?? false,
                // `posts_count - 1`, never `reply_count`: Discourse's
                // `reply_count` counts only posts answering *another post*, a
                // much smaller unrelated number (t/105832: 25 posts, so 24
                // replies, but `reply_count` 7). The site's own replies column
                // is `posts_count - 1`.
                comments: max(0, (topic.postsCount ?? 1) - 1),
                hasImage: false,
                avatarURL: match?.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                authorUsername: author,
                authorName: match?.name,
                tags: (topic.tags ?? []).compactMap(\.name)
            )
        }
    }

    private func users(term: String) async -> [SearchUserResult] {
        guard let response = try? await client.searchUsers(term: term) else { return [] }
        return (response.users ?? []).map { user in
            SearchUserResult(
                id: user.id,
                username: user.username,
                displayName: user.name?.isEmpty == false ? user.name : nil,
                avatarURL: user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 96) }
            )
        }
    }

    /// Nodes are matched here rather than server-side: Discourse's category
    /// search only matches names loosely (it misses "chit" → chit-chat), while
    /// site.json has already given us all 160-odd of them.
    private func matchingNodes(_ term: String) -> [SearchNodeResult] {
        let needle = term.lowercased()
        return categoriesByID.values
            // Nodes are the subcategories; the top level is broad sections.
            .filter { $0.parentCategoryId != nil }
            .filter {
                $0.slug.lowercased().contains(needle)
                    || $0.name.lowercased().contains(needle)
                    || ($0.descriptionExcerpt?.lowercased().contains(needle) ?? false)
            }
            .sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }
            .prefix(30)
            .map { category in
                SearchNodeResult(
                    id: category.id,
                    slug: category.slug,
                    name: category.name,
                    desc: DiscourseFormat.plainText(category.descriptionExcerpt ?? category.description),
                    logoURL: category.uploadedLogo?.url.flatMap {
                        URL(string: $0, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
                    }
                )
            }
    }

    /// Apps whose name/slug/description contains the term. The discourse-apps
    /// plugin has no search endpoint, so this filters the (small) directory.
    private func matchingApps(_ term: String) async -> [DirectoryApp] {
        if appsDirectory == nil {
            appsDirectory = (try? await client.appsDirectory()) ?? []
        }
        let lowered = term.lowercased()
        return (appsDirectory ?? []).filter { app in
            app.name.lowercased().contains(lowered)
                || app.slug.lowercased().contains(lowered)
                || (app.description?.lowercased().contains(lowered) ?? false)
        }
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "0" }
        return value >= 1000 ? String(format: "%.0fk", Double(value) / 1000) : "\(value)"
    }
}

// MARK: - Chat

private enum ChatListMapper {
    private struct ChannelItem {
        let originalIndex: Int
        let channel: ChatChannel
        let tracking: ChatTrackingState?
    }

    static func chats(from response: ChatChannelsResponse) -> [Chat] {
        var items: [ChannelItem] = []
        for (index, channel) in response.allChannels.enumerated() {
            items.append(
                ChannelItem(
                    originalIndex: index,
                    channel: channel,
                    tracking: response.tracking?.state(for: channel.id)
                )
            )
        }

        var sortedItems: [ChannelItem] = []
        for item in items {
            var inserted = false
            for index in sortedItems.indices {
                if isMoreRecent(item, than: sortedItems[index]) {
                    sortedItems.insert(item, at: index)
                    inserted = true
                    break
                }
            }
            if !inserted {
                sortedItems.append(item)
            }
        }

        var mappedChats: [Chat] = []
        for (displayIndex, item) in sortedItems.enumerated() {
            mappedChats.append(chat(from: item.channel, tracking: item.tracking, displayIndex: displayIndex))
        }
        return mappedChats
    }

    private static func isMoreRecent(_ lhs: ChannelItem, than rhs: ChannelItem) -> Bool {
        let leftDate = activityDate(for: lhs.channel, tracking: lhs.tracking)
        let rightDate = activityDate(for: rhs.channel, tracking: rhs.tracking)

        switch (leftDate, rightDate) {
        case let (left?, right?):
            if left == right { return lhs.originalIndex < rhs.originalIndex }
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.originalIndex < rhs.originalIndex
        }
    }

    static func chat(from channel: ChatChannel, displayIndex: Int) -> Chat {
        chat(from: channel, tracking: nil, displayIndex: displayIndex)
    }

    private static func chat(from channel: ChatChannel, tracking: ChatTrackingState?, displayIndex: Int) -> Chat {
        let name = displayName(for: channel)
        let message = messageText(for: channel)
        let unreadCount = tracking?.totalUnreadCount ?? channel.currentUserMembership?.unreadCount ?? 0
        let threadUnreadCount = tracking?.watchedThreadsUnreadCount ?? 0

        return Chat(
            id: channel.id,
            name: name,
            letter: avatarLetter(for: channel, name: name),
            variant: displayIndex % 2,
            lastMsg: message.isEmpty ? AppString("暂无消息") : message,
            time: DiscourseFormat.relative(channel.lastMessage?.createdAt ?? tracking?.lastReplyCreatedAt),
            unread: unreadCount > 0,
            avatarURL: avatarURL(for: channel),
            threadUnreadCount: threadUnreadCount
        )
    }

    private static func displayName(for channel: ChatChannel) -> String {
        if channel.isDirectMessage {
            var names: [String] = []
            for user in displayUsers(for: channel) {
                let name = displayName(for: user)
                if !name.isEmpty {
                    names.append(name)
                }
            }
            if !names.isEmpty {
                return names.joined(separator: ", ")
            }
        }

        if let title = nonEmpty(channel.unicodeTitle ?? channel.title) {
            return title
        }
        if let categoryName = nonEmpty(channel.chatable?.name) {
            return categoryName
        }
        if let slug = nonEmpty(channel.slug) {
            return channel.isDirectMessage ? slug : "#\(slug)"
        }
        if let username = nonEmpty(channel.lastMessage?.user?.username) {
            return username
        }
        return channel.isDirectMessage ? AppString("私信") : AppString("频道")
    }

    private static func displayName(for user: ChatUser) -> String {
        nonEmpty(user.name) ?? user.username
    }

    private static func messageText(for channel: ChatChannel) -> String {
        let source = channel.lastMessage?.excerpt
            ?? channel.lastMessage?.message
            ?? channel.lastMessage?.cooked
            ?? channel.description
        return DiscourseFormat.plainText(source)
    }

    private static func activityDate(for channel: ChatChannel, tracking: ChatTrackingState?) -> Date? {
        DiscourseFormat.date(channel.lastMessage?.createdAt)
            ?? DiscourseFormat.date(tracking?.lastReplyCreatedAt)
            ?? DiscourseFormat.date(channel.currentUserMembership?.lastViewedAt)
    }

    private static func avatarLetter(for channel: ChatChannel, name: String) -> String {
        if !channel.isDirectMessage { return "#" }
        return String(name.prefix(1)).uppercased()
    }

    private static func avatarURL(for channel: ChatChannel) -> URL? {
        guard channel.isDirectMessage else { return nil }
        return displayUsers(for: channel)
            .compactMap { resolvedAvatarURL($0.avatarTemplate, size: 120) }
            .first
    }

    private static func displayUsers(for channel: ChatChannel) -> [ChatUser] {
        let users = channel.chatable?.users ?? []
        guard let currentUsername = DiscourseAuth.shared.username?.lowercased() else {
            return users
        }
        let others = users.filter { $0.username.lowercased() != currentUsername }
        return others.isEmpty ? users : others
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func resolvedAvatarURL(_ raw: String?, size: Int = 96) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: "{size}", with: String(size))
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("//") { return URL(string: "https:\(raw)") }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: raw)
    }
}

private enum ChatThreadMapper {
    static func threads(from response: ChatThreadsResponse) -> [ChatThreadListItem] {
        response.threads.enumerated().compactMap { index, thread in
            threadItem(from: thread, fallbackVariant: index)
        }
    }

    static func threadItem(from thread: ChatThreadSummary, fallbackVariant: Int) -> ChatThreadListItem? {
        let channelID = thread.channelId ?? thread.channel?.id ?? thread.originalMessage?.chatChannelId
        guard let channelID else { return nil }

        let originalText = plainText(
            thread.originalMessage?.excerpt
            ?? thread.originalMessage?.message
            ?? thread.originalMessage?.cooked
        )
        let previewText = plainText(thread.preview?.lastReplyExcerpt)
        let title = nonEmpty(thread.title)
            ?? (originalText.isEmpty ? nil : String(originalText.prefix(80)))
            ?? AppString("讨论串")
        let excerpt = previewText.isEmpty ? originalText : previewText
        let lastActivity = thread.preview?.lastReplyCreatedAt
            ?? thread.originalMessage?.createdAt
        let replyCount = thread.replyCount ?? thread.preview?.replyCount ?? 0
        let unreadCount = thread.currentUserMembership?.unreadCount ?? 0
        let avatarUser = thread.preview?.lastReplyUser
            ?? thread.originalMessage?.user
            ?? thread.preview?.participantUsers?.first
        let resolvedChannelName: String
        if let channel = thread.channel {
            resolvedChannelName = channelName(for: channel)
        } else {
            resolvedChannelName = AppString("聊天")
        }

        return ChatThreadListItem(
            id: thread.id,
            channelID: channelID,
            title: title,
            channelName: resolvedChannelName,
            excerpt: excerpt.isEmpty ? AppString("暂无回复") : excerpt,
            time: DiscourseFormat.relative(lastActivity),
            replyCount: replyCount,
            unread: unreadCount > 0,
            avatarLetter: avatarLetter(for: avatarUser, fallback: title),
            variant: fallbackVariant % 2,
            avatarURL: ChatListMapper.resolvedAvatarURL(avatarUser?.avatarTemplate, size: 96)
        )
    }

    private static func channelName(for channel: ChatChannel) -> String {
        if let title = nonEmpty(channel.unicodeTitle ?? channel.title) {
            return title
        }
        if let categoryName = nonEmpty(channel.chatable?.name) {
            return categoryName
        }
        if let slug = nonEmpty(channel.slug) {
            return channel.isDirectMessage ? slug : "#\(slug)"
        }
        return channel.isDirectMessage ? AppString("私信") : AppString("频道")
    }

    private static func avatarLetter(for user: ChatUser?, fallback: String) -> String {
        let source = user.flatMap { nonEmpty($0.name) ?? $0.username } ?? fallback
        return String(source.prefix(1)).uppercased()
    }

    private static func plainText(_ value: String?) -> String {
        DiscourseFormat.plainText(value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private enum ChatMessageMapper {
    static func messages(from response: ChatMessagesResponse) -> [ChatConversationMessage] {
        response.messages.enumerated().map { index, message in
            conversationMessage(from: message, fallbackVariant: index)
        }
    }

    static func conversationMessage(from message: ChatMessage, fallbackVariant: Int) -> ChatConversationMessage {
        let user = message.user
        let username = user?.username ?? "system"
        let authorName = nonEmpty(user?.name) ?? username
        let content = ChatCookedContentParser.content(from: message)
        let thread = threadItem(for: message, fallbackVariant: fallbackVariant)
        let currentUsername = DiscourseAuth.shared.username?.lowercased()

        return ChatConversationMessage(
            id: message.id,
            authorName: authorName,
            username: username,
            text: content.text.isEmpty && content.media.isEmpty ? AppString("消息已删除") : content.text,
            time: DiscourseFormat.relative(message.createdAt),
            avatarLetter: String(authorName.prefix(1)).uppercased(),
            variant: fallbackVariant % 2,
            avatarURL: ChatListMapper.resolvedAvatarURL(user?.avatarTemplate, size: 96),
            isMine: username.lowercased() == currentUsername,
            thread: thread,
            replyTo: quotedMessage(from: message.inReplyTo),
            reactions: (message.reactions ?? []).map {
                ChatReaction(
                    emoji: $0.emoji,
                    count: $0.count ?? 0,
                    reacted: $0.reacted ?? false
                )
            },
            isEdited: message.edited ?? false,
            // Drops the nulls the server sends for unresolvable custom flags.
            availableFlags: (message.availableFlags ?? []).compactMap { $0 },
            content: content.fragments,
            media: content.media,
            videos: content.videos
        )
    }

    private static func quotedMessage(from reply: ChatInReplyToMessage?) -> ChatQuotedMessage? {
        guard let reply, let id = reply.id else { return nil }
        let username = reply.user?.username ?? "system"
        let excerpt = DiscourseFormat.plainText(reply.excerpt ?? reply.cooked ?? reply.message)
        return ChatQuotedMessage(
            id: id,
            authorName: nonEmpty(reply.user?.name) ?? username,
            username: username,
            excerpt: excerpt.isEmpty ? AppString("消息") : excerpt
        )
    }

    static func threadItem(for message: ChatMessage, fallbackVariant: Int) -> ChatThreadListItem? {
        if let thread = message.thread {
            return ChatThreadMapper.threadItem(from: thread, fallbackVariant: fallbackVariant)
        }

        guard let threadID = message.threadId, let channelID = message.chatChannelId else {
            return nil
        }

        let title = nonEmpty(message.threadTitle)
            ?? nonEmpty(DiscourseFormat.plainText(message.excerpt ?? message.message ?? message.cooked))
            ?? AppString("讨论串")

        return ChatThreadListItem(
            id: threadID,
            channelID: channelID,
            title: title,
            channelName: AppString("聊天"),
            excerpt: AppString("查看讨论串"),
            time: "",
            replyCount: 0,
            unread: false,
            avatarLetter: String(title.prefix(1)).uppercased(),
            variant: fallbackVariant % 2,
            avatarURL: nil
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private enum ChatSearchResultMapper {
    static func results(from response: ChatSearchResponse) -> [ChatSearchResult] {
        response.messages.enumerated().compactMap { index, message in
            guard let channel = message.channel ?? message.thread?.channel else {
                return nil
            }

            let chat = ChatListMapper.chat(from: channel, displayIndex: index)
            let mappedMessage = ChatMessageMapper.conversationMessage(from: message, fallbackVariant: index)
            return ChatSearchResult(
                id: message.id,
                chat: chat,
                message: mappedMessage,
                thread: ChatMessageMapper.threadItem(for: message, fallbackVariant: index)
            )
        }
    }
}

private struct ChatParsedContent {
    let text: String
    let fragments: [ChatContentFragment]
    let media: [PostMedia]
    let videos: [URL]
}

private enum ChatCookedContentParser {
    static func content(from message: ChatMessage) -> ChatParsedContent {
        // Deliberately *not* falling back to `inReplyTo`: the quoted message is
        // rendered as a quote above the body now, and using it as the body made
        // an uploads-only reply look like it had repeated the original.
        let source = message.cooked
            ?? message.message
            ?? message.excerpt

        let fragments = inlineFragments(from: source)
        let text = readableText(from: source)
        return ChatParsedContent(
            text: text,
            fragments: fragments,
            media: mediaItems(from: message),
            videos: videoItems(from: message)
        )
    }

    private static func inlineFragments(from source: String?) -> [ChatContentFragment] {
        guard let source, !source.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else {
            return textFragments(from: source)
        }

        var fragments: [ChatContentFragment] = []
        var nextID = 0
        var cursor = source.startIndex
        let range = NSRange(source.startIndex..<source.endIndex, in: source)

        for match in regex.matches(in: source, range: range) {
            guard let tagRange = Range(match.range, in: source) else { continue }
            appendTextFragments(String(source[cursor..<tagRange.lowerBound]), to: &fragments, nextID: &nextID)

            let tag = String(source[tagRange])
            if let emojiImage = emojiImage(from: tag) {
                fragments.append(ChatContentFragment(id: "emoji-\(nextID)", kind: .emojiImage(emojiImage)))
                nextID += 1
            } else if isEmojiImage(tag) {
                // Unreachable for a well-formed emoji image — `emojiImage` takes
                // both kinds now — but a tag with no usable `src` still has its
                // shortcode, and that reads better than nothing.
                appendTextFragments(emojiReplacement(for: tag), to: &fragments, nextID: &nextID)
            }

            cursor = tagRange.upperBound
        }

        appendTextFragments(String(source[cursor...]), to: &fragments, nextID: &nextID)
        return fragments
    }

    private static func readableText(from source: String?) -> String {
        guard var text = source, !text.isEmpty else { return "" }

        text = replacingMatches(in: text, pattern: #"<img\b[^>]*>"#) { tag in
            isEmojiImage(tag) ? emojiReplacement(for: tag) : ""
        }
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</(p|div|li|blockquote|h[1-6])>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<li\b[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = replaceEmojiShortcodes(in: text)
        return normalizeWhitespace(text)
    }

    private static func textFragments(from source: String) -> [ChatContentFragment] {
        var fragments: [ChatContentFragment] = []
        var nextID = 0
        appendTextFragments(source, to: &fragments, nextID: &nextID)
        return fragments
    }

    private static func appendTextFragments(
        _ source: String,
        to fragments: inout [ChatContentFragment],
        nextID: inout Int
    ) {
        let text = cleanedInlineText(from: source)
        guard !text.isEmpty else { return }

        let lines = text.components(separatedBy: .newlines)
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                fragments.append(ChatContentFragment(id: "break-\(nextID)", kind: .lineBreak))
                nextID += 1
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            fragments.append(ChatContentFragment(id: "text-\(nextID)", kind: .text(trimmed)))
            nextID += 1
        }
    }

    private static func cleanedInlineText(from source: String) -> String {
        var text = source
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</(p|div|li|blockquote|h[1-6])>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<li\b[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = replaceEmojiShortcodes(in: text)
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    private static func mediaItems(from message: ChatMessage) -> [PostMedia] {
        var media: [PostMedia] = []
        var seen = Set<String>()

        if let cooked = message.cooked {
            for tag in matches(in: cooked, pattern: #"<img\b[^>]*>"#) where !isEmojiImage(tag) {
                guard let rawURL = attribute("src", in: tag), let url = absoluteURL(rawURL) else { continue }
                appendMedia(
                    url: url,
                    width: attribute("width", in: tag).flatMap(Int.init),
                    height: attribute("height", in: tag).flatMap(Int.init),
                    to: &media,
                    seen: &seen
                )
            }
        }

        for upload in message.uploads ?? [] where isImageUpload(upload) {
            guard let rawURL = upload.url ?? upload.shortUrl, let url = absoluteURL(rawURL) else { continue }
            appendMedia(
                url: url,
                width: upload.width,
                height: upload.height,
                to: &media,
                seen: &seen
            )
        }

        return media
    }

    private static func appendMedia(
        url: URL,
        width: Int?,
        height: Int?,
        to media: inout [PostMedia],
        seen: inout Set<String>
    ) {
        let key = url.absoluteString
        guard seen.insert(key).inserted else { return }
        media.append(PostMedia(url: url, width: width, height: height))
    }

    /// Video uploads, which `mediaItems` deliberately skips. Read off `uploads`
    /// rather than the cooked HTML: chat cooks a clip into a placeholder div
    /// whose shape is the post renderer's problem, while the upload row already
    /// carries a playable URL.
    private static func videoItems(from message: ChatMessage) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for upload in message.uploads ?? [] where isVideoUpload(upload) {
            guard let raw = upload.url ?? upload.shortUrl,
                  let url = absoluteURL(raw),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func isVideoUpload(_ upload: DiscourseUpload) -> Bool {
        guard let ext = upload.fileExtension?.lowercased() else { return false }
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"].contains(ext)
    }

    private static func isImageUpload(_ upload: DiscourseUpload) -> Bool {
        if let ext = upload.fileExtension?.lowercased() {
            return imageExtensions.contains(ext)
        }
        if let url = upload.url ?? upload.shortUrl {
            return imageExtensions.contains(URL(string: url)?.pathExtension.lowercased() ?? "")
        }
        return false
    }

    private static func isEmojiImage(_ tag: String) -> Bool {
        let classes = classList(in: tag)
        let src = attribute("src", in: tag) ?? ""
        return classes.contains("emoji")
            || classes.contains("emoji-custom")
            || src.range(of: #"/_?emoji/"#, options: .regularExpression) != nil
    }

    /// Any emoji image, custom *or* standard.
    ///
    /// Standard ones used to be swapped for a Unicode character from a table of
    /// about fifteen — every other shortcode fell through and the bubble showed
    /// `:grinning_face:` as literal text. Discourse serves them all as images
    /// (`/images/emoji/unicode/<name>.png`), which is what the web and this
    /// app's post renderer both draw, so drawing them here too is both simpler
    /// and complete.
    private static func emojiImage(from tag: String) -> ChatEmojiImage? {
        guard isEmojiImage(tag),
              let rawURL = attribute("src", in: tag),
              let url = absoluteURL(rawURL) else {
            return nil
        }

        let shortcode = customEmojiShortcode(from: tag)
        return ChatEmojiImage(
            shortcode: shortcode,
            url: url,
            width: attribute("width", in: tag).flatMap(Int.init),
            height: attribute("height", in: tag).flatMap(Int.init)
        )
    }

    private static func emojiReplacement(for tag: String) -> String {
        let rawValue = attribute("alt", in: tag)
            ?? attribute("title", in: tag)
            ?? attribute("aria-label", in: tag)
            ?? ""
        let decoded = decodeHTMLEntities(rawValue)
        return emojiDisplay(for: decoded)
    }

    private static func customEmojiShortcode(from tag: String) -> String {
        let rawValue = attribute("alt", in: tag)
            ?? attribute("title", in: tag)
            ?? attribute("aria-label", in: tag)
            ?? "custom_emoji"
        let decoded = decodeHTMLEntities(rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return ":custom_emoji:" }
        if decoded.hasPrefix(":") && decoded.hasSuffix(":") {
            return decoded
        }
        return ":\(decoded.trimmingCharacters(in: CharacterSet(charactersIn: ":"))):"
    }

    private static func classList(in tag: String) -> Set<String> {
        let className = attribute("class", in: tag) ?? ""
        return Set(className.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    private static func replaceEmojiShortcodes(in text: String) -> String {
        replacingMatches(in: text, pattern: #":[A-Za-z0-9_+\-]+:"#) { shortcode in
            emojiDisplay(for: shortcode)
        }
    }

    private static func emojiDisplay(for rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if let native = nativeEmojiByShortcode[value] {
            return native
        }
        return value
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var text = value
        let named = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&hellip;": "…",
            "&nbsp;": " "
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        text = replacingMatches(in: text, pattern: #"&#x([0-9A-Fa-f]+);"#) { match in
            guard let scalar = scalarValue(in: match, radix: 16) else { return match }
            return String(scalar)
        }
        text = replacingMatches(in: text, pattern: #"&#([0-9]+);"#) { match in
            guard let scalar = scalarValue(in: match, radix: 10) else { return match }
            return String(scalar)
        }
        return text
    }

    private static func scalarValue(in entity: String, radix: Int) -> UnicodeScalar? {
        let digits = entity
            .replacingOccurrences(of: "&#x", with: "")
            .replacingOccurrences(of: "&#", with: "")
            .replacingOccurrences(of: ";", with: "")
        guard let value = UInt32(digits, radix: radix) else { return nil }
        return UnicodeScalar(value)
    }

    private static func absoluteURL(_ raw: String) -> URL? {
        let decoded = decodeHTMLEntities(raw)
        if decoded.hasPrefix("http") { return URL(string: decoded) }
        if decoded.hasPrefix("//") { return URL(string: "https:\(decoded)") }
        if decoded.hasPrefix("/") {
            return URL(string: decoded, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: decoded)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let stringRange = Range(matchRange, in: tag) else { continue }
            return String(tag[stringRange])
        }
        return nil
    }

    private static func matches(in value: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let stringRange = Range(match.range, in: value) else { return nil }
            return String(value[stringRange])
        }
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        var output = value
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: range)
        for match in matches.reversed() {
            guard let stringRange = Range(match.range, in: output) else { continue }
            let replacement = transform(String(output[stringRange]))
            output.replaceSubrange(stringRange, with: replacement)
        }
        return output
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif"
    ]

    private static let nativeEmojiByShortcode: [String: String] = [
        ":+1:": "👍",
        ":-1:": "👎",
        ":100:": "💯",
        ":clap:": "👏",
        ":eyes:": "👀",
        ":fire:": "🔥",
        ":heart:": "❤️",
        ":heart_eyes:": "😍",
        ":joy:": "😂",
        ":laughing:": "😆",
        ":ok_hand:": "👌",
        ":pray:": "🙏",
        ":rocket:": "🚀",
        ":rofl:": "🤣",
        ":slight_smile:": "🙂",
        ":smile:": "😄",
        ":smiley:": "😃",
        ":sob:": "😭",
        ":sweat_smile:": "😅",
        ":tada:": "🎉",
        ":thinking:": "🤔",
        ":thumbsdown:": "👎",
        ":thumbsup:": "👍",
        ":wink:": "😉",
        ":x:": "❌",
        ":white_check_mark:": "✅"
    ]
}

@MainActor
@Observable
final class ChatStore {
    private let client = DiscourseClient()

    var chats: [Chat] = []
    var isLoading = false
    var needsLogin = false
    private var loaded = false

    func load() async {
        guard DiscourseAuth.shared.isAuthenticated else {
            needsLogin = true
            chats = []
            return
        }
        needsLogin = false
        guard !loaded else { return }
        isLoading = true
        do {
            let response = try await client.chatChannels()
            chats = ChatListMapper.chats(from: response)
            loaded = true
        } catch {
            chats = []
        }
        isLoading = false
    }
}

/// Resolves a notification to the nodeloc URL its row should open. Topic-based
/// kinds (replies, mentions, likes, PMs) build a /t/<slug>/<id>/<post> deep
/// link; the rest resolve to their web page. The URL is fed through
/// `LinkRouter`, so topics/PMs open natively and badges/groups/chat open in the
/// in-app browser. `nil` when nothing sensible to open (row stays inert).
enum NotificationRouting {
    static func url(for notification: DiscourseNotification) -> URL? {
        let base = DiscourseConfig.baseURL

        if let topicID = notification.topicId {
            let slug = notification.slug ?? "topic"
            var path = "t/\(slug)/\(topicID)"
            if let post = notification.postNumber, post > 1 { path += "/\(post)" }
            return base.appending(path: path)
        }

        let data = notification.data
        if let channel = data?.chatChannelId {
            var path = "chat/c/-/\(channel)"
            if let message = data?.chatMessageId { path += "/\(message)" }
            return base.appending(path: path)
        }
        if let badgeID = data?.badgeId {
            return base.appending(path: "badges/\(badgeID)/\(data?.badgeSlug ?? "-")")
        }
        if let group = data?.groupName, let username = data?.username {
            return base.appending(path: "u/\(username)/messages/group/\(group)")
        }
        return nil
    }
}

/// Formats a Discourse notification for display. Shared by the inbox rows,
/// the notifications overlay, and the push banners so they all describe a
/// notification with the same words.
enum NotificationFormatter {
    static func kind(forType type: Int) -> NotificationKind {
        switch type {
        case 5:
            return .like
        case 16:
            // group_message_summary — a system notice about a group inbox.
            return .system
        case 6, 7:
            return .message
        case 1, 2, 3, 9:
            return .comment
        case 12:
            return .star
        default:
            return .star
        }
    }

    static func displayName(for notification: DiscourseNotification, kind: NotificationKind) -> String {
        kind == .system
            ? AppString("系统通知")
            : (notification.data?.displayUsername ?? notification.data?.username ?? "NODELOC")
    }

    static func text(for notification: DiscourseNotification, kind: NotificationKind) -> String {
        if kind == .system {
            let group = notification.data?.groupName ?? AppString("群组")
            if let count = notification.data?.inboxCount {
                return AppString("您的 \(group) 收件箱有 \(count) 条消息")
            }
            return AppString("您的 \(group) 收件箱有新消息")
        }
        if kind == .message {
            if let title = notification.data?.topicTitle { return title }
            return AppString("给你发了一条私信")
        }
        if let title = notification.data?.topicTitle {
            switch kind {
            case .like:
                return AppString("点赞了你在 \(title) 的内容")
            case .comment:
                return AppString("回复了 \(title)")
            default:
                return title
            }
        }
        if let badge = notification.data?.badgeName { return AppString("授予你 \(badge) 徽章") }
        return AppString("发来一条通知")
    }

    /// One `AppNotification` row from the raw payload.
    static func appNotification(from notification: DiscourseNotification) -> AppNotification {
        let kind = kind(forType: notification.notificationType)
        return AppNotification(
            id: notification.id,
            kind: kind,
            name: displayName(for: notification, kind: kind),
            text: text(for: notification, kind: kind),
            time: DiscourseFormat.relative(notification.createdAt),
            unread: !notification.read,
            url: NotificationRouting.url(for: notification)
        )
    }
}

@MainActor
@Observable
final class MessageCenterStore {
    /// Shared so the bottom tab's unread badge and the inbox read the same
    /// counts without each fetching their own.
    static let shared = MessageCenterStore()

    private let client = DiscourseClient()

    var notifications: [AppNotification] = []
    /// Personal private-message conversations (from /topics/private-messages),
    /// not the PM-typed notifications the old code derived.
    var conversations: [PMConversation] = []
    /// Conversations for the currently selected group filter.
    var groupConversations: [PMConversation] = []
    /// Group names with a message inbox — the PM pane's filter options.
    var messageGroups: [String] = []
    /// nil = personal inbox; otherwise the selected group's name.
    var selectedPMGroup: String?
    var isLoadingGroupPMs = false

    /// What the PM pane shows for the current filter.
    var visibleConversations: [PMConversation] {
        selectedPMGroup == nil ? conversations : groupConversations
    }
    var chats: [Chat] = []
    var threads: [ChatThreadListItem] = []
    var chatSearchResults: [ChatSearchResult] = []
    var isLoading = false
    var isSearchingChat = false
    var needsLogin = false
    var errorText: String?
    var chatSearchErrorText: String?

    // Unread counts for the tab badge. Notifications and PMs come from the
    // current-user payload; chat is summed from the loaded channels.
    var unreadNotifications = 0
    var unreadPrivateMessages = 0
    var unreadChat = 0
    /// What the bottom Message tab badges.
    var unreadTotal: Int { unreadNotifications + unreadPrivateMessages + unreadChat }

    /// Live updates for the inbox list itself, separate from the open
    /// conversation's own subscription.
    @ObservationIgnored private let bus = MessageBusClient()
    @ObservationIgnored private var watchedChannelIDs: Set<Int> = []

    private var loaded = false
    private var chatSearchRequestID: UUID?

    /// Forces the next `load()` to hit the network — used when re-entering the
    /// inbox so counts and lists reflect anything read elsewhere.
    func reload() async {
        loaded = false
        await load()
    }

    /// Marks all notifications read, as opening the notifications menu does on
    /// the web.
    ///
    /// Called when the 通知 pane is *shown*, not when the inbox is opened — the
    /// inbox lands on 聊天, and clearing the badge on entry meant unread
    /// notifications were gone before they had been seen.
    func markNotificationsRead() async {
        guard unreadNotifications > 0 else { return }
        unreadNotifications = 0
        try? await client.markNotificationsRead()
    }

    /// 全部已读 for the whole inbox. Two calls cover all three panes:
    /// `notifications/mark-read` also clears the private-message count, since
    /// Discourse derives that from PM notifications, and the chat plugin has a
    /// bulk endpoint of its own. Applied locally first so the badges drop
    /// immediately rather than after two round trips.
    func markAllRead() async {
        unreadNotifications = 0
        unreadPrivateMessages = 0
        unreadChat = 0
        for index in notifications.indices { notifications[index].unread = false }
        for index in conversations.indices { conversations[index].unread = false }
        for index in chats.indices {
            chats[index].unread = false
            chats[index].threadUnreadCount = 0
        }

        async let notificationsCall: Data? = try? await client.markNotificationsRead()
        async let chatCall: Data? = try? await client.markAllChatChannelsRead()
        _ = await (notificationsCall, chatCall)
    }

    /// Clears a conversation's unread dot and the PM count when it's opened.
    /// The server marks the topic read once its posts are viewed; this keeps
    /// the badge honest immediately.
    func markConversationRead(id: Int) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].unread else { return }
        conversations[index].unread = false
        unreadPrivateMessages = conversations.filter(\.unread).count
    }

    /// Switches the PM pane's filter. `nil` shows the personal inbox (already
    /// loaded); a group name fetches that group's PMs.
    func selectPMGroup(_ group: String?) async {
        selectedPMGroup = group
        guard let group,
              let username = DiscourseAuth.shared.username else {
            groupConversations = []
            return
        }
        // A group arriving from a notification may not be in the fetched list
        // yet; surface it as a chip so the filter shows as selected.
        if !messageGroups.contains(group) { messageGroups.append(group) }
        isLoadingGroupPMs = true
        defer { isLoadingGroupPMs = false }
        do {
            let response = try await client.groupPrivateMessages(username: username, group: group)
            // Guard against a slow response landing after the user switched away.
            guard selectedPMGroup == group else { return }
            groupConversations = Self.conversations(from: response, client: client)
        } catch {
            if selectedPMGroup == group { groupConversations = [] }
        }
    }

    /// Keeps the inbox live: one long poll covering every channel's
    /// `new-messages` bus channel, which is what the site's own sidebar
    /// subscribes to. Without it the list only changed when the tab was
    /// re-entered, so a message that arrived while it was open stayed invisible
    /// until a manual refresh.
    ///
    /// One HTTP request regardless of channel count — MessageBus takes all the
    /// positions in a single poll.
    private func watchChannels() {
        let channels = chats.map { "/chat/\($0.id)/new-messages" }
        guard !channels.isEmpty else {
            bus.stop()
            watchedChannelIDs = []
            return
        }

        // Re-subscribing restarts the poll, so only do it when the set actually
        // changed — otherwise every list refresh would drop a poll mid-flight.
        let ids = Set(chats.map(\.id))
        guard ids != watchedChannelIDs else { return }
        watchedChannelIDs = ids

        bus.subscribe(channels: channels) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshChats() }
        }
    }

    /// Re-reads just the channel list. Cheap enough to run per event, and it
    /// carries everything a row shows: last message, unread count, ordering.
    private func refreshChats() async {
        guard let response = try? await client.chatChannels() else { return }
        chats = ChatListMapper.chats(from: response)
        unreadChat = chats.reduce(0) { $0 + $1.threadUnreadCount + ($1.unread ? 1 : 0) }
        watchChannels()
    }

    /// The direct-message channel with one person, opening it if the two have
    /// never talked. The server returns the existing channel when there is one,
    /// so this is safe to call repeatedly. Nil means the request failed — the
    /// caller shows the notice, since only it knows what the user was doing.
    func directMessageChannel(with username: String) async -> Chat? {
        guard !username.isEmpty else { return nil }

        // Prefer a channel already in the inbox: it carries unread counts and
        // the last message, which a freshly created one has none of.
        if let existing = chats.first(where: { $0.name.caseInsensitiveCompare(username) == .orderedSame }) {
            return existing
        }

        do {
            let response = try await client.createDirectMessageChannel(usernames: [username])
            return ChatListMapper.chat(from: response.channel, displayIndex: 0)
        } catch {
            ToastCenter.shared.showError(error)
            return nil
        }
    }

    /// Starts a chat with one or several people.
    ///
    /// The same endpoint either way: `target_usernames[]` with more than one
    /// name makes Discourse create a *group* direct message. Existing channels
    /// come back rather than duplicates.
    func createDirectMessage(with usernames: [String]) async -> Chat? {
        guard !usernames.isEmpty else { return nil }
        do {
            let response = try await client.createDirectMessageChannel(usernames: usernames)
            let chat = ChatListMapper.chat(from: response.channel, displayIndex: 0)
            // Show up in the inbox straight away rather than after a reload.
            if !chats.contains(where: { $0.id == chat.id }) {
                chats.insert(chat, at: 0)
            }
            return chat
        } catch {
            ToastCenter.shared.showError(error)
            return nil
        }
    }

    /// Marks a chat channel read up to its latest message (server) and clears
    /// its unread locally so the chat badge drops immediately.
    func markChatChannelRead(channelID: Int, messageID: Int) async {
        if let index = chats.firstIndex(where: { $0.id == channelID }) {
            chats[index].unread = false
            chats[index].threadUnreadCount = 0
        }
        unreadChat = chats.reduce(0) { $0 + $1.threadUnreadCount + ($1.unread ? 1 : 0) }
        try? await client.markChatChannelRead(channelID: channelID, messageID: messageID)
    }

    func load() async {
        guard DiscourseAuth.shared.isAuthenticated else {
            needsLogin = true
            notifications = []
            conversations = []
            chats = []
            threads = []
            unreadNotifications = 0
            unreadPrivateMessages = 0
            unreadChat = 0
            return
        }
        needsLogin = false
        guard !loaded else { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        // Unread notification count rides along on the current user, as does
        // the list of groups with a message inbox (for the PM filter). The PM
        // count is derived from the conversation list below so it matches the
        // rows' own unread dots.
        if let current = try? await client.currentUser().currentUser {
            unreadNotifications = current.unreadNotifications ?? 0
            messageGroups = (current.groups ?? [])
                .filter { $0.hasMessages == true }
                .map(\.name)
        }

        do {
            let response = try await client.notifications()
            notifications = response.notifications.map(NotificationFormatter.appNotification(from:))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        if let username = DiscourseAuth.shared.username {
            do {
                let response = try await client.privateMessages(username: username)
                conversations = Self.conversations(from: response, client: client)
                unreadPrivateMessages = conversations.filter(\.unread).count
            } catch {
                if errorText == nil {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }

        do {
            let response = try await client.chatChannels()
            chats = ChatListMapper.chats(from: response)
            unreadChat = chats.reduce(0) { $0 + $1.threadUnreadCount + ($1.unread ? 1 : 0) }
            watchChannels()
        } catch {
            if errorText == nil {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        do {
            let response = try await client.currentUserChatThreads()
            threads = ChatThreadMapper.threads(from: response)
        } catch {
            if errorText == nil {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        loaded = true
    }

    /// Maps a PM list into conversation rows: the counterpart is whoever on the
    /// thread isn't the current user, its avatar resolved from the top-level
    /// `users`, and unread is last-read trailing the highest post.
    private static func conversations(
        from response: PrivateMessagesResponse,
        client: DiscourseClient
    ) -> [PMConversation] {
        let usersByID = Dictionary(
            (response.users ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let me = DiscourseAuth.shared.username

        return response.topicList.topics.map { topic in
            // Prefer a participant who isn't me; fall back to the first.
            let participantIDs = (topic.participants ?? []).compactMap(\.userId)
            let counterpartID = participantIDs.first { usersByID[$0]?.username != me }
                ?? participantIDs.first
            let counterpart = counterpartID.flatMap { usersByID[$0] }

            let name = counterpart?.name?.isEmpty == false
                ? (counterpart?.name ?? "")
                : (counterpart?.username ?? AppString("私信"))
            let avatarURL = counterpart?.avatarTemplate.flatMap {
                client.avatarURL(template: $0, size: 120)
            }

            let highest = topic.highestPostNumber ?? 0
            let lastRead = topic.lastReadPostNumber ?? 0
            let unread = lastRead < highest

            return PMConversation(
                id: topic.id,
                title: topic.fancyTitle ?? topic.title ?? name,
                counterpart: name,
                avatarURL: avatarURL,
                letter: String(name.prefix(1)).uppercased(),
                variant: topic.id % 5,
                time: DiscourseFormat.relative(topic.lastPostedAt ?? topic.bumpedAt),
                unread: unread
            )
        }
    }

    func searchChatMessages(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearChatSearch()
            return
        }

        let requestID = UUID()
        chatSearchRequestID = requestID
        isSearchingChat = true
        chatSearchErrorText = nil

        do {
            let response = try await client.chatSearch(query: trimmed, sort: "latest")
            guard chatSearchRequestID == requestID else { return }
            chatSearchResults = ChatSearchResultMapper.results(from: response)
        } catch {
            guard chatSearchRequestID == requestID else { return }
            chatSearchResults = []
            chatSearchErrorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        if chatSearchRequestID == requestID {
            isSearchingChat = false
        }
    }

    func clearChatSearch() {
        chatSearchRequestID = nil
        chatSearchResults = []
        chatSearchErrorText = nil
        isSearchingChat = false
    }

}

// MARK: - Notifications

@MainActor
@Observable
final class NotificationsStore {
    private let client = DiscourseClient()

    var items: [AppNotification] = []
    var isLoading = false
    private var loaded = false

    func load() async {
        guard DiscourseAuth.shared.isAuthenticated else {
            items = []
            return
        }
        guard !loaded else { return }
        isLoading = true
        do {
            let response = try await client.notifications()
            items = response.notifications.map(NotificationFormatter.appNotification(from:))
            loaded = true
        } catch {
            // Keep whatever is shown; the overlay's empty state covers a
            // first load that produced nothing.
        }
        isLoading = false
    }

}

// MARK: - Public profile

@MainActor
@Observable
final class PublicProfileStore {
    private let client = DiscourseClient()

    var username = ""
    var displayName = ""
    var initial = "?"
    var avatarURL: URL?
    var backgroundURL: URL?
    var title: String?
    var bio = ""
    var joined = ""
    var lastSeen = ""
    var location: String?
    var website: String?
    var websiteURL: URL?
    var roles: [ProfileRole] = []
    var badges: [String] = []
    var stats: [ProfileStat] = []
    /// 常去节点, resolved against `NodeCatalog` so they carry the node's real
    /// logo and colour. The summary endpoint alone can't: `top_categories` is
    /// only id/name/color/slug/counts, with no `uploaded_logo`.
    var topCategories: [SidebarNodeSummary] = []
    var isLoading = false
    var errorText: String?

    /// Group flair (资质) and discourse-follow state.
    var flair: UserFlair?
    var followerCount: Int?
    var canFollow = false
    var isFollowing = false
    var isTogglingFollow = false

    /// The viewer's 通知方式 for this person, and whether a change is in flight.
    var notificationLevel: UserNotificationLevel = .normal
    var isUpdatingNotificationLevel = false

    /// Admin-designed 头衔 style from discourse-custom-badge.
    var titleStyle: TitleStyle?
    /// Badges with descriptions for the bottom sheet.
    var badgeDetails: [ProfileBadge] = []
    /// Account age like "1 年", shown in the stat row.
    var accountAge = ""
    /// 能量 total from discourse-points-service.
    var pointsTotal: Int?
    var pointsHistory: [PointsHistoryEntry] = []
    private var pointsLoaded = false

    /// Cached activity items per tab, mirroring ProfileStore.
    var actionItems: [ProfileStore.ProfileTab: [UserActionItem]] = [:]
    var loadingTab: ProfileStore.ProfileTab?
    /// Tabs with another page behind them, so the list knows to keep a sentinel.
    var tabsWithMore: Set<ProfileStore.ProfileTab> = []
    /// Tabs whose request failed, so the list can offer a retry rather than
    /// claiming the tab is empty.
    var failedTabs: Set<ProfileStore.ProfileTab> = []
    private var loadingMoreTabs: Set<ProfileStore.ProfileTab> = []

    /// Loads the activity stream (or 能量 history) for a tab on demand.
    func loadTab(_ tab: ProfileStore.ProfileTab) async {
        guard !username.isEmpty else { return }

        guard let filter = tab.filter else {
            guard !pointsLoaded else { return }
            loadingTab = .energy
            defer { if loadingTab == .energy { loadingTab = nil } }
            pointsHistory = (try? await client.pointsHistory(username: username))?.pointsHistory ?? []
            pointsLoaded = true
            return
        }

        guard actionItems[tab] == nil else { return }
        loadingTab = tab
        failedTabs.remove(tab)
        defer { if loadingTab == tab { loadingTab = nil } }

        do {
            let response = try await client.userActions(username: username, filter: filter)
            actionItems[tab] = response.userActions
            setHasMore(response.userActions.count, for: tab)
        } catch {
            // Deliberately *not* `actionItems[tab] = []`. That poisoned the
            // cache: the guard above then short-circuited forever, so a tab
            // that lost its request to a 429 stayed permanently "empty" — even
            // switching away and back wouldn't retry it. And an empty array is
            // indistinguishable from a genuinely empty tab, so the screen said
            // "还没有主题" about a request that had failed.
            failedTabs.insert(tab)
        }
    }

    /// Appends the next page of a tab. No-op while one is in flight or when the
    /// last page came back short.
    func loadMore(_ tab: ProfileStore.ProfileTab) async {
        guard let filter = tab.filter,
              tabsWithMore.contains(tab),
              !loadingMoreTabs.contains(tab),
              let existing = actionItems[tab]
        else { return }

        loadingMoreTabs.insert(tab)
        defer { loadingMoreTabs.remove(tab) }

        guard let response = try? await client.userActions(
            username: username,
            filter: filter,
            offset: existing.count
        ) else { return }

        // The stream can repeat an action across pages when something is bumped
        // mid-scroll; dedupe so `ForEach` doesn't get two rows with one id.
        let seen = Set(existing.map(\.id))
        let fresh = response.userActions.filter { !seen.contains($0.id) }
        actionItems[tab] = existing + fresh
        setHasMore(response.userActions.count, for: tab, appended: fresh.count)
    }

    private func setHasMore(_ received: Int, for tab: ProfileStore.ProfileTab, appended: Int? = nil) {
        // A short page is the end. A full page that added nothing new also is —
        // otherwise a duplicate-only page would spin the sentinel forever.
        if received < DiscourseClient.userActionsPageSize || appended == 0 {
            tabsWithMore.remove(tab)
        } else {
            tabsWithMore.insert(tab)
        }
    }

    /// Follows / unfollows, updating the button and follower count optimistically.
    func toggleFollow() async {
        guard canFollow, !isTogglingFollow, !username.isEmpty else { return }
        isTogglingFollow = true
        defer { isTogglingFollow = false }

        let wasFollowing = isFollowing
        isFollowing = !wasFollowing
        followerCount = (followerCount ?? 0) + (wasFollowing ? -1 : 1)

        do {
            if wasFollowing {
                try await client.unfollow(username: username)
            } else {
                try await client.follow(username: username)
            }
        } catch {
            // Roll back when the request fails.
            isFollowing = wasFollowing
            followerCount = (followerCount ?? 0) + (wasFollowing ? 1 : -1)
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Sets 通知方式 for this person. Applied locally first so the menu's
    /// checkmark answers immediately, rolled back if the write fails.
    func setNotificationLevel(_ level: UserNotificationLevel) async {
        guard !isUpdatingNotificationLevel, !username.isEmpty, level != notificationLevel else { return }
        isUpdatingNotificationLevel = true
        defer { isUpdatingNotificationLevel = false }

        let previous = notificationLevel
        notificationLevel = level

        do {
            try await client.setUserNotificationLevel(
                username: username,
                level: level.rawValue,
                expiringAt: level.expiry
            )
            // The cached payload still carries the old flags, so a re-open
            // would show the previous level.
            Self.cache.removeValue(forKey: username)
        } catch {
            notificationLevel = previous
            ToastCenter.shared.showError(error)
        }
    }

    /// Sends a 私信. Returns whether it went through, so the sheet can stay
    /// open with the draft intact on failure.
    func sendPrivateMessage(title: String, body: String) async -> Bool {
        guard !username.isEmpty else { return false }
        do {
            try await client.createPrivateMessage(recipient: username, title: title, raw: body)
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// Decoded profile payloads, shared across every screen that opens a
    /// profile. Without this, each open refetched four endpoints (~2s) even
    /// when returning to the profile you just closed.
    struct CachedProfile {
        let user: UserResponse
        let summary: UserSummaryResponse?
        let pointsTotal: Int?
    }

    static let cache = ResponseCache<CachedProfile>(ttl: 300, limit: 40)

    /// `force` is what pull-to-refresh passes: without it a profile viewed
    /// moments ago returns straight from cache and the gesture does nothing.
    func load(target: UserProfileTarget, force: Bool = false) async {
        // The 用户组 chips are named from the site's translations, so the bundle
        // has to be in hand before `apply(response:)` builds them.
        await DiscourseLocale.shared.preload()
        username = target.username
        displayName = target.displayName ?? target.username
        initial = target.initial
        avatarURL = target.avatarURL
        topCategories = []
        actionItems = [:]
        tabsWithMore = []
        failedTabs = []
        pointsHistory = []
        pointsLoaded = false

        // Paint from cache first, even if stale: a profile you just viewed
        // should appear instantly rather than behind a spinner.
        let cached = Self.cache.staleValue(forKey: target.username)
        if let cached {
            applyCached(cached.value)
            if !cached.isStale, !force { return }
        }

        // Only show the spinner when there is nothing to show.
        isLoading = cached == nil
        errorText = nil
        defer { isLoading = false }

        // One batch, not a chain: these three only need the username, so the
        // profile costs one round-trip's latency instead of three.
        async let profileCall = client.user(target.username)
        async let summaryCall: UserSummaryResponse? = try? await client.userSummary(target.username)
        async let pointsCall: PointsScoresResponse? = try? await client.pointsTotal(username: target.username)

        var loadedUser: UserResponse?
        do {
            let response = try await profileCall
            loadedUser = response
            apply(response: response)
        } catch {
            // A refresh failing behind cached content shouldn't replace it
            // with an error.
            if cached == nil {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if stats.isEmpty {
                    stats = ProfileStat.placeholders
                }
            }
        }

        // Summary enriches badges and top categories.
        let loadedSummary = await summaryCall
        if let summary = loadedSummary {
            let s = summary.userSummary
            if let badgeList = summary.badges {
                let details = badgeList
                    .filter { $0.name?.isEmpty == false }
                    .map { ProfileBadge($0) { resolvedURL($0) } }
                if !details.isEmpty {
                    badgeDetails = details
                    badges = details.map(\.name)
                }
            }
            if let categories = s.topCategories, !categories.isEmpty {
                topCategories = await resolveNodes(categories.prefix(6))
            }
        }

        // 能量 total leads the stat row.
        let loadedPoints = await pointsCall?.totalScores
        if let total = loadedPoints {
            pointsTotal = total
            rebuildStats()
        }

        if let title, !title.isEmpty {
            titleStyle = await TitleStyleCatalog.shared.style(forTitle: title)
        }

        if let loadedUser {
            Self.cache.insert(
                CachedProfile(user: loadedUser, summary: loadedSummary, pointsTotal: loadedPoints),
                forKey: target.username
            )
        }
    }

    /// Rebuilds state from a cached payload — the same steps `load` performs,
    /// minus the network.
    private func applyCached(_ cached: CachedProfile) {
        apply(response: cached.user)
        if let summary = cached.summary {
            let s = summary.userSummary
            if let badgeList = summary.badges {
                let details = badgeList
                    .filter { $0.name?.isEmpty == false }
                    .map { ProfileBadge($0) { resolvedURL($0) } }
                if !details.isEmpty {
                    badgeDetails = details
                    badges = details.map(\.name)
                }
            }
            if let categories = s.topCategories, !categories.isEmpty {
                // Painted from the summary alone so the cached path stays
                // synchronous, then upgraded once the catalog answers.
                let summaries = Array(categories.prefix(6))
                topCategories = summaries.map(fallbackNode)
                Task { topCategories = await resolveNodes(summaries) }
            }
        }
        if let total = cached.pointsTotal {
            pointsTotal = total
        }
        rebuildStats()
        if let title, !title.isEmpty {
            Task { titleStyle = await TitleStyleCatalog.shared.style(forTitle: title) }
        }
    }

    /// Fills in each node from the catalog the rest of the app draws nodes
    /// from — that is where the uploaded logo, the description and the real
    /// colour live.
    private func resolveNodes(_ categories: some Sequence<SummaryCategory>) async -> [SidebarNodeSummary] {
        var nodes: [SidebarNodeSummary] = []
        for category in categories {
            if let node = await NodeCatalog.shared.node(id: category.id) {
                nodes.append(node)
            } else {
                // A node the catalog doesn't list (restricted, or fetched
                // before the categories arrived): show what the summary gave.
                nodes.append(fallbackNode(category))
            }
        }
        return nodes
    }

    private func fallbackNode(_ category: SummaryCategory) -> SidebarNodeSummary {
        let slug = category.slug ?? "\(category.id)"
        return SidebarNodeSummary(
            id: category.id,
            name: category.name ?? AppString("节点"),
            slug: slug,
            description: "n/\(slug)",
            memberCount: compactCount(category.topicCount ?? 0),
            colorHex: category.color ?? "009966",
            logoURL: nil,
            isCreator: false,
            isJoined: false,
            url: "/n/\(slug)",
            iconName: category.styleType == "icon" ? category.icon : nil,
            emoji: category.styleType == "emoji" ? category.emoji : nil
        )
    }

    /// Stat row with 能量 first, matching the 我的 page.
    private func rebuildStats() {
        let core = coreStats ?? ("--", "--", "--")
        stats = ProfileStat.row(
            points: pointsTotal == nil ? "--" : compactCount(pointsTotal),
            likes: core.likes,
            topics: core.topics,
            posts: core.posts,
            accountAge: accountAge.isEmpty ? "--" : accountAge
        )
    }

    private var coreStats: (likes: String, topics: String, posts: String)?

    private func apply(response: UserResponse) {
        let user = response.user
        username = user.username
        displayName = user.name?.isEmpty == false ? user.name! : user.username
        initial = String(displayName.prefix(1)).uppercased()
        avatarURL = user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 240) } ?? avatarURL
        backgroundURL = resolvedURL(user.profileBackgroundUploadUrl ?? user.cardBackgroundUploadUrl)
        title = user.title
        bio = DiscourseFormat.plainText(user.bioRaw ?? user.bioExcerpt)
        joined = formattedJoined(user.createdAt)
        lastSeen = formattedLastSeen(user.lastSeenAt)
        location = user.location
        website = user.websiteName
        // `website_name` is only the host to show; opening it needs the real
        // URL, which Discourse serves separately.
        websiteURL = user.website.flatMap { URL(string: $0) }
        roles = roleLabels(for: user)
        badges = Array((response.badges ?? []).map(\.name).prefix(6))
        flair = UserFlair(
            flairURL: user.flairUrl,
            name: user.flairName,
            bgColor: user.flairBgColor,
            color: user.flairColor,
            resolveImage: { resolvedURL($0) }
        )
        followerCount = user.totalFollowers
        canFollow = user.canFollow ?? false
        isFollowing = user.isFollowed ?? false
        // Absent flags mean 常规: the serializer only includes them for a
        // signed-in viewer looking at somebody else.
        notificationLevel = UserNotificationLevel(ignored: user.ignored, muted: user.muted)
        accountAge = formattedAge(user.createdAt)
        coreStats = (
            compactCount(user.likesReceived),
            compactCount(user.topicCount),
            compactCount(user.postCount)
        )
        rebuildStats()
    }

    private func formattedAge(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "" }
        let components = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
        if let years = components.year, years >= 1 { return AppString("\(years) 年") }
        if let months = components.month, months >= 1 { return AppString("\(months) 个月") }
        return AppString("新用户")
    }

    /// Named from the site's own translations, not from constants in here: the
    /// API gives a trust *number* and two booleans, so the words are ours to
    /// look up — and they were stuck in English. See `DiscourseRoleNames`.
    private func roleLabels(for user: UserProfile) -> [ProfileRole] {
        var roles: [ProfileRole] = []
        if user.admin == true {
            roles.append(ProfileRole(kind: .admin, label: DiscourseRoleNames.admin))
        }
        if user.moderator == true {
            roles.append(ProfileRole(kind: .moderator, label: DiscourseRoleNames.moderator))
        }
        if let trustLevel = user.trustLevel {
            roles.append(ProfileRole(
                kind: .trustLevel(trustLevel),
                label: DiscourseRoleNames.trustLevel(trustLevel)
            ))
        }
        return roles.isEmpty
            ? [ProfileRole(kind: .trustLevel(2), label: DiscourseRoleNames.member)]
            : roles
    }

    private func formattedJoined(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "Joined recently" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return "Joined \(formatter.string(from: date))"
    }

    private func formattedLastSeen(_ value: String?) -> String {
        let relative = DiscourseFormat.relative(value)
        return relative.isEmpty ? "Public profile" : "Active \(relative) ago"
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "--" }
        if value >= 1_000_000 { return String(format: "%.1fm", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    private func resolvedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: raw)
    }
}

@MainActor
@Observable
final class ChatConversationStore {
    private let client = DiscourseClient()
    /// Live updates for the open channel, MessageBus long-poll.
    private let bus = MessageBusClient()
    private var liveChannelID: Int?

    var messages: [ChatConversationMessage] = []
    var channelThreads: [ChatThreadListItem] = []
    var selectedThread: ChatThreadListItem?
    var threadMessages: [ChatConversationMessage] = []
    var channelInitialScrollMessageID: Int?
    var channelInitialScrollIsUnread = false
    var threadInitialScrollMessageID: Int?
    var threadInitialScrollIsUnread = false
    var isLoading = false
    var isLoadingThread = false
    var isSending = false
    var errorText: String?
    /// Channel-level settings for the header's controls: muted, notification
    /// level, and who the other person is in a direct message.
    var isMuted = false
    var notificationLevel: ChatNotificationLevel = .always
    var counterpart: UserProfileTarget?
    var isDirectMessage = false
    /// Which of the three kinds this is. A group DM and a one-to-one DM are both
    /// `DirectMessage` channels server-side; `chatable.group` is what separates
    /// them, and it decides whether 查看资料 means one person or a member list.
    var channelKind: ChatChannelKind = .direct
    /// The channel's pinned messages, and whether the site allows pinning.
    var pins: [ChatPinnedMessage] = []
    var isPinningAvailable = false
    /// Everyone in the channel, for the member list. Loaded on demand.
    var members: [UserProfileTarget] = []
    var memberTotal = 0
    var isLoadingMembers = false
    private var loadedChannelID: Int?
    private var loadedChannelTargetMessageID: Int?
    private var loadedThreadID: Int?
    private var loadedThreadTargetMessageID: Int?

    func load(
        chat: Chat,
        initialThread: ChatThreadListItem? = nil,
        targetMessageID: Int? = nil
    ) async {
        guard DiscourseAuth.shared.isAuthenticated else {
            errorText = AppString("登录后查看聊天")
            return
        }

        let channelTargetMessageID = initialThread == nil ? targetMessageID : nil

        if loadedChannelID == chat.id && loadedChannelTargetMessageID == channelTargetMessageID {
            startLiveUpdates(chat)
            if let initialThread, selectedThread?.id != initialThread.id {
                await openThread(initialThread, targetMessageID: targetMessageID)
            }
            return
        }

        loadedChannelID = chat.id
        loadedChannelTargetMessageID = channelTargetMessageID
        errorText = nil

        // Cache first, messenger-style: the stored snapshot renders instantly
        // and the network fetch below only reconciles. Skipped when jumping to
        // a specific message, which the snapshot may not contain.
        var showedCache = false
        if channelTargetMessageID == nil,
           let cached = await ChatDiskCache.shared.load(channelID: chat.id),
           let response = Self.decodeSnapshot(cached) {
            messages = ChatMessageMapper.messages(from: response)
            channelInitialScrollMessageID = messages.last?.id
            channelInitialScrollIsUnread = false
            showedCache = !messages.isEmpty
        }

        isLoading = !showedCache
        defer { isLoading = false }

        do {
            let (response, raw) = try await client.chatMessagesWithRaw(
                channelID: chat.id,
                targetMessageID: channelTargetMessageID
            )
            guard loadedChannelID == chat.id else { return }
            messages = ChatMessageMapper.messages(from: response)
            if channelTargetMessageID == nil {
                await ChatDiskCache.shared.store(raw, channelID: chat.id)
            }
            let target = initialScrollTarget(
                for: messages,
                targetMessageID: channelTargetMessageID ?? response.meta?.targetMessageId,
                isExplicitTarget: channelTargetMessageID != nil,
                hasUnread: chat.unread
            )
            channelInitialScrollMessageID = target.messageID
            channelInitialScrollIsUnread = target.isUnread
        } catch {
            // With a cached copy on screen, fail quietly — the live loop or
            // the next open reconciles.
            if !showedCache {
                loadedChannelID = nil
                loadedChannelTargetMessageID = nil
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }

        startLiveUpdates(chat)
        await loadChannelSettings(chat.id)

        do {
            let response = try await client.chatThreads(channelID: chat.id)
            channelThreads = ChatThreadMapper.threads(from: response)
        } catch DiscourseError.badResponse(let code, _) where code == 404 {
            channelThreads = []
        } catch {
            channelThreads = []
        }

        if let initialThread {
            await openThread(initialThread, targetMessageID: targetMessageID)
        }
    }

    func openThread(_ thread: ChatThreadListItem, targetMessageID: Int? = nil) async {
        selectedThread = thread
        guard loadedThreadID != thread.id || loadedThreadTargetMessageID != targetMessageID else { return }

        loadedThreadID = thread.id
        loadedThreadTargetMessageID = targetMessageID
        isLoadingThread = true
        errorText = nil
        defer { isLoadingThread = false }

        do {
            let response = try await client.chatThreadMessages(
                channelID: thread.channelID,
                threadID: thread.id,
                targetMessageID: targetMessageID
            )
            threadMessages = ChatMessageMapper.messages(from: response)
            let target = initialScrollTarget(
                for: threadMessages,
                targetMessageID: targetMessageID ?? response.meta?.targetMessageId,
                isExplicitTarget: targetMessageID != nil,
                hasUnread: thread.unread
            )
            threadInitialScrollMessageID = target.messageID
            threadInitialScrollIsUnread = target.isUnread
        } catch {
            loadedThreadID = nil
            loadedThreadTargetMessageID = nil
            threadMessages = []
            threadInitialScrollMessageID = nil
            threadInitialScrollIsUnread = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func closeThread() {
        selectedThread = nil
        threadMessages = []
        threadInitialScrollMessageID = nil
        threadInitialScrollIsUnread = false
        loadedThreadID = nil
        loadedThreadTargetMessageID = nil
    }

    func send(_ text: String, chat: Chat, inReplyToID: Int? = nil, uploadIDs: [Int] = []) async {
        await send(
            text,
            channelID: chat.id,
            threadID: nil,
            inReplyToID: inReplyToID,
            uploadIDs: uploadIDs
        )
        // A light reconcile, not the old full channel reload: the latest page
        // replaces the list in place, so the conversation doesn't blink.
        await refreshLatest(channelID: chat.id)
    }

    func sendToSelectedThread(_ text: String, inReplyToID: Int? = nil, uploadIDs: [Int] = []) async {
        guard let selectedThread else { return }
        await send(
            text,
            channelID: selectedThread.channelID,
            threadID: selectedThread.id,
            inReplyToID: inReplyToID,
            uploadIDs: uploadIDs
        )
        await refreshLatest(channelID: selectedThread.channelID)
    }

    /// Uploads one picked image or video into chat's own bucket and answers the
    /// id the send call needs. Nil means it failed and said so.
    func upload(data: Data, fileName: String, mimeType: String) async -> Int? {
        do {
            let upload = try await client.uploadChatMedia(
                data: data,
                fileName: fileName,
                mimeType: mimeType
            )
            return upload.id
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: Channel settings

    /// Reads the channel's own row: the mute flag, the notification level and,
    /// for a direct message, the other participant. The message list doesn't
    /// carry any of it.
    private func loadChannelSettings(_ channelID: Int) async {
        guard let channel = try? await client.chatChannel(id: channelID).channel else { return }
        isDirectMessage = channel.isDirectMessage
        channelKind = ChatChannelKind(channel)
        members = []
        memberTotal = 0
        pins = []
        apply(channel.currentUserMembership)

        let me = DiscourseAuth.shared.username?.lowercased()
        counterpart = (channel.chatable?.users ?? [])
            .first { $0.username.lowercased() != me }
            .map {
                UserProfileTarget(
                    username: $0.username,
                    displayName: $0.name,
                    avatarURL: $0.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 120) }
                )
            }
    }

    /// Pinned messages, and whether pinning is available at all.
    ///
    /// `chat_pinned_messages` can be off site-wide, in which case the endpoint
    /// 404s — that is a "feature disabled", not an error worth showing, so the
    /// pin actions simply stay hidden.
    func loadPins(channelID: Int) async {
        do {
            let response = try await client.chatChannelPins(channelID: channelID)
            pins = (response.pinnedMessages ?? []).compactMap { pin in
                guard let messageID = pin.chatMessageId else { return nil }
                let excerpt = DiscourseFormat.plainText(pin.excerpt ?? pin.message?.excerpt)
                return ChatPinnedMessage(
                    id: pin.id,
                    messageID: messageID,
                    authorName: pin.message?.user?.name ?? pin.message?.user?.username ?? "",
                    excerpt: excerpt.isEmpty ? AppString("消息") : excerpt,
                    pinnedBy: pin.pinnedBy?.username
                )
            }
            isPinningAvailable = true
        } catch {
            pins = []
            // 404 = the site setting is off. Anything else is transient; either
            // way there is nothing to show and nothing to say.
            isPinningAvailable = false
        }
    }

    func togglePin(messageID: Int, channelID: Int) async {
        let isPinned = pins.contains { $0.messageID == messageID }
        do {
            if isPinned {
                try await client.unpinChatMessage(channelID: channelID, messageID: messageID)
            } else {
                try await client.pinChatMessage(channelID: channelID, messageID: messageID)
            }
            await loadPins(channelID: channelID)
            ToastCenter.shared.show(isPinned ? AppString("已取消置顶") : AppString("已置顶"))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func markPinsRead(channelID: Int) async {
        try? await client.markChatPinsRead(channelID: channelID)
    }

    /// Adds people to this channel. Returns whether it worked, so the sheet can
    /// stay open on failure.
    func addMembers(_ usernames: [String], channelID: Int) async -> Bool {
        guard !usernames.isEmpty else { return false }
        do {
            try await client.addUsersToChatChannel(channelID: channelID, usernames: usernames)
            // The roster is cached for the member sheet; drop it so the next
            // open reflects the addition.
            members = []
            memberTotal = 0
            ToastCenter.shared.show(usernames.count == 1 ? AppString("已添加成员") : AppString("已添加 \(usernames.count) 位成员"))
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Saves the unsent draft server-side. Fire-and-forget: a failed draft save
    /// is not worth interrupting anyone over.
    func saveDraft(_ text: String, channelID: Int, threadID: Int?) async {
        try? await client.saveChatDraft(channelID: channelID, threadID: threadID, message: text)
    }

    /// Chat messages as forum markdown, for quoting them into a topic.
    func transcript(messageIDs: [Int], channelID: Int) async -> String? {
        guard !messageIDs.isEmpty else { return nil }
        do {
            return try await client.chatTranscript(channelID: channelID, messageIDs: messageIDs).markdown
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Toggles an emoji reaction, locally first so the tap answers at once.
    ///
    /// The channel is the addressing unit for reactions — the endpoint is
    /// `/chat/:channel_id/react/:message_id` — so a thread message reacts
    /// through its channel, not its thread.
    func toggleReaction(emoji: String, messageID: Int, channelID: Int) async {
        let bare = emoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let adding = !isReacted(emoji: bare, messageID: messageID)
        applyReaction(emoji: bare, messageID: messageID, adding: adding)

        do {
            try await client.reactToChatMessage(
                channelID: channelID,
                messageID: messageID,
                emoji: bare,
                add: adding
            )
        } catch {
            applyReaction(emoji: bare, messageID: messageID, adding: !adding)
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func isReacted(emoji: String, messageID: Int) -> Bool {
        message(id: messageID)?.reactions.first { $0.emoji == emoji }?.reacted ?? false
    }

    private func message(id: Int) -> ChatConversationMessage? {
        messages.first { $0.id == id } ?? threadMessages.first { $0.id == id }
    }

    /// Applies the optimistic change in both lists — a message can be showing in
    /// the channel and in an open thread at the same time.
    private func applyReaction(emoji: String, messageID: Int, adding: Bool) {
        func update(_ list: inout [ChatConversationMessage]) {
            guard let index = list.firstIndex(where: { $0.id == messageID }) else { return }
            var reactions = list[index].reactions
            if let existing = reactions.firstIndex(where: { $0.emoji == emoji }) {
                let count = max(0, reactions[existing].count + (adding ? 1 : -1))
                if count == 0 {
                    reactions.remove(at: existing)
                } else {
                    reactions[existing] = ChatReaction(emoji: emoji, count: count, reacted: adding)
                }
            } else if adding {
                reactions.append(ChatReaction(emoji: emoji, count: 1, reacted: true))
            }
            list[index].reactions = reactions
        }
        update(&messages)
        update(&threadMessages)
    }

    /// Edits a message's text. The server re-cooks it; the local copy is
    /// replaced from the refresh that follows.
    func editMessage(_ text: String, messageID: Int, channelID: Int) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await client.updateChatMessage(
                channelID: channelID,
                messageID: messageID,
                message: trimmed
            )
            await refreshLatest(channelID: channelID)
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Trashes a message. Dropped locally rather than refetched, the same as the
    /// post reader does — the row is gone either way.
    func deleteMessage(messageID: Int, channelID: Int) async {
        do {
            try await client.deleteChatMessage(channelID: channelID, messageID: messageID)
            messages.removeAll { $0.id == messageID }
            threadMessages.removeAll { $0.id == messageID }
            ToastCenter.shared.show(AppString("已删除"))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Flags a message for review. `flagTypeID` comes from the site's own flag
    /// list, filtered by the message's `available_flags`.
    func flagMessage(
        messageID: Int,
        channelID: Int,
        flagTypeID: Int,
        message text: String?
    ) async throws {
        try await client.flagChatMessage(
            channelID: channelID,
            messageID: messageID,
            flagTypeID: flagTypeID,
            message: text
        )
    }

    /// Loads the member list, paging until the server says there are no more.
    ///
    /// Capped: a busy category channel can have thousands of members, and a
    /// sheet that fetches them all to show the first screenful is worse than one
    /// that says "and N others".
    func loadMembers(channelID: Int) async {
        guard members.isEmpty, !isLoadingMembers else { return }
        isLoadingMembers = true
        defer { isLoadingMembers = false }

        var collected: [UserProfileTarget] = []
        var seen = Set<String>()
        var offset = 0
        let pageSize = 50

        while collected.count < Self.memberCap {
            guard let response = try? await client.chatChannelMemberships(
                channelID: channelID,
                offset: offset,
                limit: pageSize
            ) else { break }

            if let total = response.meta?.totalRows { memberTotal = total }
            let page = response.memberships ?? []
            for user in page.compactMap(\.user) where !seen.contains(user.username.lowercased()) {
                seen.insert(user.username.lowercased())
                collected.append(
                    UserProfileTarget(
                        username: user.username,
                        displayName: user.name,
                        avatarURL: user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 120) }
                    )
                )
            }
            if page.count < pageSize { break }
            offset += pageSize
        }

        members = collected
        if memberTotal == 0 { memberTotal = collected.count }
    }

    /// Members fetched before the sheet stops asking for more.
    private static let memberCap = 200

    private func apply(_ membership: ChatChannel.ChatMembership?) {
        isMuted = membership?.muted ?? false
        if let level = membership?.notificationLevel.flatMap(ChatNotificationLevel.init(rawValue:)) {
            notificationLevel = level
        }
    }

    /// Applied locally first, rolled back if the server refuses — the bell has
    /// to answer the tap.
    func toggleMute(channelID: Int) async {
        let previous = isMuted
        isMuted = !previous
        do {
            let response = try await client.updateChatChannelNotifications(id: channelID, muted: !previous)
            apply(response.membership)
            ToastCenter.shared.show(isMuted ? AppString("已设为免打扰") : AppString("已恢复通知"))
        } catch {
            isMuted = previous
            ToastCenter.shared.showError(error)
        }
    }

    func setNotificationLevel(_ level: ChatNotificationLevel, channelID: Int) async {
        guard level != notificationLevel else { return }
        let previous = notificationLevel
        notificationLevel = level
        do {
            let response = try await client.updateChatChannelNotifications(
                id: channelID,
                notificationLevel: level.rawValue
            )
            apply(response.membership)
        } catch {
            notificationLevel = previous
            ToastCenter.shared.showError(error)
        }
    }

    /// Leaves the conversation. Returns whether it worked, so the screen only
    /// dismisses on success.
    func leaveChannel(_ channelID: Int) async -> Bool {
        do {
            try await client.unfollowChatChannel(id: channelID)
            await MessageCenterStore.shared.reload()
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    // MARK: Live updates

    /// Long-polls MessageBus for the open channel; any event (sent / edited /
    /// deleted) triggers a quiet refetch through the existing mappers.
    private func startLiveUpdates(_ chat: Chat) {
        guard liveChannelID != chat.id else { return }
        liveChannelID = chat.id
        bus.subscribe(channels: ["/chat/\(chat.id)"]) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshLatest(channelID: chat.id) }
        }
    }

    func stopLiveUpdates() {
        bus.stop()
        liveChannelID = nil
    }

    /// Refetches the newest page without spinners or scroll resets, updates
    /// the snapshot cache, and lands on the newest message when one arrived.
    private func refreshLatest(channelID: Int) async {
        do {
            let (response, raw) = try await client.chatMessagesWithRaw(channelID: channelID)
            // The user may have switched channels while this was in flight.
            guard loadedChannelID == channelID else { return }
            let previousLast = messages.last?.id
            messages = ChatMessageMapper.messages(from: response)
            await ChatDiskCache.shared.store(raw, channelID: channelID)
            if let last = messages.last?.id, last != previousLast {
                channelInitialScrollMessageID = last
                channelInitialScrollIsUnread = false
            }

            if let selectedThread {
                let threadResponse = try await client.chatThreadMessages(
                    channelID: selectedThread.channelID,
                    threadID: selectedThread.id
                )
                let previousThreadLast = threadMessages.last?.id
                threadMessages = ChatMessageMapper.messages(from: threadResponse)
                if let last = threadMessages.last?.id, last != previousThreadLast {
                    threadInitialScrollMessageID = last
                    threadInitialScrollIsUnread = false
                }
            }
        } catch {
            // The next bus event or open retries; nothing on screen is lost.
        }
    }

    /// Decodes a cached snapshot with the same strategy as the live client.
    private static func decodeSnapshot(_ data: Data) -> ChatMessagesResponse? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ChatMessagesResponse.self, from: data)
    }

    private func send(
        _ text: String,
        channelID: Int,
        threadID: Int?,
        inReplyToID: Int?,
        uploadIDs: [Int]
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Uploads alone are a message; only both being empty is nothing to send.
        guard !trimmed.isEmpty || !uploadIDs.isEmpty else { return }

        isSending = true
        errorText = nil
        defer { isSending = false }

        do {
            _ = try await client.createChatMessage(
                channelID: channelID,
                message: trimmed,
                threadID: threadID,
                inReplyToID: inReplyToID,
                uploadIDs: uploadIDs
            )
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func initialScrollTarget(
        for messages: [ChatConversationMessage],
        targetMessageID: Int?,
        isExplicitTarget: Bool,
        hasUnread: Bool
    ) -> (messageID: Int?, isUnread: Bool) {
        guard !messages.isEmpty else {
            return (nil, false)
        }

        if isExplicitTarget, let targetMessageID {
            let messageID = messages.first(where: { $0.id == targetMessageID })?.id
                ?? messages.first(where: { $0.id >= targetMessageID })?.id
                ?? messages.last?.id
            return (messageID, true)
        }

        if let targetMessageID {
            if let firstUnread = messages.first(where: { $0.id > targetMessageID }) {
                return (firstUnread.id, true)
            }
            return (messages.last?.id, false)
        }

        if hasUnread {
            return (messages.first?.id, true)
        }

        return (messages.last?.id, false)
    }
}

// MARK: - Profile

@MainActor
@Observable
final class ProfileStore {
    /// Shared, not per-view. `ProfileView` is a tab, so SwiftUI tears its
    /// `@State` down when you switch tabs — a per-view store meant the signed-in
    /// user's avatar, badges and stats reverted to placeholders and refetched
    /// every time you came back. There is only ever one signed-in user, so
    /// there only needs to be one store.
    static let shared = ProfileStore()

    private let client = DiscourseClient()

    // Neutral placeholders until the real profile loads — never demo values.
    var username = ""
    var displayName = ""
    var initial = "?"
    var avatarURL: URL?
    var backgroundURL: URL?
    var title: String?
    var bio = ""
    var joined = ""
    var lastSeen = ""
    var location: String?
    var website: String?
    var websiteURL: URL?
    var roles: [ProfileRole] = []
    var badges: [String] = []
    var stats: [ProfileStat] = ProfileStat.placeholders
    /// Recently visited nodes, sourced the same way as the sidebar.
    var recentNodes: [SidebarNodeSummary] = []
    /// Account age like "1 年" / "11 个月", shown in the primary stat row.
    var accountAge = ""
    /// Detailed summary metrics (icon, value, label) shown flat below the header.
    var summaryStats: [(icon: String, value: String, label: String)] = []
    /// Badges with descriptions for the bottom sheet.
    var badgeDetails: [ProfileBadge] = []

    /// Reddit-style activity tabs shown below the header.
    enum ProfileTab: String, CaseIterable, Identifiable {
        case topics = "主题"
        case posts = "帖子"
        case likes = "赞"
        case bookmarks = "书签"
        case energy = "能量"

        var id: String { rawValue }

        /// The raw values are identifiers (they key the tab-loading task), and
        /// a raw value must be a compile-time constant — so the displayed word
        /// comes from here.
        var label: String {
            switch self {
            case .topics: return AppString("主题")
            case .posts: return AppString("帖子")
            case .likes: return AppString("赞")
            case .bookmarks: return AppString("书签")
            case .energy: return AppString("能量")
            }
        }

        /// Discourse UserAction filter code; `nil` tabs render summary data instead.
        var filter: Int? {
            switch self {
            case .topics: return 4
            case .posts: return 5
            case .likes: return 1
            case .bookmarks: return 3
            case .energy: return nil
            }
        }
    }

    /// Cached activity items per tab.
    var actionItems: [ProfileTab: [UserActionItem]] = [:]
    var loadingTab: ProfileTab?
    /// Tabs with another page behind them, so the list knows to keep a sentinel.
    var tabsWithMore: Set<ProfileTab> = []
    /// Tabs whose request failed, so the list can offer a retry rather than
    /// claiming the tab is empty.
    var failedTabs: Set<ProfileTab> = []
    private var loadingMoreTabs: Set<ProfileTab> = []

    /// 能量 history from the discourse-points-service plugin.
    var pointsHistory: [PointsHistoryEntry] = []
    var pointsTotal: Int?
    var pointsLoaded = false

    /// Admin-configured style for the user's 头衔, from discourse-custom-badge.
    var titleStyle: TitleStyle?

    /// Group flair (资质) shown after @username.
    var flair: UserFlair?
    /// 升级进度 (discourse-upgrade-process), shown beside the flair.
    var upgradeProgress: UpgradeProgressReport?
    /// 签到 (discourse-checkin). The plugin keeps no status endpoint — its own
    /// button remembers the day in localStorage — so the app mirrors that with
    /// a per-user, per-day key.
    var hasCheckedInToday = false
    var isCheckingIn = false
    /// Follower count from discourse-follow.
    var followerCount: Int?

    /// Reputation / topics / replies, kept so `stats` can be rebuilt when the
    /// 能量 total arrives separately.
    private var coreStats: (likes: String, topics: String, posts: String)?

    /// 签到. Mirrors the site's own button: post, then remember the day so the
    /// control reads as done until tomorrow.
    func checkIn() async {
        guard !isCheckingIn, !hasCheckedInToday,
              let username = DiscourseAuth.shared.username else { return }
        isCheckingIn = true
        defer { isCheckingIn = false }
        do {
            let response = try await client.checkIn()
            if response.success == true {
                hasCheckedInToday = true
                Self.rememberCheckIn(username: username, day: response.userDate)
                if let points = response.points {
                    ToastCenter.shared.show(AppString("签到成功，获得 \(points) 能量"))
                } else {
                    ToastCenter.shared.show(AppString("签到成功"))
                }
                // The award lands on the points balance.
                if let total = try? await client.pointsTotal(username: username).totalScores {
                    pointsTotal = total
                    rebuildStats()
                }
            } else {
                // A refusal ("already signed in today") is normal, not an error.
                hasCheckedInToday = true
                Self.rememberCheckIn(username: username, day: nil)
                ToastCenter.shared.show(response.message ?? AppString("今天已签到"))
            }
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    private static func checkInKey(username: String) -> String {
        "nodeloc.checkin.\(username)"
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func checkedIn(username: String) -> Bool {
        UserDefaults.standard.string(forKey: checkInKey(username: username)) == today()
    }

    private static func rememberCheckIn(username: String, day: String?) {
        UserDefaults.standard.set(day ?? today(), forKey: checkInKey(username: username))
    }

    /// Rebuilds the header stat row with 能量 first, ahead of 声望.
    private func rebuildStats() {
        let core = coreStats ?? ("--", "--", "--")
        stats = ProfileStat.row(
            points: pointsTotal == nil ? "--" : compactCount(pointsTotal),
            likes: core.likes,
            topics: core.topics,
            posts: core.posts,
            accountAge: accountAge.isEmpty ? "--" : accountAge
        )
    }

    var isGuest = false
    var isLoading = false
    var errorText: String?
    private var loaded = false
    private var loadedUsername: String?
    /// Whether there is anything real on screen — from the network *or* from
    /// last launch's snapshot. Distinct from `loaded`, which means the network
    /// has answered: a snapshot gives content without being loaded.
    private(set) var hasContent = false

    /// First open of this account with nothing to draw yet, so the page should
    /// show its skeleton rather than a screenful of `--` placeholders.
    ///
    /// False as soon as a snapshot renders, which is the point of keeping one:
    /// a returning reader sees their profile, not a shimmer.
    var isShowingSkeleton: Bool { isLoading && !hasContent }

    /// `force` is for pull-to-refresh, which must ignore the loaded guard.
    func load(isAppAuthed: Bool = false, force: Bool = false) async {
        guard DiscourseAuth.shared.isAuthenticated || isAppAuthed else {
            applyGuest()
            return
        }

        // Before anything is known about who this is: the snapshot belongs to
        // whoever is signed in, so it can go up while the name is still being
        // worked out.
        let earlySnapshot = !force && !loaded && applyCachedSnapshot()

        // The name usually comes from the Keychain, but a credential can be
        // stored without one — see `resolveUsernameIfNeeded`. This used to
        // `seed("")` and return, which is why the page could sit on `?` and
        // `--` forever: nothing re-ran `load`, so there was no way back.
        var resolvedUsername = DiscourseAuth.shared.username
        if resolvedUsername?.isEmpty != false {
            if !earlySnapshot { isLoading = true }
            resolvedUsername = await DiscourseLogin.shared.resolveUsernameIfNeeded()
            isLoading = false
        }

        guard let username = resolvedUsername, !username.isEmpty else {
            // Genuinely unknown — the server couldn't be reached. Placeholders,
            // but `loaded` stays false so returning to the tab tries again.
            if !earlySnapshot { seed(username: "") }
            loaded = false
            loadedUsername = nil
            return
        }

        guard DiscourseAuth.shared.isAuthenticated else {
            applyGuest()
            return
        }

        // Order matters: `seed` resets avatar/badges/stats to placeholders, so
        // it must not run when the guard is about to short-circuit — that would
        // blank a profile that is already loaded and then return, which is
        // exactly what made the avatar vanish on returning to the tab.
        guard force || !loaded || loadedUsername != username else { return }

        // Names for the 用户组 chips; see `PublicProfileStore.load`.
        await DiscourseLocale.shared.preload()
        // Either the snapshot went up above, or there is still time to try —
        // the username guard can have returned early on a previous call.
        let renderedFromCache = earlySnapshot || (!force && !loaded && applyCachedSnapshot())

        // Only reseed when actually about to fetch, and never over a snapshot —
        // seeding is what puts placeholders up, which is the flash the cache
        // exists to remove.
        if !force, !renderedFromCache { seed(username: username) }

        // A cache hit means the screen is already complete, so the refresh
        // behind it shouldn't drive a spinner.
        isLoading = !renderedFromCache
        errorText = nil
        defer { isLoading = false }

        if FeatureFlags.shared.profileAggregateEnabled,
           await loadAggregated(username: username, force: force) {
            // One request served the whole page.
        } else {
            await loadFannedOut(username: username)
        }

        // A manual refresh should renew the tab lists too, not just the header.
        if force {
            actionItems = [:]
            // Or a tab that had been paged to its end would stay ended.
            tabsWithMore = []
            failedTabs = []
            pointsLoaded = false
        }

        // Admin-designed 头衔 styling from discourse-custom-badge.
        if let title, !title.isEmpty {
            titleStyle = await TitleStyleCatalog.shared.style(forTitle: title)
        }
    }

    /// One request for the whole page — `/mobile/profile.json`.
    ///
    /// Returns false when the endpoint isn't there or answered with nothing
    /// usable, so the caller can fall back to the five separate calls. That
    /// fallback is the point: the flag can be wrong, and a 404 must degrade to
    /// the old behaviour rather than to an empty profile.
    private func loadAggregated(username: String, force: Bool) async -> Bool {
        guard let result = try? await client.profileAggregate(
            username: nil,
            activityFilter: ProfileTab.topics.filter ?? 4
        ) else { return false }

        // `user` is the only part the page can't be drawn without.
        guard let user = result.response.user else { return false }

        apply(response: user)
        loaded = true
        loadedUsername = username

        applyAggregate(result.response, username: username, force: force)
        // Stored after applying, so a payload that can't be used is never the
        // thing the next launch starts from.
        ProfileSnapshot.save(result.data)
        return true
    }

    /// The original five parallel calls.
    ///
    /// Kept as the fallback rather than deleted: it is what runs until the
    /// server sets `profile_aggregate`, and what runs again if that endpoint is
    /// ever rolled back.
    private func loadFannedOut(username: String) async {
        // All of these only need the username, so they go out together and the
        // screen waits for the slowest rather than the sum. They're still
        // awaited in priority order, so the header paints as soon as the
        // profile itself lands and the rest fills in behind it.
        async let profileCall = client.user(username)
        async let summaryCall: UserSummaryResponse? = try? await client.userSummary(username)
        async let recentNodesCall: SidebarCommunitiesResponse? = try? await client.recentlyVisitedNodes()
        async let pointsCall: PointsScoresResponse? = try? await client.pointsTotal(username: username)
        async let upgradeCall: UpgradeProgressReport? = try? await client.upgradeProgress(username: username)

        do {
            let response = try await profileCall
            apply(response: response)
            loaded = true
            loadedUsername = username
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // Best-effort: enrich stats/badges/nodes from the summary endpoint.
        if let summary = await summaryCall {
            applySummary(summary)
        }

        // Recently visited nodes — same source as the sidebar.
        if let response = await recentNodesCall {
            applyRecentNodes(response)
        }

        // 能量 total leads the stat row, so fetch it up front rather than
        // waiting for the 能量 tab to be opened.
        if let total = await pointsCall?.totalScores {
            pointsTotal = total
            rebuildStats()
        }

        upgradeProgress = await upgradeCall
        hasCheckedInToday = Self.checkedIn(username: username)
    }

    /// Everything in an aggregate payload except `user`, which the callers
    /// apply first because the page depends on it.
    ///
    /// Each part is independently optional — the endpoint is specified to null
    /// out whatever its plugin couldn't produce rather than fail as a whole, so
    /// a missing key here means "no data", never "bad response".
    private func applyAggregate(
        _ payload: ProfileAggregateResponse,
        username: String,
        force: Bool
    ) {
        if let summary = payload.summary {
            applySummary(summary)
        }
        if let nodes = payload.nodes {
            applyRecentNodes(nodes)
        }
        if let total = payload.points?.totalScores {
            pointsTotal = total
            rebuildStats()
        }
        if let upgrade = payload.upgrade {
            upgradeProgress = upgrade
        }

        // The server's answer, with the device's memory as the fallback. This
        // is the way round it should always have been: a reinstall or a second
        // device used to show a live 签到 button that the server then refused.
        if let checkedIn = payload.checkin?.checkedInToday {
            hasCheckedInToday = checkedIn
            if checkedIn { Self.rememberCheckIn(username: username, day: nil) }
        } else {
            hasCheckedInToday = Self.checkedIn(username: username)
        }

        // The default tab's first page rides along, which is the sixth request
        // gone. Skipped on a manual refresh, because the caller clears the tab
        // caches straight after and this would refill one of them from a
        // payload fetched a moment before.
        if !force, let actions = payload.activity?.userActions {
            actionItems[.topics] = actions
            setHasMore(actions.count, for: .topics)
        }
    }

    /// Draws last launch's payload, if there is one. Returns whether it did.
    private func applyCachedSnapshot() -> Bool {
        guard let data = ProfileSnapshot.load(),
              let payload = DiscourseClient.decodeProfileAggregate(data),
              let user = payload.user
        else { return false }

        apply(response: user)
        // `user.username` rather than the caller's: the snapshot is the record
        // of who was signed in, and at this point that may be the only place
        // the name exists.
        applyAggregate(payload, username: user.user.username, force: false)
        // Deliberately *not* marking this `loaded`: the values on screen are
        // from disk and a refresh still has to run. `loaded` is what suppresses
        // that.
        return true
    }

    private func applyRecentNodes(_ response: SidebarCommunitiesResponse) {
        let communities = response.communities ?? response.recommended ?? []
        recentNodes = communities.prefix(8).map(NodeSummaryFactory.node)
    }

    /// Loads the activity stream for a tab on demand (cached after first fetch).
    func loadTab(_ tab: ProfileTab) async {
        // A guest has genuinely nothing here, so an empty list is the answer.
        guard !isGuest else {
            if tab == .energy { pointsLoaded = true } else { actionItems[tab] = [] }
            return
        }
        // No username yet is *not* an answer. Caching `[]` for it is what left
        // "还没有主题" on screen permanently: `loadTab` returns early while the
        // list is already marked loaded, so the real fetch never ran.
        guard !username.isEmpty else { return }

        guard let filter = tab.filter else {
            await loadPoints()
            return
        }

        guard actionItems[tab] == nil else { return }

        loadingTab = tab
        failedTabs.remove(tab)
        defer { if loadingTab == tab { loadingTab = nil } }

        do {
            let response = try await client.userActions(username: username, filter: filter)
            actionItems[tab] = response.userActions
            setHasMore(response.userActions.count, for: tab)
        } catch {
            // Leaves the tab unloaded rather than caching an empty array — see
            // `PublicProfileStore.loadTab` for why that mattered.
            failedTabs.insert(tab)
        }
    }

    /// Appends the next page of a tab. Mirrors `PublicProfileStore.loadMore`;
    /// the two stores keep separate copies because they load different headers
    /// around the same activity stream.
    func loadMore(_ tab: ProfileTab) async {
        guard let filter = tab.filter,
              tabsWithMore.contains(tab),
              !loadingMoreTabs.contains(tab),
              let existing = actionItems[tab]
        else { return }

        loadingMoreTabs.insert(tab)
        defer { loadingMoreTabs.remove(tab) }

        guard let response = try? await client.userActions(
            username: username,
            filter: filter,
            offset: existing.count
        ) else { return }

        let seen = Set(existing.map(\.id))
        let fresh = response.userActions.filter { !seen.contains($0.id) }
        actionItems[tab] = existing + fresh
        setHasMore(response.userActions.count, for: tab, appended: fresh.count)
    }

    private func setHasMore(_ received: Int, for tab: ProfileTab, appended: Int? = nil) {
        if received < DiscourseClient.userActionsPageSize || appended == 0 {
            tabsWithMore.remove(tab)
        } else {
            tabsWithMore.insert(tab)
        }
    }

    /// Loads 能量 history + total balance (cached after first fetch).
    private func loadPoints() async {
        guard !pointsLoaded else { return }

        loadingTab = .energy
        defer { if loadingTab == .energy { loadingTab = nil } }

        async let historyCall = try? client.pointsHistory(username: username)
        // The total is usually already loaded with the profile; only refetch if not.
        async let totalCall = pointsTotal == nil ? (try? client.pointsTotal(username: username))?.totalScores : nil

        pointsHistory = (await historyCall)?.pointsHistory ?? []
        if let total = await totalCall {
            pointsTotal = total
            rebuildStats()
        }
        pointsLoaded = true
    }

    private func applyGuest() {
        // The guest screen is a finished screen, not a loading one.
        hasContent = true
        username = "guest"
        displayName = AppString("访客")
        initial = AppString("访")
        avatarURL = nil
        backgroundURL = nil
        title = nil
        bio = AppString("登录后可以同步你的 NodeLoc 资料、徽章和发帖数据。")
        joined = AppString("未登录")
        lastSeen = AppString("访客模式")
        location = nil
        website = nil
        websiteURL = nil
        roles = [ProfileRole(kind: .guest, label: "GUEST")]
        badges = []
        stats = ProfileStat.placeholders
        coreStats = nil
        titleStyle = nil
        flair = nil
        followerCount = nil
        summaryStats = []
        badgeDetails = []
        accountAge = ""
        upgradeProgress = nil
        hasCheckedInToday = false
        actionItems = [:]
        loadingTab = nil
        pointsHistory = []
        pointsTotal = nil
        pointsLoaded = false
        recentNodes = []
        isGuest = true
        errorText = nil
        // The store is shared now, so it outlives a sign-out. Clearing these
        // means the next sign-in actually fetches instead of short-circuiting
        // on the previous user's data.
        loaded = false
        loadedUsername = nil
    }

    private func seed(username: String) {
        // Placeholders, not content — this is the state the skeleton covers.
        hasContent = false
        isGuest = false
        self.username = username
        displayName = username
        initial = username.isEmpty ? "?" : String(username.prefix(1)).uppercased()
        avatarURL = nil
        backgroundURL = nil
        title = nil
        bio = ""
        joined = ""
        lastSeen = ""
        location = nil
        website = nil
        websiteURL = nil
        roles = []
        badges = []
        stats = ProfileStat.placeholders
        coreStats = nil
        titleStyle = nil
        flair = nil
        followerCount = nil
        summaryStats = []
        badgeDetails = []
        accountAge = ""
        upgradeProgress = nil
        errorText = nil
    }

    private func apply(response: UserResponse) {
        // Real values from here on, so the skeleton gives way — whether these
        // came from the network or off disk.
        hasContent = true
        let user = response.user
        username = user.username
        displayName = user.name?.isEmpty == false ? user.name! : user.username
        initial = String(displayName.prefix(1)).uppercased()
        avatarURL = user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 240) }
        backgroundURL = resolvedURL(user.profileBackgroundUploadUrl ?? user.cardBackgroundUploadUrl)
        title = user.title
        bio = DiscourseFormat.plainText(user.bioRaw ?? user.bioExcerpt)
        joined = formattedJoined(user.createdAt)
        lastSeen = formattedLastSeen(user.lastSeenAt)
        location = user.location
        website = user.websiteName
        // `website_name` is only the host to show; opening it needs the real
        // URL, which Discourse serves separately.
        websiteURL = user.website.flatMap { URL(string: $0) }
        roles = roleLabels(for: user)
        badges = Array((response.badges ?? []).map(\.name).prefix(8))
        accountAge = formattedAge(user.createdAt)
        flair = UserFlair(
            flairURL: user.flairUrl,
            name: user.flairName,
            bgColor: user.flairBgColor,
            color: user.flairColor,
            resolveImage: { resolvedURL($0) }
        )
        followerCount = user.totalFollowers
        actionItems = [:]
        loadingTab = nil
        pointsHistory = []
        pointsTotal = nil
        pointsLoaded = false
        coreStats = (
            compactCount(user.likesReceived),
            compactCount(user.topicCount),
            compactCount(user.postCount)
        )
        rebuildStats()
    }

    private func applySummary(_ response: UserSummaryResponse) {
        let s = response.userSummary

        coreStats = (
            compactCount(s.likesReceived),
            compactCount(s.topicCount),
            compactCount(s.postCount)
        )
        rebuildStats()

        summaryStats = [
            ("hand.thumbsup.fill", compactCount(s.likesGiven), AppString("点赞")),
            ("book.fill", compactCount(s.postsReadCount), AppString("已读帖子")),
            ("calendar", compactCount(s.daysVisited), AppString("访问天数")),
            ("clock.fill", readTime(s.timeRead), AppString("阅读时长")),
            ("rectangle.stack.fill", compactCount(s.topicsEntered), AppString("浏览话题")),
            ("checkmark.seal.fill", compactCount(s.solvedCount), AppString("已解决"))
        ]

        if let summaryBadges = response.badges {
            let details = summaryBadges
                .filter { $0.name?.isEmpty == false }
                .map { ProfileBadge($0) { resolvedURL($0) } }
            if !details.isEmpty {
                badgeDetails = details
                badges = details.map(\.name)
            }
        }

    }

    private func formattedAge(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "" }
        let components = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
        if let years = components.year, years >= 1 { return AppString("\(years) 年") }
        if let months = components.month, months >= 1 { return AppString("\(months) 个月") }
        return AppString("新用户")
    }

    private func readTime(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "--" }
        let hours = seconds / 3600
        if hours >= 24 { return AppString("\(hours / 24) 天") }
        if hours >= 1 { return AppString("\(hours) 小时") }
        return AppString("\(max(1, seconds / 60)) 分")
    }

    /// Named from the site's own translations, not from constants in here: the
    /// API gives a trust *number* and two booleans, so the words are ours to
    /// look up — and they were stuck in English. See `DiscourseRoleNames`.
    private func roleLabels(for user: UserProfile) -> [ProfileRole] {
        var roles: [ProfileRole] = []
        if user.admin == true {
            roles.append(ProfileRole(kind: .admin, label: DiscourseRoleNames.admin))
        }
        if user.moderator == true {
            roles.append(ProfileRole(kind: .moderator, label: DiscourseRoleNames.moderator))
        }
        if let trustLevel = user.trustLevel {
            roles.append(ProfileRole(
                kind: .trustLevel(trustLevel),
                label: DiscourseRoleNames.trustLevel(trustLevel)
            ))
        }
        return roles.isEmpty
            ? [ProfileRole(kind: .trustLevel(2), label: DiscourseRoleNames.member)]
            : roles
    }

    private func formattedJoined(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return AppString("最近加入") }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.resolved.locale
        // A template, not a pattern: "yyyy年M月" only reads correctly in
        // Chinese, whereas `yMMM` lets each language order and punctuate the
        // year and month its own way. The surrounding word is a separate
        // translatable string for the same reason.
        formatter.setLocalizedDateFormatFromTemplate("yMMM")
        return AppString("\(formatter.string(from: date)) 加入")
    }

    private func formattedLastSeen(_ value: String?) -> String {
        let relative = DiscourseFormat.relative(value)
        guard !relative.isEmpty else { return AppString("公开资料") }
        if relative == "now" { return AppString("刚刚在线") }
        return AppString("最近活跃 \(localizedDuration(relative))前")
    }

    private func localizedDuration(_ value: String) -> String {
        if value.hasSuffix("mo"), let number = Int(value.dropLast(2)) { return AppString("\(number) 个月") }
        guard let unit = value.last, let number = Int(value.dropLast()) else { return value }
        switch unit {
        case "m": return AppString("\(number) 分钟")
        case "h": return AppString("\(number) 小时")
        case "d": return AppString("\(number) 天")
        case "w": return AppString("\(number) 周")
        default: return value
        }
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "--" }
        if value >= 1_000_000 { return String(format: "%.1fm", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    private func resolvedURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return URL(string: raw)
    }

}

// MARK: - Vote faces

/// The reaction faces each vote direction offers, from `site.json`.
///
/// Loaded once and shared: the same two lists drive every picker in the app, and
/// `discourse_reactions_excluded_from_like` — which decides what counts as a
/// downvote — is never sent to the client, so this is the only way to know.
@MainActor
@Observable
final class VoteFaces {
    static let shared = VoteFaces()

    private(set) var up: [String] = []
    private(set) var down: [String] = []
    /// Posts at or below this collapse on the web. Kept for when the app does.
    private(set) var collapseThreshold: Int?

    private var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let site = await SiteResources.shared.siteResponse() else {
            // Retry on the next open rather than sticking with nothing.
            loaded = false
            return
        }
        up = site.voteUpvoteReactions ?? []
        down = site.voteDownvoteReactions ?? []
        collapseThreshold = site.voteCollapseScoreThreshold
    }

    func faces(for direction: VoteDirection) -> [String] {
        direction == .down ? down : up
    }

    /// Discourse serves its emoji as PNGs under the site's own set. Built from
    /// the name because a reaction is only ever named, never given a URL.
    nonisolated static func imageURL(for name: String) -> URL? {
        // The path takes the name verbatim: "+1" is a filename, not an escape.
        DiscourseConfig.baseURL
            .appending(path: "images/emoji/unicode/\(name).png")
    }
}
