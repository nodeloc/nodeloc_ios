//
//  NodelocHTTP.swift
//  nodeloc
//
//  The transport for the NodeLoc backend (`/api/v1`): one place that builds
//  requests, attaches the credential, keeps the few cookies the server relies
//  on, and turns the server's error envelope into `DiscourseError`.
//
//  Foundation-only on purpose — it is also compiled by `NodelocKit` (SwiftPM)
//  so it can be unit-tested on Linux against a local backend.
//

import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated enum DiscourseConfig {
    /// `NODELOC_BASE_URL` in the scheme's environment points a debug build at a
    /// local backend; release builds always talk to the site.
    static let baseURL: URL = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["NODELOC_BASE_URL"],
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        #endif
        return URL(string: "https://www.nodeloc.com")!
    }()
    static let appName = "NODELOC iOS"
    static let clientIDDefaultsKey = "nodeloc.client_id"
    /// The URL scheme the server sends social sign-in back to.
    static let callbackScheme = "nodeloc"

    /// Klipy API key for the GIF picker. Empty = GIF button disabled, which is
    /// why a clone builds and runs without one.
    ///
    /// Read from `Secrets.plist` rather than written here, because this
    /// repository is public. Put a `Secrets.plist` beside `Info.plist`:
    ///
    ///     <dict><key>KlipyAPIKey</key><string>…</string></dict>
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

    /// Stable per-install id, generated once and memoized.
    static let clientID: String = {
        if let existing = UserDefaults.standard.string(forKey: clientIDDefaultsKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientIDDefaultsKey)
        return id
    }()

    /// The bundle's build number, which the release check and device
    /// registration report.
    static let appBuild: Int = {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }()

    static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }()

    /// The server answers URLSession's default User-Agent (`CFNetwork/…`) on
    /// old Discourse paths with 410 "please update"; naming the app keeps this
    /// build out of that net and makes its traffic recognisable in the logs.
    static var userAgent: String {
        "NodeLoc/\(appVersion) (iOS; build \(appBuild))"
    }
}

/// How requests prove who they are.
///
/// The backend issues app sessions as bearer tokens; a website session cookie
/// (`nl_session`) is accepted as a fallback, so a server without the token
/// endpoint still works. Whichever the login response carried is used as is.
nonisolated enum NodelocCredential: Equatable, Sendable {
    case bearer(String)
    case cookie(String)

    var encoded: String {
        switch self {
        case .bearer(let token): return "bearer:" + token
        case .cookie(let value): return "cookie:" + value
        }
    }

    init?(encoded: String) {
        if encoded.hasPrefix("bearer:") {
            self = .bearer(String(encoded.dropFirst(7)))
        } else if encoded.hasPrefix("cookie:") {
            self = .cookie(String(encoded.dropFirst(7)))
        } else {
            return nil
        }
    }
}

/// Holds the signed-in user's auth state.
@Observable
final class DiscourseAuth {
    // nonisolated so value types (DiscourseClient) can capture the shared
    // reference in a nonisolated init; its mutable state is still touched only
    // from the main actor.
    nonisolated static let shared = DiscourseAuth()

    nonisolated init() {}

    var credential: NodelocCredential?
    var username: String?
    var userID: Int?
    /// Admin or moderator. Staff-only actions are offered on this rather than
    /// attempted and refused.
    var isStaff = false
    /// Cookies the server sets for its own bookkeeping — the device token its
    /// per-device limits count on (`rc_t`) and "trust this device" for 2FA
    /// (`nl_2fa_trust`). Kept even when signed out, like a browser would.
    var cookies: [String: String] = [:]

    var isAuthenticated: Bool { credential != nil }
}

enum DiscourseError: Error, LocalizedError {
    /// Status code, plus what the server said about it: its localized
    /// `message` and its machine-readable `code` (`second_factor_required`,
    /// `rate_limited`, …).
    case badResponse(Int, message: String? = nil, code: String? = nil)
    /// Kept for source compatibility: an edge proxy challenge rather than an
    /// API answer.
    case challenged
    case decoding(Error)
    case transport(Error)
    /// The backend has no equivalent of what was asked for.
    case unsupported

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

    /// The body of the last error answer, for the few errors that carry
    /// more than a message (409 `penalty_exists` names the penalty in force).
    /// Read it right after catching the error.
    nonisolated(unsafe) static var lastErrorBody: Data?
    /// `Retry-After` of the last 429, in seconds.
    nonisolated(unsafe) static var lastRetryAfter: Double?

    /// The server's error code, when it sent one.
    var serverCode: String? {
        if case .badResponse(_, _, let code) = self { return code }
        return nil
    }

    var statusCode: Int? {
        if case .badResponse(let status, _, _) = self { return status }
        return nil
    }

    /// Friendly, user-facing wording only — status codes and technical detail
    /// stay out of the UI.
    var errorDescription: String? {
        switch self {
        case .badResponse(let code, let message, let serverCode):
            // A 500's generic "服务器内部错误" / "Internal server error" is
            // the server saying nothing — the friendly line reads better.
            if let message, !message.isEmpty, !(code >= 500 && (serverCode == nil || serverCode == "internal")) {
                return message
            }
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
        case .unsupported:
            return AppString("暂不支持这个操作")
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

/// One multipart file part.
nonisolated struct MultipartFile: Sendable {
    let fieldName: String
    let fileName: String
    let mimeType: String
    let data: Data
}

/// What a request sends as its body.
nonisolated enum RequestBody {
    case none
    case json([String: Any])
    case multipart(fields: [String: String], file: MultipartFile)
}

/// The request funnel. Every call to the backend goes through `send`.
struct NodelocHTTP {
    var baseURL: URL
    var session: URLSession
    var auth: DiscourseAuth

    /// Called when an authenticated request is answered 401: the stored
    /// session is gone server-side, so the app should sign out rather than
    /// keep presenting a signed-in UI that every action fails in.
    static var onUnauthorized: (@MainActor () -> Void)?

    /// Called whenever the server sets a cookie the app keeps, so the caller
    /// can persist it.
    static var onCookiesChanged: (@MainActor () -> Void)?

    /// A session that never touches the shared cookie jar: the credential is
    /// attached explicitly, so a stale jar cookie can't contradict it.
    nonisolated static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Cookies the client keeps when the server sets them.
    nonisolated static let keptCookies: Set<String> = ["rc_t", "nl_2fa_trust", "nl_session"]

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appending(path: trimmed), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        // `+` is legal in a query but the server reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func makeRequest(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(DiscourseConfig.userAgent, forHTTPHeaderField: "User-Agent")
        // Server-rendered names (nodes, tiers, system notices) follow the
        // reader's language, picked from this header and the `lang` cookie.
        // A language chosen in 设置 › 界面 › 语言 wins; it may be one the app
        // has no strings for but the server speaks.
        request.setValue(
            ServerLanguage.choice?.acceptLanguage ?? AppLanguage.resolved.acceptLanguageHeader,
            forHTTPHeaderField: "Accept-Language"
        )
        // Times the server writes into messages ("禁言到 12 月 4 日 10:24")
        // are in this zone; without it they are Beijing time.
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Time-Zone")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        applyAuth(to: &request)

        switch body {
        case .none:
            break
        case .json(let object):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        case .multipart(let fields, let file):
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(boundary: boundary, fields: fields, file: file)
        }
        return request
    }

    private func applyAuth(to request: inout URLRequest) {
        var cookies = auth.cookies.filter { $0.key != "nl_session" }
        switch auth.credential {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .cookie(let value):
            cookies["nl_session"] = value
        case nil:
            break
        }
        if !cookies.isEmpty {
            let header = cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
    }

    static func multipartBody(boundary: String, fields: [String: String], file: MultipartFile) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        let safeName = file.fileName.replacingOccurrences(of: "\"", with: "")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(safeName)\"\r\n")
        body.appendUTF8("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Sends a request and returns the body of a 2xx answer.
    @discardableResult
    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        headers: [String: String] = [:]
    ) async throws -> Data {
        try await sendWithResponse(method, path, query: query, body: body, headers: headers).data
    }

    func sendWithResponse(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: RequestBody = .none,
        headers: [String: String] = [:]
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let request: URLRequest
        do {
            request = try makeRequest(method, path, query: query, body: body, headers: headers)
        } catch {
            throw DiscourseError.decoding(error)
        }
        guard method == "GET", let key = request.url?.absoluteString else {
            return try await perform(request, retriesRemaining: 0)
        }
        // Several screens and stores ask for the same thing at the same
        // moment (launch asked for /me, the unread counts and the block list
        // twice each). Identical GETs for the same credential share one request.
        let coalesceKey = key + "|" + (request.value(forHTTPHeaderField: "Authorization") ?? "")
            + "|" + (request.value(forHTTPHeaderField: "Cookie") ?? "")
        if let running = Self.inFlight[coalesceKey] {
            return try await running.value
        }
        let task = Task { try await perform(request, retriesRemaining: 1) }
        Self.inFlight[coalesceKey] = task
        defer { Self.inFlight[coalesceKey] = nil }
        return try await task.value
    }

    /// GETs on the wire, by URL and credential.
    private static var inFlight: [String: Task<(data: Data, response: HTTPURLResponse), Error>] = [:]

    /// The longest a 429 retry will wait before giving up instead: retrying
    /// early only earns another 429.
    private static let maximumRetryWait: Double = 5

    private func perform(_ request: URLRequest, retriesRemaining: Int) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscourseError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiscourseError.transport(URLError(.badServerResponse))
        }
        absorbCookies(from: http)

        if http.statusCode == 429, retriesRemaining > 0 {
            let asked = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0.8
            if asked <= Self.maximumRetryWait {
                let wait = max(asked, 0.4) + Double.random(in: 0...0.3)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return try await perform(request, retriesRemaining: retriesRemaining - 1)
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let envelope = Self.errorEnvelope(from: data)
            #if DEBUG
            print("[NodelocAPI] \(http.statusCode) \(request.httpMethod ?? "GET") \(request.url?.path ?? "") \(envelope.code ?? "-")")
            #endif
            if http.statusCode == 401, auth.credential != nil,
               request.value(forHTTPHeaderField: "Authorization") != nil
                || request.value(forHTTPHeaderField: "Cookie")?.contains("nl_session=") == true,
               envelope.code == nil || envelope.code == "unauthorized" {
                Self.onUnauthorized?()
            }
            DiscourseError.lastErrorBody = data
            DiscourseError.lastRetryAfter = http.statusCode == 429
                ? http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) : nil
            throw DiscourseError.badResponse(http.statusCode, message: envelope.message, code: envelope.code)
        }
        return (data, http)
    }

    /// `{"error":{"code","message","fields"}}`. For a validation error the
    /// field's own message is the useful one, so it is preferred.
    static func errorEnvelope(from data: Data) -> (code: String?, message: String?) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String
            var message = error["message"] as? String
            if let fields = error["fields"] as? [String: String], !fields.isEmpty {
                let detail = fields.keys.sorted().compactMap { fields[$0] }.filter { !$0.isEmpty }
                if !detail.isEmpty { message = detail.joined(separator: "\n") }
            }
            return (code, message)
        }
        // `/apps/*` still answers in the Discourse shape.
        if let list = object["errors"] as? [String], !list.isEmpty {
            return (object["error_type"] as? String, list.joined(separator: "\n"))
        }
        if let single = object["error"] as? String { return (nil, single) }
        return (nil, nil)
    }

    private func absorbCookies(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        var changed = false
        for cookie in cookies where Self.keptCookies.contains(cookie.name) {
            if cookie.name == "nl_session" {
                // Only a cookie-mode session follows the server's rotation; a
                // bearer session never adopts a website cookie.
                if case .cookie = auth.credential, !cookie.value.isEmpty {
                    auth.credential = .cookie(cookie.value)
                    changed = true
                }
                continue
            }
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 < Date() } ?? false) {
                if auth.cookies.removeValue(forKey: cookie.name) != nil { changed = true }
            } else if auth.cookies[cookie.name] != cookie.value {
                auth.cookies[cookie.name] = cookie.value
                changed = true
            }
        }
        if changed { Self.onCookiesChanged?() }
    }

    /// The session cookie a login response set, for servers that answer a
    /// native login with a website session instead of a token.
    static func sessionCookie(in response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == "nl_session" && !$0.value.isEmpty }?.value
    }
}

extension Data {
    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

/// Decoding shared by every response: snake_case keys onto camelCase
/// properties, as the models are written.
nonisolated enum NodelocJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) throws -> T {
        do {
            return try decoder().decode(T.self, from: data)
        } catch {
            #if DEBUG
            let preview = String(decoding: data.prefix(400), as: UTF8.self)
            print("[NodelocAPI] decode failed for \(T.self): \(error)\n  body: \(preview)")
            #endif
            throw DiscourseError.decoding(error)
        }
    }

    /// Re-decodes a JSON object built by the adapter through the app's models.
    static func decode<T: Decodable>(_ type: T.Type = T.self, object: Any) throws -> T {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw DiscourseError.decoding(error)
        }
        return try decode(T.self, from: data)
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

