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
import SwiftUI
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

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await http.send("GET", path, query: query)
        return try NodelocJSON.decode(T.self, from: data)
    }

    @discardableResult
    func send(_ method: String, _ path: String, json: [String: Any]? = nil, query: [URLQueryItem] = [], headers: [String: String] = [:]) async throws -> Data {
        try await http.send(method, path, query: query, body: json.map { .json($0) } ?? .none, headers: headers)
    }

    private func sendDecoding<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> T {
        let data = try await send(method, path, json: json, headers: headers)
        return try NodelocJSON.decode(T.self, from: data)
    }

    static func shaped<T: Decodable>(_ object: Any) throws -> T {
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
        // `/api/v1/nodes` is the full directory (~160 KB) and has been seen
        // taking 10–30 s to answer. Everything that maps a node slug waits on
        // it — the home feed sat on its skeleton that whole time — so a stale
        // copy (this session's, or the last launch's from disk) is used at
        // once and the refresh happens behind it.
        if !force {
            // ~160 KB of JSON: read and decoded off the main thread.
            if state.allNodes.isEmpty,
               let cached = await Task.detached(priority: .userInitiated, operation: { NodeDirectoryDiskCache.load() }).value,
               state.allNodes.isEmpty {
                state.seed(nodes: cached)
            }
            if !state.allNodes.isEmpty {
                refreshNodesInBackground()
                return state.allNodes
            }
        }
        return try await fetchNodes()
    }

    private func fetchNodes() async throws -> [NLNode] {
        // Several callers can miss the cache at once on a first launch; they
        // share one download of the directory.
        if let running = NodelocAdapterState.nodesFetch {
            return try await running.value
        }
        let client = self
        let task = Task { try await client.fetchNodesNow() }
        NodelocAdapterState.nodesFetch = task
        defer { NodelocAdapterState.nodesFetch = nil }
        return try await task.value
    }

    private func fetchNodesNow() async throws -> [NLNode] {
        let data = try await http.send("GET", "api/v1/nodes")
        // Decoding the full directory and writing it to disk took the main
        // thread for most of a second at launch, holding up every other
        // response (the first feed page among them).
        let list = try await Task.detached(priority: .userInitiated) { () throws -> NLNodeList in
            let list = try NodelocJSON.decode(NLNodeList.self, from: data)
            NodeDirectoryDiskCache.save(data)
            return list
        }.value
        state.store(nodes: list.nodes)
        // Joined/muted state: awaited only the first time (roles and bells
        // are shaped from it); a refresh updates it behind the directory.
        if state.myNodes.isEmpty {
            await loadMyNodes()
        } else {
            let client = self
            Task { await client.loadMyNodes() }
        }
        return list.nodes
    }

    private func refreshNodesInBackground() {
        guard !state.isRefreshingNodes else { return }
        state.isRefreshingNodes = true
        let client = self
        Task {
            _ = try? await client.fetchNodes()
            NodelocAdapterState.shared.isRefreshingNodes = false
        }
    }

    /// The reader's relation to nodes, as the server has it, and the shared
    /// state updated from it.
    func myNodes() async throws -> NLMyNodes {
        let mine: NLMyNodes = try await get("api/v1/me/nodes")
        state.myNodes = Dictionary(mine.joined.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        state.mutedNodes = Set(mine.muted ?? [])
        state.favoriteNodes = (mine.favorites ?? []).map(\.slug)
        return mine
    }

    /// 收藏 / 取消收藏 a node (`PUT` / `DELETE /api/v1/nodes/{slug}/favorite`).
    @discardableResult
    func setNodeFavorite(slug: String, favorite: Bool) async throws -> Data {
        let path = "api/v1/nodes/\(Self.pathEscape(slug))/favorite"
        return favorite ? try await send("PUT", path) : try await send("DELETE", path)
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
        // Decoded off the main thread: a page of topics is the biggest
        // routine answer, and decoding it on main was the hitch each time a
        // feed loaded its next page.
        let result = try await Self.decodeTopicPage(try await http.send("GET", path, query: query))
        state.setCursor(result.nextCursor, list: key, page: page + 1)
        return result
    }

    @concurrent
    nonisolated private static func decodeTopicPage(_ data: Data) async throws -> NLTopicPage {
        try NodelocJSON.decode(NLTopicPage.self, from: data)
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
        case .following:
            // The joined nodes only; cursor-paged like latest.
            result = try await topicPage(
                list: "following", page: page,
                query: [URLQueryItem(name: "joined", value: "1")]
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

    /// `GET /api/v1/search?type=tags`: tags whose name matches.
    func searchTags(_ term: String) async throws -> [SearchTagResult] {
        struct Envelope: Decodable {
            struct Tag: Decodable { let name: String; let label: String?; let topicCount: Int? }
            let tags: [Tag]?
        }
        let found: Envelope = try await get("api/v1/search", query: [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "type", value: "tags"),
        ])
        return (found.tags ?? []).map { SearchTagResult(name: $0.name, label: $0.label ?? $0.name, topicCount: $0.topicCount ?? 0) }
    }

    /// The author's own topics (`GET /api/v1/users/{u}/topics`), newest first,
    /// for the reader's 同一作者.
    func authorTopics(username: String, limit: Int = 20) async throws -> LatestResponse {
        let page: NLTopicPage = try await get(
            "api/v1/users/\(Self.pathEscape(username))/topics",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return try Self.shaped(DiscourseShape.latest(page.topics, hasMore: false))
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
        notify: Bool = true,
        onConflict: String? = nil
    ) async throws -> Data {
        // The server reads `kind` and `days` (0 is permanent); `type` and
        // `hours` were never fields and were refused as unknown.
        var body: [String: Any] = ["kind": type, "reason": reason, "notify": notify]
        body["days"] = hours.map { max(0, $0 / 24) } ?? 0
        if deleteRecentHours > 0 { body["delete_recent_hours"] = min(deleteRecentHours, 720) }
        if let onConflict { body["on_conflict"] = onConflict }
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
        deleteRecentHours: Int = 0,
        onConflict: String? = nil
    ) async throws -> Data {
        var body: [String: Any] = ["username": username, "kind": type, "reason": reason]
        if let days { body["days"] = days }
        if deleteRecentHours > 0 { body["delete_recent_hours"] = min(deleteRecentHours, 720) }
        if let onConflict { body["on_conflict"] = onConflict }
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

    /// The penalties of an account that can't sign in (login said 403
    /// `suspended`), with the same username and password. 401 wrong password,
    /// 409 `not_suspended`, 10 an hour per address.
    func lookupRestrictions(login: String, password: String) async throws -> [NLRestrictions.Restriction] {
        let response: NLRestrictions = try await sendDecoding(
            "POST", "api/v1/restrictions/lookup", json: ["login": login, "password": password]
        )
        return response.restrictions
    }

    /// Appeals a penalty with the account's username and password, for an
    /// account that can't sign in.
    @discardableResult
    func appealRestriction(
        login: String,
        password: String,
        kind: String,
        id: Int,
        reason: AppealReason,
        text: String
    ) async throws -> NLRestrictions.Appeal {
        let response: NLAppealEnvelope = try await sendDecoding(
            "POST", "api/v1/restrictions/\(kind)/\(id)/appeal",
            json: ["login": login, "password": password, "reason": reason.rawValue, "text": text]
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
            list: "node:\(slug):\(sort == "featured" ? "featured" : (scoped ?? "latest"))",
            page: page,
            // 精华 is a filter on the latest list (`featured=1`), not a sort.
            query: [URLQueryItem(name: "node", value: slug)] + Self.sortQuery(scoped)
                + (sort == "featured" ? [URLQueryItem(name: "featured", value: "1")] : []),
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
        // Independent calls: asked for together rather than one after the other.
        async let providersCall = try? authProviders()
        async let tiersCall: NLTiers? = try? get("api/v1/tiers")
        if let providers = await providersCall {
            object["auth_providers"] = providers.map { ["name": $0.name, "custom_url": DiscourseShape.value($0.url)] as [String: Any] }
        }
        if let tiers = await tiersCall {
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
        state.setJoined(slug: slug, joined: true)
        state.invalidateNodes()
        await loadMyNodes()
        return try Self.shaped(["success": true, "joined": true])
    }

    func leaveNode(categoryID: Int) async throws -> NodeMembershipResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        try await send("DELETE", "api/v1/nodes/\(slug)/membership")
        state.setJoined(slug: slug, joined: false)
        state.invalidateNodes()
        await loadMyNodes()
        return try Self.shaped(["success": true, "joined": false])
    }

    /// The sections a new node may go under, out of `candidates` (slugs):
    /// `GET /api/v1/node-parents` lists only sections with `open_for_nodes`
    /// (all of them for node admins). It answers at most 10 rows, so when the
    /// first page is full each section it didn't name is asked for by slug.
    func createNodeParentSlugs(candidates: [String]) async throws -> Set<String> {
        struct Options: Decodable {
            struct Option: Decodable { let slug: String }
            let nodes: [Option]
        }
        let first: Options = try await get("api/v1/node-parents")
        var open = Set(first.nodes.map { $0.slug.lowercased() })
        guard first.nodes.count >= 10 else { return open }
        let rest = candidates.filter { !open.contains($0.lowercased()) }
        for slug in rest {
            let page: Options? = try? await get("api/v1/node-parents", query: [URLQueryItem(name: "q", value: slug)])
            if page?.nodes.contains(where: { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }) == true {
                open.insert(slug.lowercased())
            }
        }
        return open
    }

    func setCategoryNotification(categoryID: Int, level: Int) async throws -> Data {
        let slug = try await nodeSlug(categoryID: categoryID)
        let data = try await send("PUT", "api/v1/nodes/\(slug)/notification", json: ["level": DiscourseShape.nodeLevel(fromDiscourse: level)])
        await loadMyNodes()
        return data
    }

    /// `DELETE /api/v1/nodes/{slug}/block`. The bell's 免打扰 *is* this block
    /// on the v1 backend, so lifting it leaves the member's earlier level.
    func unblockNode(slug: String) async throws {
        try await send("DELETE", "api/v1/nodes/\(Self.pathEscape(slug))/block")
        await loadMyNodes()
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

    /// The drawer's node list (the nodes the reader joined), plus what the
    /// node directory reads: the biggest nodes as `recommended` and one
    /// bucket per section as `grouped`. Without those two the directory fell
    /// back to its built-in sample nodes, whose made-up member counts
    /// ("3.5k") disagreed with the node page's real one.
    func sidebarNodes() async throws -> SidebarCommunitiesResponse {
        let nodes = try await loadNodes()
        let mine = nodes.filter { ($0.joined == true || state.myNodes[$0.slug] != nil) && $0.parentId != nil }
        let leaves = nodes.filter { $0.parentId != nil }
        let recommended = leaves
            .sorted { ($0.memberCount ?? 0) > ($1.memberCount ?? 0) }
            .prefix(8)
        var grouped: [String: Any] = [:]
        for section in nodes where section.parentId == nil {
            let count = leaves.filter { $0.parentId == section.id }.count
            guard count > 0 else { continue }
            grouped[String(section.id)] = [
                "category": DiscourseShape.category(section),
                "total_count": count,
                "has_more": count > 4,
            ] as [String: Any]
        }
        return try Self.shaped([
            "communities": mine.map { DiscourseShape.category($0, isMine: $0.ownerId == state.me?.id) },
            "recommended": recommended.map { DiscourseShape.category($0) },
            "grouped": grouped,
        ])
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

    /// `GET /api/v1/nodes?page=1&limit=100`: the first page of the directory
    /// (every section, then nodes section by section), which answers in under
    /// a second where the full list has taken 10–30 s. The nodes tab draws
    /// its first screen from it on a launch with no cached directory. Shaped
    /// like `categories(includeSubcategories: true)`; not folded into the
    /// cached directory, which would then look complete when it isn't.
    func nodeDirectoryFirstPage() async throws -> CategoriesResponse {
        let page: NLNodeList = try await get("api/v1/nodes", query: [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: "100"),
        ])
        let categories = page.nodes.filter { $0.parentId == nil }.map { section in
            DiscourseShape.category(section, children: page.nodes.filter { $0.parentId == section.id })
        }
        return try Self.shaped(["category_list": ["categories": categories]])
    }

    /// `GET /api/v1/nodes?q=…&limit=…`: the server's node search (name, slug
    /// and description, best match first), sections left out.
    func searchNodes(term: String, limit: Int = 30) async throws -> [DiscourseCategory] {
        let page: NLNodeList = try await get("api/v1/nodes", query: [
            URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: SidebarCommunitiesResponse = try Self.shaped([
            "communities": page.nodes.filter { $0.parentId != nil }.map { DiscourseShape.category($0) },
        ])
        return response.communities ?? []
    }

    /// Waits out a directory refresh that `loadNodes` started behind a stale
    /// copy (rather than asking `/api/v1/nodes` a second time) and says
    /// whether the directory is fresh now.
    func awaitNodesRefresh() async -> Bool {
        var waited = 0
        while state.isRefreshingNodes, waited < 600, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        return state.nodesFresh
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
        parentCategoryID: Int,
        visibility: String? = nil,
        topicPolicy: String? = nil,
        rules: [(title: String, description: String)] = []
    ) async throws -> CreateCommunityResponse {
        let parent = try await nodeSlug(categoryID: parentCategoryID)
        var body: [String: Any] = [
            "parent": parent,
            "slug": slug,
            "name": name,
            "description": description,
            "color": colorHex ?? "",
            "open_for_nodes": false,
        ]
        // Optional; left out, the server keeps its defaults (public, anyone).
        if let visibility { body["visibility"] = visibility }
        if let topicPolicy { body["topic_policy"] = topicPolicy }
        if !rules.isEmpty {
            body["rules"] = rules.map { ["title": $0.title, "description": $0.description] }
        }
        let created: NLNodeEnvelope = try await sendDecoding("POST", "api/v1/nodes", json: body)
        state.merge(node: created.node)
        state.invalidateNodes()
        return try Self.shaped(["category": DiscourseShape.category(created.node, isMine: true)])
    }

    /// What the reader may do and how far (`GET /api/v1/me/permissions`):
    /// `nodes.create`, and limits such as `nodes.max_owned` (-1 = unlimited).
    func myPermissions() async throws -> NLMyPermissions {
        try await get("api/v1/me/permissions")
    }

    // MARK: Custom feeds

    func customFeeds() async throws -> CustomFeedsResponse {
        let list: NLCustomFeeds = try await get("api/v1/custom-feeds")
        // The list is the reader's own feeds, and its items are summaries
        // (id, name, color, public, node_count): no `owner`, no `mine`. The
        // sidebar keys a feed by its owner, so every row was dropped — the
        // reader's feeds never showed. Fill both in from who is asking.
        let me = auth.username
        return try Self.shaped(["custom_feeds": list.feeds.map { feed -> DiscourseShape.Object in
            var object = DiscourseShape.customFeed(feed)
            if feed.owner == nil, let me { object["username"] = me }
            if feed.mine == nil { object["can_edit"] = true }
            return object
        }])
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
        page: Int = 0,
        sort: String = "hot"
    ) async throws -> CategoryTopicsResponse {
        // `hot` pages by offset, `new` by cursor (feed.md).
        let result = try await topicPage(
            list: "feed:\(slug):\(sort)", page: page,
            query: [URLQueryItem(name: "sort", value: sort)],
            path: "api/v1/custom-feeds/\(slug)/topics", offsetPaged: sort == "hot"
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
        // Polls, the lottery and the red envelope are independent calls that
        // all hold up the reader; they used to go out one after another.
        let pollPosts = posts.filter { $0.html.contains("class=\"poll\"") }.map(\.id)
        let lotteryPostID = (topic.hasLottery ?? true)
            ? posts.first(where: { $0.postNumber == 1 })?.id
            : nil
        let wantsEnvelope = topic.hasRedEnvelope ?? true

        async let lotteryCall: NLLottery? = {
            guard let lotteryPostID else { return nil }
            return (try? await get("api/v1/posts/\(lotteryPostID)/lottery") as NLLotteryEnvelope)?.lottery
        }()
        async let envelopeCall: NLRedEnvelope? = {
            guard wantsEnvelope else { return nil }
            return (try? await get("api/v1/topics/\(topicID)/red-envelope") as NLRedEnvelopeEnvelope)?.redEnvelope
        }()

        var polls: [Int: [NLPoll]] = [:]
        await withTaskGroup(of: (Int, [NLPoll]?).self) { group in
            for postID in pollPosts {
                group.addTask {
                    let list: NLPolls? = try? await self.get("api/v1/posts/\(postID)/polls")
                    return (postID, list?.polls)
                }
            }
            for await (postID, list) in group {
                if let list { polls[postID] = list }
            }
        }
        return (polls, await lotteryCall, await envelopeCall)
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

    func createTopic(title: String, raw: String, categoryID: Int, tags: [String] = [], draftKey: String? = nil) async throws -> CreatePostResponse {
        let slug = try await nodeSlug(categoryID: categoryID)
        var body: [String: Any] = ["node": slug, "title": title, "raw": raw]
        if !tags.isEmpty { body["tags"] = tags }
        // A draft continued from 草稿箱: the server deletes it once posted.
        if let draftKey { body["draft_key"] = draftKey }
        let created: NLCreatedTopic = try await sendDecoding("POST", "api/v1/topics", json: body)
        return try Self.shaped(["id": DiscourseShape.value(created.post?.id), "topic_id": created.topic.id, "post_number": 1, "held": created.held ?? false])
    }

    func reply(topicID: Int, raw: String, replyToPostNumber: Int? = nil) async throws -> CreatePostResponse {
        var body: [String: Any] = ["raw": raw]
        if let replyToPostNumber, replyToPostNumber > 1 { body["reply_to_post_number"] = replyToPostNumber }
        let created: NLCreatedReply = try await sendDecoding("POST", "api/v1/topics/\(topicID)/posts", json: body)
        return try Self.shaped(["id": created.post.id, "topic_id": topicID, "post_number": created.post.postNumber, "held": created.held ?? false])
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
        try await moderationReasonList().map(\.value)
    }

    /// The same list with its keys, labels and which one is 「其他」.
    func moderationReasonList() async throws -> [NLReason] {
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

    /// `pollID`, when the caller has it, saves looking the poll up first.
    func votePoll(postID: Int, pollName: String, options: [String], pollID: Int? = nil) async throws -> PollVoteResponse {
        let id: Int
        if let pollID { id = pollID } else { id = try await poll(postID: postID, name: pollName).id }
        let ids = options.compactMap(Int.init)
        let updated: NLPollEnvelope = try await sendDecoding("PUT", "api/v1/polls/\(id)/votes", json: ["option_ids": ids])
        return try Self.shaped(["poll": DiscourseShape.poll(updated.poll), "vote": options])
    }

    func removePollVote(postID: Int, pollName: String, pollID: Int? = nil) async throws -> PollVoteResponse {
        let id: Int
        if let pollID { id = pollID } else { id = try await poll(postID: postID, name: pollName).id }
        let updated: NLPollEnvelope = try await sendDecoding("PUT", "api/v1/polls/\(id)/votes", json: ["option_ids": [Int]()])
        return try Self.shaped(["poll": DiscourseShape.poll(updated.poll), "vote": [String]()])
    }

    func participateInLottery(
        lotteryID: Int,
        quantity: Int,
        isRandom: Bool
    ) async throws -> LotteryActionResponse {
        // `{"tickets": n}` is the viewer's total after the purchase.
        let data = try await send("POST", "api/v1/lotteries/\(lotteryID)/tickets",
                                  json: ["tickets": quantity, "random": isRandom],
                                  headers: ["Idempotency-Key": UUID().uuidString])
        let total = (try? NodelocJSON.decode(NLLotteryTickets.self, from: data))?.tickets
        return try Self.shaped(["success": true, "tickets": DiscourseShape.value(total)])
    }

    /// `GET /api/v1/posts/{id}/lottery` on its own, for a refresh after buying.
    func lottery(postID: Int, isOwner: Bool) async throws -> PostLottery {
        let envelope: NLLotteryEnvelope = try await get("api/v1/posts/\(postID)/lottery")
        return try Self.shaped(DiscourseShape.lottery(envelope.lottery, isOwner: isOwner))
    }

    /// `GET /api/v1/lotteries/{id}/participants` — everyone, most tickets first.
    func lotteryParticipants(lotteryID: Int) async throws -> LotteryParticipantsResponse {
        let list: NLLotteryParticipants = try await get("api/v1/lotteries/\(lotteryID)/participants")
        return try Self.shaped([
            "participants": list.participants.map { holder -> [String: Any] in
                [
                    "username": holder.username,
                    "avatar_template": DiscourseShape.value(holder.avatarUrl),
                    "tickets": DiscourseShape.value(holder.tickets),
                    "joined_at": DiscourseShape.time(holder.joinedAt),
                ]
            },
            "participant_count": DiscourseShape.value(list.participantCount),
            "ticket_count": DiscourseShape.value(list.ticketCount),
        ])
    }

    /// `DELETE /api/v1/lotteries/{id}` — admins only; closes it and refunds
    /// every ticket.
    func cancelLottery(lotteryID: Int) async throws {
        try await send("DELETE", "api/v1/lotteries/\(lotteryID)")
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
            "min_tickets": draft.minTicketsPerUser,
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
    func search(_ term: String, filters: String? = nil, sort: String? = nil) async throws -> SearchResponse {
        _ = try? await loadNodes()
        var object: [String: Any] = [:]
        // The node page seeds the field with "#slug ". The backend scopes by
        // the `node` parameter, not by text, so lift the prefix into it.
        var queryTerm = term
        var queryItems: [URLQueryItem] = []
        if term.hasPrefix("#"), let space = term.firstIndex(of: " ") {
            let slug = String(term[term.index(after: term.startIndex)..<space])
            let rest = String(term[space...]).trimmingCharacters(in: .whitespaces)
            // The backend refuses an empty q, so "#slug" alone stays as typed.
            if !slug.isEmpty, !rest.isEmpty {
                queryItems.append(URLQueryItem(name: "node", value: slug))
                queryTerm = rest
            }
        }
        queryItems.insert(URLQueryItem(name: "q", value: queryTerm), at: 0)
        if let sort { queryItems.append(URLQueryItem(name: "sort", value: sort)) }
        if let results: NLSearchResults = try? await get("api/v1/search", query: queryItems) {
            // The matched words, kept apart from the plain titles every other
            // screen uses (see `SearchHighlight`).
            var highlights: [Int: SearchHighlight.Marked] = [:]
            for hit in results.posts ?? [] where highlights[hit.topicId] == nil {
                highlights[hit.topicId] = SearchHighlight.Marked(
                    title: hit.titleHtml.map(SearchHighlight.marked),
                    blurb: hit.folded == true ? nil : hit.blurb.map(SearchHighlight.marked)
                )
            }
            SearchHighlight.latest = highlights
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
                    // The topic list carries these; the replies list doesn't.
                    "vote_score": DiscourseShape.value(topic.voteScore),
                    "reply_count": DiscourseShape.value(topic.replyCount),
                    "image_url": DiscourseShape.value(topic.imageUrl),
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
        // Three independent counts: asked for together, not one by one.
        async let notificationsCall = try? get("api/v1/notifications", query: [URLQueryItem(name: "limit", value: "1")]) as NLNotifications
        async let chatCall = try? get("api/v1/chat/unread") as NLUnread
        async let balanceCall = try? get("api/v1/points") as NLPointsBalance
        let (notifications, chat, balance) = await (notificationsCall, chatCall, balanceCall)
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

    /// `PUT /api/v1/auth/password-reset` `{token, password}` — the token from
    /// the emailed link (one hour, single use). Doesn't sign in.
    func resetPassword(token: String, password: String) async throws {
        _ = try await send("PUT", "api/v1/auth/password-reset", json: ["token": token, "password": password])
    }

    /// `POST /api/v1/auth/password-reset` `{email, captcha}` → 204, always
    /// "sent" once the captcha passes, registered or not.
    func requestPasswordReset(email: String, captcha: String?) async throws {
        var body: [String: Any] = ["email": email]
        if let captcha, !captcha.isEmpty { body["captcha"] = captcha }
        _ = try await send("POST", "api/v1/auth/password-reset", json: body)
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

    /// `GET /api/v1/me/groups` — the groups whose 头衔 you may wear.
    func myGroups() async throws -> NLMyGroups {
        try await get("api/v1/me/groups")
    }

    /// `PUT /api/v1/me/primary-group {"group_id": n}` → 204; 0 wears none.
    func setPrimaryGroup(_ groupID: Int) async throws {
        try await send("PUT", "api/v1/me/primary-group", json: ["group_id": groupID])
    }

    /// `POST /api/v1/me/deletion {"password": …}` → 204. `password` is the
    /// current password, or the username for an account without one
    /// (`/me/account` `has_password == false`). 422 wrong secret, 403 staff.
    @discardableResult
    func deleteAccount(password: String) async throws -> Data {
        try await send("POST", "api/v1/me/deletion", json: ["password": password])
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
    ///
    /// An array, not a dictionary keyed by pack name: the server lists packs in
    /// the order the admin arranged them, and the pickers show them that way.
    func emojis() async throws -> [EmojiPack] {
        let response: NLEmojis = try await get("api/v1/emojis")
        var packs: [EmojiPack] = []
        for pack in response.packs ?? [] where pack.enabled != false {
            let name = pack.name ?? AppString("站点表情")
            let emojis = pack.emojis.map {
                DiscourseEmoji(name: $0.code, url: $0.url, group: name, tonable: nil, createdBy: nil, searchAliases: $0.name.map { [$0] })
            }
            // Two packs sharing a display name still read as one group.
            if let index = packs.firstIndex(where: { $0.name == name }) {
                packs[index] = EmojiPack(name: name, emojis: packs[index].emojis + emojis)
            } else {
                packs.append(EmojiPack(name: name, emojis: emojis))
            }
        }
        if packs.isEmpty, let flat = response.emojis {
            packs = [EmojiPack(name: AppString("站点表情"), emojis: flat.keys.sorted().map {
                DiscourseEmoji(name: $0, url: flat[$0], group: nil, tonable: nil, createdBy: nil, searchAliases: nil)
            })]
        }
        return packs
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

// MARK: - Node access, channels, drafts
//
// First written from the design before the API spec was available; now
// matched to the backend: node/manage_handlers.go (access),
// channel/handlers.go (channels) and content/handlers.go (drafts).

extension DiscourseClient {
    // Node access list

    /// The list and the groups the viewer may put on it. Owner or site staff
    /// only; a node category has no list (400 `not_joinable`).
    func nodeAccess(slug: String) async throws -> NLNodeAccess {
        try await get("api/v1/nodes/\(Self.pathEscape(slug))/access")
    }

    /// Replaces the whole list; answers 204, so read it back with `nodeAccess`.
    func updateNodeAccess(slug: String, entries: [NLNodeAccess.Entry]) async throws {
        try await send(
            "PUT", "api/v1/nodes/\(Self.pathEscape(slug))/access",
            json: ["entries": entries.map { ["subject": $0.subject, "level": $0.level] as [String: Any] }]
        )
    }

    // Node channels

    func nodeChannels(slug: String) async throws -> [NLNodeChannels.Channel] {
        let answer: NLNodeChannels = try await get("api/v1/nodes/\(Self.pathEscape(slug))/channels")
        return answer.channels
    }

    /// `kind` is `rss`, `youtube`, `telegram` or `bilibili`; `source` is a
    /// link (or @name / UID) the server inspects before saving — a source it
    /// can't read is 422 `channel_problem`.
    @discardableResult
    func addNodeChannel(slug: String, kind: String, source: String) async throws -> Data {
        try await send("POST", "api/v1/nodes/\(Self.pathEscape(slug))/channels", json: ["kind": kind, "source": source])
    }

    /// The update replaces every setting (missing ones fall back to defaults,
    /// and a missing `enabled` means on), so this sends the channel's current
    /// values back with only `enabled` changed.
    @discardableResult
    func setNodeChannelPaused(slug: String, channel: NLNodeChannels.Channel, paused: Bool) async throws -> Data {
        var body: [String: Any] = ["enabled": !paused]
        if let name = channel.name { body["name"] = name }
        if let postAs = channel.postAs { body["post_as"] = postAs }
        if let prefix = channel.titlePrefix { body["title_prefix"] = prefix }
        if let tags = channel.tags { body["tags"] = tags }
        if let limit = channel.dailyLimit { body["daily_limit"] = limit }
        if let review = channel.review { body["review"] = review }
        if let embed = channel.embed { body["embed"] = embed }
        if let minutes = channel.pollMinutes, minutes > 0 { body["poll_minutes"] = minutes }
        return try await send("PUT", "api/v1/nodes/\(Self.pathEscape(slug))/channels/\(channel.id)", json: body)
    }

    /// 立即同步 / 重试: checks the source now. Answers 200 with a `problem`
    /// when it still can't read it; the reloaded card shows the error.
    @discardableResult
    func retryNodeChannel(slug: String, id: Int) async throws -> Data {
        try await send("POST", "api/v1/nodes/\(Self.pathEscape(slug))/channels/\(id)/sync")
    }

    @discardableResult
    func removeNodeChannel(slug: String, id: Int) async throws -> Data {
        try await send("DELETE", "api/v1/nodes/\(Self.pathEscape(slug))/channels/\(id)")
    }

    // Drafts

    func drafts() async throws -> NLDrafts {
        try await get("api/v1/drafts")
    }

    /// Drafts are keyed by where they were written (`topic:12`,
    /// `new_topic:…`), not by a numeric id.
    @discardableResult
    func deleteDraft(key: String) async throws -> Data {
        try await send("DELETE", "api/v1/drafts/\(Self.pathEscape(key))")
    }

    /// `POST /api/v1/drafts/delete {"keys"}` — several at once.
    @discardableResult
    func deleteDrafts(keys: [String]) async throws -> Data {
        try await send("POST", "api/v1/drafts/delete", json: ["keys": keys])
    }

    /// Settles a held-back save: `held` takes the other device's version,
    /// `current` keeps the one on the server.
    @discardableResult
    func resolveDraftConflict(key: String, use: String) async throws -> Data {
        try await send("POST", "api/v1/drafts/\(Self.pathEscape(key))/conflict", json: ["use": use])
    }
}

/// The last node directory this device received, so a cold launch doesn't
/// wait on `/api/v1/nodes` before showing anything.
nonisolated enum NodeDirectoryDiskCache {
    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "node-directory.json")
    }

    static func load() -> [NLNode]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return (try? NodelocJSON.decode(NLNodeList.self, from: data))?.nodes
    }

    static func save(_ data: Data) {
        guard let url else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Moderation dashboard

extension DiscourseClient {
    /// The nodes the reader owns or moderates, with their pending counts —
    /// the dashboard's node chips. Read from `/api/v1/me/nodes`, which only
    /// attaches `pending` to nodes the reader can manage.
    func managedNodes() async throws -> [NLManagedNodes.Node] {
        let mine: NLManagedNodes = try await get("api/v1/me/nodes")
        return mine.joined.filter { $0.pending != nil }
    }
}


/// The server wraps matched words in `<mark>` (`title_html`, `blurb`). They
/// travel as two private-use characters around each match, and are drawn
/// bold in the accent — never as markup.
nonisolated enum SearchHighlight {
    struct Marked: Sendable {
        let title: String?
        let blurb: String?
    }

    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    nonisolated(unsafe) static var latest: [Int: Marked] = [:]

    static func marked(_ html: String) -> String {
        let swapped = html
            .replacingOccurrences(of: "<mark>", with: String(open))
            .replacingOccurrences(of: "</mark>", with: String(close))
        return DiscourseFormat.plainText(swapped)
    }

    static func attributed(_ text: String, tint: Color) -> AttributedString {
        var out = AttributedString()
        var inside = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if inside {
                piece.foregroundColor = tint
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            out += piece
            run = ""
        }
        for character in text {
            if character == open { flush(); inside = true } else if character == close { flush(); inside = false } else { run.append(character) }
        }
        flush()
        return out
    }
}
