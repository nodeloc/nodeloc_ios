//
//  DiscourseAPI.swift
//  nodeloc
//
//  Lightweight async client for the nodeloc.com Discourse backend.
//  Reading is public (login_required = false); authenticated calls attach either
//  a Discourse User-Api-Key or a website session cookie after login.
//

import Foundation

enum DiscourseConfig {
    static let baseURL = URL(string: "https://www.nodeloc.com")!
    /// Custom URL scheme registered for the User API Key redirect.
    static let authRedirect = "nodeloc://auth"
    static let appName = "NODELOC iOS"
    static let clientIDDefaultsKey = "nodeloc.client_id"

    static func clientID() -> String {
        if let existing = UserDefaults.standard.string(forKey: clientIDDefaultsKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientIDDefaultsKey)
        return id
    }
}

/// Holds the signed-in user's auth state. The app supports both Discourse User API
/// keys and normal website sessions so it can use the same username/password flow
/// as the site.
@Observable
final class DiscourseAuth {
    static let shared = DiscourseAuth()
    var userApiKey: String?
    var sessionCookie: String?
    var csrfToken: String?
    var username: String?
    var isAuthenticated: Bool { userApiKey != nil || sessionCookie != nil }
}

enum DiscourseError: Error, LocalizedError {
    case badResponse(Int)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Server returned status \(code)."
        case .decoding(let error): return "Couldn't read the response: \(error.localizedDescription)"
        case .transport(let error): return error.localizedDescription
        }
    }
}

struct DiscourseClient {
    var baseURL = DiscourseConfig.baseURL
    var session: URLSession = .shared
    var auth: DiscourseAuth = .shared

    private struct MultipartFile {
        let fieldName: String
        let fileName: String
        let mimeType: String
        let data: Data
    }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request, includeCSRF: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DiscourseError.badResponse(http.statusCode)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DiscourseError.decoding(error)
        }
    }

    private func applyAuth(to request: inout URLRequest, includeCSRF: Bool) {
        let hasUserAPIKey = auth.userApiKey != nil
        let hasWebsiteSession = auth.sessionCookie != nil

        if let key = auth.userApiKey {
            request.setValue(key, forHTTPHeaderField: "User-Api-Key")
            request.setValue(DiscourseConfig.clientID(), forHTTPHeaderField: "User-Api-Client-Id")
        }
        if let cookie = auth.sessionCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if hasUserAPIKey || hasWebsiteSession {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("true", forHTTPHeaderField: "Discourse-Present")
        }
        if (includeCSRF || hasWebsiteSession), let csrf = auth.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
    }

    // MARK: Endpoints

    func latest() async throws -> LatestResponse {
        try await get("latest.json")
    }

    func site() async throws -> SiteResponse {
        try await get("site.json")
    }

    func categories() async throws -> CategoriesResponse {
        try await get("categories.json")
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

    func currentUser() async throws -> CurrentUserResponse {
        try await get("session/current.json")
    }

    func notifications() async throws -> NotificationsResponse {
        try await get("notifications.json")
    }

    func chatChannels() async throws -> ChatChannelsResponse {
        do {
            return try await get("chat/api/me/channels.json")
        } catch DiscourseError.badResponse(let code) where code == 404 {
            return try await get("chat/api/channels.json")
        }
    }

    // MARK: Write actions (require authentication)

    @discardableResult
    private func post(_ path: String, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request, includeCSRF: true)

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DiscourseError.badResponse(http.statusCode)
        }
        return data
    }

    private func postMultipart<T: Decodable>(_ path: String, fields: [String: String], file: MultipartFile) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request, includeCSRF: true)

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

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DiscourseError.badResponse(http.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DiscourseError.decoding(error)
        }
    }

    /// Likes a post (post_action_type_id 2).
    func likePost(id: Int) async throws {
        try await post("post_actions", form: [
            "id": String(id),
            "post_action_type_id": "2",
            "flag_topic": "false",
        ])
    }

    /// Posts a reply to a topic.
    func reply(topicID: Int, raw: String) async throws {
        try await post("posts", form: [
            "raw": raw,
            "topic_id": String(topicID),
        ])
    }

    /// Creates a new topic in a category.
    func createTopic(title: String, raw: String, categoryID: Int) async throws {
        try await post("posts", form: [
            "title": title,
            "raw": raw,
            "category": String(categoryID),
            "archetype": "regular",
        ])
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
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CreateCommunityResponse.self, from: data)
        } catch {
            throw DiscourseError.decoding(error)
        }
    }

    /// Uploads a composer attachment and returns the Discourse upload token/URL.
    func uploadComposerMedia(data: Data, fileName: String, mimeType: String) async throws -> DiscourseUpload {
        try await postMultipart(
            "uploads.json",
            fields: [
                "type": "composer",
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
    static func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&hellip;": "…", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mediaItems(for topic: TopicListItem) -> [PostMedia] {
        let preferred = nonEmpty(topic.topicThumbnails)
            ?? nonEmpty(topic.topicImages)
            ?? topic.imageUrl.map { [$0] }
            ?? []
        var seen = Set<String>()

        return preferred.compactMap { raw in
            guard let url = absoluteURL(raw) else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            let dimensions = dimensions(from: raw)
            return PostMedia(url: url, width: dimensions.width, height: dimensions.height)
        }
    }

    private static func nonEmpty(_ values: [String]?) -> [String]? {
        guard let values else { return nil }
        let filtered = values.filter { !$0.isEmpty }
        return filtered.isEmpty ? nil : filtered
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
