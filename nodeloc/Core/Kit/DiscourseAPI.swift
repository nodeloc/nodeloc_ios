//
//  DiscourseAPI.swift
//  nodeloc
//
//  The app's API facade. Screens and stores call `DiscourseClient` and get
//  the models in `DiscourseModels.swift`, as they did against Discourse; each
//  method now talks to the NodeLoc backend's `/api/v1` (`NodelocHTTP`) and
//  shapes the answer for those models (`DiscourseShape`).
//
//  Methods whose feature the backend does not have throw
//  `DiscourseError.unsupported` or return an empty answer, and the screens
//  that offer them are hidden through `FeatureFlags` — see `NodelocFeatures`.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DiscourseClient {
    var baseURL = DiscourseConfig.baseURL
    var session: URLSession = NodelocHTTP.sharedSession
    var auth: DiscourseAuth = .shared

    // Explicit nonisolated init so the caching actors can construct a client
    // at property-init without hopping to the main actor.
    nonisolated init() {}

    nonisolated init(baseURL: URL, auth: DiscourseAuth, session: URLSession = NodelocHTTP.sharedSession) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
    }

    var http: NodelocHTTP { NodelocHTTP(baseURL: baseURL, session: session, auth: auth) }
    private var state: NodelocAdapterState { .shared }

    static let pageSize = 30

    // MARK: Request helpers

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await http.send("GET", path, query: query)
        return try NodelocJSON.decode(T.self, from: data)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, query: [URLQueryItem] = [], headers: [String: String] = [:]) async throws -> Data {
        try await http.send(method, path, query: query, body: json.map { .json($0) } ?? .none, headers: headers)
    }

    private func sendDecoding<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> T {
        let data = try await send(method, path, json: json, headers: headers)
        return try NodelocJSON.decode(T.self, from: data)
    }

    private static func shaped<T: Decodable>(_ object: Any) throws -> T {
        try NodelocJSON.decode(T.self, object: object)
    }

    private static let ok = Data("{\"success\":\"OK\"}".utf8)

    private static func notFound() -> DiscourseError {
        .badResponse(404, message: nil, code: "not_found")
    }

    // MARK: Nodes directory

    /// Every node the reader can see, cached for a few minutes: the screens
    /// address nodes by id and the backend by slug, so this is the map.
    @discardableResult
    func loadNodes(force: Bool = false) async throws -> [NLNode] {
        if !force, state.nodesFresh { return state.allNodes }
        let list: NLNodeList = try await get("api/v1/nodes")
        state.store(nodes: list.nodes)
        await loadMyNodes()
        return list.nodes
    }

    /// Which nodes the reader joined (with role and bell), favorited, muted.
    func loadMyNodes() async {
        guard auth.isAuthenticated, let mine: NLMyNodes = try? await get("api/v1/me/nodes") else { return }
        state.myNodes = Dictionary(mine.joined.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        state.mutedNodes = Set(mine.muted ?? [])
        state.favoriteNodes = (mine.favorites ?? []).map(\.slug)
    }

    func nodeSlug(categoryID: Int) async throws -> String {
        if let slug = state.nodeSlug(forID: categoryID) { return slug }
        try await loadNodes(force: true)
        guard let slug = state.nodeSlug(forID: categoryID) else { throw Self.notFound() }
        return slug
    }

    private func children(of parentID: Int?) -> [NLNode] {
        state.allNodes.filter { $0.parentId == parentID }
    }

    // MARK: Topic lists

    private func topicPage(
        list key: String,
        page: Int,
        query base: [URLQueryItem],
        path: String = "api/v1/topics",
        offsetPaged: Bool = false
    ) async throws -> NLTopicPage {
        var query = base + [URLQueryItem(name: "limit", value: String(Self.pageSize))]
        if offsetPaged {
            query.append(URLQueryItem(name: "offset", value: String(page * Self.pageSize)))
        } else if page > 0 {
            guard let cursor = state.cursor(list: key, page: page) else {
                return NLTopicPage(topics: [], nextCursor: nil, nextOffset: nil)
            }
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        _ = try? await loadNodes()
        let result: NLTopicPage = try await get(path, query: query)
        state.setCursor(result.nextCursor, list: key, page: page + 1)
        return result
    }

    private static func hasMore(_ page: NLTopicPage) -> Bool {
        page.nextCursor != nil || page.nextOffset != nil
    }

    /// One of the home tab's lists.
    func topicList(
        feed: HomeFeed,
        page: Int = 0,
        seed: String? = nil
    ) async throws -> LatestResponse {
        let result: NLTopicPage
        var shapedSeed: String?
        switch feed {
        case .best:
            let seed = seed ?? String(Int.random(in: 1...999_999))
            shapedSeed = seed
            result = try await topicPage(
                list: "best", page: page,
                query: [URLQueryItem(name: "seed", value: seed)],
                path: "api/v1/feed/personal", offsetPaged: true
            )
        case .latest:
            result = try await topicPage(list: "latest", page: page, query: [])
        case .hot:
            result = try await topicPage(list: "hot", page: page, query: [URLQueryItem(name: "sort", value: "hot")], offsetPaged: true)
        case .top:
            result = try await topicPage(list: "featured", page: page, query: [URLQueryItem(name: "featured", value: "1")])
        case .rising:
            // Offset-paged like hot.
            result = try await topicPage(
                list: "rising", page: page,
                query: [URLQueryItem(name: "sort", value: "rising")], offsetPaged: true
            )
        case .fresh:
            // Cursor-paged like latest, but the cursor records posting time and
            // only works while `sort=fresh` stays on the request.
            result = try await topicPage(
                list: "fresh", page: page,
                query: [URLQueryItem(name: "sort", value: "fresh")]
            )
        }
        var object = DiscourseShape.latest(result.topics, hasMore: Self.hasMore(result))
        if Self.hasMore(result), var list = object["topic_list"] as? [String: Any] {
            var more = "/latest?page=\(page + 1)"
            if let shapedSeed { more += "&seed=\(shapedSeed)" }
            list["more_topics_url"] = more
            object["topic_list"] = list
        }
        return try Self.shaped(object)
    }

    /// The three columns the topic page's "related" strip can show.
    enum RelatedTopicsKind: String, CaseIterable, Sendable {
        /// Same node and tags, most shared tags first.
        case similar
        /// Recently active in this topic's own node.
        case node
        /// Site-wide: posted in the last seven days, most upvoted.
        case week

        var title: String {
            switch self {
            case .similar: AppString("相关主题")
            case .node: AppString("本节点最近")
            case .week: AppString("本周热门")
            }
        }
    }

    /// One column of the topic page's "related" strip. Five at a time; a null
    /// `nextOffset` means that column is exhausted, and the caller starts over
    /// at 0 if it wants to cycle.
    func relatedTopics(
        topicID: Int,
        kind: RelatedTopicsKind = .similar,
        offset: Int = 0
    ) async throws -> (topics: LatestResponse, nextOffset: Int?) {
        let result: NLTopicPage = try await get("api/v1/topics/\(topicID)/related", query: [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        let shaped: LatestResponse = try Self.shaped(
            DiscourseShape.latest(result.topics, hasMore: false)
        )
        return (shaped, result.nextOffset)
    }

    // MARK: Penalties and the watch list

    /// Silences or suspends someone site-wide.
    ///
    /// - Parameter deleteRecentHours: 0 leaves their posts alone; 1–720 also
    ///   removes what they posted in that window, up to 500 items. Those
    ///   deletions aren't announced separately — the penalty's own
    ///   notification covers them.
    /// - Parameter notify: False also suppresses the email for a site-wide
    ///   penalty.
    @discardableResult
    func penalizeUser(
        id: Int,
        type: String,
        reason: String,
        hours: Int? = nil,
        deleteRecentHours: Int = 0,
        notify: Bool = true
    ) async throws -> Data {
        var body: [String: Any] = ["type": type, "reason": reason, "notify": notify]
        if let hours { body["hours"] = hours }
        if deleteRecentHours > 0 { body["delete_recent_hours"] = min(deleteRecentHours, 720) }
        return try await send("POST", "api/v1/admin/users/\(id)/penalties", json: body)
    }

    /// Restricts someone inside one node. A node moderator is held to 1–30
    /// days; a node's owner isn't, being the node's highest rank.
    @discardableResult
    func restrictInNode(
        slug: String,
        username: String,
        type: String,
        reason: String,
        days: Int? = nil,
        deleteRecentHours: Int = 0
    ) async throws -> Data {
        var body: [String: Any] = ["username": username, "type": type, "reason": reason]
        if let days { body["days"] = days }
        if deleteRecentHours > 0 { body["delete_recent_hours"] = min(deleteRecentHours, 720) }
        return try await send("POST", "api/v1/nodes/\(slug)/restrictions", json: body)
    }

    /// Puts someone on the watch list, so their posts are held for review.
    /// Calling it again for someone already on the list edits their reason and
    /// expiry rather than failing.
    ///
    /// - Parameter days: 0–365; 0 watches until they are taken off by hand.
    /// - Parameter slug: Nil watches them site-wide; a slug watches only what
    ///   they post in that node. Nobody may watch themselves or a manager
    ///   (403 `protected`), though an administrator may watch a site-wide
    ///   moderator.
    @discardableResult
    func watchUser(id: Int, reason: String, days: Int = 0, slug: String? = nil) async throws -> Data {
        let body: [String: Any] = ["watch": true, "reason": reason, "days": min(max(days, 0), 365)]
        return try await send("PUT", Self.watchPath(userID: id, slug: slug), json: body)
    }

    @discardableResult
    func unwatchUser(id: Int, slug: String? = nil) async throws -> Data {
        try await send("DELETE", Self.watchPath(userID: id, slug: slug))
    }

    /// Site-wide the id is the path's last segment; inside a node it trails
    /// the node's own `watch`.
    private static func watchPath(userID: Int, slug: String?) -> String {
        slug.map { "api/v1/nodes/\($0)/watch/\(userID)" } ?? "api/v1/admin/users/\(userID)/watch"
    }

    // MARK: Moderation log and undo

    /// The audit trail: site-wide for staff, a node's own for its managers.
    func moderationLog(_ scope: ReviewScope, before: Int? = nil, limit: Int = 30) async throws -> NLModerationLog {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get(Self.logPath(scope), query: query)
    }

    /// Reverses one entry. The server performs the opposite action — and logs
    /// *that* in the usual way — rather than erasing the original, which only
    /// gets stamped as undone.
    ///
    /// Only some actions can be reversed at all (400 `not_undoable`), only
    /// while they are still the one in force (409 `nothing_to_undo`), and only
    /// once (409 `already_undone`). Follow each entry's own `undoable` rather
    /// than guessing from its action.
    @discardableResult
    func undoModerationLog(_ scope: ReviewScope, id: Int) async throws -> Data {
        try await send("POST", "\(Self.logPath(scope))/\(id)/undo")
    }

    private static func logPath(_ scope: ReviewScope) -> String {
        switch scope {
        case .site: "api/v1/admin/audit-logs"
        case .node(let slug): "api/v1/nodes/\(slug)/mod-log"
        }
    }

    // MARK: Review queue

    /// Which queue to read. A node's managers can only reach their own; the
    /// site-wide one needs the review permission.
    enum ReviewScope: Sendable, Hashable {
        case site
        case node(String)

        var basePath: String {
            switch self {
            case .site: "api/v1/admin/review"
            case .node(let slug): "api/v1/nodes/\(slug)/review"
            }
        }
    }

    func reviewQueue(
        _ scope: ReviewScope,
        status: String? = nil,
        kind: String? = nil,
        item: Int? = nil,
        before: Int? = nil,
        limit: Int = 30
    ) async throws -> NLReviewQueue {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        if let item { query.append(URLQueryItem(name: "item", value: String(item))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await get(scope.basePath, query: query)
    }

    /// Settles one item.
    ///
    /// - Parameter reputationPenalty: Only accepted alongside a decision that
    ///   finds against the author (`delete_post`, `hide_post`, a risk item's
    ///   `confirm`); anything else with a non-zero value is 422, as is a value
    ///   above the reader's cap — read that from the queue's
    ///   `reputationPenaltyMax` rather than assuming 1000 or 20.
    @discardableResult
    func resolveReviewItem(
        _ scope: ReviewScope,
        id: Int,
        action: String,
        note: String? = nil,
        reputationPenalty: Int? = nil
    ) async throws -> Data {
        var body: [String: Any] = ["action": action]
        if let note, !note.isEmpty { body["note"] = note }
        if let reputationPenalty, reputationPenalty > 0 {
            body["reputation_penalty"] = reputationPenalty
        }
        return try await send("POST", "\(scope.basePath)/\(id)/resolve", json: body)
    }

    /// Puts a settled item back to pending. Doesn't itself restore the post or
    /// undo a node penalty, but it does return any reputation taken.
    @discardableResult
    func reopenReviewItem(_ scope: ReviewScope, id: Int, note: String? = nil) async throws -> Data {
        try await send("POST", "\(scope.basePath)/\(id)/reopen", json: note.map { ["note": $0] })
    }

    /// Brings the post back and marks the item unfounded (a pending post is
    /// approved instead). Returns any reputation taken.
    @discardableResult
    func restoreReviewItemPost(_ scope: ReviewScope, id: Int, note: String? = nil) async throws -> Data {
        try await send("POST", "\(scope.basePath)/\(id)/restore-post", json: note.map { ["note": $0] })
    }

    /// Gives the reputation back without disturbing the decision or the post.
    /// 409 `nothing_to_refund` when none was taken or it already went back.
    @discardableResult
    func refundReviewReputation(_ scope: ReviewScope, id: Int, note: String? = nil) async throws -> Int {
        let data = try await send(
            "POST", "\(scope.basePath)/\(id)/refund-reputation", json: note.map { ["note": $0] }
        )
        struct Refund: Decodable { let refunded: Int? }
        return (try? NodelocJSON.decode(Refund.self, from: data))?.refunded ?? 0
    }

    // MARK: Account status and appeals

    /// Every penalty currently on this account. Empty for an account in good
    /// standing, which is the common case.
    func myRestrictions() async throws -> [NLRestrictions.Restriction] {
        let response: NLRestrictions = try await get("api/v1/me/restrictions")
        return response.restrictions
    }

    /// Why an appeal is being made. `wrong` is the default.
    enum AppealReason: String, CaseIterable, Sendable {
        case wrong
        case willImprove = "will_improve"

        var title: String {
            switch self {
            case .wrong: AppString("判错了")
            case .willImprove: AppString("我会改")
            }
        }
    }

    /// Appeal one penalty. One appeal per penalty ever — a second attempt is
    /// 409 whether or not the first was decided — and five a day per account.
    @discardableResult
    func appealRestriction(
        kind: String,
        id: Int,
        reason: AppealReason = .wrong,
        text: String
    ) async throws -> NLRestrictions.Appeal {
        let response: NLAppealEnvelope = try await sendDecoding(
            "POST", "api/v1/me/restrictions/\(kind)/\(id)/appeal",
            json: ["reason": reason.rawValue, "text": text]
        )
        return response.appeal
    }

    /// Appeal a deleted or hidden post — or, when the whole topic went, the
    /// topic. Only its author may, only once per removal, and only inside the
    /// seven-day window (409 `appeal_expired` after that).
    @discardableResult
    func appealRemoval(postID: Int? = nil, topicID: Int? = nil, text: String) async throws -> NLContentAppeal.Appeal {
        var body: [String: Any] = ["text": text]
        if let postID { body["post_id"] = postID }
        if let topicID { body["topic_id"] = topicID }
        let response: NLContentAppeal = try await sendDecoding("POST", "api/v1/appeals", json: body)
        return response.appeal
    }

    /// One node's detail. Worth asking for even when the catalogue already has
    /// the node: for a signed-in reader this request is what records them as
    /// having looked at it, so app-only readers show up in `onlineCount`.
    func nodeDetail(slug: String) async throws -> NLNodeDetail {
        try await get("api/v1/nodes/\(slug)")
    }

    /// A node's pinned carousel. No paging, and readable signed out.
    func nodePins(slug: String) async throws -> LatestResponse {
        let pins: NLNodePins = try await get("api/v1/nodes/\(slug)/pins")
        return try Self.shaped(DiscourseShape.pinnedCarousel(pins.topics, nodeSlug: slug))
    }

    /// Which board the wealth leaderboard shows. Income over a period never
    /// counts transfers between members; tips, red envelopes and lotteries do.
    enum LeaderboardPeriod: String, CaseIterable, Sendable {
        /// Current energy rather than income.
        case all
        /// From Monday, Beijing time.
        case week
        /// From the first of the month, Beijing time.
        case month

        var title: String {
            switch self {
            case .all: AppString("总榜")
            case .week: AppString("本周")
            case .month: AppString("本月")
            }
        }
    }

    /// The wealth leaderboard, the same table as the web's /rank. Read-only —
    /// the server recomputes it hourly — and readable signed out, in which
    /// case the response carries no `me`.
    func leaderboard(
        period: LeaderboardPeriod = .all,
        page: Int = 1,
        limit: Int = 50
    ) async throws -> NLLeaderboard {
        try await get("api/v1/points/leaderboard", query: [
            URLQueryItem(name: "period", value: period.rawValue),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
        ])
    }

    /// This reader's reputation page: the totals, the week split five ways,
    /// the weekly task allowance and the rolling 30-day change.
    func reputation() async throws -> NLReputation {
        try await get("api/v1/me/reputation")
    }

    /// The tier catalogue, with what each tier widens over the one below.
    /// Readable signed out.
    func tierCatalog() async throws -> [NLTiers.Tier] {
        let response: NLTiers = try await get("api/v1/tiers")
        return response.tiers
    }

    /// The home banner carousel. Readable signed out, so a guest gets rows too
    /// — only the dismissal below needs an account.
    func homeAnnouncements() async throws -> [NLHomeAnnouncements.Announcement] {
        let response: NLHomeAnnouncements = try await get("api/v1/announcements/home")
        return response.announcements
    }

    /// Dismiss one for good, across this reader's devices. Signed-in only: a
    /// guest has no account to record it against and would get a 401, so the
    /// caller keeps a guest's dismissals on the device instead.
    func dismissAnnouncement(id: Int) async throws {
        guard auth.isAuthenticated else { return }
        try await send("PUT", "api/v1/announcements/\(id)/dismissal")
    }

    func nodeTopics(
        path: String,
        categoryID: Int,
        sort: String = "latest",
        page: Int = 0
    ) async throws -> CategoryTopicsResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        let scoped = Self.scopedSort(sort)
        let result = try await topicPage(
            list: "node:\(slug):\(scoped ?? "latest")",
            page: page,
            query: [URLQueryItem(name: "node", value: slug)] + Self.sortQuery(scoped),
            // `hot` and `rising` page by offset; `latest` and `fresh` by cursor.
            offsetPaged: scoped == "hot" || scoped == "rising"
        )
        return try Self.shaped(DiscourseShape.latest(result.topics, hasMore: Self.hasMore(result)))
    }

    /// Which `sort=` a node or tag list should ask for, or nil for the default
    /// "latest". Inside a node or a tag the "doesn't reach the home page" rule
    /// is off, so these are the node page's own orderings.
    private static func scopedSort(_ sort: String) -> String? {
        switch sort {
        case "hot", "top": "hot"
        case "rising": "rising"
        case "fresh": "fresh"
        default: nil
        }
    }

    private static func sortQuery(_ scoped: String?) -> [URLQueryItem] {
        scoped.map { [URLQueryItem(name: "sort", value: $0)] } ?? []
    }

    func tagTopics(slug: String, sort: String = "latest", page: Int = 0) async throws -> CategoryTopicsResponse {
        let scoped = Self.scopedSort(sort)
        let result = try await topicPage(
            list: "tag:\(slug):\(scoped ?? "latest")",
            page: page,
            query: [URLQueryItem(name: "tag", value: slug)] + Self.sortQuery(scoped),
            offsetPaged: scoped == "hot" || scoped == "rising"
        )
        return try Self.shaped(DiscourseShape.latest(result.topics, hasMore: Self.hasMore(result)))
    }

    // MARK: Site

    /// The backend has no site.json; this assembles the parts the app reads
    /// from it: nodes, social sign-in providers, tiers, report reasons.
    func site() async throws -> SiteResponse {
        let nodes = try await loadNodes()
        var object: [String: Any] = [
            "categories": nodes.map { DiscourseShape.category($0) },
            "post_action_types": NodelocReports.flagTypes,
            "topic_flag_types": NodelocReports.flagTypes,
            "user_fields": [Any](),
            "site_settings": [
                "poll_enabled": true,
                "poll_maximum_options": 20,
                "red_envelope_enabled": true,
                "red_envelope_min_points": 10,
                "red_envelope_min_avg_points": 10,
                "red_envelope_min_count": 1,
                "red_envelope_max_count": 1000,
                "lottery_enabled": true,
            ] as [String: Any],
        ]
        if let providers = try? await authProviders() {
            object["auth_providers"] = providers.map { ["name": $0.name, "custom_url": DiscourseShape.value($0.url)] as [String: Any] }
        }
        if let tiers: NLTiers = try? await get("api/v1/tiers") {
            object["trust_levels"] = Dictionary(tiers.tiers.map { ($0.name, $0.level) }, uniquingKeysWith: { first, _ in first })
        }
        return try Self.shaped(object)
    }

    /// Sign-in providers the site has enabled, when the server lists them.
    func authProviders() async throws -> [NLAuthProviders.Provider] {
        let response: NLAuthProviders = try await get("api/v1/auth/providers")
        NodelocAuthCapabilities.appleNative = response.appleNative ?? false
        NodelocAuthCapabilities.providerURLs = Dictionary(
            response.providers.compactMap { provider in provider.url.map { (provider.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return response.providers
    }

    // MARK: Nodes

    func joinNode(categoryID: Int) async throws -> NodeMembershipResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        try await send("PUT", "api/v1/nodes/\(slug)/membership")
        state.invalidateNodes()
        await loadMyNodes()
        return try Self.shaped(["success": true, "joined": true])
    }

    func leaveNode(categoryID: Int) async throws -> NodeMembershipResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        try await send("DELETE", "api/v1/nodes/\(slug)/membership")
        state.invalidateNodes()
        await loadMyNodes()
        return try Self.shaped(["success": true, "joined": false])
    }

    func setCategoryNotification(categoryID: Int, level: Int) async throws -> Data {
        let slug = try await nodeSlug(categoryID: categoryID)
        let data = try await send("PUT", "api/v1/nodes/\(slug)/notification", json: ["level": DiscourseShape.nodeLevel(fromDiscourse: level)])
        await loadMyNodes()
        return data
    }

    func setTopicNotification(topicID: Int, level: Int) async throws -> Data {
        let mapped = level >= 3 ? "watching" : (level == 0 ? "muted" : "normal")
        let data = try await send("PUT", "api/v1/topics/\(topicID)/follow", json: ["level": mapped])
        state.topicLevels[topicID] = level >= 3 ? 3 : (level == 0 ? 0 : 1)
        return data
    }

    func categories(includeSubcategories: Bool = false) async throws -> CategoriesResponse {
        let nodes = try await loadNodes()
        let sections = nodes.filter { $0.parentId == nil }
        let categories = sections.map { section in
            DiscourseShape.category(section, children: includeSubcategories ? children(of: section.id) : nil)
        }
        return try Self.shaped(["category_list": ["categories": categories]])
    }

    /// The drawer's node list: the nodes the reader joined.
    func sidebarNodes() async throws -> SidebarCommunitiesResponse {
        let nodes = try await loadNodes()
        let mine = nodes.filter { ($0.joined == true || state.myNodes[$0.slug] != nil) && $0.parentId != nil }
        return try Self.shaped(["communities": mine.map { DiscourseShape.category($0, isMine: $0.ownerId == state.me?.id) }])
    }

    func nodeBrowse(parentCategoryID: Int, page: Int = 0, perPage: Int? = nil) async throws -> SidebarCommunitiesResponse {
        let nodes = try await loadNodes()
        let size = perPage ?? 30
        let all = nodes.filter { $0.parentId == parentCategoryID }
        let slice = Array(all.dropFirst(page * size).prefix(size))
        return try Self.shaped([
            "communities": slice.map { DiscourseShape.category($0) },
            "meta": ["total": all.count, "page": page, "per_page": size, "has_more": (page + 1) * size < all.count] as [String: Any],
        ])
    }

    /// No visit history on the server; the reader's own nodes stand in.
    func recentlyVisitedNodes() async throws -> SidebarCommunitiesResponse {
        try await sidebarNodes()
    }

    func checkNodeSlug(_ slug: String) async throws -> NodeSlugAvailabilityResponse {
        let result: NLSlugAvailability = try await get("api/v1/nodes/slug-available", query: [URLQueryItem(name: "slug", value: slug)])
        let message: String?
        switch result.slug {
        case "format": message = AppString("只能用小写字母、数字和连字符，2 到 12 个字符")
        case "reserved": message = AppString("这个地址被保留了")
        case "taken": message = AppString("这个地址已经被使用了")
        default: message = nil
        }
        return try Self.shaped(["available": result.available ?? (result.slug == "ok"), "message": DiscourseShape.value(message)])
    }

    func createNode(
        name: String,
        slug: String,
        description: String,
        colorHex: String?,
        parentCategoryID: Int
    ) async throws -> CreateCommunityResponse {
        let parent = try await nodeSlug(categoryID: parentCategoryID)
        let body: [String: Any] = [
            "parent": parent,
            "slug": slug,
            "name": name,
            "description": description,
            "color": colorHex ?? "",
            "open_for_nodes": false,
        ]
        let created: NLNodeEnvelope = try await sendDecoding("POST", "api/v1/nodes", json: body)
        state.merge(node: created.node)
        state.invalidateNodes()
        return try Self.shaped(["category": DiscourseShape.category(created.node, isMine: true)])
    }

    // MARK: Custom feeds

    func customFeeds() async throws -> CustomFeedsResponse {
        let list: NLCustomFeeds = try await get("api/v1/custom-feeds")
        return try Self.shaped(["custom_feeds": list.feeds.map(DiscourseShape.customFeed)])
    }

    /// The backend lists only the reader's own feeds.
    func customFeeds(username: String) async throws -> CustomFeedsResponse {
        guard username.lowercased() == auth.username?.lowercased() else {
            return try Self.shaped(["custom_feeds": [Any]()])
        }
        return try await customFeeds()
    }

    /// Feeds are addressed by id; the shaped `slug` is that id.
    func customFeed(username: String, slug: String) async throws -> CustomFeedResponse {
        _ = try? await loadNodes()
        let feed: NLCustomFeedEnvelope = try await get("api/v1/custom-feeds/\(slug)")
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func customFeedTopics(
        username: String,
        slug: String,
        page: Int = 0
    ) async throws -> CategoryTopicsResponse {
        let result = try await topicPage(
            list: "feed:\(slug)", page: page,
            query: [URLQueryItem(name: "sort", value: "hot")],
            path: "api/v1/custom-feeds/\(slug)/topics", offsetPaged: true
        )
        return try Self.shaped(DiscourseShape.latest(result.topics, hasMore: Self.hasMore(result)))
    }

    func createCustomFeed(
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        let feed: NLCustomFeedEnvelope = try await sendDecoding("POST", "api/v1/custom-feeds", json: [
            "name": name, "description": description, "public": !isPrivate,
        ])
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func updateCustomFeed(
        id: Int,
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        let feed: NLCustomFeedEnvelope = try await sendDecoding("PUT", "api/v1/custom-feeds/\(id)", json: [
            "name": name, "description": description, "public": !isPrivate,
        ])
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func deleteCustomFeed(id: Int) async throws {
        try await send("DELETE", "api/v1/custom-feeds/\(id)")
    }

    func copyCustomFeed(
        username: String,
        slug: String,
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        let copy: NLCustomFeedEnvelope = try await sendDecoding("POST", "api/v1/custom-feeds/\(slug)/copy")
        // The copy keeps the original's name; apply what the reader typed.
        let feed: NLCustomFeedEnvelope = try await sendDecoding("PUT", "api/v1/custom-feeds/\(copy.feed.id)", json: [
            "name": name, "description": description, "public": !isPrivate,
        ])
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func addCustomFeedNode(feedID: Int, categoryID: Int) async throws -> CustomFeedResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        let feed: NLCustomFeedEnvelope = try await sendDecoding("PUT", "api/v1/custom-feeds/\(feedID)/nodes/\(slug)")
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func removeCustomFeedNode(feedID: Int, categoryID: Int) async throws -> CustomFeedResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        let feed: NLCustomFeedEnvelope = try await sendDecoding("DELETE", "api/v1/custom-feeds/\(feedID)/nodes/\(slug)")
        return try Self.shaped(["custom_feed": DiscourseShape.customFeed(feed.feed)])
    }

    func customFeedNodeSearch(term: String) async throws -> CustomFeedNodeSearchResponse {
        let list: NLNodeList = try await get("api/v1/nodes", query: [
            URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "20"),
        ])
        for node in list.nodes { state.merge(node: node) }
        return try Self.shaped(["nodes": list.nodes.filter { $0.parentId != nil }.map { DiscourseShape.category($0) }])
    }

    // MARK: Topics

    /// The topic with its first page of posts, plus the poll, lottery and red
    /// envelope data the post HTML only marks the place of.
    func topic(id: Int) async throws -> TopicResponse {
        _ = try? await loadNodes()
        let detail: NLTopicDetail = try await get("api/v1/topics/\(id)", query: [URLQueryItem(name: "limit", value: "1")])
        state.store(posts: detail.posts, topicID: id)
        if detail.permissions?.moderate == true { state.topicModerators.insert(id) }
        let extras = await topicExtras(topicID: id, topic: detail.topic, posts: detail.posts)
        return try Self.shaped(DiscourseShape.topicResponse(
            detail, polls: extras.polls, lottery: extras.lottery, redEnvelope: extras.redEnvelope
        ))
    }

    /// The topic *and* the bytes to keep for next time (`TopicSnapshot`).
    ///
    /// On this backend the bytes are the adapter's output, not the server's
    /// own — the shaped object is what `TopicResponse` decodes. That still
    /// leaves one decoding path, which is the property the snapshot needs: a
    /// re-encoded model would be a second one, free to drift.
    func topicWithRaw(id: Int) async throws -> (response: TopicResponse, raw: Data) {
        _ = try? await loadNodes()
        let detail: NLTopicDetail = try await get("api/v1/topics/\(id)", query: [URLQueryItem(name: "limit", value: "1")])
        state.store(posts: detail.posts, topicID: id)
        if detail.permissions?.moderate == true { state.topicModerators.insert(id) }
        let extras = await topicExtras(topicID: id, topic: detail.topic, posts: detail.posts)
        let object = DiscourseShape.topicResponse(
            detail, polls: extras.polls, lottery: extras.lottery, redEnvelope: extras.redEnvelope
        )
        let raw = try JSONSerialization.data(withJSONObject: object)
        return (try Self.decodeTopic(raw), raw)
    }

    /// Decodes a snapshot's bytes back, so a cached topic and a fresh one go
    /// through exactly the same path.
    static func decodeTopic(_ data: Data) throws -> TopicResponse {
        try NodelocJSON.decode(TopicResponse.self, from: data)
    }

    /// The nested replies *and* their bytes, for the same snapshot reason as
    /// `topicWithRaw`: the reply list is a second request, and without it
    /// cached the reader still watched a skeleton on every visit.
    func nestedTopicWithRaw(
        id: Int,
        slug: String = "topic",
        sort: String,
        page: Int = 0
    ) async throws -> (response: NestedTopicResponse, raw: Data) {
        let object = try await nestedTopicObject(id: id, sort: sort, page: page)
        let raw = try JSONSerialization.data(withJSONObject: object)
        return (try Self.decodeNestedTopic(raw), raw)
    }

    static func decodeNestedTopic(_ data: Data) throws -> NestedTopicResponse {
        try NodelocJSON.decode(NestedTopicResponse.self, from: data)
    }

    /// Polls are marked in the HTML; lottery and red envelope come only when
    /// the topic says it has one.
    private func topicExtras(topicID: Int, topic: NLTopicDetail.Topic, posts: [NLPost]) async -> (polls: [Int: [NLPoll]], lottery: NLLottery?, redEnvelope: NLRedEnvelope?) {
        var polls: [Int: [NLPoll]] = [:]
        for post in posts where post.html.contains("class=\"poll\"") {
            if let list: NLPolls = try? await get("api/v1/posts/\(post.id)/polls") {
                polls[post.id] = list.polls
            }
        }
        var lottery: NLLottery?
        if topic.hasLottery ?? true, let first = posts.first(where: { $0.postNumber == 1 }) {
            lottery = (try? await get("api/v1/posts/\(first.id)/lottery") as NLLotteryEnvelope)?.lottery
        }
        var envelope: NLRedEnvelope?
        if topic.hasRedEnvelope ?? true {
            envelope = (try? await get("api/v1/topics/\(topicID)/red-envelope") as NLRedEnvelopeEnvelope)?.redEnvelope
        }
        return (polls, lottery, envelope)
    }

    private static func replySort(_ sort: String) -> String {
        switch sort {
        case "new", "latest", "newest": return "new"
        case "old", "oldest": return "old"
        default: return "best"
        }
    }

    /// The replies as a tree, a page of top-level replies at a time.
    func nestedTopic(id: Int, slug: String = "topic", sort: String, page: Int = 0) async throws -> NestedTopicResponse {
        try Self.shaped(try await nestedTopicObject(id: id, sort: sort, page: page))
    }

    /// The shaped reply tree before decoding, so the snapshot can keep the
    /// same bytes the decode runs on.
    private func nestedTopicObject(id: Int, sort: String, page: Int) async throws -> [String: Any] {
        let thread: NLThreadPage = try await get("api/v1/topics/\(id)/thread", query: [
            URLQueryItem(name: "sort", value: Self.replySort(sort)),
            URLQueryItem(name: "offset", value: String(page * Self.pageSize)),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ])
        let posts = thread.posts.filter { $0.postNumber > 1 }
        state.store(posts: posts, topicID: id)
        let canModerate = state.topicModerators.contains(id)
        // `/thread` has no `topic`, so the best answer and whether this reader
        // may accept one arrive at the top level.
        var object: [String: Any] = [
            "roots": DiscourseShape.nestedRoots(posts, canModerate: canModerate),
            "has_more_roots": thread.nextOffset != nil,
            "page": page,
            "sort": sort,
            "can_accept_answer": thread.canAccept ?? false,
        ]
        if let answer = thread.acceptedAnswer {
            object["accepted_answer"] = DiscourseShape.acceptedAnswer(answer)
        }
        return object
    }

    func nestedChildren(topicID: Int, postNumber: Int, slug: String = "topic", sort: String, page: Int = 0) async throws -> NestedChildrenResponse {
        var query = [
            URLQueryItem(name: "parent", value: String(postNumber)),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ]
        if page > 0, let after = state.cursor(list: "children:\(topicID):\(postNumber)", page: page) {
            query.append(URLQueryItem(name: "after", value: after))
        } else if page > 0 {
            return try Self.shaped(["children": [Any](), "has_more": false])
        }
        let thread: NLThreadPage = try await get("api/v1/topics/\(topicID)/thread", query: query)
        let posts = thread.posts.filter { $0.postNumber != postNumber }
        state.store(posts: posts, topicID: topicID)
        state.setCursor(thread.nextAfter.map(String.init), list: "children:\(topicID):\(postNumber)", page: page + 1)
        let canModerate = state.topicModerators.contains(topicID)
        return try Self.shaped([
            "children": DiscourseShape.nestedRoots(posts, canModerate: canModerate),
            "has_more": thread.nextAfter != nil,
            "page": page,
        ])
    }

    /// Posts by id. The backend serves posts with their topic, so ids not seen
    /// yet are found by reading the topic's newest pages.
    func topicPosts(topicID: Int, postIDs: [Int]) async throws -> TopicPostsResponse {
        var missing = postIDs.filter { state.post($0) == nil }
        if !missing.isEmpty {
            var after = 0
            for _ in 0..<20 where !missing.isEmpty {
                let detail: NLTopicDetail = try await get("api/v1/topics/\(topicID)", query: [
                    URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "50"),
                ])
                state.store(posts: detail.posts, topicID: topicID)
                if detail.permissions?.moderate == true { state.topicModerators.insert(topicID) }
                missing = missing.filter { state.post($0) == nil }
                guard let next = detail.nextAfter else { break }
                after = next
            }
        }
        let canModerate = state.topicModerators.contains(topicID)
        let posts = postIDs.compactMap { state.post($0) }.map { DiscourseShape.topicPost($0, canModerate: canModerate) }
        return try Self.shaped(["post_stream": ["posts": posts, "stream": postIDs]])
    }

    /// Re-reads a post's current state from the server.
    private func refreshPost(_ postID: Int) async {
        guard let topicID = state.topicID(forPost: postID), let post = state.post(postID) else { return }
        let after = max(post.postNumber - 1, 0)
        if let detail: NLTopicDetail = try? await get("api/v1/topics/\(topicID)", query: [
            URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "1"),
        ]) {
            state.store(posts: detail.posts, topicID: topicID)
        }
    }

    func postCooked(id: Int) async throws -> PostCookedResponse {
        await refreshPost(id)
        guard let post = state.post(id) else { throw Self.notFound() }
        return try Self.shaped(["cooked": NodelocMarkup.cooked(post.html)])
    }

    func postRaw(id: Int) async throws -> PostRawResponse {
        let raw: NLPostRaw = try await get("api/v1/posts/\(id)/raw")
        let cached = state.post(id)
        return try Self.shaped([
            "id": id,
            "raw": raw.raw,
            "topic_id": DiscourseShape.value(raw.topic?.id ?? state.topicID(forPost: id)),
            "post_number": DiscourseShape.value(cached?.postNumber),
            "can_edit": true,
        ])
    }

    func createTopic(title: String, raw: String, categoryID: Int) async throws -> CreatePostResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        let created: NLCreatedTopic = try await sendDecoding("POST", "api/v1/topics", json: [
            "node": slug, "title": title, "raw": raw,
        ])
        return try Self.shaped(["id": DiscourseShape.value(created.post?.id), "topic_id": created.topic.id, "post_number": 1])
    }

    func reply(topicID: Int, raw: String, replyToPostNumber: Int? = nil) async throws -> CreatePostResponse {
        var body: [String: Any] = ["raw": raw]
        if let replyToPostNumber, replyToPostNumber > 1 { body["reply_to_post_number"] = replyToPostNumber }
        let created: NLCreatedReply = try await sendDecoding("POST", "api/v1/topics/\(topicID)/posts", json: body)
        return try Self.shaped(["id": created.post.id, "topic_id": topicID, "post_number": created.post.postNumber])
    }

    func updatePost(id: Int, raw: String, editReason: String? = nil) async throws -> Data {
        var body: [String: Any] = ["raw": raw]
        if let editReason, !editReason.isEmpty { body["reason"] = editReason }
        let data = try await send("PATCH", "api/v1/posts/\(id)", json: body)
        await refreshPost(id)
        return data
    }

    /// Deletes a post. The three options only mean anything when a manager
    /// removes somebody else's work — the server ignores them for an author
    /// deleting their own — so they are sent only when one is given.
    ///
    /// - Parameters:
    ///   - reason: Up to 200 characters. Shows on the placeholder, in the
    ///     logs and in the notification to the author.
    ///   - notify: Whether the author hears about it. Defaults to true.
    ///   - appealable: Whether the author may contest it. Defaults to true.
    func deletePost(
        id: Int,
        reason: String? = nil,
        notify: Bool? = nil,
        appealable: Bool? = nil
    ) async throws -> Data {
        let body = Self.removalBody(reason: reason, notify: notify, appealable: appealable)
        return try await send("DELETE", "api/v1/posts/\(id)", json: body)
    }

    /// An empty body is the normal case and has to stay empty: this endpoint
    /// rejects unknown fields, and "no body at all" is what the web sends.
    private static func removalBody(reason: String?, notify: Bool?, appealable: Bool?) -> [String: Any]? {
        var body: [String: Any] = [:]
        if let reason, !reason.isEmpty { body["reason"] = reason }
        if let notify { body["notify"] = notify }
        if let appealable { body["appealable"] = appealable }
        return body.isEmpty ? nil : body
    }

    /// Hides a post, or brings it back. Hiding a first post hides the whole
    /// topic; the author is told and may appeal. Unhiding a post still in the
    /// queue releases it as approved.
    func setPostHidden(id: Int, hidden: Bool, reason: String? = nil) async throws {
        var body: [String: Any] = ["hidden": hidden]
        if hidden, let reason, !reason.isEmpty { body["reason"] = reason }
        try await send("PUT", "api/v1/posts/\(id)/hidden", json: body)
    }

    /// A post's edit history, oldest first. Shown to the author and to the
    /// post's managers; anyone else gets 403.
    func postRevisions(postID: Int) async throws -> [NLRevision] {
        let list: NLRevisionList = try await get("api/v1/posts/\(postID)/revisions")
        return list.revisions.sorted { $0.number < $1.number }
    }

    /// Rolls a post back to revision `n` from its edit history (1 is as first
    /// published), writing a new revision rather than erasing the ones since.
    /// 409 `same_content` when that revision is what's already there.
    @discardableResult
    func restoreRevision(postID: Int, number: Int) async throws -> Data {
        try await send("POST", "api/v1/posts/\(postID)/revisions/\(number)/restore")
    }

    /// The reasons a manager may pick from when removing something. Site
    /// settings, so they change without an app release; "其他" is appended by
    /// the server and always last.
    func moderationReasons() async throws -> [String] {
        let response: NLModerationReasons = try await get("api/v1/moderation/reasons")
        return response.reasons
    }

    func recoverPost(id: Int) async throws -> Data {
        try await send("POST", "api/v1/posts/\(id)/restore")
    }

    /// Title and node live on the first post's edit, which needs its body.
    func updateTopic(id: Int, title: String? = nil, categoryID: Int? = nil) async throws -> Data {
        var firstPostID = state.firstPostID(topicID: id)
        if firstPostID == nil {
            let detail: NLTopicDetail = try await get("api/v1/topics/\(id)", query: [URLQueryItem(name: "limit", value: "1")])
            state.store(posts: detail.posts, topicID: id)
            firstPostID = state.firstPostID(topicID: id)
        }
        guard let firstPostID else { throw Self.notFound() }
        let raw: NLPostRaw = try await get("api/v1/posts/\(firstPostID)/raw")
        var body: [String: Any] = ["raw": raw.raw]
        if let title, !title.isEmpty { body["title"] = title }
        if let categoryID { body["node"] = try await nodeSlug(categoryID: categoryID) }
        return try await send("PATCH", "api/v1/posts/\(firstPostID)", json: body)
    }

    func deleteTopic(
        id: Int,
        reason: String? = nil,
        notify: Bool? = nil,
        appealable: Bool? = nil
    ) async throws -> Data {
        let body = Self.removalBody(reason: reason, notify: notify, appealable: appealable)
        return try await send("DELETE", "api/v1/topics/\(id)", json: body)
    }

    func setTopicStatus(
        id: Int,
        status: String,
        enabled: Bool,
        until: Date? = nil
    ) async throws -> Data {
        switch status {
        case "closed":
            return try await send("PUT", "api/v1/topics/\(id)/state", json: ["closed": enabled])
        case "pinned", "pinned_globally":
            var body: [String: Any] = ["pinned": enabled]
            if enabled {
                if let until {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    body["pinned_until"] = formatter.string(from: until)
                } else {
                    body["pin_days"] = 0
                }
            }
            return try await send("PUT", "api/v1/topics/\(id)/state", json: body)
        default:
            throw DiscourseError.unsupported
        }
    }

    /// A per-reader "hide this pin" doesn't exist; pins are the moderators'.
    func clearTopicPin(id: Int) async throws -> Data { Self.ok }
    func reTopicPin(id: Int) async throws -> Data { Self.ok }
    func makeTopicBanner(id: Int) async throws -> Data { throw DiscourseError.unsupported }
    func removeTopicBanner(id: Int) async throws -> Data { throw DiscourseError.unsupported }

    func topicFeatureStats(categoryID: Int?) async throws -> TopicFeatureStats {
        try Self.shaped(["pinned_globally_count": 0, "banner_count": 0, "pinned_in_category_count": 0])
    }

    func togglePinnedPost(topicID: Int, slug: String = "topic", postID: Int) async throws -> PinnedPostsResponse {
        throw DiscourseError.unsupported
    }

    func repost(topicID: Int, categoryID: Int, title: String) async throws -> Data {
        let slug = try await nodeSlug(categoryID: categoryID)
        return try await send("POST", "api/v1/topics/\(topicID)/reposts", json: [
            "to": "node", "node": slug, "title": title, "comment": "",
        ])
    }

    /// Reading heartbeat. The server counts seconds itself and caps a beat at
    /// two minutes.
    func sendTopicTimings(topicID: Int, topicTimeMs: Int, timings: [Int: Int]) async throws -> Data {
        guard let furthest = timings.keys.max() else { return Self.ok }
        let seconds = min(max(topicTimeMs / 1000, 0), 120)
        return try await send("PUT", "api/v1/topics/\(topicID)/read", json: [
            "post_number": furthest, "seconds": seconds, "end": false,
        ])
    }

    // MARK: Votes, bookmarks, rewards, reports

    func castVote(
        postID: Int,
        direction: VoteDirection,
        reaction: String? = nil
    ) async throws -> Data {
        let value = direction == .up ? 1 : (direction == .down ? -1 : 0)
        var body: [String: Any] = ["value": value]
        if let reaction, !reaction.isEmpty { body["emoji"] = reaction }
        let data = try await send("PUT", "api/v1/posts/\(postID)/vote", json: body)
        if let result = try? NodelocJSON.decode(NLVoteResult.self, from: data) {
            state.update(post: postID) {
                $0.upvotes = result.upvotes
                $0.downvotes = result.downvotes
                $0.viewerVote = result.viewerVote
            }
        }
        return data
    }

    func likePost(id: Int) async throws {
        _ = try await castVote(postID: id, direction: .up)
    }

    func unlikePost(id: Int) async throws {
        _ = try await castVote(postID: id, direction: .none)
    }

    /// Accept a reply as the topic's best answer, or withdraw one. The server
    /// refuses with 422 for the cases the caller shouldn't offer anyway: the
    /// first post, the author's own reply, the reader's own reply, and
    /// replies that are deleted or hidden.
    @discardableResult
    func acceptAnswer(postID: Int, accepted: Bool = true) async throws -> Data {
        try await send("PUT", "api/v1/posts/\(postID)/accepted", json: ["accepted": accepted])
    }

    /// Who voted isn't public on the backend.
    func reactionUsers(postID: Int) async throws -> ReactionUsersResponse {
        try Self.shaped(["reaction_users": [Any]()])
    }

    func bookmark(postID: Int) async throws -> Data {
        let data = try await send("PUT", "api/v1/posts/\(postID)/bookmark")
        state.update(post: postID) { $0.bookmarked = true }
        return data
    }

    func removeBookmark(postID: Int) async throws -> Data {
        let data = try await send("DELETE", "api/v1/posts/\(postID)/bookmark")
        state.update(post: postID) { $0.bookmarked = false }
        return data
    }

    func giveReward(postID: Int, amount: Int, note: String? = nil) async throws -> Data {
        try await send("POST", "api/v1/posts/\(postID)/tips", json: ["amount": amount, "note": note ?? ""])
    }

    func flag(
        id: Int,
        typeID: Int,
        message: String? = nil,
        flagTopic: Bool = false
    ) async throws -> Data {
        var postID = id
        if flagTopic {
            if let first = state.firstPostID(topicID: id) {
                postID = first
            } else {
                let detail: NLTopicDetail = try await get("api/v1/topics/\(id)", query: [URLQueryItem(name: "limit", value: "1")])
                guard let first = detail.posts.first else { throw Self.notFound() }
                postID = first.id
            }
        }
        return try await send("POST", "api/v1/posts/\(postID)/reports", json: [
            "reason": NodelocReports.reason(forFlagType: typeID),
            "note": String((message ?? "").prefix(500)),
        ])
    }

    // MARK: Polls, lottery, red envelope

    private func poll(postID: Int, name: String) async throws -> NLPoll {
        let list: NLPolls = try await get("api/v1/posts/\(postID)/polls")
        guard let poll = list.polls.first(where: { $0.name == name }) ?? list.polls.first else { throw Self.notFound() }
        return poll
    }

    func votePoll(postID: Int, pollName: String, options: [String]) async throws -> PollVoteResponse {
        let poll = try await poll(postID: postID, name: pollName)
        let ids = options.compactMap(Int.init)
        let updated: NLPollEnvelope = try await sendDecoding("PUT", "api/v1/polls/\(poll.id)/votes", json: ["option_ids": ids])
        return try Self.shaped(["poll": DiscourseShape.poll(updated.poll), "vote": options])
    }

    func removePollVote(postID: Int, pollName: String) async throws -> PollVoteResponse {
        let poll = try await poll(postID: postID, name: pollName)
        let updated: NLPollEnvelope = try await sendDecoding("PUT", "api/v1/polls/\(poll.id)/votes", json: ["option_ids": [Int]()])
        return try Self.shaped(["poll": DiscourseShape.poll(updated.poll), "vote": [String]()])
    }

    func participateInLottery(
        lotteryID: Int,
        quantity: Int,
        isRandom: Bool
    ) async throws -> LotteryActionResponse {
        try await send("POST", "api/v1/lotteries/\(lotteryID)/tickets",
                       json: ["tickets": quantity, "random": isRandom],
                       headers: ["Idempotency-Key": UUID().uuidString])
        return try Self.shaped(["success": true])
    }

    func createRedEnvelope(topicID: Int, totalPoints: Int, totalCount: Int) async throws -> RedEnvelopeResponse {
        do {
            let created: NLRedEnvelopeEnvelope = try await sendDecoding("POST", "api/v1/topics/\(topicID)/red-envelope", json: [
                "total": totalPoints, "count": totalCount,
            ])
            return try Self.shaped(["success": true, "id": created.redEnvelope.topicId])
        } catch let error as DiscourseError {
            return try Self.shaped(["success": false, "error": error.errorDescription ?? ""])
        }
    }

    func createLottery(postID: Int, draft: LotteryDraft) async throws -> LotteryCreateResponse {
        let drawAt = draft.drawAt ?? Date().addingTimeInterval(86_400)
        let body: [String: Any] = [
            "title": draft.title,
            "draw_at": NLDate.format(drawAt),
            "min_tickets": 1,
            "max_tickets": draft.maxTicketsPerUser,
            "min_participants": draft.minParticipants,
            "max_participants": draft.parsedMaxParticipants ?? 0,
            "min_trust_level": draft.minTrustLevel,
            "prizes": draft.completeLevels.map { ["name": $0.name, "prize": $0.prize, "quantity": $0.quantity] as [String: Any] },
        ]
        do {
            let created: NLLotteryEnvelope = try await sendDecoding("POST", "api/v1/posts/\(postID)/lottery", json: body)
            return try Self.shaped(["success": true, "id": created.lottery.id])
        } catch let error as DiscourseError {
            return try Self.shaped(["success": false, "error": error.errorDescription ?? ""])
        }
    }

    // MARK: Search

    /// The server's search: posts (one per topic for the topic list), users,
    /// nodes. Users and nodes fall back to their own lookups on a server
    /// without it.
    func search(_ term: String, filters: String? = nil) async throws -> SearchResponse {
        _ = try? await loadNodes()
        var object: [String: Any] = [:]
        if let results: NLSearchResults = try? await get("api/v1/search", query: [URLQueryItem(name: "q", value: term)]) {
            var topics: [[String: Any]] = []
            var posts: [[String: Any]] = []
            var seenTopics = Set<Int>()
            for hit in results.posts ?? [] {
                if let author = hit.author { state.remember(username: author, id: hit.authorId) }
                if seenTopics.insert(hit.topicId).inserted {
                    var topic: [String: Any] = [
                        "id": hit.topicId,
                        "title": DiscourseFormat.plainText(hit.topicTitle ?? ""),
                        "slug": "topic",
                        "posts_count": (hit.replyCount ?? 0) + 1,
                        "created_at": DiscourseShape.time(hit.createdAt),
                    ]
                    if let slug = hit.nodeSlug { topic["category_id"] = state.nodeID(forSlug: slug) }
                    topics.append(topic)
                }
                posts.append([
                    "id": hit.id,
                    "topic_id": hit.topicId,
                    "blurb": DiscourseFormat.plainText(hit.folded == true ? "" : (hit.blurb ?? hit.excerpt ?? "")),
                    "username": DiscourseShape.value(hit.author),
                    "avatar_template": DiscourseShape.avatar(nil, username: hit.author),
                    "like_count": DiscourseShape.value(hit.upvotes),
                    "created_at": DiscourseShape.time(hit.createdAt),
                    "post_number": DiscourseShape.value(hit.postNumber),
                ])
            }
            object["topics"] = topics
            object["posts"] = posts
            if let users = results.users {
                object["users"] = users.map { DiscourseShape.user(username: $0.username, name: $0.name, avatar: $0.avatar) }
            }
            if let nodes = results.nodes {
                object["categories"] = nodes.map { node -> [String: Any] in
                    ["id": state.nodeID(forSlug: node.slug), "name": node.name, "slug": node.slug,
                     "color": DiscourseShape.value(node.color), "description": DiscourseShape.value(node.description),
                     "member_count": DiscourseShape.value(node.memberCount), "is_joined": node.joined ?? false]
                }
            }
        }
        if object["users"] == nil, auth.isAuthenticated,
           let users: NLMentionCandidates = try? await get("api/v1/mention-candidates", query: [URLQueryItem(name: "q", value: term)]) {
            object["users"] = users.users.map { DiscourseShape.user(username: $0.username, name: $0.name, avatar: $0.avatar) }
        }
        if object["categories"] == nil,
           let nodes: NLNodeList = try? await get("api/v1/nodes", query: [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "10")]) {
            object["categories"] = nodes.nodes.map { DiscourseShape.category($0) }
        }
        return try Self.shaped(object)
    }

    func searchTags(term: String, limit: Int = 5) async throws -> TagSearchResponse {
        let tags: NLTags = try await get("api/v1/tags", query: [
            URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 30))),
        ])
        return try Self.shaped(["results": tags.tags.map { tag -> [String: Any] in
            ["id": tag.id ?? 0, "name": tag.name, "text": tag.label ?? tag.name, "slug": tag.name, "count": tag.topicCount ?? 0]
        }])
    }

    func searchUsers(term: String) async throws -> UserSearchResponse {
        let users: NLMentionCandidates = try await get("api/v1/mention-candidates", query: [URLQueryItem(name: "q", value: term)])
        return try Self.shaped(["users": users.users.map { DiscourseShape.user(username: $0.username, name: $0.name, avatar: $0.avatar) }])
    }

    // MARK: Users

    func user(_ username: String) async throws -> UserResponse {
        let profile: NLUserProfile = try await get("api/v1/users/\(Self.pathEscape(username))")
        state.remember(username: profile.user.username, id: profile.user.id, avatar: profile.user.avatarUrl)
        var avatar = profile.user.avatarUrl
        var object = DiscourseShape.userProfile(profile, avatar: nil)
        if isMe(profile.user.username) {
            if avatar == nil { avatar = state.myAvatar }
            // Your own profile carries your block list, as Discourse's did.
            if let blocks: NLFollowList = try? await get("api/v1/me/blocks"), var user = object["user"] as? [String: Any] {
                user["ignored_usernames"] = blocks.users.map(\.username)
                user["can_ignore_users"] = true
                user["can_mute_users"] = true
                object["user"] = user
            }
        }
        if var user = object["user"] as? [String: Any] {
            user["avatar_template"] = DiscourseShape.value(avatar ?? state.avatar(for: username))
            object["user"] = user
        }
        return try Self.shaped(object)
    }

    func userSummary(_ username: String) async throws -> UserSummaryResponse {
        let profile: NLUserProfile = try await get("api/v1/users/\(Self.pathEscape(username))")
        let stats = profile.stats
        return try Self.shaped([
            "user_summary": [
                "likes_received": DiscourseShape.value(stats?.votesReceived),
                "days_visited": DiscourseShape.value(stats?.daysVisited),
                "topic_count": DiscourseShape.value(stats?.topicCount),
                "post_count": DiscourseShape.value(stats?.postCount),
            ] as [String: Any],
            "badges": [Any](),
        ])
    }

    func follow(username: String) async throws {
        try await send("PUT", "api/v1/users/\(Self.pathEscape(username))/follow")
    }

    func unfollow(username: String) async throws {
        try await send("DELETE", "api/v1/users/\(Self.pathEscape(username))/follow")
    }

    /// Ignore and mute both map to blocking, the one per-user control the
    /// backend has.
    func setUserNotificationLevel(
        username: String,
        level: String,
        expiringAt: Date? = nil
    ) async throws -> Data {
        let path = "api/v1/users/\(Self.pathEscape(username))/block"
        return try await send(level == "normal" ? "DELETE" : "PUT", path)
    }

    func userBadges(username: String) async throws -> UserBadgesResponse {
        let achievements: NLAchievements = try await get("api/v1/users/\(Self.pathEscape(username))/achievements")
        return try Self.shaped(["badges": achievements.showcase.enumerated().map { index, item -> [String: Any] in
            ["id": index + 1, "name": item.name ?? item.key, "description": DiscourseShape.value(item.description)]
        }])
    }

    /// No level-up checklist on the backend.
    func upgradeProgress(username: String) async throws -> UpgradeProgressReport {
        throw DiscourseError.unsupported
    }

    /// The single-response profile is a Discourse plugin; `FeatureFlags`
    /// keeps the app on the individual calls.
    func profileAggregate(
        username: String?,
        activityFilter: Int
    ) async throws -> (data: Data, response: ProfileAggregateResponse) {
        throw DiscourseError.unsupported
    }

    static func decodeProfileAggregate(_ data: Data) -> ProfileAggregateResponse? {
        try? NodelocJSON.decode(ProfileAggregateResponse.self, from: data)
    }

    static func decodeChatChannels(_ data: Data) throws -> ChatChannelsResponse {
        try NodelocJSON.decode(ChatChannelsResponse.self, from: data)
    }

    /// One page of a profile tab; a shorter page is the end of the list.
    static let userActionsPageSize = 30

    /// Profile activity tabs, by Discourse's filter codes: 4 topics, 5
    /// replies, 3 the reader's own saved posts. Likes aren't listed by the
    /// backend. `offset` is how many rows the screen already has.
    func userActions(
        username: String,
        filter: Int,
        offset: Int = 0
    ) async throws -> UserActionsResponse {
        let user = Self.pathEscape(username)
        let listKey = "activity:\(username.lowercased()):\(filter)"
        var query = [URLQueryItem(name: "limit", value: String(Self.userActionsPageSize))]
        if offset > 0 {
            guard let cursor = state.cursor(list: listKey, page: offset) else {
                return try Self.shaped(["user_actions": [Any]()])
            }
            query.append(URLQueryItem(name: filter == 3 ? "offset" : "cursor", value: cursor))
        }
        var items: [[String: Any]] = []
        switch filter {
        case 4:
            _ = try? await loadNodes()
            let page: NLTopicPage = try await get("api/v1/users/\(user)/topics", query: query)
            state.setCursor(page.nextCursor, list: listKey, page: offset + page.topics.count)
            items = page.topics.map { topic in
                [
                    "action_type": 4,
                    "title": topic.title,
                    "excerpt": DiscourseShape.value(topic.excerpt),
                    "created_at": DiscourseShape.time(topic.createdAt),
                    "username": topic.author,
                    "avatar_template": DiscourseShape.avatar(topic.authorAvatar, username: topic.author),
                    "category_id": state.nodeID(forSlug: topic.nodeSlug),
                    "topic_id": topic.id,
                    "post_number": 1,
                    "post_id": DiscourseShape.value(topic.firstPostId),
                ]
            }
        case 5:
            _ = try? await loadNodes()
            let page: NLUserPosts = try await get("api/v1/users/\(user)/posts", query: query)
            state.setCursor(page.nextCursor, list: listKey, page: offset + page.posts.count)
            items = page.posts.map { post in
                var item: [String: Any] = [
                    "action_type": 5,
                    "title": DiscourseShape.value(post.topicTitle),
                    "excerpt": DiscourseShape.value(post.excerpt ?? post.html.map { NodelocMarkup.excerpt($0) }),
                    "created_at": DiscourseShape.time(post.createdAt),
                    "username": username,
                    "avatar_template": DiscourseShape.avatar(nil, username: username),
                    "topic_id": post.topicId,
                    "post_number": post.postNumber,
                    "post_id": post.id,
                ]
                if let slug = post.nodeSlug { item["category_id"] = state.nodeID(forSlug: slug) }
                return item
            }
        case 3 where isMe(username):
            let page = try await saved(offset: offset)
            state.setCursor(page.nextOffset.map(String.init), list: listKey, page: offset + page.bookmarks.count)
            items = page.bookmarks.map { item in
                var row: [String: Any] = [
                    "action_type": 3,
                    "title": DiscourseShape.value(item.topicTitle),
                    "excerpt": DiscourseShape.value(item.excerpt),
                    "created_at": DiscourseShape.time(item.createdAt),
                    "username": DiscourseShape.value(item.author),
                    "avatar_template": DiscourseShape.avatar(nil, username: item.author),
                    "topic_id": item.topicId,
                    "post_number": item.postNumber,
                    "post_id": item.postId,
                ]
                if let slug = item.nodeSlug { row["category_id"] = state.nodeID(forSlug: slug) }
                return row
            }
        default:
            break
        }
        return try Self.shaped(["user_actions": items])
    }

    // MARK: Saved posts

    func bookmarkFolders() async throws -> NLBookmarkFolders {
        try await get("api/v1/bookmark-folders")
    }

    /// Saved posts, newest first. `folder` is a folder id, "none" for
    /// unfiled, or nil for all.
    func saved(folder: String? = nil, offset: Int = 0, limit: Int = 30) async throws -> NLSaved {
        var query = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let folder { query.append(URLQueryItem(name: "folder", value: folder)) }
        return try await get("api/v1/saved", query: query)
    }

    // MARK: Points

    func checkIn() async throws -> CheckinResponse {
        do {
            let result: NLCheckinResult = try await sendDecoding("POST", "api/v1/checkin")
            return try Self.shaped(["success": true, "points": result.points, "user_date": DiscourseShape.value(result.day)])
        } catch let error as DiscourseError where error.statusCode == 409 || error.statusCode == 403 {
            return try Self.shaped(["success": false, "message": error.errorDescription ?? ""])
        }
    }

    func checkinState() async throws -> NLCheckinState {
        try await get("api/v1/checkin")
    }

    /// Only the reader's own ledger is visible.
    func pointsHistory(username: String, page: Int = 0) async throws -> PointsHistoryResponse {
        guard isMe(username) else { throw DiscourseError.unsupported }
        var query = [URLQueryItem(name: "limit", value: "30")]
        if page > 0 {
            guard let before = state.cursor(list: "points", page: page) else {
                return try Self.shaped(["points_history": [Any](), "page": page, "has_more": false])
            }
            query.append(URLQueryItem(name: "before", value: before))
        }
        let history: NLPointsHistory = try await get("api/v1/points/history", query: query)
        state.setCursor(history.nextBefore.map(String.init), list: "points", page: page + 1)
        return try Self.shaped([
            "points_history": history.entries.map { entry -> [String: Any] in
                [
                    "date": DiscourseShape.time(entry.createdAt),
                    "points": abs(entry.amount),
                    "description": entry.memo ?? entry.ref?.label ?? NodelocReports.pointsKindLabel(entry.kind),
                    "created_at": DiscourseShape.time(entry.createdAt),
                    "is_positive": entry.amount >= 0,
                ]
            },
            "page": page,
            "has_more": history.nextBefore != nil,
        ])
    }

    func pointsTotal(username: String) async throws -> PointsScoresResponse {
        guard isMe(username) else { throw DiscourseError.unsupported }
        let balance: NLPointsBalance = try await get("api/v1/points")
        return try Self.shaped(["total_scores": balance.balance])
    }

    // MARK: Apps

    /// The apps directory is served under `/apps` in Discourse's own shape.
    func appsDirectory() async throws -> [DirectoryApp] {
        try await appsDirectoryPages().apps
    }

    /// The whole directory, plus the category's featured app. `featured` comes
    /// from the first page only — it describes the category, not the page.
    func appsDirectoryPages(kind: String? = nil) async throws -> (apps: [DirectoryApp], featured: DirectoryApp?) {
        var apps: [DirectoryApp] = []
        var featured: DirectoryApp?
        for page in 0..<20 {
            var query = [URLQueryItem(name: "page", value: String(page))]
            if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
            let data = try await http.send("GET", "apps/directory", query: query)
            let response = try NodelocJSON.decode(AppsDirectoryResponse.self, from: data)
            if page == 0 { featured = response.featured }
            apps.append(contentsOf: response.apps)
            if response.apps.isEmpty || apps.count >= (response.total ?? 0) { break }
        }
        return (apps, featured)
    }

    func app(slug: String) async throws -> DirectoryAppResponse {
        let data = try await http.send("GET", "apps/\(Self.pathEscape(slug))")
        return try NodelocJSON.decode(DirectoryAppResponse.self, from: data)
    }

    func appWebviewURL(installID: Int) -> URL {
        http.url("apps/installs/\(installID)/webview")
    }

    func customGroupStyles() async throws -> [CustomGroupStyleItem] { [] }
    func customBadgeStyles() async throws -> [CustomBadgeStyleItem] { [] }

    // MARK: Current user

    func currentUser() async throws -> CurrentUserResponse {
        let me: NLUserEnvelope = try await get("api/v1/me")
        state.me = me.user
        auth.userID = me.user.id
        auth.isStaff = me.user.isStaff
        let avatar = me.user.avatarUrl.flatMap { $0.isEmpty ? nil : $0 }
        state.myAvatar = avatar
        state.remember(username: me.user.username, id: me.user.id, avatar: avatar)
        let notifications = try? await get("api/v1/notifications", query: [URLQueryItem(name: "limit", value: "1")]) as NLNotifications
        let chat = try? await get("api/v1/chat/unread") as NLUnread
        let balance = try? await get("api/v1/points") as NLPointsBalance
        return try Self.shaped(DiscourseShape.currentUser(
            me.user,
            avatar: avatar,
            unreadNotifications: notifications?.unread ?? 0,
            unreadMessages: chat?.unreadCount ?? 0,
            balance: balance?.balance
        ))
    }

    func checkUsername(_ username: String) async throws -> UsernameCheckResponse {
        do {
            let _: NLUsernameCheck = try await get("api/v1/auth/username-check", query: [URLQueryItem(name: "username", value: username)])
            return try Self.shaped(["available": true])
        } catch let error as DiscourseError where error.statusCode == 409 {
            return try Self.shaped(["available": false])
        }
    }

    func resendActivationEmail(username: String) async throws -> Data {
        guard username.contains("@") else { throw DiscourseError.unsupported }
        return try await send("POST", "api/v1/auth/verify-email/resend", json: ["email": username])
    }

    func requestPasswordReset(login: String) async throws -> Data {
        guard login.contains("@") else {
            throw DiscourseError.badResponse(422, message: AppString("请输入注册时用的邮箱地址"), code: "invalid")
        }
        return try await send("POST", "api/v1/auth/password-reset", json: ["email": login])
    }

    /// Discourse took a form of `user_option` keys; the backend's settings are
    /// a different set, so these stay local to the device.
    func updatePreferences(username: String, items: [(String, String)]) async throws -> Data {
        Self.ok
    }

    /// Profile fields. The backend replaces name, bio, website and location
    /// together, so the current values fill whatever wasn't edited.
    func updateProfile(username: String, items: [(String, String)]) async throws -> Data {
        var fields = Dictionary(items, uniquingKeysWith: { _, last in last })
        if let url = fields.removeValue(forKey: "card_background_upload_url")
            ?? fields.removeValue(forKey: "profile_background_upload_url") {
            if url.isEmpty {
                try await send("DELETE", "api/v1/me/cover")
            } else if let upload = state.uploadID(forURL: url) {
                try await send("PUT", "api/v1/me/cover", json: ["upload_id": upload])
            }
        }
        if let locale = fields.removeValue(forKey: "locale") {
            _ = try? await send("POST", "api/v1/locale", json: ["locale": locale.replacingOccurrences(of: "_", with: "-")])
        }
        let profileKeys: Set<String> = ["name", "bio_raw", "website", "location"]
        guard !fields.keys.filter({ profileKeys.contains($0) }).isEmpty else { return Self.ok }
        let me: NLUserEnvelope = try await get("api/v1/me")
        let body: [String: Any] = [
            "name": fields["name"] ?? me.user.name ?? "",
            "bio": fields["bio_raw"] ?? me.user.bioRaw ?? "",
            "website": fields["website"] ?? me.user.website ?? "",
            "location": fields["location"] ?? me.user.location ?? "",
        ]
        return try await send("PUT", "api/v1/me", json: body)
    }

    func uploadUserImage(data: Data, fileName: String, mimeType: String, type: String) async throws -> DiscourseUpload {
        try await upload(data: data, fileName: fileName, mimeType: mimeType)
    }

    func pickAvatar(username: String, uploadID: Int, type: String = "uploaded") async throws -> Data {
        let data = try await send("PUT", "api/v1/me/avatar", json: ["upload_id": uploadID])
        if let url = state.upload(uploadID)?.url { state.myAvatar = url }
        return data
    }

    func accountDetail(username: String) async throws -> AccountDetail {
        let identities = try? await get("api/v1/me/identities") as NLIdentities
        let sessions = try? await get("api/v1/me/sessions") as NLSessions
        let twoFactor = try? await get("api/v1/me/two-factor") as NLTwoFactorState
        return try Self.shaped(["user": [
            "associated_accounts": (identities?.identities ?? []).filter(\.linked).map { identity -> [String: Any] in
                ["name": identity.provider, "description": identity.email ?? identity.name ?? identity.label ?? identity.provider]
            },
            "user_auth_tokens": (sessions?.sessions ?? []).map { session -> [String: Any] in
                [
                    "id": session.id,
                    "client_name": DiscourseShape.value(session.userAgent),
                    "device_name": DiscourseShape.value(session.ip),
                    "seen_at": DiscourseShape.time(session.lastSeenAt),
                    "is_active": session.current ?? false,
                ]
            },
            "second_factor_enabled": twoFactor?.enabled ?? false,
        ] as [String: Any]])
    }

    func revokeAssociatedAccount(username: String, provider: String) async throws -> Data {
        try await send("DELETE", "api/v1/me/identities/\(Self.pathEscape(provider))")
    }

    func revokeAuthToken(username: String, tokenID: Int?) async throws -> Data {
        if let tokenID {
            return try await send("DELETE", "api/v1/me/sessions/\(tokenID)")
        }
        return try await send("DELETE", "api/v1/me/sessions")
    }

    /// Sensitive changes need a recent password confirmation.
    func trustedSession() async throws -> SessionTrustResponse {
        try Self.shaped(["failed": "FAILED"])
    }

    func confirmSession(password: String) async throws -> SessionTrustResponse {
        do {
            try await send("POST", "api/v1/me/reauth", json: ["password": password])
            return try Self.shaped(["success": "OK"])
        } catch let error as DiscourseError where error.statusCode == 422 {
            return try Self.shaped(["failed": "FAILED", "error": error.errorDescription ?? ""])
        }
    }

    func listSecondFactors() async throws -> SecondFactorsResponse {
        let state: NLTwoFactorState = try await get("api/v1/me/two-factor")
        return try Self.shaped(["totps": state.enabled ? [["id": 1, "name": "TOTP"] as [String: Any]] : [Any]()])
    }

    func createTOTP() async throws -> TOTPCreateResponse {
        let setup: NLTwoFactorSetup = try await sendDecoding("POST", "api/v1/me/two-factor")
        return try Self.shaped(["key": setup.secret, "qr": DiscourseShape.value(setup.uri)])
    }

    func enableTOTP(token: String, name: String) async throws -> Data {
        try await send("PUT", "api/v1/me/two-factor", json: ["code": token])
    }

    /// Turning 2FA off and new backup codes both need a current code; the
    /// screens that offer them pass it through these.
    func disableSecondFactor(code: String) async throws -> Data {
        try await send("DELETE", "api/v1/me/two-factor", json: ["code": code])
    }

    func disableSecondFactor() async throws -> Data {
        throw DiscourseError.badResponse(422, message: AppString("请在网页版的账号安全设置中关闭两步验证"), code: "code_required")
    }

    func generateBackupCodes(code: String) async throws -> BackupCodesResponse {
        let codes: NLBackupCodes = try await sendDecoding("POST", "api/v1/me/two-factor/backup-codes", json: ["code": code])
        return try Self.shaped(["backup_codes": codes.backupCodes])
    }

    func generateBackupCodes() async throws -> BackupCodesResponse {
        try Self.shaped(["error": AppString("请在网页版的账号安全设置中重新生成备用码")])
    }

    /// Self-deletion needs the password (social-only accounts send their
    /// username, as the server specifies).
    func deleteAccount(username: String, password: String) async throws -> Data {
        try await send("POST", "api/v1/me/deletion", json: ["password": password])
    }

    func deleteAccount(username: String) async throws -> Data {
        try await deleteAccount(username: username, password: username)
    }

    func featureFlags() async throws -> FeatureFlagConfig {
        let flags: NLMobileFlags = try await get("api/v1/mobile/flags", query: [
            URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "build", value: String(DiscourseConfig.appBuild)),
        ])
        return try Self.shaped([
            "mini_apps_enabled": flags.flags["mini_apps"] ?? flags.flags["mini_apps_enabled"] ?? true,
            "lottery_enabled": flags.flags["lottery"] ?? flags.flags["lottery_enabled"] ?? true,
            "profile_aggregate": false,
        ])
    }

    /// The 小尾巴 (posting-device line) isn't kept by the backend.
    func postSourceLevel() async throws -> PostSourceLevelResponse { throw DiscourseError.unsupported }
    func setPostSourceLevel(_ level: Int) async throws -> PostSourceLevelResponse { throw DiscourseError.unsupported }
    func clearPostSourceHistory() async throws -> ClearPostSourcesResponse { throw DiscourseError.unsupported }

    /// Release check for the update prompt.
    func releaseCheck() async throws -> NLRelease {
        try await get("api/v1/mobile/update", query: [
            URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "build", value: String(DiscourseConfig.appBuild)),
        ])
    }

    // MARK: Push devices

    /// Registers this device's APNs token for the signed-in account.
    func registerPushDevice(token: String) async throws {
        try await send("POST", "api/v1/mobile/devices", json: [
            "platform": "ios",
            "push_token": token,
            "app_build": DiscourseConfig.appBuild,
            "name": DeviceName.current,
        ])
    }

    func unregisterPushDevice(token: String) async throws {
        try await send("POST", "api/v1/mobile/devices/unregister", json: ["push_token": token])
    }

    // MARK: Notifications

    /// - Parameter filter: `moderation` narrows to the queue's own alerts —
    ///   new reports, held posts, appeals, backlog. Only someone with review
    ///   permission or who manages a node receives any, so the tab is worth
    ///   offering only to them.
    func notifications(filter: String? = nil) async throws -> NotificationsResponse {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        let list: NLNotifications = try await get("api/v1/notifications", query: query)
        return try Self.shaped(["notifications": list.notifications.map(DiscourseShape.notification)])
    }

    func markNotificationsRead() async throws -> Data {
        try await send("POST", "api/v1/notifications/read", json: [:])
    }

    func markNotificationRead(id: Int) async throws -> Data {
        try await send("POST", "api/v1/notifications/read", json: ["id": id])
    }

    /// Private messages are chat conversations on the backend; the topic-style
    /// inbox has nothing in it.
    func privateMessages(username: String) async throws -> PrivateMessagesResponse {
        try Self.shaped(["users": [Any](), "topic_list": ["topics": [Any]()]])
    }

    func groupPrivateMessages(username: String, group: String) async throws -> PrivateMessagesResponse {
        try await privateMessages(username: username)
    }

    /// "Send a private message" starts (or continues) a direct conversation.
    func createPrivateMessage(recipient: String, title: String, raw: String) async throws -> CreatePostResponse {
        let text = title.isEmpty ? raw : "**\(title)**\n\n\(raw)"
        let sent: NLChatMessageEnvelope = try await sendDecoding("POST", "api/v1/messages/\(Self.pathEscape(recipient))", json: ["raw": text])
        return try Self.shaped(["id": sent.message.id])
    }

    // MARK: Chat

    func chatChannels() async throws -> ChatChannelsResponse {
        try await chatChannelsWithRaw().response
    }

    func chatChannelsWithRaw() async throws -> (response: ChatChannelsResponse, raw: Data) {
        let overview: NLChatOverview = try await get("api/v1/chat")
        let data = NodelocJSON.data(DiscourseShape.chatChannels(overview))
        return (try NodelocJSON.decode(ChatChannelsResponse.self, from: data), data)
    }

    private enum ChatTarget {
        case direct(username: String, conversationID: Int?)
        case room(id: Int)

        var messagesPath: String {
            switch self {
            case .direct(let username, _): return "api/v1/messages/\(DiscourseClient.pathEscape(username))"
            case .room(let id): return "api/v1/chat/channels/\(id)/messages"
            }
        }
    }

    private func chatTarget(_ channelID: Int) async throws -> ChatTarget {
        if let username = state.pendingDirectUsername(channelID) {
            // Kept for the life of the screen that opened it, so it keeps
            // working after the first message created the real conversation.
            return .direct(username: username, conversationID: state.directConversation(with: username)?.id)
        }
        if state.conversations[channelID] == nil {
            _ = try await chatChannelsWithRaw()
        }
        guard let conversation = state.conversations[channelID] else { throw Self.notFound() }
        if conversation.kind == .direct, let username = conversation.username {
            return .direct(username: username, conversationID: channelID)
        }
        return .room(id: channelID)
    }

    func chatMessages(channelID: Int, pageSize: Int = 50, targetMessageID: Int? = nil) async throws -> ChatMessagesResponse {
        try await chatMessagesWithRaw(channelID: channelID, pageSize: pageSize, targetMessageID: targetMessageID).response
    }

    /// The newest page, or the page ending at `targetMessageID` (how the
    /// transcript scrolls back).
    func chatMessagesWithRaw(
        channelID: Int,
        pageSize: Int = 50,
        targetMessageID: Int? = nil
    ) async throws -> (response: ChatMessagesResponse, raw: Data) {
        let target = try await chatTarget(channelID)
        var query = [URLQueryItem(name: "limit", value: String(min(max(pageSize, 1), 100)))]
        if let targetMessageID { query.append(URLQueryItem(name: "before", value: String(targetMessageID + 1))) }
        let page: NLChatPage = try await get(target.messagesPath, query: query)
        let data = NodelocJSON.data(DiscourseShape.chatMessages(page, channelID: channelID))
        return (try NodelocJSON.decode(ChatMessagesResponse.self, from: data), data)
    }

    /// Messages newer than `afterID`, oldest first, without moving the read
    /// marker — what a live update fetches.
    func chatMessages(channelID: Int, after afterID: Int) async throws -> ChatMessagesResponse {
        let target = try await chatTarget(channelID)
        let page: NLChatPage = try await get(target.messagesPath, query: [
            URLQueryItem(name: "after", value: String(afterID)), URLQueryItem(name: "read", value: "0"),
        ])
        return try Self.shaped(DiscourseShape.chatMessages(page, channelID: channelID))
    }

    func createChatMessage(
        channelID: Int,
        message: String,
        threadID: Int? = nil,
        inReplyToID: Int? = nil,
        uploadIDs: [Int] = []
    ) async throws -> ChatCreateMessageResponse {
        let target = try await chatTarget(channelID)
        // Images travel inline: one message per picture, as the web sends them.
        var bodies: [String] = uploadIDs.compactMap { id in state.upload(id).map { "![](\($0.url))" } }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { bodies.insert(text, at: 0) }
        var lastID: Int?
        for (index, raw) in bodies.enumerated() {
            var body: [String: Any] = ["raw": raw]
            if index == 0, let inReplyToID { body["reply_to"] = inReplyToID }
            let sent: NLChatMessageEnvelope = try await sendDecoding("POST", target.messagesPath, json: body)
            lastID = sent.message.id
        }
        if case .direct(let username, nil) = target {
            // The first message created the conversation; learn its id.
            _ = try? await chatChannelsWithRaw()
            _ = username
        }
        return try Self.shaped(["success": "OK", "message_id": DiscourseShape.value(lastID)])
    }

    func uploadChatMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        try await upload(data: data, fileName: fileName, mimeType: mimeType)
    }

    func markChatChannelRead(channelID: Int, messageID: Int) async throws -> Data {
        guard let conversation = state.serverConversationID(channelID), messageID > 0 else { return Self.ok }
        return try await send("PUT", "api/v1/chat/conversations/\(conversation)/read", json: ["message_id": messageID])
    }

    func chatChannel(id: Int) async throws -> ChatChannelResponse {
        if let username = state.pendingDirectUsername(id) {
            return try Self.shaped(["channel": DiscourseShape.directChannel(id: id, with: username, avatar: nil, last: nil, unread: 0, muted: false)])
        }
        let (_, raw) = try await chatChannelsWithRaw()
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Self.notFound() }
        let all = (object["direct_message_channels"] as? [[String: Any]] ?? [])
            + (object["public_channels"] as? [[String: Any]] ?? [])
        guard let channel = all.first(where: { ($0["id"] as? Int) == id }) else { throw Self.notFound() }
        return try Self.shaped(["channel": channel])
    }

    func updateChatChannelNotifications(
        id: Int,
        muted: Bool? = nil,
        notificationLevel: String? = nil
    ) async throws -> ChatMembershipResponse {
        let mute = muted ?? (notificationLevel == "never")
        guard let conversation = state.serverConversationID(id) else { throw DiscourseError.unsupported }
        try await send(mute ? "PUT" : "DELETE", "api/v1/chat/conversations/\(conversation)/mute")
        return try Self.shaped(["membership": [
            "muted": mute, "following": true, "notification_level": mute ? "never" : "always",
        ] as [String: Any]])
    }

    /// Leaves a channel or group.
    func unfollowChatChannel(id: Int) async throws -> Data {
        try await send("DELETE", "api/v1/chat/channels/\(id)/membership")
    }

    func joinChatChannel(id: Int) async throws -> Data {
        try await send("PUT", "api/v1/chat/channels/\(id)/membership")
    }

    /// Reading the newest page of a conversation marks it read.
    func markAllChatChannelsRead() async throws -> Data {
        let overview: NLChatOverview = try await get("api/v1/chat")
        for channel in overview.channels where (channel.unreadCount ?? 0) > 0 && channel.joined == true {
            _ = try? await http.send("GET", "api/v1/chat/channels/\(channel.id)/messages", query: [URLQueryItem(name: "limit", value: "1")])
        }
        for group in overview.groups where (group.unreadCount ?? 0) > 0 {
            _ = try? await http.send("GET", "api/v1/chat/channels/\(group.id)/messages", query: [URLQueryItem(name: "limit", value: "1")])
        }
        for direct in overview.directs where (direct.unreadCount ?? 0) > 0 {
            _ = try? await http.send("GET", "api/v1/messages/\(Self.pathEscape(direct.with))", query: [URLQueryItem(name: "limit", value: "1")])
        }
        return Self.ok
    }

    /// One person: their direct conversation (created by the first message).
    /// Several: a group chat.
    func createDirectMessageChannel(usernames: [String]) async throws -> ChatChannelResponse {
        let others = usernames.filter { $0.lowercased() != auth.username?.lowercased() }
        if others.count <= 1, let username = others.first {
            if state.directConversation(with: username) == nil { _ = try? await chatChannelsWithRaw() }
            if let existing = state.directConversation(with: username) {
                return try await chatChannel(id: existing.id)
            }
            let id = state.pendingDirectID(for: username)
            return try Self.shaped(["channel": DiscourseShape.directChannel(id: id, with: username, avatar: nil, last: nil, unread: 0, muted: false)])
        }
        let created: NLCreatedGroup = try await sendDecoding("POST", "api/v1/chat/groups", json: ["name": "", "usernames": others])
        _ = try await chatChannelsWithRaw()
        return try await chatChannel(id: created.group.id)
    }

    func deleteChatMessage(channelID: Int, messageID: Int) async throws -> Data {
        try await send("DELETE", "api/v1/chat/messages/\(messageID)")
    }

    func addUsersToChatChannel(channelID: Int, usernames: [String]) async throws -> Data {
        try await send("POST", "api/v1/chat/groups/\(channelID)/members", json: ["usernames": usernames])
    }

    func removeUserFromChatChannel(channelID: Int, userID: Int) async throws -> Data {
        guard let username = state.username(forID: userID) else { throw Self.notFound() }
        return try await send("DELETE", "api/v1/chat/groups/\(channelID)/members/\(Self.pathEscape(username))")
    }

    func chatChannelMemberships(
        channelID: Int,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> ChatMembershipsResponse {
        let target = try await chatTarget(channelID)
        switch target {
        case .direct(let username, _):
            var users = [DiscourseShape.chatUser(username)]
            if let me = auth.username { users.insert(DiscourseShape.chatUser(me), at: 0) }
            return try Self.shaped(["memberships": users.map { ["user": $0] }, "meta": ["total_rows": users.count]])
        case .room(let id):
            guard state.conversations[id]?.kind == .group else {
                return try Self.shaped(["memberships": [Any](), "meta": ["total_rows": 0]])
            }
            let members: NLChatGroupMembers = try await get("api/v1/chat/groups/\(id)/members")
            let users = members.members.map { DiscourseShape.chatUser($0.username, avatar: $0.avatar) }
            return try Self.shaped(["memberships": users.map { ["user": $0] }, "meta": ["total_rows": users.count]])
        }
    }

    // Chat features the backend doesn't have. The screens hide their entry
    // points (`NodelocFeatures`); these keep any stray call harmless.
    func chatSearch(query: String, limit: Int = 20, offset: Int = 0, sort: String = "latest", excludeThreads: Bool = false) async throws -> ChatSearchResponse {
        try Self.shaped(["messages": [Any](), "meta": ["has_more": false]])
    }
    func chatThreads(channelID: Int, limit: Int = 10, offset: Int = 0) async throws -> ChatThreadsResponse {
        try Self.shaped(["threads": [Any]()])
    }
    func currentUserChatThreads(limit: Int = 10, offset: Int = 0) async throws -> ChatThreadsResponse {
        try Self.shaped(["threads": [Any]()])
    }
    func chatThreadMessages(channelID: Int, threadID: Int, pageSize: Int = 50, targetMessageID: Int? = nil) async throws -> ChatMessagesResponse {
        try Self.shaped(["messages": [Any]()])
    }
    func reactToChatMessage(channelID: Int, messageID: Int, emoji: String, add: Bool) async throws -> Data { throw DiscourseError.unsupported }
    func updateChatMessage(channelID: Int, messageID: Int, message: String) async throws -> Data { throw DiscourseError.unsupported }
    func restoreChatMessage(channelID: Int, messageID: Int) async throws -> Data { throw DiscourseError.unsupported }
    func flagChatMessage(channelID: Int, messageID: Int, flagTypeID: Int, message: String? = nil) async throws -> Data { throw DiscourseError.unsupported }
    func chatChannelPins(channelID: Int) async throws -> ChatPinsResponse { try Self.shaped(["pinned_messages": [Any]()]) }
    func pinChatMessage(channelID: Int, messageID: Int) async throws -> Data { throw DiscourseError.unsupported }
    func unpinChatMessage(channelID: Int, messageID: Int) async throws -> Data { throw DiscourseError.unsupported }
    func markChatPinsRead(channelID: Int) async throws -> Data { Self.ok }
    func saveChatDraft(channelID: Int, threadID: Int? = nil, message: String) async throws -> Data { Self.ok }
    func chatTranscript(channelID: Int, messageIDs: [Int]) async throws -> ChatTranscriptResponse { throw DiscourseError.unsupported }
    func setChatThreadNotificationLevel(channelID: Int, threadID: Int, level: String) async throws -> Data { Self.ok }

    // MARK: Uploads and media

    func upload(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        let response = try await http.send("POST", "api/v1/uploads", body: .multipart(
            fields: [:],
            file: MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
        ))
        let envelope = try NodelocJSON.decode(NLUploadEnvelope.self, from: response)
        return try Self.shaped(DiscourseShape.upload(envelope.upload))
    }

    func uploadComposerMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        if mimeType.hasPrefix("video/") {
            let response = try await http.send("POST", "api/v1/videos", body: .multipart(
                fields: [:],
                file: MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
            ))
            let video = try NodelocJSON.decode(NLVideoEnvelope.self, from: response).video
            // The composer inserts `url`; for a video that is the embed marker.
            return try Self.shaped([
                "id": abs(Int(truncatingIfNeeded: StableHash.fnv1a(video.sha1))) % 1_000_000_000,
                "url": "[video id=\(video.sha1)]",
                "original_filename": fileName,
                "width": DiscourseShape.value(video.width),
                "height": DiscourseShape.value(video.height),
                "extension": "mp4",
            ])
        }
        return try await upload(data: data, fileName: fileName, mimeType: mimeType)
    }

    /// The server makes its own poster frame.
    func uploadVideoPoster(data: Data, videoSHA1: String) async throws -> DiscourseUpload {
        throw DiscourseError.unsupported
    }

    func anyVideo(sha1: String) async throws -> AnyVideoResponse {
        let video: NLVideoEnvelope = try await get("api/v1/videos/\(sha1)")
        return try Self.shaped([
            "status": video.video.status,
            "thumbnail_url": DiscourseShape.value(video.video.posterUrl),
            "duration_seconds": DiscourseShape.value(video.video.duration),
            "width": DiscourseShape.value(video.video.width),
            "height": DiscourseShape.value(video.video.height),
            "hls_url": DiscourseShape.value(video.video.hlsUrl),
        ])
    }

    func videoSuggestions(excludingTopicID: Int? = nil) async throws -> VideoSuggestionsResponse {
        try Self.shaped(["topics": [Any]()])
    }

    /// Site emoji, grouped by pack. Standard emoji are typed as characters.
    func emojis() async throws -> [String: [DiscourseEmoji]] {
        let response: NLEmojis = try await get("api/v1/emojis")
        var groups: [String: [DiscourseEmoji]] = [:]
        for pack in response.packs ?? [] where pack.enabled != false {
            let name = pack.name ?? AppString("站点表情")
            groups[name, default: []].append(contentsOf: pack.emojis.map {
                DiscourseEmoji(name: $0.code, url: $0.url, group: name, tonable: nil, createdBy: nil, searchAliases: $0.name.map { [$0] })
            })
        }
        if groups.isEmpty, let flat = response.emojis {
            groups[AppString("站点表情")] = flat.keys.sorted().map {
                DiscourseEmoji(name: $0, url: flat[$0], group: nil, tonable: nil, createdBy: nil, searchAliases: nil)
            }
        }
        return groups
    }

    func klipySearch(query: String, pos: String? = nil) async throws -> KlipySearchResponse {
        var components = URLComponents(string: "https://api.klipy.com/api/v1/\(DiscourseConfig.klipyAPIKey)/gifs/search")!
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "24")]
        if let pos { items.append(URLQueryItem(name: "page", value: pos)) }
        components.queryItems = items
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try NodelocJSON.decode(KlipySearchResponse.self, from: data)
    }

    // MARK: Native sign-in

    /// Sign in with Apple: the identity token is exchanged for a session.
    func nativeAppleLogin(_ credential: AppleSignInCredential) async throws -> Data {
        var body: [String: Any] = [
            "identity_token": credential.identityToken,
            "nonce": credential.nonce,
        ]
        if let code = credential.authorizationCode { body["authorization_code"] = code }
        if let name = credential.fullName, !name.isEmpty { body["name"] = name }
        return try await send("POST", NodelocAuthPaths.appleExchange, json: body)
    }

    // MARK: Utilities

    func avatarURL(template: String, size: Int = 120) -> URL? {
        let path = template.replacingOccurrences(of: "{size}", with: String(size))
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    private func isMe(_ username: String) -> Bool {
        username.lowercased() == auth.username?.lowercased()
    }

    nonisolated static func pathEscape(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
