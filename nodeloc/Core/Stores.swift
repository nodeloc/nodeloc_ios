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
    let description: String
    let colorHex: String
    let url: String?
    let nodeCount: Int?
}

struct SidebarNodeSummary: Identifiable {
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
}

struct NodeGroupSummary: Identifiable {
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
            url: category.url ?? "/n/\(category.slug)"
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
    private var loaded = false

    func style(forTitle title: String) async -> TitleStyle? {
        await loadIfNeeded()
        return styles[Self.slug(title)]
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true

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
        async let feedsCall: SidebarCustomFeedsResponse? = isSignedIn ? (try? await client.customFeeds()) : nil

        let site = await siteCall
        let currentUser = await currentUserCall
        let nodeResponse = await nodesCall
        let feeds = await feedsCall

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

    private func map(feed: SidebarCustomFeed) -> SidebarFeedSummary {
        SidebarFeedSummary(
            id: feed.id,
            name: feed.name,
            description: DiscourseFormat.plainText(feed.description).isEmpty ? "\(feed.nodeCount ?? 0) 个节点" : DiscourseFormat.plainText(feed.description),
            colorHex: feed.color ?? "009966",
            url: feed.url ?? feed.username.map { "/f/\($0)/\(feed.slug)" },
            nodeCount: feed.nodeCount
        )
    }

    private func resolvedURL(_ raw: String?) -> URL? {
        NodeSummaryFactory.resolvedURL(raw)
    }

    private static let defaultResources: [SidebarResourceSummary] = [
        SidebarResourceSummary(title: "关于", url: "/about", icon: "circle-info", dividerAbove: false),
        SidebarResourceSummary(title: "常见问题", url: "/faq", icon: "questionmark.circle", dividerAbove: false),
        SidebarResourceSummary(title: "服务条款", url: "/tos", icon: "doc.text", dividerAbove: false),
        SidebarResourceSummary(title: "隐私政策", url: "/privacy", icon: "shield", dividerAbove: false),
        SidebarResourceSummary(title: "OAuth 应用", url: "/oauth-provider/applications", icon: "key", dividerAbove: true),
        SidebarResourceSummary(title: "支付应用", url: "/payment/applications", icon: "wallet.pass", dividerAbove: false),
        SidebarResourceSummary(title: "广告合作", url: "/t/topic/61119", icon: "megaphone", dividerAbove: true),
        SidebarResourceSummary(title: "认证说明", url: "/t/topic/51439", icon: "checkmark.seal", dividerAbove: false)
    ]

    static let fallbackNodes: [SidebarNodeSummary] = [
        SidebarNodeSummary(id: 31, name: "AI", slug: "ai", description: "大模型、AI 应用与自动化", memberCount: "3.5k", colorHex: "0088CC", logoURL: nil, isCreator: false, isJoined: false, url: "/n/ai"),
        SidebarNodeSummary(id: 83, name: "杂谈", slug: "chit-chat", description: "海阔天空随便说", memberCount: "1.5k", colorHex: "FFA500", logoURL: nil, isCreator: false, isJoined: false, url: "/n/chit-chat"),
        SidebarNodeSummary(id: 27, name: "VPS", slug: "vps", description: "云服务器、线路和运维", memberCount: "1.1k", colorHex: "E45735", logoURL: nil, isCreator: false, isJoined: false, url: "/n/vps"),
        SidebarNodeSummary(id: 12, name: "抽奖", slug: "lottery", description: "站内抽奖和活动", memberCount: "1.3k", colorHex: "C90D0D", logoURL: nil, isCreator: false, isJoined: false, url: "/n/lottery")
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
        case .latest: return "最新"
        case .new: return "新"
        case .hot: return "热门"
        case .featured: return "推荐"
        case .top: return "热门榜"
        }
    }

    /// Tooltip text mirroring Discourse's own titles.
    var detail: String {
        switch self {
        case .latest: return "有新帖子的话题"
        case .new: return "最近几天创建或回复的话题"
        case .hot: return "最近热门话题"
        case .featured: return "查看推荐话题"
        case .top: return "按点赞数排列的热门话题"
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
        case .compact: return "紧凑"
        case .expand: return "展开"
        case .card: return "卡片"
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
        case .watching: return "关注"
        case .tracking: return "跟踪"
        case .watchingFirstPost: return "关注第一个帖子"
        case .regular: return "常规"
        case .muted: return "已设为免打扰"
        }
    }

    var detail: String {
        switch self {
        case .watching:
            return "您将自动关注此节点中的所有话题。您会收到每个话题中每个新帖子的通知，并且会显示新回复数量。"
        case .tracking:
            return "您将自动跟踪此节点中的所有话题。您会在别人 @ 您或回复您时收到通知，并且会显示新回复数量。"
        case .watchingFirstPost:
            return "您将收到此节点中新话题的通知，但不会收到话题回复。"
        case .regular:
            return "您会在别人 @ 您或回复您时收到通知。"
        case .muted:
            return "您不会收到有关此节点中新话题的任何通知，它们也不会出现在最新话题页面上。"
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

/// Remembers the reading mode across launches, mirroring the web plugin's
/// `community-view-mode` service so the app and the site agree on precedence:
///
/// 1. this device's own choice (the dropdown), then
/// 2. the account's saved preference (`user_option.community_view_mode`), then
/// 3. the plugin's fallback.
///
/// The device wins deliberately: picking a mode on a phone shouldn't be undone
/// by a preference set on the desktop, which is the web service's rule too
/// (there, localStorage outranks the server value).
@MainActor
@Observable
final class NodeReadingModeStore {
    static let shared = NodeReadingModeStore()

    private static let defaultsKey = "communityViewMode"

    /// Matches the plugin's own fallback (`COMPACT` in community-view-mode.js),
    /// not the `.expand` this view used to hardcode.
    private static let fallback: NodeReadingMode = .compact

    private(set) var mode: NodeReadingMode

    /// Set once the account preference arrives. A device choice outranks it, so
    /// this only takes effect when nothing has been chosen here.
    private var hasDeviceChoice: Bool

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(NodeReadingMode.init(rawValue:))
        hasDeviceChoice = stored != nil
        mode = stored ?? Self.fallback
    }

    /// The reader picked a mode here; remember it and stop deferring to the account.
    func select(_ value: NodeReadingMode) {
        mode = value
        hasDeviceChoice = true
        UserDefaults.standard.set(value.rawValue, forKey: Self.defaultsKey)
    }

    /// Applies `user_option.community_view_mode` from the server. Ignored once
    /// this device has a choice of its own.
    func applyAccountPreference(_ raw: String?) {
        guard !hasDeviceChoice, let raw, let value = NodeReadingMode(rawValue: raw) else { return }
        mode = value
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
            if reset { errorText = "无法打开该节点" }
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

    func load() async {
        guard !loaded else { return }
        isLoading = true
        errorText = nil
        defer {
            isLoading = false
            loaded = true
        }

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
            for group in groups.prefix(6) {
                await loadGroupPreview(group)
            }
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
            errorText = "无法加载上级节点，请稍后重试。"
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
            errorText = "请先登录再创建节点。"
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
        case .recentPost: "最近发布"
        case .joined: "已加入"
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
        0: "新用户", 1: "基本用户", 2: "成员", 3: "活跃用户", 4: "领导者",
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

        isLotteryEnabled = settings?.lotteryEnabled ?? true
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
            errorText = "请先登录再发帖。"
            return .failed
        }

        // Posting twice would create a second topic and, worse, charge the red
        // envelope again. Once a topic is live this store is spent.
        guard !hasPublished else {
            errorText = "这篇帖子已经发布过了。"
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
                failures.append("没有拿到主题 ID，红包未创建。")
            } else if let failure = await createRedEnvelope(redEnvelope) {
                failures.append(failure)
            }
        }

        if let lottery {
            if created.id == nil {
                failures.append("没有拿到帖子 ID，抽奖未创建。")
            } else if let failure = await createLottery(lottery) {
                failures.append(failure)
            }
        }

        guard failures.isEmpty else {
            return .postedWithFollowUpFailure("帖子已发布，但：\n" + failures.joined(separator: "\n"))
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
                return "红包创建失败：\(response.error ?? "未知错误")"
            }
            pendingRedEnvelopeTopicID = nil
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "红包创建失败：\(reason)"
        }
    }

    private func createLottery(_ draft: LotteryDraft) async -> String? {
        guard let postID = pendingLotteryPostID else { return nil }

        do {
            let response = try await client.createLottery(postID: postID, draft: draft)
            if response.success == false {
                return "抽奖创建失败：\(response.error ?? "未知错误")"
            }
            pendingLotteryPostID = nil
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "抽奖创建失败：\(reason)"
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
        if case DiscourseError.badResponse(let status) = error {
            switch status {
            case 429: return "上传太频繁，请稍后重试。"
            case 413: return "图片太大，站点拒绝了上传。"
            case 401, 403: return "没有上传权限，请重新登录。"
            default: return "上传失败（\(status)）。"
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
        case .notAuthenticated: "请先登录再上传图片。"
        case .encodingFailed: "无法读取这张图片。"
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

@MainActor
@Observable
final class SearchStore {
    private let client = DiscourseClient()

    var communities: [Community] = []
    var results: [Post] = []
    var isSearching = false
    private var loadedCategories = false
    private var categoriesByID: [Int: DiscourseCategory] = [:]

    func loadCategories() async {
        guard !loadedCategories else { return }
        async let responseCall = SiteResources.shared.categoriesResponse()
        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
        let response = await responseCall
        let site = await siteCall

        guard let listed = response?.categoryList.categories, !listed.isEmpty else {
            if communities.isEmpty { communities = SampleData.communities }
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

    func search(_ query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { results = []; return }
        isSearching = true
        do {
            await loadCategories()
            let response = try await client.search(term)
            if let categories = response.categories {
                categoriesByID.merge(
                    Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                    uniquingKeysWith: { first, _ in first }
                )
            }
            results = (response.topics ?? []).map { topic in
                let category = topic.categoryId.flatMap { categoriesByID[$0] }
                let media = DiscourseFormat.mediaItems(for: topic)
                return Post(
                    id: topic.id,
                    node: category.map { "n/\($0.slug)" } ?? "n/nodeloc",
                    avatarLetter: String((category?.name ?? topic.title).prefix(1)).uppercased(),
                    variant: topic.id % 2,
                    time: DiscourseFormat.relative(topic.createdAt),
                    title: topic.title.breakingLongTokens(),
                    excerpt: DiscourseFormat.plainText(topic.excerpt),
                    baseVotes: topic.likeCount ?? 0,
                    comments: topic.postsCount.map { max(0, $0 - 1) } ?? 0,
                    hasImage: !media.isEmpty,
                    imageURL: media.first?.url,
                    media: media
                )
            }
        } catch {
            results = []
        }
        isSearching = false
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
            lastMsg: message.isEmpty ? "暂无消息" : message,
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
        return channel.isDirectMessage ? "私信" : "频道"
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
            ?? "讨论串"
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
            resolvedChannelName = "聊天"
        }

        return ChatThreadListItem(
            id: thread.id,
            channelID: channelID,
            title: title,
            channelName: resolvedChannelName,
            excerpt: excerpt.isEmpty ? "暂无回复" : excerpt,
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
        return channel.isDirectMessage ? "私信" : "频道"
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
            text: content.text.isEmpty && content.media.isEmpty ? "消息已删除" : content.text,
            time: DiscourseFormat.relative(message.createdAt),
            avatarLetter: String(authorName.prefix(1)).uppercased(),
            variant: fallbackVariant % 2,
            avatarURL: ChatListMapper.resolvedAvatarURL(user?.avatarTemplate, size: 96),
            isMine: username.lowercased() == currentUsername,
            thread: thread,
            content: content.fragments,
            media: content.media
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
            ?? "讨论串"

        return ChatThreadListItem(
            id: threadID,
            channelID: channelID,
            title: title,
            channelName: "聊天",
            excerpt: "查看讨论串",
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
}

private enum ChatCookedContentParser {
    static func content(from message: ChatMessage) -> ChatParsedContent {
        let source = message.cooked
            ?? message.message
            ?? message.excerpt
            ?? message.inReplyTo?.cooked
            ?? message.inReplyTo?.message
            ?? message.inReplyTo?.excerpt

        let fragments = inlineFragments(from: source)
        let text = readableText(from: source)
        return ChatParsedContent(text: text, fragments: fragments, media: mediaItems(from: message))
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
            if let customEmoji = customEmoji(from: tag) {
                fragments.append(ChatContentFragment(id: "emoji-\(nextID)", kind: .customEmoji(customEmoji)))
                nextID += 1
            } else if isEmojiImage(tag) {
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

    private static func isCustomEmojiImage(_ tag: String) -> Bool {
        classList(in: tag).contains("emoji-custom")
    }

    private static func customEmoji(from tag: String) -> ChatCustomEmoji? {
        guard isCustomEmojiImage(tag),
              let rawURL = attribute("src", in: tag),
              let url = absoluteURL(rawURL) else {
            return nil
        }

        let shortcode = customEmojiShortcode(from: tag)
        return ChatCustomEmoji(
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

@MainActor
@Observable
final class MessageCenterStore {
    /// Shared so the bottom tab's unread badge and the inbox read the same
    /// counts without each fetching their own.
    static let shared = MessageCenterStore()

    private let client = DiscourseClient()

    var notifications: [AppNotification] = []
    /// Real private-message conversations (from /topics/private-messages),
    /// not the PM-typed notifications the old code derived.
    var conversations: [PMConversation] = []
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

    private var loaded = false
    private var chatSearchRequestID: UUID?

    /// Forces the next `load()` to hit the network — used when re-entering the
    /// inbox so counts and lists reflect anything read elsewhere.
    func reload() async {
        loaded = false
        await load()
    }

    /// Marks all notifications read (as opening the notifications menu does on
    /// the web) so the tab badge clears once the inbox is opened.
    func markNotificationsRead() async {
        guard unreadNotifications > 0 else { return }
        unreadNotifications = 0
        try? await client.markNotificationsRead()
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

        // Unread notification count rides along on the current user. The PM
        // count is derived from the conversation list below so it matches the
        // rows' own unread dots.
        if let current = try? await client.currentUser().currentUser {
            unreadNotifications = current.unreadNotifications ?? 0
        }

        do {
            let response = try await client.notifications()
            notifications = response.notifications.map(map(notification:))
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
                : (counterpart?.username ?? "私信")
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

    private func map(notification: DiscourseNotification) -> AppNotification {
        let kind: NotificationKind
        switch notification.notificationType {
        case 5:
            kind = .like
        case 6, 7, 16:
            kind = .message
        case 1, 2, 3, 9:
            kind = .comment
        case 12:
            kind = .star
        default:
            kind = .star
        }

        let name = notification.data?.displayUsername ?? notification.data?.username ?? "NODELOC"
        return AppNotification(
            id: notification.id,
            kind: kind,
            name: name,
            text: text(for: notification, kind: kind),
            time: DiscourseFormat.relative(notification.createdAt),
            unread: !notification.read,
            url: NotificationRouting.url(for: notification)
        )
    }

    private func text(for notification: DiscourseNotification, kind: NotificationKind) -> String {
        if kind == .message {
            if let title = notification.data?.topicTitle { return title }
            return "给你发了一条私信"
        }
        if let title = notification.data?.topicTitle {
            switch kind {
            case .like:
                return "点赞了你在 \(title) 的内容"
            case .comment:
                return "回复了 \(title)"
            default:
                return title
            }
        }
        if let badge = notification.data?.badgeName { return "授予你 \(badge) 徽章" }
        return "发来一条通知"
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
            if items.isEmpty { items = SampleData.notifications }
            return
        }
        guard !loaded else { return }
        isLoading = true
        do {
            let response = try await client.notifications()
            items = response.notifications.map(map(notification:))
            loaded = true
        } catch {
            if items.isEmpty { items = SampleData.notifications }
        }
        isLoading = false
    }

    private func map(notification: DiscourseNotification) -> AppNotification {
        let kind: NotificationKind
        switch notification.notificationType {
        case 5: kind = .like
        case 6, 7, 16: kind = .message
        case 1, 2, 3, 9: kind = .comment
        case 12: kind = .star
        default: kind = .star
        }
        let name = notification.data?.displayUsername ?? notification.data?.username ?? "NODELOC"
        return AppNotification(
            id: notification.id,
            kind: kind,
            name: name,
            text: text(for: notification, kind: kind),
            time: DiscourseFormat.relative(notification.createdAt),
            unread: !notification.read,
            url: NotificationRouting.url(for: notification)
        )
    }

    private func text(for notification: DiscourseNotification, kind: NotificationKind) -> String {
        if let title = notification.data?.topicTitle {
            switch kind {
            case .like: return "liked your post in \(title)"
            case .comment: return "replied in \(title)"
            case .message: return "sent you a private message in \(title)"
            default: return title
            }
        }
        if let badge = notification.data?.badgeName { return "granted you '\(badge)'" }
        return "sent you a notification"
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
    var roles: [String] = []
    var badges: [String] = []
    var stats: [(value: String, label: String)] = []
    var topCategories: [Community] = []
    var isLoading = false
    var errorText: String?

    /// Group flair (资质) and discourse-follow state.
    var flair: UserFlair?
    var followerCount: Int?
    var canFollow = false
    var isFollowing = false
    var isTogglingFollow = false

    /// Admin-designed 头衔 style from discourse-custom-badge.
    var titleStyle: TitleStyle?
    /// Badges with descriptions for the bottom sheet.
    var badgeDetails: [(id: Int, name: String, description: String)] = []
    /// Account age like "1 年", shown in the stat row.
    var accountAge = ""
    /// 能量 total from discourse-points-service.
    var pointsTotal: Int?
    var pointsHistory: [PointsHistoryEntry] = []
    private var pointsLoaded = false

    /// Cached activity items per tab, mirroring ProfileStore.
    var actionItems: [ProfileStore.ProfileTab: [UserActionItem]] = [:]
    var loadingTab: ProfileStore.ProfileTab?

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
        defer { if loadingTab == tab { loadingTab = nil } }

        if let response = try? await client.userActions(username: username, filter: filter) {
            actionItems[tab] = response.userActions
        } else {
            actionItems[tab] = []
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

    /// Decoded profile payloads, shared across every screen that opens a
    /// profile. Without this, each open refetched four endpoints (~2s) even
    /// when returning to the profile you just closed.
    struct CachedProfile {
        let user: UserResponse
        let summary: UserSummaryResponse?
        let pointsTotal: Int?
    }

    static let cache = ResponseCache<CachedProfile>(ttl: 300, limit: 40)

    func load(target: UserProfileTarget) async {
        username = target.username
        displayName = target.displayName ?? target.username
        initial = target.initial
        avatarURL = target.avatarURL
        topCategories = []
        actionItems = [:]
        pointsHistory = []
        pointsLoaded = false

        // Paint from cache first, even if stale: a profile you just viewed
        // should appear instantly rather than behind a spinner.
        let cached = Self.cache.staleValue(forKey: target.username)
        if let cached {
            applyCached(cached.value)
            if !cached.isStale { return }
        }

        // Only show the spinner when there is nothing to show.
        isLoading = cached == nil
        errorText = nil
        defer { isLoading = false }

        var loadedUser: UserResponse?
        do {
            let response = try await client.user(target.username)
            loadedUser = response
            apply(response: response)
        } catch {
            // A refresh failing behind cached content shouldn't replace it
            // with an error.
            if cached == nil {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if stats.isEmpty {
                    stats = [("--", "能量"), ("--", "声望"), ("--", "主题"), ("--", "回复"), ("--", "账户年龄")]
                }
            }
        }

        // Summary enriches badges and top categories.
        let loadedSummary = try? await client.userSummary(target.username)
        if let summary = loadedSummary {
            let s = summary.userSummary
            if let badgeList = summary.badges {
                let details = badgeList.compactMap { badge -> (id: Int, name: String, description: String)? in
                    guard let name = badge.name else { return nil }
                    return (badge.id, name, badge.description.map { DiscourseFormat.plainText($0) } ?? "")
                }
                if !details.isEmpty {
                    badgeDetails = details
                    badges = details.map(\.name)
                }
            }
            if let categories = s.topCategories, !categories.isEmpty {
                topCategories = categories.prefix(6).map(mapSummaryCategory)
            }
        }

        // 能量 total leads the stat row.
        let loadedPoints = try? await client.pointsTotal(username: target.username).totalScores
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
                let details = badgeList.compactMap { badge -> (id: Int, name: String, description: String)? in
                    guard let name = badge.name else { return nil }
                    return (badge.id, name, badge.description.map { DiscourseFormat.plainText($0) } ?? "")
                }
                if !details.isEmpty {
                    badgeDetails = details
                    badges = details.map(\.name)
                }
            }
            if let categories = s.topCategories, !categories.isEmpty {
                topCategories = categories.prefix(6).map(mapSummaryCategory)
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

    private func mapSummaryCategory(_ category: SummaryCategory) -> Community {
        let name = category.name ?? "节点"
        return Community(
            id: category.id,
            name: name,
            letter: String(name.prefix(1)),
            variant: abs(name.hashValue) % 2,
            members: "\(compactCount(category.topicCount ?? 0)) 主题",
            desc: category.slug ?? ""
        )
    }

    /// Stat row with 能量 first, matching the 我的 page.
    private func rebuildStats() {
        let core = coreStats ?? ("--", "--", "--")
        stats = [
            (pointsTotal == nil ? "--" : compactCount(pointsTotal), "能量"),
            (core.likes, "声望"),
            (core.topics, "主题"),
            (core.posts, "回复"),
            (accountAge.isEmpty ? "--" : accountAge, "账户年龄")
        ]
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
        if let years = components.year, years >= 1 { return "\(years) 年" }
        if let months = components.month, months >= 1 { return "\(months) 个月" }
        return "新用户"
    }

    private func roleLabels(for user: UserProfile) -> [String] {
        var labels: [String] = []
        if user.admin == true { labels.append("ADMIN") }
        if user.moderator == true { labels.append("MOD") }
        if let trustLevel = user.trustLevel {
            labels.append(trustLabel(for: trustLevel))
        }
        return labels.isEmpty ? ["MEMBER"] : labels
    }

    private func trustLabel(for level: Int) -> String {
        switch level {
        case 0: return "NEW"
        case 1: return "BASIC"
        case 2: return "MEMBER"
        case 3: return "REGULAR"
        case 4: return "LEADER"
        default: return "TL\(level)"
        }
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
            errorText = "登录后查看聊天"
            return
        }

        let channelTargetMessageID = initialThread == nil ? targetMessageID : nil

        if loadedChannelID == chat.id && loadedChannelTargetMessageID == channelTargetMessageID {
            if let initialThread, selectedThread?.id != initialThread.id {
                await openThread(initialThread, targetMessageID: targetMessageID)
            }
            return
        }

        loadedChannelID = chat.id
        loadedChannelTargetMessageID = channelTargetMessageID
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let response = try await client.chatMessages(channelID: chat.id, targetMessageID: channelTargetMessageID)
            messages = ChatMessageMapper.messages(from: response)
            let target = initialScrollTarget(
                for: messages,
                targetMessageID: channelTargetMessageID ?? response.meta?.targetMessageId,
                isExplicitTarget: channelTargetMessageID != nil,
                hasUnread: chat.unread
            )
            channelInitialScrollMessageID = target.messageID
            channelInitialScrollIsUnread = target.isUnread
        } catch {
            loadedChannelID = nil
            loadedChannelTargetMessageID = nil
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        do {
            let response = try await client.chatThreads(channelID: chat.id)
            channelThreads = ChatThreadMapper.threads(from: response)
        } catch DiscourseError.badResponse(let code) where code == 404 {
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

    func send(_ text: String, chat: Chat) async {
        await send(text, channelID: chat.id, threadID: nil)
        await refreshChannel(chat)
    }

    func sendToSelectedThread(_ text: String) async {
        guard let selectedThread else { return }
        await send(text, channelID: selectedThread.channelID, threadID: selectedThread.id)
        loadedThreadID = nil
        await openThread(selectedThread)
    }

    private func send(_ text: String, channelID: Int, threadID: Int?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        errorText = nil
        defer { isSending = false }

        do {
            _ = try await client.createChatMessage(channelID: channelID, message: trimmed, threadID: threadID)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshChannel(_ chat: Chat) async {
        loadedChannelID = nil
        loadedChannelTargetMessageID = nil
        await load(chat: chat)
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

    var username = SampleData.userName
    var displayName = SampleData.userName
    var initial = SampleData.userInitial
    var avatarURL: URL?
    var backgroundURL: URL?
    var title: String?
    var bio = "自由、平等、友好、开放、有趣的互联网交流社区。"
    var joined = "2024年3月加入"
    var lastSeen = "最近活跃"
    var location: String?
    var website: String?
    var roles: [String] = ["MEMBER"]
    var badges: [String] = ["First Like", "Welcome", "Reader"]
    var stats: [(value: String, label: String)] = [
        (SampleData.userKarma, "声望"),
        (SampleData.userPosts, "主题"),
        (SampleData.userComments, "回复"),
        ("3", "徽章")
    ]
    var topCategories: [Community] = ProfileStore.defaultCommunities
    /// Recently visited nodes, sourced the same way as the sidebar.
    var recentNodes: [SidebarNodeSummary] = []
    /// Account age like "1 年" / "11 个月", shown in the primary stat row.
    var accountAge = ""
    /// Detailed summary metrics (icon, value, label) shown flat below the header.
    var summaryStats: [(icon: String, value: String, label: String)] = []
    /// Badges with descriptions for the bottom sheet.
    var badgeDetails: [(id: Int, name: String, description: String)] = []

    /// Reddit-style activity tabs shown below the header.
    enum ProfileTab: String, CaseIterable, Identifiable {
        case topics = "主题"
        case posts = "帖子"
        case likes = "赞"
        case bookmarks = "书签"
        case energy = "能量"

        var id: String { rawValue }

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

    /// 能量 history from the discourse-points-service plugin.
    var pointsHistory: [PointsHistoryEntry] = []
    var pointsTotal: Int?
    var pointsLoaded = false

    /// Admin-configured style for the user's 头衔, from discourse-custom-badge.
    var titleStyle: TitleStyle?

    /// Group flair (资质) shown after @username.
    var flair: UserFlair?
    /// Follower count from discourse-follow.
    var followerCount: Int?

    /// Reputation / topics / replies, kept so `stats` can be rebuilt when the
    /// 能量 total arrives separately.
    private var coreStats: (likes: String, topics: String, posts: String)?

    /// Rebuilds the header stat row with 能量 first, ahead of 声望.
    private func rebuildStats() {
        let core = coreStats ?? ("--", "--", "--")
        stats = [
            (pointsTotal == nil ? "--" : compactCount(pointsTotal), "能量"),
            (core.likes, "声望"),
            (core.topics, "主题"),
            (core.posts, "回复"),
            (accountAge.isEmpty ? "--" : accountAge, "账户年龄")
        ]
    }

    var isGuest = false
    var isLoading = false
    var errorText: String?
    private var loaded = false
    private var loadedUsername: String?

    /// `force` is for pull-to-refresh, which must ignore the loaded guard.
    func load(isAppAuthed: Bool = false, force: Bool = false) async {
        guard DiscourseAuth.shared.isAuthenticated || isAppAuthed else {
            applyGuest()
            return
        }

        guard let username = DiscourseAuth.shared.username else {
            seed(username: SampleData.userName)
            joined = "2024年3月加入"
            lastSeen = "最近活跃"
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
        // Only reseed when actually about to fetch. A refresh keeps the current
        // values on screen until the new ones arrive.
        if !force { seed(username: username) }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let response = try await client.user(username)
            apply(response: response)
            loaded = true
            loadedUsername = username
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        // Best-effort: enrich stats/badges/nodes from the summary endpoint.
        if let summary = try? await client.userSummary(username) {
            applySummary(summary)
        }

        // Recently visited nodes — same source as the sidebar.
        if let response = try? await client.recentlyVisitedNodes() {
            let communities = response.communities ?? response.recommended ?? []
            recentNodes = communities.prefix(8).map(NodeSummaryFactory.node)
        }

        // 能量 total leads the stat row, so fetch it up front rather than
        // waiting for the 能量 tab to be opened.
        if let total = try? await client.pointsTotal(username: username).totalScores {
            pointsTotal = total
            rebuildStats()
        }

        // A manual refresh should renew the tab lists too, not just the header.
        if force {
            actionItems = [:]
            pointsLoaded = false
        }

        // Admin-designed 头衔 styling from discourse-custom-badge.
        if let title, !title.isEmpty {
            titleStyle = await TitleStyleCatalog.shared.style(forTitle: title)
        }
    }

    /// Loads the activity stream for a tab on demand (cached after first fetch).
    func loadTab(_ tab: ProfileTab) async {
        guard !isGuest, !username.isEmpty else {
            if tab == .energy { pointsLoaded = true } else { actionItems[tab] = [] }
            return
        }

        guard let filter = tab.filter else {
            await loadPoints()
            return
        }

        guard actionItems[tab] == nil else { return }

        loadingTab = tab
        defer { if loadingTab == tab { loadingTab = nil } }

        if let response = try? await client.userActions(username: username, filter: filter) {
            actionItems[tab] = response.userActions
        } else {
            actionItems[tab] = []
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
        username = "guest"
        displayName = "访客"
        initial = "访"
        avatarURL = nil
        backgroundURL = nil
        title = nil
        bio = "登录后可以同步你的 NodeLoc 资料、徽章和发帖数据。"
        joined = "未登录"
        lastSeen = "访客模式"
        location = nil
        website = nil
        roles = ["GUEST"]
        badges = []
        stats = [
            ("--", "能量"),
            ("--", "声望"),
            ("--", "主题"),
            ("--", "回复"),
            ("--", "账户年龄")
        ]
        coreStats = nil
        titleStyle = nil
        flair = nil
        followerCount = nil
        summaryStats = []
        badgeDetails = []
        accountAge = ""
        actionItems = [:]
        loadingTab = nil
        pointsHistory = []
        pointsTotal = nil
        pointsLoaded = false
        topCategories = Self.defaultCommunities
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
        isGuest = false
        self.username = username
        displayName = username
        initial = String(username.prefix(1)).uppercased()
        avatarURL = nil
        backgroundURL = nil
        title = nil
        bio = "自由、平等、友好、开放、有趣的互联网交流社区。"
        joined = "2024年3月加入"
        lastSeen = "最近活跃"
        location = nil
        website = nil
        roles = ["MEMBER"]
        badges = ["First Like", "Welcome", "Reader"]
        stats = [
            ("--", "能量"),
            (SampleData.userKarma, "声望"),
            (SampleData.userPosts, "主题"),
            (SampleData.userComments, "回复"),
            ("--", "账户年龄")
        ]
        coreStats = nil
        titleStyle = nil
        flair = nil
        followerCount = nil
        summaryStats = []
        badgeDetails = []
        accountAge = ""
        topCategories = Self.defaultCommunities
        errorText = nil
    }

    private func apply(response: UserResponse) {
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
            ("hand.thumbsup.fill", compactCount(s.likesGiven), "点赞"),
            ("book.fill", compactCount(s.postsReadCount), "已读帖子"),
            ("calendar", compactCount(s.daysVisited), "访问天数"),
            ("clock.fill", readTime(s.timeRead), "阅读时长"),
            ("rectangle.stack.fill", compactCount(s.topicsEntered), "浏览话题"),
            ("checkmark.seal.fill", compactCount(s.solvedCount), "已解决")
        ]

        if let summaryBadges = response.badges {
            let details = summaryBadges.compactMap { badge -> (id: Int, name: String, description: String)? in
                guard let name = badge.name else { return nil }
                return (badge.id, name, badge.description.map { DiscourseFormat.plainText($0) } ?? "")
            }
            if !details.isEmpty {
                badgeDetails = details
                badges = details.map(\.name)
            }
        }

        if let categories = s.topCategories, !categories.isEmpty {
            topCategories = categories.prefix(6).map(mapCategory)
        }
    }

    private func mapCategory(_ category: SummaryCategory) -> Community {
        let name = category.name ?? "节点"
        let topics = category.topicCount ?? 0
        return Community(
            id: category.id,
            name: name,
            letter: String(name.prefix(1)),
            variant: abs(name.hashValue) % 2,
            members: "\(compactCount(topics)) 主题",
            desc: category.slug ?? ""
        )
    }

    private func formattedAge(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "" }
        let components = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
        if let years = components.year, years >= 1 { return "\(years) 年" }
        if let months = components.month, months >= 1 { return "\(months) 个月" }
        return "新用户"
    }

    private func readTime(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "--" }
        let hours = seconds / 3600
        if hours >= 24 { return "\(hours / 24) 天" }
        if hours >= 1 { return "\(hours) 小时" }
        return "\(max(1, seconds / 60)) 分"
    }

    private func roleLabels(for user: UserProfile) -> [String] {
        var labels: [String] = []
        if user.admin == true { labels.append("ADMIN") }
        if user.moderator == true { labels.append("MOD") }
        if let trustLevel = user.trustLevel {
            labels.append(trustLabel(for: trustLevel))
        }
        return labels.isEmpty ? ["MEMBER"] : labels
    }

    private func trustLabel(for level: Int) -> String {
        switch level {
        case 0: return "NEW"
        case 1: return "BASIC"
        case 2: return "MEMBER"
        case 3: return "REGULAR"
        case 4: return "LEADER"
        default: return "TL\(level)"
        }
    }

    private func formattedJoined(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "最近加入" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月加入"
        return formatter.string(from: date)
    }

    private func formattedLastSeen(_ value: String?) -> String {
        let relative = DiscourseFormat.relative(value)
        guard !relative.isEmpty else { return "公开资料" }
        if relative == "now" { return "刚刚在线" }
        return "最近活跃 \(localizedDuration(relative))前"
    }

    private func localizedDuration(_ value: String) -> String {
        if value.hasSuffix("mo"), let number = Int(value.dropLast(2)) { return "\(number) 个月" }
        guard let unit = value.last, let number = Int(value.dropLast()) else { return value }
        switch unit {
        case "m": return "\(number) 分钟"
        case "h": return "\(number) 小时"
        case "d": return "\(number) 天"
        case "w": return "\(number) 周"
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

    private static let defaultCommunities: [Community] = [
        Community(id: 5, name: "互联网服务", letter: "互", variant: 0, members: "13.1k", desc: "VPS / 域名 / 云计算"),
        Community(id: 7, name: "科技与创作", letter: "科", variant: 1, members: "2.5k", desc: "编程、运维和创作"),
        Community(id: 8, name: "数码与硬件", letter: "数", variant: 0, members: "3.5k", desc: "设备、硬件与折腾"),
        Community(id: 9, name: "生活与兴趣", letter: "生", variant: 1, members: "854", desc: "日常分享与兴趣圈"),
        Community(id: 10, name: "活动与互动", letter: "活", variant: 0, members: "33", desc: "抽奖、活动和互动")
    ]
}
