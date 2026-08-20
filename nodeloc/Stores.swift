//
//  Stores.swift
//  nodeloc
//
//  Observable loaders for search, chat, notifications, and profile. Each falls
//  back to sample data (or a guest state) when unauthenticated or offline.
//

import Foundation

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

        async let siteCall: SiteResponse? = try? client.site()
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

// MARK: - Nodes

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

        do {
            async let categoriesCall = client.categories()
            async let siteCall: SiteResponse? = try? client.site()
            let response = try await categoriesCall
            let site = await siteCall
            let source = site?.categories ?? response.categoryList.categories
            parentCategories = source
                .filter { $0.parentCategoryId == nil }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            selectedParentID = selectedParentID ?? parentCategories.first?.id
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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

@MainActor
@Observable
final class ComposeStore {
    private let client = DiscourseClient()

    var communities: [Community] = SampleData.communities
    var isLoadingCommunities = false
    var isSubmitting = false
    var isUploadingMedia = false
    var errorText: String?

    func loadCommunities() async {
        guard !isLoadingCommunities else { return }
        isLoadingCommunities = true
        defer { isLoadingCommunities = false }

        do {
            let response = try await client.categories()
            let top = response.categoryList.categories
                .filter { $0.parentCategoryId == nil }
                .sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }

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
        } catch {
            if communities.isEmpty { communities = SampleData.communities }
        }
    }

    func submit(title: String, body: String, community: Community?) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let community else { return false }
        guard DiscourseAuth.shared.isAuthenticated else {
            errorText = "请先登录再发帖。"
            return false
        }

        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }

        do {
            try await client.createTopic(
                title: trimmedTitle,
                raw: trimmedBody.isEmpty ? trimmedTitle : trimmedBody,
                categoryID: community.id
            )
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func uploadMedia(data: Data, fileName: String, mimeType: String) async -> DiscourseUpload? {
        guard DiscourseAuth.shared.isAuthenticated else {
            errorText = "请先登录再上传媒体。"
            return nil
        }

        isUploadingMedia = true
        errorText = nil
        defer { isUploadingMedia = false }

        do {
            return try await client.uploadComposerMedia(data: data, fileName: fileName, mimeType: mimeType)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "0" }
        return value >= 1000 ? String(format: "%.0fk", Double(value) / 1000) : "\(value)"
    }
}

// MARK: - Search

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
        do {
            async let responseCall = client.categories()
            async let siteCall: SiteResponse? = try? client.site()
            let response = try await responseCall
            let site = await siteCall
            categoriesByID = Dictionary(
                (site?.categories ?? response.categoryList.categories).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let top = response.categoryList.categories
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
        } catch {
            if communities.isEmpty { communities = SampleData.communities }
        }
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
                    title: topic.title,
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

    private static func chat(from channel: ChatChannel, tracking: ChatTrackingState?, displayIndex: Int) -> Chat {
        let name = displayName(for: channel)
        let message = messageText(for: channel)
        let unreadCount = tracking?.totalUnreadCount ?? channel.currentUserMembership?.unreadCount ?? 0

        return Chat(
            id: channel.id,
            name: name,
            letter: avatarLetter(for: channel, name: name),
            variant: displayIndex % 2,
            lastMsg: message.isEmpty ? "暂无消息" : message,
            time: DiscourseFormat.relative(channel.lastMessage?.createdAt ?? tracking?.lastReplyCreatedAt),
            unread: unreadCount > 0
        )
    }

    private static func displayName(for channel: ChatChannel) -> String {
        if channel.isDirectMessage {
            var names: [String] = []
            for user in channel.chatable?.users ?? [] {
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
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

@MainActor
@Observable
final class MessageCenterStore {
    private let client = DiscourseClient()
    private let privateMessageNotificationTypes: Set<Int> = [6, 7, 16]

    var notifications: [AppNotification] = []
    var privateMessages: [AppNotification] = []
    var chats: [Chat] = []
    var isLoading = false
    var needsLogin = false
    var errorText: String?
    private var loaded = false

    func load() async {
        guard DiscourseAuth.shared.isAuthenticated else {
            needsLogin = true
            notifications = []
            privateMessages = []
            chats = []
            return
        }
        needsLogin = false
        guard !loaded else { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let response = try await client.notifications()
            notifications = response.notifications.map(map(notification:))
            privateMessages = response.notifications
                .filter { privateMessageNotificationTypes.contains($0.notificationType) }
                .map(map(notification:))
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        do {
            let response = try await client.chatChannels()
            chats = ChatListMapper.chats(from: response)
        } catch {
            if errorText == nil {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        loaded = true
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
            unread: !notification.read
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
            unread: !notification.read
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

    func load(target: UserProfileTarget) async {
        username = target.username
        displayName = target.displayName ?? target.username
        initial = target.initial
        avatarURL = target.avatarURL
        topCategories = Array(SampleData.communities.prefix(6))

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let response = try await client.user(target.username)
            apply(response: response)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if stats.isEmpty {
                stats = [
                    ("--", "Topics"),
                    ("--", "Replies"),
                    ("--", "Likes"),
                ]
            }
        }
    }

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
        stats = [
            (compactCount(user.topicCount), "Topics"),
            (compactCount(user.postCount), "Replies"),
            (compactCount(user.likesReceived), "Likes"),
        ]
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

// MARK: - Profile

@MainActor
@Observable
final class ProfileStore {
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
    var isGuest = false
    var isLoading = false
    var errorText: String?
    private var loaded = false
    private var loadedUsername: String?

    func load(isAppAuthed: Bool = false) async {
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

        seed(username: username)
        guard !loaded || loadedUsername != username else { return }

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
            ("--", "声望"),
            ("--", "主题"),
            ("--", "回复"),
            ("--", "徽章")
        ]
        topCategories = Self.defaultCommunities
        isGuest = true
        errorText = nil
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
            (SampleData.userKarma, "声望"),
            (SampleData.userPosts, "主题"),
            (SampleData.userComments, "回复"),
            ("3", "徽章")
        ]
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
        stats = [
            (compactCount(user.likesReceived), "获赞"),
            (compactCount(user.topicCount), "主题"),
            (compactCount(user.postCount), "回复"),
            (compactCount(user.badgeCount), "徽章")
        ]
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
