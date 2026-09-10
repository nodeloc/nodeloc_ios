//
//  DiscourseAPI.swift
//  nodeloc
//
//  Lightweight async client for the nodeloc.com Discourse backend.
//  Reading is public (login_required = false); authenticated calls ride the
//  website session established at login (see DiscourseAuthService).
//

import Foundation

nonisolated enum DiscourseConfig {
    static let baseURL = URL(string: "https://www.nodeloc.com")!
    static let appName = "NODELOC iOS"
    static let clientIDDefaultsKey = "nodeloc.client_id"
    /// Klipy API key for the GIF picker (nodeloc's discourse-gifs runs the Klipy
    /// provider). Empty = GIF button disabled, which is why a clone builds and
    /// runs without one.
    ///
    /// Read from `Secrets.plist` rather than written here, because this
    /// repository is public. The previous key was committed and therefore lives
    /// in the git history for good — removing it from this file would not have
    /// unpublished it, so it was rotated at Klipy instead and the replacement
    /// never enters the repository.
    ///
    /// To enable GIF search locally, put a `Secrets.plist` beside `Info.plist`:
    ///
    ///     <dict><key>KlipyAPIKey</key><string>…</string></dict>
    ///
    /// It is gitignored, and the app folder is a synchronized group, so Xcode
    /// picks it up with no project changes.
    static let klipyAPIKey: String = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let key = plist["KlipyAPIKey"] as? String
        else { return "" }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// The invite code the app registers with.
    ///
    /// The site has `require_invite_code` on, so `POST /users` refuses a signup
    /// without one — and an app user has nowhere to get a code from. The admin
    /// set this value aside for the app, so signing up from here works without
    /// asking for something the reader doesn't have.
    ///
    /// **This is not a secret.** It ships in the binary, and anyone can read it
    /// out of the IPA with `strings`. Once it is public, the site's invite gate
    /// is open to anyone who bothers — including on the web, since the server
    /// compares against one global value (`strip.downcase`, so case and spacing
    /// don't matter). Treat it as a speed bump against casual spam, not as
    /// access control.
    ///
    /// If the gate needs to mean something, the code has to stop being a shared
    /// constant: the companion plugin would issue a short-lived or per-install
    /// code that the app fetches, so revoking it doesn't require an App Store
    /// release. Rotating this one does.
    static let appInviteCode = "nodelocapp"

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

/// Holds the signed-in user's auth state — a website session, however it was
/// obtained (password, or one of Discourse's auth providers). `userApiKey` is
/// kept only so a session stored by an older build still restores.
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
    /// Admin or moderator, from `current_user`. Staff-only actions (pinning a
    /// reply, for one) are offered on this rather than attempted and refused.
    var isStaff = false
    var isAuthenticated: Bool { userApiKey != nil || sessionCookie != nil }
}

enum DiscourseError: Error, LocalizedError {
    /// Status code, plus whatever the server said about it.
    ///
    /// Discourse explains itself in the body — `{"error": "…"}` or
    /// `{"errors": ["…"]}` — and throwing that away meant a precise, already
    /// localized message ("该账号开启了两步验证，请通过网站登录。") was replaced
    /// by generic copy about permissions. The message is preferred over the
    /// canned wording whenever there is one.
    case badResponse(Int, message: String? = nil)
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
        case .badResponse(let code, let message):
            // The server's own wording is more specific than anything that can
            // be inferred from a status code.
            if let message, !message.isEmpty { return message }
            switch code {
            case 401, 403: return AppString("没有权限或登录已失效，请重新登录后再试")
            case 404: return AppString("内容不存在或已被删除")
            case 429: return AppString("操作太频繁，请稍后再试")
            case 500...: return AppString("服务器开小差了，请稍后再试")
            default: return AppString("请求失败，请稍后重试")
            }
        case .challenged:
            return AppString("请求被站点安全防护拦截，请稍后再试")
        case .decoding:
            return AppString("数据加载出错，请稍后重试")
        case .transport(let error):
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    return AppString("网络不可用，请检查网络连接")
                case .timedOut:
                    return AppString("连接超时，请稍后重试")
                default:
                    break
                }
            }
            return AppString("网络异常，请稍后重试")
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
        // Server-rendered content — topic titles, excerpts, cooked posts — is
        // translated by Discourse's content localization, and it picks the
        // language from this header. Without it every list came back in the
        // topic's original language whatever the app was set to.
        request.setValue(AppLanguage.resolved.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        applyAuth(to: &request, includeCSRF: includeCSRF)
        return request
    }

    /// Executes a request, mapping transport failures and non-2xx statuses to
    /// `DiscourseError`. The single funnel for all network I/O in this client.
    private func perform(_ request: URLRequest, retriesRemaining: Int = 1) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }

        // Discourse rate-limits per user, and opening a screen that fans out
        // (a profile fires the user, summary, points and activity calls at
        // once) can trip it. One short retry turns a screen that came up empty
        // into one that just took a moment.
        //
        // Reads only: replaying a POST could double-post.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 429,
           retriesRemaining > 0,
           (request.httpMethod ?? "GET").uppercased() == "GET" {
            let asked = Self.retryDelay(from: http, body: data) ?? 0.8
            if asked <= Self.maximumRetryWait {
                // A little jitter, so several calls rejected together don't
                // return in lockstep and trip the limit again as a group.
                let wait = max(asked, 0.4) + Double.random(in: 0...0.3)
                #if DEBUG
                print("[DiscourseAPI] 429 \(request.url?.path ?? "") — retrying in \(String(format: "%.1f", wait))s")
                #endif
                try? await Task.sleep(for: .seconds(wait))
                return try await perform(request, retriesRemaining: retriesRemaining - 1)
            }
            #if DEBUG
            print("[DiscourseAPI] 429 \(request.url?.path ?? "") — server asked for \(asked)s, giving up rather than retrying early")
            #endif
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

            throw isChallenge
                ? DiscourseError.challenged
                : DiscourseError.badResponse(
                    http.statusCode,
                    message: Self.serverMessage(from: data)
                )
        }
        return data
    }

    /// Discourse's own explanation for a failure, if the body carries one.
    ///
    /// Both shapes appear: `{"error": "…"}` from plugins and custom endpoints,
    /// `{"errors": ["…"]}` from core. Anything else — an HTML error page, an
    /// empty body — yields nil and the caller falls back to canned wording.
    private static func serverMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let single = object["error"] as? String, !single.isEmpty { return single }
        if let list = object["errors"] as? [String] {
            let joined = list.filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    /// `Retry-After` when the server sends one, else a short default. Clamped
    /// so a generous server value can't leave a screen waiting.
    /// The longest a retry will wait before giving up instead.
    ///
    /// Past this the request is abandoned rather than delayed. Waiting 20s
    /// behind a screen is not a fix, and — more to the point — *retrying early*
    /// is strictly worse than not retrying: it earns a second 429, and each
    /// rejected request extends the window. That is visible in the wild as a
    /// countdown that never counts down (20s → 16s → 12s → 9s across
    /// successive attempts), which is the client feeding its own block.
    private static let maximumRetryWait: Double = 5

    /// How long the server asked us to wait, or nil if it didn't say.
    ///
    /// The body is authoritative for Discourse — it answers with
    /// `extras.wait_seconds` — and `Retry-After` is the HTTP-level fallback,
    /// which a proxy may round or drop. Neither is clamped downwards any more;
    /// the old code capped the answer at 3s, so a server asking for 20 was
    /// always retried 17s too early.
    private static func retryDelay(from response: HTTPURLResponse, body: Data) -> Double? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let extras = object["extras"] as? [String: Any] {
            if let seconds = extras["wait_seconds"] as? Double { return seconds }
            if let seconds = extras["wait_seconds"] as? Int { return Double(seconds) }
        }
        return response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
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
            // Callers routinely use `try?`, so a decode failure is
            // otherwise indistinguishable from "no data" — that silence
            // has already hidden real bugs (a mis-spelled optional field
            // simply stayed nil forever).
            #if DEBUG
            let preview = String(decoding: data.prefix(400), as: UTF8.self)
            print("[DiscourseAPI] decode failed for \(T.self): \(error)")
            print("[DiscourseAPI]   body: \(preview)")
            #endif
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

    /// One of the home tab's lists. All four answer with the same `topic_list`
    /// payload, so only the path differs.
    ///
    /// `seed` is for `best`, whose ordering is randomised per request — see
    /// `HomeFeed.isSeeded`. Pass back the seed the first page reported and
    /// later pages continue that same ordering.
    func topicList(
        feed: HomeFeed,
        page: Int = 0,
        seed: String? = nil
    ) async throws -> LatestResponse {
        var query: [URLQueryItem] = []
        if page > 0 { query.append(URLQueryItem(name: "page", value: String(page))) }
        if let seed { query.append(URLQueryItem(name: "seed", value: seed)) }
        return try await get(feed.path, query: query)
    }

    /// Sends the activation mail again, for an account that hasn't been
    /// activated yet. Core Discourse's `UsersController#send_activation_email`.
    ///
    /// Needs no session — the account being activated can't sign in yet, which
    /// is the whole point.
    @discardableResult
    func resendActivationEmail(username: String) async throws -> Data {
        try await post("u/action/send_activation_email", form: ["username": username])
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

    /// Topics carrying a tag. Same `topic_list` payload as a node's list, so
    /// the rows and the mapping are shared; paginated with `?page=` from 0.
    func tagTopics(slug: String, page: Int = 0) async throws -> CategoryTopicsResponse {
        try await get(
            "tag/\(slug).json",
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

    /// How much a *topic* notifies this user — the same integers as a node's
    /// level (`NodeNotificationLevel`), on the topic's own endpoint.
    @discardableResult
    func setTopicNotification(topicID: Int, level: Int) async throws -> Data {
        try await post(
            "t/\(topicID)/notifications",
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

    // MARK: Custom feeds
    //
    // discourse-community's custom feeds: a named set of nodes read as one
    // list. Routes taken from the plugin's own bundle — the web client has no
    // create/manage *page*, only modals, which is why there is no `/custom-feeds`
    // GET route to lean on here.

    /// The signed-in reader's own feeds, private ones included.
    func customFeeds() async throws -> CustomFeedsResponse {
        try await get("custom-feeds.json")
    }

    /// Someone else's feeds — only those they marked `show_on_profile`.
    func customFeeds(username: String) async throws -> CustomFeedsResponse {
        try await get("custom-feeds/by-user/\(username).json")
    }

    /// One feed and the nodes it gathers.
    func customFeed(username: String, slug: String) async throws -> CustomFeedResponse {
        try await get("custom-feeds/\(username)/\(slug).json")
    }

    /// The feed's topics. A plain `topic_list` with `users`, exactly like the
    /// home feed, so `FeedMapper` maps it unchanged. Paginates with `?page=`,
    /// as its own `more_topics_url` advertises.
    func customFeedTopics(
        username: String,
        slug: String,
        page: Int = 0
    ) async throws -> CategoryTopicsResponse {
        try await get(
            "f/\(username)/\(slug).json",
            query: page > 0 ? [URLQueryItem(name: "page", value: String(page))] : []
        )
    }

    func createCustomFeed(
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        try await Self.decode(
            formItems("POST", path: "custom-feeds", items: Self.customFeedForm(
                name: name, description: description,
                isPrivate: isPrivate, showOnProfile: showOnProfile
            ))
        )
    }

    func updateCustomFeed(
        id: Int,
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        try await Self.decode(
            formItems("PUT", path: "custom-feeds/\(id)", items: Self.customFeedForm(
                name: name, description: description,
                isPrivate: isPrivate, showOnProfile: showOnProfile
            ))
        )
    }

    func deleteCustomFeed(id: Int) async throws {
        _ = try await send("DELETE", path: "custom-feeds/\(id)")
    }

    /// Copies someone else's feed, nodes and all, into one of your own.
    func copyCustomFeed(
        username: String,
        slug: String,
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) async throws -> CustomFeedResponse {
        try await Self.decode(
            formItems("POST", path: "custom-feeds/\(username)/\(slug)/copy", items: Self.customFeedForm(
                name: name, description: description,
                isPrivate: isPrivate, showOnProfile: showOnProfile
            ))
        )
    }

    /// Both node mutations answer with the whole updated feed.
    func addCustomFeedNode(feedID: Int, categoryID: Int) async throws -> CustomFeedResponse {
        try await Self.decode(
            formItems(
                "POST",
                path: "custom-feeds/\(feedID)/nodes",
                items: [("category_id", String(categoryID))]
            )
        )
    }

    func removeCustomFeedNode(feedID: Int, categoryID: Int) async throws -> CustomFeedResponse {
        try await Self.decode(send("DELETE", path: "custom-feeds/\(feedID)/nodes/\(categoryID)"))
    }

    /// Nodes matching `term`, to add to a feed.
    func customFeedNodeSearch(term: String) async throws -> CustomFeedNodeSearchResponse {
        try await get(
            "custom-feeds/node-search",
            query: [URLQueryItem(name: "term", value: term)]
        )
    }

    /// The four fields the plugin's create/edit/copy forms all submit.
    private static func customFeedForm(
        name: String,
        description: String,
        isPrivate: Bool,
        showOnProfile: Bool
    ) -> [(String, String)] {
        [
            ("name", name),
            ("description", description),
            ("private", isPrivate ? "true" : "false"),
            // The plugin clears this itself when private is set, but sending a
            // contradiction would be asking the server to resolve our bug.
            ("show_on_profile", (isPrivate ? false : showOnProfile) ? "true" : "false"),
        ]
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

    /// Full-page search. `filters` are Discourse's own `q` operators, e.g.
    /// "with:images" — appended to the term the way the web search box does.
    func search(_ term: String, filters: String? = nil) async throws -> SearchResponse {
        let q = [term, filters].compactMap { $0 }.joined(separator: " ")
        return try await get("search.json", query: [URLQueryItem(name: "q", value: q)])
    }

    // MARK: Checkin & upgrade progress (site plugins)

    /// 签到 — discourse-checkin. The site's own button posts a nonce and a
    /// timestamp with two marker headers; the reply carries the points award
    /// or a message explaining why it was refused (already signed in today).
    func checkIn() async throws -> CheckinResponse {
        var request = makeRequest("POST", path: "checkin", includeCSRF: true)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "X-Discourse-Checkin")
        let nonce = UUID().uuidString
        request.setValue(nonce, forHTTPHeaderField: "X-Checkin-Nonce")
        request.httpBody = [
            "nonce=\(nonce)",
            "timestamp=\(Int(Date().timeIntervalSince1970 * 1000))",
        ].joined(separator: "&").data(using: .utf8)
        return try Self.decode(try await perform(request))
    }

    /// 升级进度 — discourse-upgrade-process.
    func upgradeProgress(username: String) async throws -> UpgradeProgressReport {
        try await get("u/\(username)/upgrade-progress.json")
    }

    /// The companion plugin's one-shot profile payload, replacing the five
    /// calls `ProfileStore.load` used to fan out — see
    /// `SERVER_TASKS_PROFILE_AGGREGATE.md`.
    ///
    /// Hands back the raw bytes as well as the decoded value: the profile page
    /// keeps the last response on disk to render from on the next launch, and
    /// storing the server's own JSON avoids inventing a second encoding path
    /// that could drift from this one.
    ///
    /// - Parameter username: `nil` asks for the signed-in user.
    func profileAggregate(
        username: String?,
        activityFilter: Int
    ) async throws -> (data: Data, response: ProfileAggregateResponse) {
        var query = [URLQueryItem(name: "activity_filter", value: String(activityFilter))]
        if let username {
            query.append(URLQueryItem(name: "username", value: username))
        }
        let data = try await perform(
            makeRequest(path: "mobile/profile.json", query: query, includeCSRF: false)
        )
        return (data, try Self.decode(data))
    }

    /// Decodes a profile payload that came off disk rather than the network.
    static func decodeProfileAggregate(_ data: Data) -> ProfileAggregateResponse? {
        try? decode(data)
    }

    /// Same, for a stored chat channel list.
    static func decodeChatChannels(_ data: Data) throws -> ChatChannelsResponse {
        try decode(data)
    }

    /// Pins (or unpins — it toggles) a top-level reply, discourse-community's
    /// nested-replies feature. Staff only; the answer is the topic's full set of
    /// pinned post ids, so callers replace rather than patch.
    func togglePinnedPost(topicID: Int, slug: String = "topic", postID: Int) async throws -> PinnedPostsResponse {
        let data = try await formItems(
            "PUT",
            path: "n/\(slug)/\(topicID)/pin.json",
            items: [("post_id", String(postID))]
        )
        return try Self.decode(data)
    }

    // MARK: 发帖来源 (discourse-mobile)

    /// The account's disclosure level for the 小尾巴 — stored server-side, so it
    /// Server-controlled feature switches (see `FeatureFlags`). Deliberately
    /// throwing rather than optional: the caller treats any failure as "keep
    /// the last known values".
    func featureFlags() async throws -> FeatureFlagConfig {
        try await get("mobile/feature_flags.json")
    }

    /// follows the account rather than the device.
    func postSourceLevel() async throws -> PostSourceLevelResponse {
        try await get("mobile/preferences/post_source")
    }

    @discardableResult
    func setPostSourceLevel(_ level: Int) async throws -> PostSourceLevelResponse {
        let data = try await formItems(
            "PUT",
            path: "mobile/preferences/post_source",
            items: [("level", String(level))]
        )
        return try Self.decode(data)
    }

    /// Strips the tail off everything already posted. A deletion, not a hidden
    /// flag: lowering the level only governs what comes next.
    func clearPostSourceHistory() async throws -> ClearPostSourcesResponse {
        let data = try await send("DELETE", path: "mobile/preferences/post_source/history")
        return try Self.decode(data)
    }

    // MARK: Relationship with one user

    /// 通知方式 for a single user: the same three levels the site's own
    /// dropdown writes (`normal` / `mute` / `ignore`).
    ///
    /// Ignoring needs an expiry — Discourse's `IgnoredUser` requires one and
    /// the server parses it unconditionally — so 屏蔽 must send a date. The web
    /// UI's 永久 option is simply a very distant one, which is what
    /// `UserNotificationLevel.expiry` produces.
    @discardableResult
    func setUserNotificationLevel(
        username: String,
        level: String,
        expiringAt: Date? = nil
    ) async throws -> Data {
        var items = [("notification_level", level)]
        if let expiringAt {
            items.append(("expiring_at", ISO8601DateFormatter().string(from: expiringAt)))
        }
        return try await formItems("PUT", path: "u/\(username)/notification_level.json", items: items)
    }

    /// Opens the direct-message channel with one user. Discourse returns the
    /// existing channel when there already is one, so this doubles as "find".
    func createDirectMessageChannel(usernames: [String]) async throws -> ChatChannelResponse {
        let data = try await formItems(
            "POST",
            path: "chat/api/direct-message-channels.json",
            items: usernames.map { ("target_usernames[]", $0) }
        )
        return try Self.decode(data)
    }

    /// Starts a 私信. `archetype=private_message` plus recipients is what turns
    /// `POST /posts` into a message rather than a public topic.
    @discardableResult
    func createPrivateMessage(recipient: String, title: String, raw: String) async throws -> CreatePostResponse {
        var form = [
            "title": title,
            "raw": raw,
            "archetype": "private_message",
            "target_recipients": recipient,
        ]
        // A message is a post like any other, and the disclosure level is the
        // author's — applying it here too keeps one setting from meaning two
        // different things.
        form.merge(DeviceSource.postFields) { current, _ in current }
        let data = try await post("posts", form: form)
        return try Self.decode(data)
    }

    /// Tag completion for the composer's `#` trigger.
    func searchTags(term: String, limit: Int = 5) async throws -> TagSearchResponse {
        try await get(
            "tags/filter/search",
            query: [
                URLQueryItem(name: "q", value: term),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    /// Dedicated user search. `/search.json` reports zero users for a plain
    /// term, so people have to be looked up through their own endpoint.
    func searchUsers(term: String) async throws -> UserSearchResponse {
        try await get(
            "u/search/users.json",
            query: [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "limit", value: "20"),
            ]
        )
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

    /// Every published app, across as many pages as it takes.
    ///
    /// Two things this got wrong before, both of which showed up as
    /// "数据加载出错" on 浏览全部应用:
    ///
    /// * The payload is an object (`{ apps, total, page, per_page }`), not the
    ///   bare array it used to decode into.
    /// * It is paginated at a fixed 24. `per_page` is reported back but
    ///   ignored as input, and `page` is zero-based — 33 apps arrive as 24 + 9,
    ///   so one request silently dropped a third of the directory.
    func appsDirectory() async throws -> [DirectoryApp] {
        var collected: [DirectoryApp] = []

        for page in 0..<Self.appsDirectoryPageLimit {
            let response: AppsDirectoryResponse = try await get(
                "apps/directory.json",
                query: [URLQueryItem(name: "page", value: String(page))]
            )
            collected.append(contentsOf: response.apps)

            // An empty page ends it too, so a missing or wrong `total` can't
            // turn this into an endless walk.
            if response.apps.isEmpty { break }
            if let total = response.total, collected.count >= total { break }
        }

        return collected
    }

    /// Enough for the directory several times over; only here so a server that
    /// keeps answering can't loop forever.
    private static let appsDirectoryPageLimit = 20

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
    ///
    /// `offset` was pinned to 0 here, which is why a profile tab could only
    /// ever show its first page. The endpoint pages fine — verified that
    /// `offset=30` returns the next 30 — so the limitation was ours.
    static let userActionsPageSize = 30

    func userActions(
        username: String,
        filter: Int,
        offset: Int = 0
    ) async throws -> UserActionsResponse {
        try await get("user_actions.json", query: [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "filter", value: String(filter)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(Self.userActionsPageSize))
        ])
    }

    // MARK: Native Sign in with Apple

    /// Trades a native Apple credential for a Discourse session.
    ///
    /// The companion plugin verifies the identity token and replies by setting
    /// the ordinary `_t` session cookie, which `URLSession.shared`'s jar picks
    /// up — so there is nothing to read out of the body. Discourse core has no
    /// endpoint for this; see `SERVER_TASKS_APPLE_SIGNIN.md`.
    ///
    /// Throws `DiscourseError.badResponse(404)` or `(501)` when the endpoint
    /// isn't deployed, which is the caller's signal to use the web flow.
    @discardableResult
    func nativeAppleLogin(_ credential: AppleSignInCredential) async throws -> Data {
        struct Body: Encodable {
            let identityToken: String
            let nonce: String
            let authorizationCode: String?
            let email: String?
            let fullName: String?

            enum CodingKeys: String, CodingKey {
                case identityToken = "identity_token"
                case nonce
                case authorizationCode = "authorization_code"
                case email
                case fullName = "full_name"
            }
        }

        let data = try await postJSON("mobile/auth/apple.json", body: Body(
            identityToken: credential.identityToken,
            nonce: credential.nonce,
            authorizationCode: credential.authorizationCode,
            email: credential.email,
            fullName: credential.fullName
        ))
        #if DEBUG
        // The two callers differ only by whether a session travels with the
        // request, so the body is the fastest way to see which branch the
        // server took.
        print("[AppleSignIn] response: \(String(decoding: data.prefix(400), as: UTF8.self))")
        #endif
        return data
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

    /// Marks one notification read.
    ///
    /// Same endpoint; Discourse narrows it to a single row when given an `id`,
    /// which is what opening one notification should do. Without the id it
    /// clears the whole list — a much bigger claim than "I read this one".
    @discardableResult
    func markNotificationRead(id: Int) async throws -> Data {
        try await formItems("PUT", path: "notifications/mark-read", items: [("id", String(id))])
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
        try await chatChannelsWithRaw().response
    }

    /// Raw variant, for the same reason `chatMessagesWithRaw` exists: the
    /// stored copy is the bytes the server sent, so opening the chat list from
    /// disk re-decodes through the identical path a live response takes.
    ///
    /// Keeps the two-path fallback — `chat/api/me/channels.json` is the newer
    /// route and older installs only answer the second.
    func chatChannelsWithRaw() async throws -> (response: ChatChannelsResponse, raw: Data) {
        func fetch(_ path: String) async throws -> (ChatChannelsResponse, Data) {
            let data = try await perform(makeRequest(path: path, includeCSRF: false))
            return (try Self.decode(data), data)
        }
        do {
            return try await fetch("chat/api/me/channels.json")
        } catch DiscourseError.badResponse(let code, _) where code == 404 {
            return try await fetch("chat/api/channels.json")
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
        // Without this MessageBus answers a long poll in its *chunked* framing —
        // `[]\r\n|\r\n[]\r\n|\r\n`, several JSON documents separated by
        // pipes — which is not JSON, so every poll's payload was discarded and
        // chat never went live. The header is MessageBus's own opt-out and it
        // still long-polls; it just answers with one array.
        request.setValue("true", forHTTPHeaderField: "Dont-Chunk")
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

    /// `uploadIDs` repeats as `upload_ids[]`, which a `[String: String]` form
    /// can't express — the same shape the site's own composer sends. A message
    /// carrying uploads may have empty text.
    func createChatMessage(
        channelID: Int,
        message: String,
        threadID: Int? = nil,
        inReplyToID: Int? = nil,
        uploadIDs: [Int] = []
    ) async throws -> ChatCreateMessageResponse {
        var items: [(String, String)] = [("message", message)]
        if let threadID {
            items.append(("thread_id", String(threadID)))
        }
        // `Chat::CreateMessage`'s own contract attribute. The reply comes back on
        // the message as `in_reply_to`, which the app already decodes.
        if let inReplyToID {
            items.append(("in_reply_to_id", String(inReplyToID)))
        }
        items.append(contentsOf: uploadIDs.map { ("upload_ids[]", String($0)) })

        let data = try await formItems("POST", path: "chat/\(channelID).json", items: items)
        return try Self.decode(data)
    }

    /// Chat's own upload bucket. The type matters: the site's uploader declares
    /// `chat-composer`, and Discourse validates allowed extensions per type.
    func uploadChatMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        try await postMultipart(
            "uploads.json",
            fields: [
                "upload_type": "chat-composer",
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

    /// One channel, with `current_user_membership` — which is where the mute
    /// flag and notification level live.
    func chatChannel(id: Int) async throws -> ChatChannelResponse {
        try await get("chat/api/channels/\(id).json")
    }

    /// The channel's notification settings for me. One endpoint for both knobs,
    /// nested under `notifications_settings` exactly as the web sends it; the
    /// answer is the updated membership.
    @discardableResult
    func updateChatChannelNotifications(
        id: Int,
        muted: Bool? = nil,
        notificationLevel: String? = nil
    ) async throws -> ChatMembershipResponse {
        var items: [(String, String)] = []
        if let muted { items.append(("notifications_settings[muted]", muted ? "true" : "false")) }
        if let notificationLevel {
            items.append(("notifications_settings[notification_level]", notificationLevel))
        }
        let data = try await formItems(
            "PUT",
            path: "chat/api/channels/\(id)/notifications-settings/me",
            items: items
        )
        return try Self.decode(data)
    }

    /// Leaves a direct message. Note the `/follows` suffix: that is what the web
    /// calls for a DM, while a public channel drops the whole membership.
    @discardableResult
    func unfollowChatChannel(id: Int) async throws -> Data {
        try await send("DELETE", path: "chat/api/channels/\(id)/memberships/me/follows")
    }

    /// Marks every chat channel read at once — the plugin's own
    /// `markAllChannelsAsRead`, which needs no message ids.
    @discardableResult
    func markAllChatChannelsRead() async throws -> Data {
        try await send("PUT", path: "chat/api/channels/read")
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

    /// Casts (or retracts) a vote — discourse-vote.
    ///
    /// The direction is where the vote should *end up*, not a toggle, so a
    /// double tap or a retried request can't drift from the server. An upvote is
    /// a core like under the hood; switching to a downvote retracts it first,
    /// which is why both directions go through this one call rather than the
    /// like endpoints.
    /// `reaction` names the face to vote with; without one the direction's
    /// default is used (the main reaction upward, the first excluded face down).
    @discardableResult
    func castVote(
        postID: Int,
        direction: VoteDirection,
        reaction: String? = nil
    ) async throws -> Data {
        var items = [("direction", direction.rawValue)]
        if let reaction, !reaction.isEmpty {
            items.append(("reaction", reaction))
        }
        return try await formItems("PUT", path: "vote/posts/\(postID)", items: items)
    }

    /// Who reacted to a post, grouped by face — discourse-reactions.
    func reactionUsers(postID: Int) async throws -> ReactionUsersResponse {
        try await get("discourse-reactions/posts/\(postID)/reactions-users.json")
    }

    /// Removes a previously-given like (post_action_type_id 2).
    func unlikePost(id: Int) async throws {
        try await formItems("DELETE", path: "post_actions/\(id)", items: [
            ("post_action_type_id", "2"),
        ])
    }

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
        form.merge(DeviceSource.postFields) { current, _ in current }
        let data = try await post("posts", form: form)
        return try Self.decode(data)
    }

    // MARK: Editing & moderation
    //
    // Every one of these is gated in the UI by a `can_*` flag the server put on
    // the post or topic, never by the app deciding who is staff. That is what
    // makes a *node* moderator behave correctly: Discourse serializes the flags
    // per object, so their rights appear on their own node's content and
    // nowhere else, and the app doesn't have to know which nodes those are.

    /// The markdown behind a post, for prefilling the editor.
    func postRaw(id: Int) async throws -> PostRawResponse {
        try await get("posts/\(id).json")
    }

    /// Saves an edit. `edit_reason` is optional and shows in the post's history.
    @discardableResult
    func updatePost(id: Int, raw: String, editReason: String? = nil) async throws -> Data {
        var items = [("post[raw]", raw)]
        if let editReason, !editReason.isEmpty {
            items.append(("post[edit_reason]", editReason))
        }
        return try await formItems("PUT", path: "posts/\(id).json", items: items)
    }

    /// Deletes a post. Discourse soft-deletes for staff (recoverable) and
    /// tombstones for an author deleting their own.
    @discardableResult
    func deletePost(id: Int) async throws -> Data {
        try await send("DELETE", path: "posts/\(id).json")
    }

    @discardableResult
    func recoverPost(id: Int) async throws -> Data {
        try await send("PUT", path: "posts/\(id)/recover.json")
    }

    /// Adds or removes an emoji reaction on a chat message.
    ///
    /// The one chat write that isn't under `/chat/api`: it lives on the legacy
    /// controller as `PUT /chat/:channel_id/react/:message_id`, taking `emoji`
    /// and `react_action` ("add" / "remove") — `Chat::MessageReactor`'s two
    /// actions.
    @discardableResult
    func reactToChatMessage(
        channelID: Int,
        messageID: Int,
        emoji: String,
        add: Bool
    ) async throws -> Data {
        try await formItems(
            "PUT",
            path: "chat/\(channelID)/react/\(messageID).json",
            items: [
                // Bare name, no colons: `Emoji.exists?` is checked against the
                // name and the serializer echoes it back the same way.
                ("emoji", emoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))),
                ("react_action", add ? "add" : "remove"),
            ]
        )
    }

    /// Edits a chat message. Only `message` changes; uploads keep whatever the
    /// message already had.
    @discardableResult
    func updateChatMessage(channelID: Int, messageID: Int, message: String) async throws -> Data {
        try await formItems(
            "PUT",
            path: "chat/api/channels/\(channelID)/messages/\(messageID)",
            items: [("message", message)]
        )
    }

    /// Trashes a chat message. Recoverable — see `restoreChatMessage`.
    @discardableResult
    func deleteChatMessage(channelID: Int, messageID: Int) async throws -> Data {
        try await send("DELETE", path: "chat/api/channels/\(channelID)/messages/\(messageID)")
    }

    @discardableResult
    func restoreChatMessage(channelID: Int, messageID: Int) async throws -> Data {
        try await send("PUT", path: "chat/api/channels/\(channelID)/messages/\(messageID)/restore")
    }

    /// Deletes the signed-in account, posts and all.
    ///
    /// `UserDestroyer` runs with `delete_posts: true`. The server refuses with
    /// 403 when `can_delete_account` is false, which is why the UI reads that
    /// flag first and offers to write to staff instead.
    @discardableResult
    func deleteAccount(username: String) async throws -> Data {
        try await send("DELETE", path: "u/\(username).json")
    }

    /// Flags a chat message. `flagTypeID` is a `PostActionType` id — the same
    /// ids `site.json` serves for posts, filtered per message by the server's
    /// `available_flags`.
    @discardableResult
    func flagChatMessage(
        channelID: Int,
        messageID: Int,
        flagTypeID: Int,
        message: String? = nil
    ) async throws -> Data {
        var items = [("flag_type_id", String(flagTypeID))]
        if let message, !message.isEmpty { items.append(("message", message)) }
        return try await formItems(
            "POST",
            path: "chat/api/channels/\(channelID)/messages/\(messageID)/flags",
            items: items
        )
    }

    /// The channel's pinned messages. Gated by the `chat_pinned_messages` site
    /// setting — a 404 means the feature is off, not that something broke.
    func chatChannelPins(channelID: Int) async throws -> ChatPinsResponse {
        try await get("chat/api/channels/\(channelID)/pins")
    }

    @discardableResult
    func pinChatMessage(channelID: Int, messageID: Int) async throws -> Data {
        try await send("POST", path: "chat/api/channels/\(channelID)/messages/\(messageID)/pin")
    }

    @discardableResult
    func unpinChatMessage(channelID: Int, messageID: Int) async throws -> Data {
        try await send("DELETE", path: "chat/api/channels/\(channelID)/messages/\(messageID)/pin")
    }

    /// Clears the "new pin" marker on the channel's pinned bar.
    @discardableResult
    func markChatPinsRead(channelID: Int) async throws -> Data {
        try await send("PUT", path: "chat/api/channels/\(channelID)/pins/read")
    }

    /// Adds people to an existing channel — a group DM or a category channel.
    /// `usernames` is capped server-side by `chat_max_direct_message_users`.
    @discardableResult
    func addUsersToChatChannel(channelID: Int, usernames: [String]) async throws -> Data {
        try await formItems(
            "POST",
            path: "chat/api/channels/\(channelID)/memberships",
            items: usernames.map { ("usernames[]", $0) }
        )
    }

    @discardableResult
    func removeUserFromChatChannel(channelID: Int, userID: Int) async throws -> Data {
        try await send("DELETE", path: "chat/api/channels/\(channelID)/memberships/\(userID)")
    }

    /// Stores the unsent draft server-side, so it survives to another device.
    /// `data` is the composer state as JSON — Discourse's own shape, which for a
    /// plain message is `{"message":"…"}`.
    @discardableResult
    func saveChatDraft(channelID: Int, threadID: Int? = nil, message: String) async throws -> Data {
        var items: [(String, String)] = []
        if let payload = try? JSONSerialization.data(withJSONObject: ["message": message]),
           let json = String(data: payload, encoding: .utf8) {
            items.append(("data", json))
        }
        if let threadID { items.append(("thread_id", String(threadID))) }
        return try await formItems(
            "POST",
            path: "chat/api/channels/\(channelID)/drafts",
            items: items
        )
    }

    /// Turns chat messages into forum markdown — `Chat::TranscriptService` — for
    /// quoting a conversation into a topic or a reply.
    func chatTranscript(channelID: Int, messageIDs: [Int]) async throws -> ChatTranscriptResponse {
        let data = try await formItems(
            "POST",
            path: "chat/\(channelID)/quote.json",
            items: messageIDs.map { ("message_ids[]", String($0)) }
        )
        return try Self.decode(data)
    }

    /// Per-thread notification level ("always" / "normal" / "tracking" / "muted"
    /// in `Chat::NotificationLevels`).
    @discardableResult
    func setChatThreadNotificationLevel(
        channelID: Int,
        threadID: Int,
        level: String
    ) async throws -> Data {
        try await formItems(
            "PUT",
            path: "chat/api/channels/\(channelID)/threads/\(threadID)/notifications-settings/me",
            items: [("notification_level", level)]
        )
    }

    /// Who belongs to a chat channel. `INDEX_LIMIT` on the server is 50, so a
    /// bigger `limit` is silently clamped — page with `offset`.
    func chatChannelMemberships(
        channelID: Int,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> ChatMembershipsResponse {
        try await get(
            "chat/api/channels/\(channelID)/memberships",
            query: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    /// Every emoji the site offers, grouped — standard sets first, then each
    /// custom group. Same endpoint the web's picker uses.
    func emojis() async throws -> [String: [DiscourseEmoji]] {
        try await get("emojis.json")
    }

    /// discourse-anyvideo's record for one upload, by the upload's SHA1 — the
    /// same lookup the web player does to find an HLS rendition.
    func anyVideo(sha1: String) async throws -> AnyVideoResponse {
        try await get("anyvideo/videos/by_sha1/\(sha1).json")
    }

    /// discourse-anyvideo's random pick of video topics, for the full-screen
    /// player's upward swipe. `excludingTopicID` keeps the one on screen out of
    /// the result — the plugin filters it server-side.
    func videoSuggestions(excludingTopicID: Int? = nil) async throws -> VideoSuggestionsResponse {
        var query: [URLQueryItem] = []
        if let excludingTopicID {
            query.append(URLQueryItem(name: "exclude_topic_id", value: String(excludingTopicID)))
        }
        return try await get("anyvideo/videos/suggestions.json", query: query)
    }

    /// One post's cooked HTML. The nested view blanks `cooked` for a reply whose
    /// author the viewer ignores; this is the endpoint the web's reveal button
    /// calls to fetch it back.
    func postCooked(id: Int) async throws -> PostCookedResponse {
        try await get("posts/\(id)/cooked.json")
    }

    /// Retitles or recategorises a topic. The `-` stands in for the slug, which
    /// only affects the canonical URL.
    @discardableResult
    func updateTopic(id: Int, title: String? = nil, categoryID: Int? = nil) async throws -> Data {
        var items: [(String, String)] = []
        if let title { items.append(("title", title)) }
        if let categoryID { items.append(("category_id", String(categoryID))) }
        return try await formItems("PUT", path: "t/-/\(id).json", items: items)
    }

    @discardableResult
    func deleteTopic(id: Int) async throws -> Data {
        try await send("DELETE", path: "t/\(id).json")
    }

    /// Topic status flags: "closed", "visible", "archived", "pinned",
    /// "pinned_globally". The same endpoint the web's topic admin menu uses.
    ///
    /// `until` only means anything to the two pinned statuses, where the server
    /// schedules an `unpin_topic` job for it. Sent as ISO 8601, which is what
    /// `Time.parse` on the other end wants.
    @discardableResult
    func setTopicStatus(
        id: Int,
        status: String,
        enabled: Bool,
        until: Date? = nil
    ) async throws -> Data {
        var items = [("status", status), ("enabled", enabled ? "true" : "false")]
        if let until {
            items.append(("until", ISO8601DateFormatter().string(from: until)))
        }
        return try await formItems("PUT", path: "t/\(id)/status.json", items: items)
    }

    /// Hides a pin from *this* reader only — `topic_users.cleared_pinned_at`.
    /// Anyone may do it to any pinned topic they can see; it moderates nothing.
    @discardableResult
    func clearTopicPin(id: Int) async throws -> Data {
        try await send("PUT", path: "t/\(id)/clear-pin.json")
    }

    /// Undoes `clearTopicPin`, putting the pin back for this reader.
    @discardableResult
    func reTopicPin(id: Int) async throws -> Data {
        try await send("PUT", path: "t/\(id)/re-pin.json")
    }

    /// The third featured mode: a banner shows on every page until each reader
    /// dismisses it. Staff only, and only one banner exists at a time — making
    /// a new one replaces the old.
    @discardableResult
    func makeTopicBanner(id: Int) async throws -> Data {
        try await send("PUT", path: "t/\(id)/make-banner.json")
    }

    @discardableResult
    func removeTopicBanner(id: Int) async throws -> Data {
        try await send("PUT", path: "t/\(id)/remove-banner.json")
    }

    /// How full the featured slots already are, for the 置顶 sheet's counts.
    func topicFeatureStats(categoryID: Int?) async throws -> TopicFeatureStats {
        var query: [URLQueryItem] = []
        if let categoryID {
            query.append(URLQueryItem(name: "category_id", value: String(categoryID)))
        }
        return try await get("topics/feature_stats.json", query: query)
    }

    /// Flags a post or a topic — Discourse's `POST /post_actions`, the same call
    /// the web's flag modal makes.
    ///
    /// With `flagTopic` true, `id` is the *topic* id and the server resolves it
    /// to the first post itself (`fetch_post_from_params`); otherwise `id` is a
    /// post id. `message` is required by some flag types and rejected as too
    /// short otherwise.
    @discardableResult
    func flag(
        id: Int,
        typeID: Int,
        message: String? = nil,
        flagTopic: Bool = false
    ) async throws -> Data {
        var form = [
            "id": String(id),
            "post_action_type_id": String(typeID),
            "flag_topic": flagTopic ? "true" : "false",
        ]
        if let message, !message.isEmpty { form["message"] = message }
        return try await post("post_actions", form: form)
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
        var form = [
            "title": title,
            "raw": raw,
            "category": String(categoryID),
            "archetype": "regular",
        ]
        form.merge(DeviceSource.postFields) { current, _ in current }
        let data = try await post("posts", form: form)
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
        // Cooked titles carry the typographic set too — `fancy_title` renders
        // an apostrophe as `&rsquo;`, which used to reach the screen literally.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&hellip;": "…", "&nbsp;": " ",
                        "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“",
                        "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .breakingLongTokens()
    }

    /// Prose from the server, which arrives as HTML, rendered as text that
    /// keeps its paragraph breaks.
    ///
    /// `plainText` is for excerpts and titles, where every tag collapses to
    /// nothing on purpose — a one-line excerpt wants no newlines. That is
    /// wrong for a message meant to be *read*: Discourse's own
    /// `login.activate_email` is
    /// `<p>…activate your account.</p><p>If it doesn't arrive…</p>`, and
    /// dropping the tags outright runs the two sentences together.
    static func plainTextParagraphs(_ html: String?) -> String {
        guard let html else { return "" }
        // Block boundaries become breaks before the tags are stripped.
        var text = html.replacing(/<\s*br\s*\/?>/.ignoresCase(), with: "\n")
        text = text.replacing(/<\s*\/\s*(p|div|li|h[1-6])\s*>/.ignoresCase(), with: "\n\n")
        return plainText(text)
            // Collapse the runs the substitutions above can leave behind, so a
            // trailing `</p>` doesn't end the message with blank lines.
            .replacing(/\n{3,}/, with: "\n\n")
            .replacing(/[ \t]+\n/, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title to display for a topic, translated when a translation exists.
    ///
    /// Content localization only rewrites `fancy_title`, so a localized topic
    /// has to be read from there. `title` stays the original and is otherwise
    /// preferable — it holds real emoji and no entities — so it keeps winning
    /// whenever `fancy_title_localized` is false.
    static func displayTitle(for topic: TopicListItem) -> String {
        displayTitle(
            title: topic.title,
            fancyTitle: topic.fancyTitle,
            isLocalized: topic.fancyTitleLocalized
        )
    }

    /// Same rule for the topic detail, which carries the fields separately.
    static func displayTitle(title: String, fancyTitle: String?, isLocalized: Bool?) -> String {
        guard isLocalized == true, let fancyTitle, !fancyTitle.isEmpty else { return title }
        return localizedTitle(fancyTitle)
    }

    /// Cleans up a cooked title for display as plain text.
    ///
    /// Emoji arrive as `:shortcode:` and are dropped rather than mapped: the
    /// chat renderer already found that a shortcode→character table covers only
    /// a fraction of the set and leaves the rest showing as literal text
    /// (`:grinning_face:`), and a row of plain text has nowhere to put the
    /// images Discourse serves instead. Losing the emoji from a *translated*
    /// title is the smaller loss — the alternative is not translating it.
    static func localizedTitle(_ fancyTitle: String) -> String {
        var text = plainText(fancyTitle)
        text = text.replacing(emojiShortcodePattern, with: " ")
        return text
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `:name:` / `:name_1:` — Discourse's shortcode form.
    ///
    /// The body must contain a letter, which keeps a timestamp intact: a naive
    /// `:[a-z0-9_+-]{2,}:` matches the `:30:` inside "10:30:45" and would turn
    /// it into "10 45". `:+1:` and `:-1:` are the two real shortcodes with no
    /// letter in them, so they are spelled out.
    private static let emojiShortcodePattern = /:(?:\+1|-1|[a-z0-9_+-]*[a-z][a-z0-9_+-]*):/

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
