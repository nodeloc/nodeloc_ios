//
//  DiscourseAPI.swift
//  nodeloc
//
//  Lightweight async client for the nodeloc.com Discourse backend.
//  Reading is public (login_required = false); authenticated calls attach either
//  a Discourse User-Api-Key or a website session cookie after login.
//

import Foundation

nonisolated enum DiscourseConfig {
    static let baseURL = URL(string: "https://www.nodeloc.com")!
    /// Custom URL scheme registered for the User API Key redirect.
    static let authRedirect = "nodeloc://auth"
    static let appName = "NODELOC iOS"
    static let clientIDDefaultsKey = "nodeloc.client_id"
    /// Klipy API key for the GIF picker (nodeloc's discourse-gifs runs the Klipy
    /// provider). It's a public theme setting on the web; paste it here to
    /// enable the native GIF search. Empty = GIF button disabled.
    static let klipyAPIKey = "EzZHqISrqNDXf1Jy8TdgG9WQzM1gqPlUYHoQrkZhL0X8WZIM8KL3XTSYatDZ83Bt"

    /// Stable per-install id, generated once and memoized (static lets are
    /// initialized lazily and thread-safely) so authenticated requests don't
    /// hit UserDefaults on every call.
    static let clientID: String = {
        if let existing = UserDefaults.standard.string(forKey: clientIDDefaultsKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientIDDefaultsKey)
        return id
    }()
}

/// Holds the signed-in user's auth state. The app supports both Discourse User API
/// keys and normal website sessions so it can use the same username/password flow
/// as the site.
@Observable
final class DiscourseAuth {
    // nonisolated so value types (DiscourseClient) can capture the shared
    // reference in a nonisolated init; its mutable state is still touched only
    // from the main actor.
    nonisolated static let shared = DiscourseAuth()
    var userApiKey: String?
    var sessionCookie: String?
    var csrfToken: String?
    var username: String?
    var isAuthenticated: Bool { userApiKey != nil || sessionCookie != nil }
}

enum DiscourseError: Error, LocalizedError {
    case badResponse(Int)
    /// Cloudflare answered with a challenge instead of the API — the app can't
    /// solve it, only report it distinctly from a real permission error.
    case challenged
    case decoding(Error)
    case transport(Error)

    /// True when the device has no usable network, so screens can show a
    /// wifi-slash state and offer a retry.
    var isOffline: Bool {
        guard case .transport(let error) = self,
              let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Friendly, user-facing wording only — status codes and technical detail
    /// stay out of the UI.
    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            switch code {
            case 401, 403: return "没有权限或登录已失效，请重新登录后再试"
            case 404: return "内容不存在或已被删除"
            case 429: return "操作太频繁，请稍后再试"
            case 500...: return "服务器开小差了，请稍后再试"
            default: return "请求失败，请稍后重试"
            }
        case .challenged:
            return "请求被站点安全防护拦截，请稍后再试"
        case .decoding:
            return "数据加载出错，请稍后重试"
        case .transport(let error):
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    return "网络不可用，请检查网络连接"
                case .timedOut:
                    return "连接超时，请稍后重试"
                default:
                    break
                }
            }
            return "网络异常，请稍后重试"
        }
    }
}

struct DiscourseClient {
    var baseURL = DiscourseConfig.baseURL
    var session: URLSession = .shared
    var auth: DiscourseAuth = .shared

    // Explicit nonisolated init so the two caching actors can construct a
    // client at property-init without hopping to the main actor. Its default
    // values are all nonisolated (config constants, URLSession.shared, the
    // Sendable auth reference); the methods stay main-actor-isolated.
    nonisolated init() {}

    private struct MultipartFile {
        let fieldName: String
        let fileName: String
        let mimeType: String
        let data: Data
    }

    // MARK: Request pipeline

    /// Builds an authenticated JSON request against the Discourse base URL.
    /// Every endpoint goes through here so headers stay consistent.
    private func makeRequest(
        _ method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        includeCSRF: Bool
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request, includeCSRF: includeCSRF)
        return request
    }

    /// Executes a request, mapping transport failures and non-2xx statuses to
    /// `DiscourseError`. The single funnel for all network I/O in this client.
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Cloudflare interception looks like a 403 but isn't one from
            // Discourse: it carries cf-mitigated (or an HTML body from the
            // cloudflare server) instead of a JSON error.
            let cfMitigated = http.value(forHTTPHeaderField: "cf-mitigated")
            let server = http.value(forHTTPHeaderField: "Server")?.lowercased() ?? ""
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let isChallenge = cfMitigated != nil
                || (http.statusCode == 403 && server.contains("cloudflare") && contentType.contains("text/html"))

            #if DEBUG
            let bodyPrefix = String(decoding: data.prefix(200), as: UTF8.self)
            print("""
            [DiscourseAPI] \(http.statusCode) \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")
              server=\(server) cf-mitigated=\(cfMitigated ?? "-") cf-ray=\(http.value(forHTTPHeaderField: "cf-ray") ?? "-")
              body: \(bodyPrefix)
            """)
            #endif

            throw isChallenge ? DiscourseError.challenged : DiscourseError.badResponse(http.statusCode)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(makeRequest(path: path, query: query, includeCSRF: false))
        return try Self.decode(data)
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DiscourseError.decoding(error)
        }
    }

    private func applyAuth(to request: inout URLRequest, includeCSRF: Bool) {
        let userApiKey = auth.userApiKey
        let sessionCookie = auth.sessionCookie

        if let userApiKey {
            request.setValue(userApiKey, forHTTPHeaderField: "User-Api-Key")
            request.setValue(DiscourseConfig.clientID, forHTTPHeaderField: "User-Api-Client-Id")
        }
        if sessionCookie != nil {
            // No manual Cookie header: Discourse rotates the `_t` auth token,
            // and a pinned snapshot goes stale and gets every request answered
            // with not_logged_in. URLSession's cookie jar attaches the cookies
            // itself and absorbs rotations from Set-Cookie; DiscourseLogin
            // seeds the jar on restore and snapshots it on backgrounding.
            request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if userApiKey != nil || sessionCookie != nil {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("true", forHTTPHeaderField: "Discourse-Present")
        }
        if (includeCSRF || sessionCookie != nil), let csrf = auth.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
    }

    // MARK: Endpoints

    func latest(page: Int = 0) async throws -> LatestResponse {
        try await get(
            "latest.json",
            query: page > 0 ? [URLQueryItem(name: "page", value: String(page))] : []
        )
    }

    func site() async throws -> SiteResponse {
        try await get("site.json")
    }

    /// A node's topics for a given ordering. `path` is the parent/child slug
    /// pair Discourse expects (e.g. "technology/ai") — /c/{slug}/{id} redirects.
    func nodeTopics(
        path: String,
        categoryID: Int,
        sort: String = "latest",
        page: Int = 0
    ) async throws -> CategoryTopicsResponse {
        try await get(
            "c/\(path)/\(categoryID)/l/\(sort).json",
            query: page > 0 ? [URLQueryItem(name: "page", value: String(page))] : []
        )
    }

    func joinNode(categoryID: Int) async throws -> NodeMembershipResponse {
        let data = try await send("POST", path: "node/join/\(categoryID)")
        return try Self.decode(data)
    }

    func leaveNode(categoryID: Int) async throws -> NodeMembershipResponse {
        let data = try await send("DELETE", path: "node/leave/\(categoryID)")
        return try Self.decode(data)
    }

    /// Sets how much a node notifies this user. `level` is a
    /// `NodeNotificationLevel` raw value — Discourse's own integers.
    /// Goes through `post(_:form:)` for its CSRF header: without one the
    /// endpoint answers 403 BAD CSRF.
    @discardableResult
    func setCategoryNotification(categoryID: Int, level: Int) async throws -> Data {
        try await post(
            "category/\(categoryID)/notifications",
            form: ["notification_level": String(level)]
        )
    }

    func categories(includeSubcategories: Bool = false) async throws -> CategoriesResponse {
        try await get(
            "categories.json",
            query: includeSubcategories ? [URLQueryItem(name: "include_subcategories", value: "true")] : []
        )
    }

    func sidebarNodes() async throws -> SidebarCommunitiesResponse {
        try await get("nodes.json")
    }

    func nodeBrowse(parentCategoryID: Int, page: Int = 0, perPage: Int? = nil) async throws -> SidebarCommunitiesResponse {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let perPage {
            query.append(URLQueryItem(name: "per_page", value: String(perPage)))
        }
        return try await get("node/browse/\(parentCategoryID).json", query: query)
    }

    func recentlyVisitedNodes() async throws -> SidebarCommunitiesResponse {
        try await get("node/recently-visited.json")
    }

    func customFeeds() async throws -> SidebarCustomFeedsResponse {
        try await get("custom-feeds.json")
    }

    func checkNodeSlug(_ slug: String) async throws -> NodeSlugAvailabilityResponse {
        try await get("node/check-slug", query: [URLQueryItem(name: "slug", value: slug)])
    }

    func topic(id: Int) async throws -> TopicResponse {
        try await get("t/\(id).json")
    }

    /// Discourse's nested-replies view with server-side sort ("top"/"new"/"old").
    /// The slug only affects the canonical URL; the id resolves the topic, so a
    /// placeholder is fine.
    func nestedTopic(id: Int, slug: String = "topic", sort: String, page: Int = 0) async throws -> NestedTopicResponse {
        try await get(
            "n/\(slug)/\(id).json",
            query: [
                URLQueryItem(name: "sort", value: sort),
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
    }

    /// More direct replies under one post in the nested view.
    func nestedChildren(topicID: Int, postNumber: Int, slug: String = "topic", sort: String, page: Int = 0) async throws -> NestedChildrenResponse {
        try await get(
            "n/\(slug)/\(topicID)/children/\(postNumber).json",
            query: [
                URLQueryItem(name: "sort", value: sort),
                URLQueryItem(name: "page", value: String(page)),
            ]
        )
    }

    func topicPosts(topicID: Int, postIDs: [Int]) async throws -> TopicPostsResponse {
        try await get(
            "t/\(topicID)/posts.json",
            query: postIDs.map { URLQueryItem(name: "post_ids[]", value: String($0)) }
        )
    }

    func search(_ term: String) async throws -> SearchResponse {
        try await get("search.json", query: [URLQueryItem(name: "q", value: term)])
    }

    func user(_ username: String) async throws -> UserResponse {
        try await get("u/\(username).json")
    }

    func userSummary(_ username: String) async throws -> UserSummaryResponse {
        try await get("u/\(username)/summary.json")
    }

    /// Follow a user (discourse-follow plugin).
    func follow(username: String) async throws {
        try await send("PUT", path: "follow/\(username)")
    }

    /// Unfollow a user (discourse-follow plugin).
    func unfollow(username: String) async throws {
        try await send("DELETE", path: "follow/\(username)")
    }

    // MARK: Apps (discourse-apps plugin)

    /// Published apps. The directory endpoint returns a bare JSON array.
    func appsDirectory() async throws -> [DirectoryApp] {
        try await get("apps/directory.json")
    }

    /// One app by slug. This payload *is* wrapped, unlike the list.
    func app(slug: String) async throws -> DirectoryAppResponse {
        try await get("apps/\(slug).json")
    }

    /// The sandboxed document that actually runs a webview app.
    func appWebviewURL(installID: Int) -> URL {
        baseURL.appending(path: "apps/installs/\(installID)/webview")
    }

    /// Group title styles from the discourse-custom-badge plugin. Public: for
    /// non-admins the server returns only groups that have a style configured.
    func customGroupStyles() async throws -> [CustomGroupStyleItem] {
        try await get("discourse_custom_badge/group-styles/list")
    }

    /// Badge styles from the discourse-custom-badge plugin (badges used as titles).
    func customBadgeStyles() async throws -> [CustomBadgeStyleItem] {
        try await get("discourse_custom_badge/badge-styles/list")
    }

    /// 能量 (points) history from the discourse-points-service plugin.
    func pointsHistory(username: String, page: Int = 0) async throws -> PointsHistoryResponse {
        try await get(
            "u/\(username)/points-history.json",
            query: [URLQueryItem(name: "page", value: String(page))]
        )
    }

    /// Total 能量 balance from the plugin's scores endpoint.
    func pointsTotal(username: String) async throws -> PointsScoresResponse {
        try await get(
            "u/\(username)/points-scores.json",
            query: [URLQueryItem(name: "page", value: "0")]
        )
    }

    /// User activity stream filtered by Discourse UserAction type
    /// (1 = likes given, 3 = bookmarks, 4 = topics, 5 = replies).
    func userActions(username: String, filter: Int) async throws -> UserActionsResponse {
        try await get("user_actions.json", query: [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "filter", value: String(filter)),
            URLQueryItem(name: "offset", value: "0")
        ])
    }

    func currentUser() async throws -> CurrentUserResponse {
        try await get("session/current.json")
    }

    /// Signup helper: whether a username is free, with Discourse's suggestion
    /// when it isn't.
    func checkUsername(_ username: String) async throws -> UsernameCheckResponse {
        try await get(
            "u/check_username.json",
            query: [URLQueryItem(name: "username", value: username)]
        )
    }

    func notifications() async throws -> NotificationsResponse {
        try await get("notifications.json")
    }

    func privateMessages(username: String) async throws -> PrivateMessagesResponse {
        try await get("topics/private-messages/\(username).json")
    }

    /// PMs addressed to one of the user's groups (staff, moderators, …).
    func groupPrivateMessages(username: String, group: String) async throws -> PrivateMessagesResponse {
        try await get("topics/private-messages-group/\(username)/\(group).json")
    }

    /// Marks every notification read and bumps last-seen — what Discourse does
    /// when you open the notifications menu, so the unread badge clears.
    @discardableResult
    func markNotificationsRead() async throws -> Data {
        try await send("PUT", path: "notifications/mark-read")
    }

    /// Reports read progress for a topic: `topicTimeMs` is time spent in the
    /// topic this batch, `timings` maps post number → ms it was on screen. The
    /// server marks those posts read, accrues the user's read time and
    /// posts-read count, and clears the topic's new/unread state.
    @discardableResult
    func sendTopicTimings(topicID: Int, topicTimeMs: Int, timings: [Int: Int]) async throws -> Data {
        var form = [
            "topic_id": String(topicID),
            "topic_time": String(topicTimeMs),
        ]
        for (postNumber, ms) in timings {
            form["timings[\(postNumber)]"] = String(ms)
        }
        return try await post("topics/timings", form: form)
    }

    func chatChannels() async throws -> ChatChannelsResponse {
        do {
            return try await get("chat/api/me/channels.json")
        } catch DiscourseError.badResponse(let code) where code == 404 {
            return try await get("chat/api/channels.json")
        }
    }

    func chatMessages(channelID: Int, pageSize: Int = 50, targetMessageID: Int? = nil) async throws -> ChatMessagesResponse {
        try await get(
            "chat/api/channels/\(channelID)/messages.json",
            query: chatMessageQuery(
                pageSize: pageSize,
                fetchFromLastRead: targetMessageID == nil,
                targetMessageID: targetMessageID
            )
        )
    }

    /// Raw variant of `chatMessages` for the disk cache: the snapshot is
    /// stored exactly as served, so it re-decodes through the same path later.
    func chatMessagesWithRaw(
        channelID: Int,
        pageSize: Int = 50,
        targetMessageID: Int? = nil
    ) async throws -> (response: ChatMessagesResponse, raw: Data) {
        let data = try await perform(makeRequest(
            path: "chat/api/channels/\(channelID)/messages.json",
            query: chatMessageQuery(
                pageSize: pageSize,
                fetchFromLastRead: targetMessageID == nil,
                targetMessageID: targetMessageID
            ),
            includeCSRF: false
        ))
        return (try Self.decode(data), data)
    }

    /// One MessageBus long-poll round — the transport Discourse itself uses
    /// for live updates. `positions` maps bus channel ("/chat/123") to the
    /// last seen message-bus id (-1 = only new events). The server holds the
    /// request ~25s and answers with whatever arrives.
    func messageBusPoll(clientID: String, positions: [String: Int]) async throws -> Data {
        var request = makeRequest("POST", path: "message-bus/\(clientID)/poll", includeCSRF: true)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = positions
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? key
                return "\(encodedKey)=\(value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await perform(request)
    }

    func chatSearch(
        query: String,
        limit: Int = 20,
        offset: Int = 0,
        sort: String = "latest",
        excludeThreads: Bool = false
    ) async throws -> ChatSearchResponse {
        let clampedLimit = min(max(limit, 1), 40)
        let normalizedOffset = max(offset, 0)
        return try await get(
            "chat/api/search.json",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: String(clampedLimit)),
                URLQueryItem(name: "offset", value: String(normalizedOffset)),
                URLQueryItem(name: "sort", value: sort),
                URLQueryItem(name: "exclude_threads", value: excludeThreads ? "true" : "false")
            ]
        )
    }

    func chatThreads(channelID: Int, limit: Int = 10, offset: Int = 0) async throws -> ChatThreadsResponse {
        try await get(
            "chat/api/channels/\(channelID)/threads.json",
            query: chatThreadsQuery(limit: limit, offset: offset)
        )
    }

    func currentUserChatThreads(limit: Int = 10, offset: Int = 0) async throws -> ChatThreadsResponse {
        try await get(
            "chat/api/me/threads.json",
            query: chatThreadsQuery(limit: limit, offset: offset)
        )
    }

    func chatThreadMessages(
        channelID: Int,
        threadID: Int,
        pageSize: Int = 50,
        targetMessageID: Int? = nil
    ) async throws -> ChatMessagesResponse {
        try await get(
            "chat/api/channels/\(channelID)/threads/\(threadID)/messages.json",
            query: chatMessageQuery(
                pageSize: pageSize,
                fetchFromLastRead: targetMessageID == nil,
                targetMessageID: targetMessageID
            )
        )
    }

    // MARK: Write actions (require authentication)

    func createChatMessage(channelID: Int, message: String, threadID: Int? = nil) async throws -> ChatCreateMessageResponse {
        var form = ["message": message]
        if let threadID {
            form["thread_id"] = String(threadID)
        }

        let data = try await post("chat/\(channelID).json", form: form)
        return try Self.decode(data)
    }

    /// Marks a chat channel read up to `messageID` (the endpoint requires the
    /// message id). Clears that channel's unread on the server so the tab badge
    /// stops counting it.
    @discardableResult
    func markChatChannelRead(channelID: Int, messageID: Int) async throws -> Data {
        try await send(
            "PUT",
            path: "chat/api/channels/\(channelID)/read",
            query: [URLQueryItem(name: "message_id", value: String(messageID))]
        )
    }

    private func chatMessageQuery(
        pageSize: Int,
        fetchFromLastRead: Bool,
        targetMessageID: Int? = nil
    ) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "page_size", value: String(pageSize))]
        if fetchFromLastRead {
            query.append(URLQueryItem(name: "fetch_from_last_read", value: "true"))
        }
        if let targetMessageID {
            query.append(URLQueryItem(name: "target_message_id", value: String(targetMessageID)))
        }
        return query
    }

    private func chatThreadsQuery(limit: Int, offset: Int) -> [URLQueryItem] {
        let clampedLimit = min(max(limit, 1), 10)
        let normalizedOffset = max(offset, 0)
        return [
            URLQueryItem(name: "limit", value: String(clampedLimit)),
            URLQueryItem(name: "offset", value: String(normalizedOffset))
        ]
    }

    /// Bodyless authenticated request (PUT/DELETE), used by the follow endpoints.
    @discardableResult
    private func send(_ method: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(makeRequest(method, path: path, query: query, includeCSRF: true))
    }

    /// Unordered form fields; sugar over `formItems` for the common case.
    @discardableResult
    private func post(_ path: String, form: [String: String]) async throws -> Data {
        try await formItems("POST", path: path, items: form.map { ($0.key, $0.value) })
    }

    /// RFC 3986 unreserved characters — everything else gets percent-encoded in
    /// form bodies.
    private static let formAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// Form-encoded request with ordered, possibly repeated keys, for any HTTP
    /// method. Rails reads `options[]=a&options[]=b` as an array; a dictionary
    /// can't represent that.
    @discardableResult
    private func formItems(
        _ method: String,
        path: String,
        items: [(String, String)]
    ) async throws -> Data {
        var request = makeRequest(method, path: path, includeCSRF: true)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = items
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: Self.formAllowedCharacters) ?? ""
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await perform(request)
    }

    /// Saves account preferences. `items` are already-encoded `user_option`
    /// pairs; repeated keys such as `watched_category_ids[]` are why this goes
    /// through `formItems` rather than a dictionary.
    ///
    /// `PUT /u/:username` is Discourse's own route (`users#update`) and rejects
    /// a request without a CSRF token with 403.
    @discardableResult
    func updatePreferences(username: String, items: [(String, String)]) async throws -> Data {
        try await formItems("PUT", path: "u/\(username).json", items: items)
    }

    // MARK: Profile

    /// Writes profile fields (name, bio_raw, website, location, title,
    /// card_background_upload_url, …) through the same `users#update` route as
    /// preferences.
    @discardableResult
    func updateProfile(username: String, items: [(String, String)]) async throws -> Data {
        try await formItems("PUT", path: "u/\(username).json", items: items)
    }

    /// Uploads an image tied to the user (avatar / card_background /
    /// profile_background) and returns its upload record.
    func uploadUserImage(data: Data, fileName: String, mimeType: String, type: String) async throws -> DiscourseUpload {
        try await postMultipart(
            "uploads.json",
            fields: ["upload_type": type, "synchronous": "true"],
            file: MultipartFile(fieldName: "file", fileName: fileName, mimeType: mimeType, data: data)
        )
    }

    /// Selects which uploaded image becomes the avatar. `type` is
    /// "uploaded" / "gravatar" / "system".
    @discardableResult
    func pickAvatar(username: String, uploadID: Int, type: String = "uploaded") async throws -> Data {
        try await formItems(
            "PUT",
            path: "u/\(username)/preferences/avatar/pick",
            items: [("upload_id", String(uploadID)), ("type", type)]
        )
    }

    /// Owner-scoped profile fetch carrying associated accounts, sessions, and
    /// second-factor state.
    func accountDetail(username: String) async throws -> AccountDetail {
        try await get("u/\(username).json")
    }

    // MARK: Badges (title options)

    /// Read only, to populate the title picker with the user's title-granting
    /// badges. The title itself is set through `updateProfile`.
    func userBadges(username: String) async throws -> UserBadgesResponse {
        try await get("user-badges/\(username).json")
    }

    // MARK: Associated accounts

    @discardableResult
    func revokeAssociatedAccount(username: String, provider: String) async throws -> Data {
        try await formItems(
            "POST",
            path: "u/\(username)/preferences/revoke-account",
            items: [("provider_name", provider)]
        )
    }

    // MARK: Security

    /// Triggers a password-reset email; Discourse has no in-app password change.
    @discardableResult
    func requestPasswordReset(login: String) async throws -> Data {
        try await formItems("POST", path: "session/forgot_password", items: [("login", login)])
    }

    /// Whether the session is recently password-confirmed. Sensitive routes
    /// (2FA, revoking sessions) require it.
    func trustedSession() async throws -> SessionTrustResponse {
        try await get("u/trusted-session")
    }

    @discardableResult
    func confirmSession(password: String) async throws -> SessionTrustResponse {
        let data = try await formItems("POST", path: "u/confirm-session", items: [("password", password)])
        return try Self.decode(data)
    }

    /// Note: the 2FA routes carry no username segment (`root_path` is `u`).
    func listSecondFactors() async throws -> SecondFactorsResponse {
        let data = try await formItems("POST", path: "u/second_factors", items: [])
        return try Self.decode(data)
    }

    func createTOTP() async throws -> TOTPCreateResponse {
        let data = try await formItems("POST", path: "u/create_second_factor_totp", items: [])
        return try Self.decode(data)
    }

    @discardableResult
    func enableTOTP(token: String, name: String) async throws -> Data {
        try await formItems(
            "POST",
            path: "u/enable_second_factor_totp",
            items: [("second_factor_token", token), ("name", name)]
        )
    }

    @discardableResult
    func disableSecondFactor() async throws -> Data {
        try await formItems("PUT", path: "u/disable_second_factor", items: [])
    }

    func generateBackupCodes() async throws -> BackupCodesResponse {
        let data = try await formItems("PUT", path: "u/second_factors_backup", items: [])
        return try Self.decode(data)
    }

    /// Revokes one session, or all others when `tokenID` is nil.
    @discardableResult
    func revokeAuthToken(username: String, tokenID: Int?) async throws -> Data {
        let items = tokenID.map { [("token_id", String($0))] } ?? []
        return try await formItems("POST", path: "u/\(username)/preferences/revoke-auth-token", items: items)
    }

    /// JSON-bodied POST. The lottery plugin's controller reads a nested `levels`
    /// array, which form encoding can't express.
    @discardableResult
    private func postJSON(_ path: String, body: Encodable) async throws -> Data {
        var request = makeRequest("POST", path: path, includeCSRF: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw DiscourseError.decoding(error)
        }
        return try await perform(request)
    }

    private func postMultipart<T: Decodable>(_ path: String, fields: [String: String], file: MultipartFile) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = makeRequest("POST", path: path, includeCSRF: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n")
        body.appendUTF8("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let data = try await perform(request)
        return try Self.decode(data)
    }

    /// Likes a post (post_action_type_id 2).
    func likePost(id: Int) async throws {
        try await post("post_actions", form: [
            "id": String(id),
            "post_action_type_id": "2",
            "flag_topic": "false",
        ])
    }

    /// Removes a previously-given like (post_action_type_id 2).
    func unlikePost(id: Int) async throws {
        try await formItems("DELETE", path: "post_actions/\(id)", items: [
            ("post_action_type_id", "2"),
        ])
    }

    /// Posts a reply to a topic.
    /// 打赏 — discourse-reward. Gives `amount` energy to a post.
    @discardableResult
    func giveReward(postID: Int, amount: Int, note: String? = nil) async throws -> Data {
        var form = ["post_id": String(postID), "amount": String(amount)]
        if let note, !note.isEmpty { form["note"] = note }
        return try await post("reward/give", form: form)
    }

    /// Repost — discourse-community. Republishes a topic into a node.
    @discardableResult
    func repost(topicID: Int, categoryID: Int, title: String) async throws -> Data {
        try await post("node/repost", form: [
            "topic_id": String(topicID),
            "category_id": String(categoryID),
            "title": title,
        ])
    }

    @discardableResult
    func reply(topicID: Int, raw: String, replyToPostNumber: Int? = nil) async throws -> CreatePostResponse {
        var form = [
            "raw": raw,
            "topic_id": String(topicID),
        ]
        if let replyToPostNumber { form["reply_to_post_number"] = String(replyToPostNumber) }
        let data = try await post("posts", form: form)
        return try Self.decode(data)
    }

    /// Bookmarks a post (保存书签).
    @discardableResult
    func bookmark(postID: Int) async throws -> Data {
        try await post("bookmarks", form: [
            "bookmarkable_id": String(postID),
            "bookmarkable_type": "Post",
        ])
    }

    /// Creates a new topic in a category.
    /// Returns the created post, whose `topic_id` is needed by follow-up calls
    /// like red-envelope creation.
    @discardableResult
    func createTopic(title: String, raw: String, categoryID: Int) async throws -> CreatePostResponse {
        let data = try await post("posts", form: [
            "title": title,
            "raw": raw,
            "category": String(categoryID),
            "archetype": "regular",
        ])
        return try Self.decode(data)
    }

    /// Creates a user-owned node under a top-level category.
    func createNode(
        name: String,
        slug: String,
        description: String,
        colorHex: String?,
        parentCategoryID: Int
    ) async throws -> CreateCommunityResponse {
        var form = [
            "name": name,
            "description": description,
            "slug": slug,
            "parent_category_id": String(parentCategoryID),
        ]
        if let colorHex, !colorHex.isEmpty {
            form["color"] = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        }

        let data = try await post("node/create", form: form)
        return try Self.decode(data)
    }

    /// Uploads a composer attachment and returns the Discourse upload token/URL.
    /// Searches Klipy for GIFs (the provider nodeloc's discourse-gifs uses).
    /// Hits Klipy directly — it's an external host, not the Discourse backend.
    func klipySearch(query: String, pos: String? = nil) async throws -> KlipySearchResponse {
        guard !DiscourseConfig.klipyAPIKey.isEmpty else { throw DiscourseError.badResponse(401) }
        var components = URLComponents(string: "https://api.klipy.com/v2/search")!
        components.queryItems = [
            URLQueryItem(name: "key", value: DiscourseConfig.klipyAPIKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "media_filter", value: "gif"),
            URLQueryItem(name: "limit", value: "24"),
            URLQueryItem(name: "pos", value: pos ?? "0"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await perform(request)
        return try Self.decode(data)
    }

    /// `upload_type` replaces the `type` param, which Discourse deprecated in
    /// 3.4 and drops in 3.5.
    func uploadComposerMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        try await postMultipart(
            "uploads.json",
            fields: [
                "upload_type": "composer",
                "synchronous": "true",
            ],
            file: MultipartFile(
                fieldName: "file",
                fileName: fileName,
                mimeType: mimeType,
                data: data
            )
        )
    }

    /// Casts a poll vote. `options[]` repeats once per selected option, which
    /// the `[String: String]` form helper can't express — hence `formItems`.
    func votePoll(postID: Int, pollName: String, options: [String]) async throws -> PollVoteResponse {
        var items = [("post_id", String(postID)), ("poll_name", pollName)]
        items.append(contentsOf: options.map { ("options[]", $0) })
        let data = try await formItems("PUT", path: "polls/vote", items: items)
        return try Self.decode(data)
    }

    func removePollVote(postID: Int, pollName: String) async throws -> PollVoteResponse {
        let data = try await formItems(
            "DELETE",
            path: "polls/vote",
            items: [("post_id", String(postID)), ("poll_name", pollName)]
        )
        return try Self.decode(data)
    }

    /// Buys lottery tickets. Each ticket costs one energy point.
    func participateInLottery(
        lotteryID: Int,
        quantity: Int,
        isRandom: Bool
    ) async throws -> LotteryActionResponse {
        let data = try await formItems(
            "POST",
            path: "lottery/\(lotteryID)/participate",
            items: [("quantity", String(quantity)), ("random", isRandom ? "true" : "false")]
        )
        return try Self.decode(data)
    }

    /// Creates a red envelope on a topic that already exists.
    ///
    /// The plugin has no markup form: its composer stashes the values and posts
    /// them from an `afterCreate` hook once the topic id is known
    /// (red-envelope-topic-creation.js), so this is always a second request
    /// after `createTopic`.
    func createRedEnvelope(topicID: Int, totalPoints: Int, totalCount: Int) async throws -> RedEnvelopeResponse {
        let data = try await post(
            "red-envelopes.json",
            form: [
                "topic_id": String(topicID),
                "total_points": String(totalPoints),
                "total_count": String(totalCount),
            ]
        )
        return try Self.decode(data)
    }

    /// Creates a lottery on an existing post.
    ///
    /// Keyed by **post id**, not topic id — `lottery_controller#create` looks up
    /// `Post.find_by(id: params[:post_id])` and enforces one lottery per post.
    /// Like the red envelope this runs after the post is saved, mirroring the
    /// plugin's `addModelCallback("post", "afterCreate")`.
    func createLottery(postID: Int, draft: LotteryDraft) async throws -> LotteryCreateResponse {
        let data = try await postJSON("lottery", body: draft.payload(postID: postID))
        return try Self.decode(data)
    }

    /// Uploads a video poster frame.
    ///
    /// Discourse links a poster to its video purely by filename: `pretty_text.rb`
    /// looks up `Upload.where("original_filename LIKE ?", "#{video_sha1}.%")`
    /// when rendering the video placeholder. So the file *must* be named after
    /// the video's SHA1, and there is no markdown that references it.
    func uploadVideoPoster(data: Data, videoSHA1: String) async throws -> DiscourseUpload {
        try await postMultipart(
            "uploads.json",
            fields: [
                "upload_type": "thumbnail",
                "synchronous": "true",
            ],
            file: MultipartFile(
                fieldName: "file",
                fileName: "\(videoSHA1).png",
                mimeType: "image/png",
                data: data
            )
        )
    }

    // MARK: Helpers

    /// Resolves a Discourse `avatar_template` into a concrete image URL.
    func avatarURL(template: String, size: Int = 120) -> URL? {
        let path = template.replacingOccurrences(of: "{size}", with: String(size))
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - Utilities

enum DiscourseFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return iso.date(from: string) ?? isoNoFraction.date(from: string)
    }

    /// Compact relative time like "2h", "3d", "5m".
    static func relative(_ string: String?) -> String {
        guard let date = date(string) else { return "" }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w"
        default: return "\(Int(seconds / 2_629_800))mo"
        }
    }

    /// Strips HTML tags and decodes a few common entities for plain-text excerpts.
    /// Excerpt text for list rows. Post *bodies* go through `PostHTMLParser`
    /// instead; this is only for previews where formatting isn't wanted.
    ///
    /// Long tokens are made breakable, because a bare URL in an excerpt has no
    /// wrap opportunity and would widen the row past the screen.
    private static let htmlTagPattern = /<[^>]+>/

    static func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        var text = html.replacing(htmlTagPattern, with: "")
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&hellip;": "…", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .breakingLongTokens()
    }

    static func mediaItems(for topic: TopicListItem) -> [PostMedia] {
        // Prefer the responsive thumbnail set: it carries the topic's
        // representative image at several widths, so each display site can pick
        // a size that matches how big it draws.
        if let media = responsiveMedia(from: topic.thumbnails) {
            return [media]
        }

        // Fall back to the single image_url when no thumbnail set is present.
        guard let raw = topic.imageUrl, let url = absoluteURL(raw) else { return [] }
        let dimensions = dimensions(from: raw)
        return [PostMedia(url: url, width: dimensions.width, height: dimensions.height)]
    }

    /// Builds one `PostMedia` from a thumbnail set: variants ascending by width,
    /// `url`/dimensions taken from the largest (the original).
    private static func responsiveMedia(from thumbnails: [TopicThumbnail]?) -> PostMedia? {
        guard let thumbnails else { return nil }
        let variants = thumbnails
            .compactMap { thumb -> ImageVariant? in
                guard let width = thumb.width, width > 0,
                      let url = thumb.url.flatMap(absoluteURL) else { return nil }
                return ImageVariant(width: width, url: url)
            }
            .sorted { $0.width < $1.width }

        guard let largest = variants.last else { return nil }
        let original = thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }
        return PostMedia(
            url: largest.url,
            width: original?.width,
            height: original?.height,
            variants: variants
        )
    }

    private static func absoluteURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: raw, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
    }

    private static func dimensions(from raw: String) -> (width: Int?, height: Int?) {
        guard let range = raw.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else {
            return (nil, nil)
        }

        let parts = raw[range].split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return (nil, nil) }
        return (parts[0], parts[1])
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
