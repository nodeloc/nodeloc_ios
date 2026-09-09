//
//  DiscourseAuthService.swift
//  nodeloc
//
//  Website-session auth, the way the site itself does it:
//    * username/password (with 2FA) through POST /session
//    * signup through POST /users
//    * social sign-in through Discourse's own auth providers — the app hosts
//      /auth/<provider> in a web view (SocialLoginView) and adopts the session
//      cookies it comes back with (`completeProviderLogin`)
//
//  Every path ends in the same place: Discourse's session cookies in
//  URLSession's jar, a matching CSRF token, and both mirrored to the Keychain.
//  No User API Key is involved, so nothing depends on the admin whitelisting a
//  redirect scheme.
//

import Foundation
import Security
import UIKit

enum AuthError: Error, LocalizedError {
    case cancelled
    case missingCredentials
    case loginFailed(String)
    /// Credentials were right but the account has 2FA — the UI should ask for
    /// the one-time code and retry.
    case secondFactorRequired
    case signupFailed(String)
    case signupNeedsActivation(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Login was cancelled."
        case .missingCredentials: return "Please fill in all required fields."
        // The server's messages arrive as HTML — Discourse's own strings carry
        // `<p>` and `<b>` — and these reach toasts and inline error labels, so
        // they are decoded here rather than at each display site.
        case .loginFailed(let message): return DiscourseFormat.plainTextParagraphs(message)
        case .secondFactorRequired: return AppString("此账号已开启两步验证，请输入验证码。")
        case .signupFailed(let message): return DiscourseFormat.plainTextParagraphs(message)
        case .signupNeedsActivation(let message): return DiscourseFormat.plainTextParagraphs(message)
        }
    }
}

enum SignupResult {
    case signedIn
    case needsActivation(String)
}

@MainActor
final class DiscourseLogin {
    static let shared = DiscourseLogin()

    private let keychainKey = "nodeloc.user_api_key"
    private let keychainSession = "nodeloc.session_cookie"
    private let keychainCSRF = "nodeloc.csrf_token"
    private let keychainUser = "nodeloc.username"

    // MARK: Restore

    /// Restores a previously stored key on launch. Returns true if signed in.
    @discardableResult
    func restore() -> Bool {
        let key = Keychain.get(keychainKey)
        let cookie = Keychain.get(keychainSession)
        guard key != nil || cookie != nil else { return false }
        DiscourseAuth.shared.userApiKey = key
        DiscourseAuth.shared.sessionCookie = cookie
        DiscourseAuth.shared.csrfToken = Keychain.get(keychainCSRF)
        DiscourseAuth.shared.username = Keychain.get(keychainUser)
        // Requests rely on the cookie jar (not a pinned header) so Discourse's
        // `_t` token rotation keeps working; seed it with the stored session.
        if let cookie {
            injectCookiesIntoJar(cookie)
        }
        return true
    }

    /// Fills in a missing username from the server, and persists it.
    ///
    /// A restored credential can arrive without one: the User API Key flow
    /// never asks for a name (it reads it back from `session/current` once, at
    /// sign-in), and anything signed in before that read-back existed has a key
    /// in the Keychain with no `nodeloc.username` beside it.
    ///
    /// That state is worse than it sounds. Every screen keyed on the username
    /// — the profile page above all — has nothing to ask for and no way to
    /// recover, so it stays empty for the life of the install. Asking the
    /// server once repairs it permanently.
    @discardableResult
    func resolveUsernameIfNeeded() async -> String? {
        if let existing = DiscourseAuth.shared.username, !existing.isEmpty {
            return existing
        }
        guard DiscourseAuth.shared.isAuthenticated,
              let response = try? await DiscourseClient().currentUser()
        else { return nil }

        let username = response.currentUser.username
        DiscourseAuth.shared.username = username
        Keychain.set(username, for: keychainUser)
        return username
    }

    /// Snapshots the (possibly rotated) session cookies back into the Keychain
    /// so the next launch restores a token the server still accepts. Called on
    /// backgrounding; a no-op for User-API-Key sign-ins.
    func persistRotatedSession() {
        guard DiscourseAuth.shared.sessionCookie != nil,
              let cookie = currentCookieHeader() else { return }
        DiscourseAuth.shared.sessionCookie = cookie
        Keychain.set(cookie, for: keychainSession)
    }

    /// Rebuilds jar cookies from a stored "name=value; name=value" header.
    private func injectCookiesIntoJar(_ header: String) {
        let host = DiscourseConfig.baseURL.host ?? "www.nodeloc.com"
        for pair in header.components(separatedBy: "; ") {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard let cookie = HTTPCookie(properties: [
                .domain: host,
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
            ]) else { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func signOut() {
        resetAuthState()
        // The interface language followed the account; without one, fall back
        // to the device again.
        AppLanguage.accountChoice = nil
    }

    /// Drops every trace of the current session: the cookie jar, the keychain
    /// copies, and the in-memory fields `applyAuth` reads.
    ///
    /// All of it, together, always. Clearing the jar but leaving
    /// `sessionCookie` / `csrfToken` set is not a half-measure but an actively
    /// broken state: `applyAuth` still believes there is a session, so it
    /// attaches a CSRF token belonging to a session that no longer exists and
    /// `isAuthenticated` still answers true. A server that behaves differently
    /// for authenticated callers — the Apple endpoint links instead of signing
    /// in — then takes the wrong branch.
    private func resetAuthState() {
        Keychain.delete(keychainKey)
        Keychain.delete(keychainSession)
        Keychain.delete(keychainCSRF)
        Keychain.delete(keychainUser)
        clearCookies()
        DiscourseAuth.shared.userApiKey = nil
        DiscourseAuth.shared.sessionCookie = nil
        DiscourseAuth.shared.csrfToken = nil
        DiscourseAuth.shared.username = nil
        // The profile page renders last launch's payload before asking the
        // server for anything, so leaving this behind would show the previous
        // account's name, avatar and 能量 to whoever signs in next.
        ProfileSnapshot.clearAll()
        // Same reasoning, and more serious: chat history is private
        // correspondence, and the outbox may hold a message the previous
        // account never managed to send.
        Task { try? await ChatStorage.shared.clearAll() }
    }

    // MARK: Username/password auth

    /// `secondFactorToken` is the OTP (or backup code, with method 2) for
    /// accounts that have 2FA; the first attempt goes without one and throws
    /// `secondFactorRequired` when the server asks for it.
    func login(
        identifier rawIdentifier: String,
        password rawPassword: String,
        secondFactorToken: String? = nil,
        secondFactorMethod: Int = 1
    ) async throws {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !password.isEmpty else { throw AuthError.missingCredentials }

        signOut()
        let csrf = try await fetchCSRFToken()
        var form = [
            "login": identifier,
            "password": password,
            "second_factor_method": String(secondFactorMethod),
            "timezone": TimeZone.current.identifier,
        ]
        if let secondFactorToken {
            form["second_factor_token"] = secondFactorToken
        }
        let (data, _) = try await postForm("session", form: form, csrf: csrf)

        // Discourse answers HTTP 200 even when the login fails — the outcome is
        // in the body. A wrong password, an unactivated account, a required
        // second factor, or a social-only account (no password) all come back
        // here as `{ "error": … }`, so the status code alone can't be trusted.
        // On success it renders the signed-in user, so `user.username` is the
        // authoritative "logged in" signal — no follow-up request needed.
        let result = try? decode(SessionLoginResponse.self, from: data)
        if result?.reason == "invalid_second_factor" {
            // Without a token this is the server asking for one; with a token
            // it means the code was wrong.
            if secondFactorToken == nil {
                throw AuthError.secondFactorRequired
            }
            throw AuthError.loginFailed(result?.error ?? AppString("验证码不正确，请重试。"))
        }
        if let message = result?.error ?? result?.failed {
            throw AuthError.loginFailed(message)
        }
        guard let username = result?.user?.username else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }

        try persistWebsiteSession(csrf: csrf, username: username)
    }

    /// `userFields` carries the admin's custom profile fields, keyed by field
    /// id. The ones the server marks required at registration must be present
    /// or `POST /users` rejects the whole thing — see `DiscourseUserField`.
    func signup(
        username rawUsername: String,
        name rawName: String,
        email rawEmail: String,
        password rawPassword: String,
        userFields: [Int: String] = [:]
    ) async throws -> SignupResult {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty else {
            throw AuthError.missingCredentials
        }

        signOut()
        let csrf = try await fetchCSRFToken()
        // Fetched *after* the CSRF call, because the server keeps the expected
        // answer in the session that call establishes — a honeypot from some
        // other session fails the check just as surely as none at all.
        let honeypot = try await fetchSignupChallenge()
        let (data, response) = try await postForm(
            "users",
            form: [
                "username": username,
                "name": name.isEmpty ? username : name,
                "email": email,
                "password": password,
                "timezone": TimeZone.current.identifier,
                // Discourse's anti-spam pair, and the reason signups appeared
                // to work while no mail was ever sent. Getting these wrong is
                // not an error: `UsersController#create` opens with
                //
                //   if honeypot_or_challenge_fails?(params) || invite_only?
                //     render json: { success: true, active: false,
                //                    message: t("login.activate_email", …) }
                //
                // — a deliberate lie to spam bots. It creates no account and
                // queues no mail, which is exactly what we were seeing: a
                // convincing check-your-inbox screen, an empty mail log, and no
                // such user.
                //
                // `password_confirmation` carries the honeypot value (it is not
                // the password), and the challenge goes back reversed.
                "password_confirmation": honeypot.value,
                "challenge": String(honeypot.challenge.reversed()),
            ].merging(
                // `user_fields[3]=Male`, the shape Rails parses back into a
                // hash. Blank answers are dropped rather than sent empty: an
                // empty string fails a required field's validation just as a
                // missing key does, but reads as a deliberate answer.
                userFields
                    .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .reduce(into: [:]) { form, entry in
                        form["user_fields[\(entry.key)]"] = entry.value
                    },
                uniquingKeysWith: { _, custom in custom }
            ),
            csrf: csrf
        )
        let signup = try? decode(SignupResponse.self, from: data)
        let message = signup?.message ?? responseMessage(from: data) ?? "Account created. Please check your email to activate it."

        guard (200...299).contains(response.statusCode), signup?.success != false else {
            throw AuthError.signupFailed(message)
        }

        if signup?.active == true {
            try await login(identifier: username, password: password)
            return .signedIn
        }

        // No check for "did that really work?" is possible here, and it isn't
        // worth trying again. Discourse's own source settles it — a real
        // success renders
        //
        //   { success: true, active: user.active?, message: activation.message }
        //     .merge(SiteSetting.hide_email_address_taken ? {} : { user_id: user.id })
        //
        // and the anti-spam decoy renders
        //
        //   { success: true, active: false, message: t("login.activate_email") }
        //
        // With `hide_email_address_taken` on — as it is on nodeloc — those are
        // the same three keys with the same kinds of values. The concealment of
        // an already-registered email takes the same shape too. Being
        // indistinguishable is the point: a spam bot must not be able to tell
        // either. A `user_id` guard was tried here and rejected *real*
        // registrations, which is worse than the silence it was meant to catch.
        //
        // So the honeypot above is the whole defence: get it right and this
        // path means what it says.
        #if DEBUG
        if signup?.userId == nil {
            print("[Signup] no user_id — expected when hide_email_address_taken is on. Body: \(String(decoding: data, as: UTF8.self))")
        }
        #endif

        throw AuthError.signupNeedsActivation(message)
    }

    /// `/session/hp.json` — the honeypot value and challenge that
    /// `POST /users` checks. Both are per-session and short-lived
    /// (`expires_in` is an hour), so this is fetched per signup attempt.
    private func fetchSignupChallenge() async throws -> SignupChallenge {
        var request = URLRequest(url: DiscourseConfig.baseURL.appending(path: "session/hp.json"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AuthError.signupFailed("Couldn't start the signup session.")
        }
        guard let challenge = try? decode(SignupChallenge.self, from: data) else {
            throw AuthError.signupFailed("Couldn't start the signup session.")
        }
        return challenge
    }

    private func fetchCSRFToken() async throws -> String {
        var request = URLRequest(url: DiscourseConfig.baseURL.appending(path: "session/csrf.json"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AuthError.loginFailed("Couldn't start the login session.")
        }
        let csrf = try decode(CSRFResponse.self, from: data).csrf
        return csrf
    }

    private func postForm(
        _ path: String,
        form: [String: String],
        csrf: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: DiscourseConfig.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("true", forHTTPHeaderField: "Discourse-Present")
        request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(DiscourseConfig.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = formURLEncoded(form)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.loginFailed("The server returned an invalid response.")
        }
        if !(200...299).contains(http.statusCode) {
            let message = responseMessage(from: data) ?? "Server returned status \(http.statusCode)."
            throw AuthError.loginFailed(message)
        }
        return (data, http)
    }

    private func persistWebsiteSession(csrf: String, username: String) throws {
        guard let cookie = currentCookieHeader() else {
            throw AuthError.loginFailed("Login did not return a website session.")
        }
        DiscourseAuth.shared.userApiKey = nil
        DiscourseAuth.shared.sessionCookie = cookie
        DiscourseAuth.shared.csrfToken = csrf
        DiscourseAuth.shared.username = username
        Keychain.delete(keychainKey)
        Keychain.set(cookie, for: keychainSession)
        Keychain.set(csrf, for: keychainCSRF)
        Keychain.set(username, for: keychainUser)
    }

    private func currentCookieHeader() -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: DiscourseConfig.baseURL),
              !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    private func clearCookies() {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: DiscourseConfig.baseURL) else { return }
        for cookie in cookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private func formURLEncoded(_ form: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private func responseMessage(from data: Data) -> String? {
        if let response = try? decode(AuthMessageResponse.self, from: data) {
            return response.message
            ?? response.error
            ?? response.reason
            ?? response.errors?.joined(separator: "\n")
        }
        return String(data: data, encoding: .utf8)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    // MARK: Social login (Discourse auth providers)

    /// Completes a `/auth/<provider>` sign-in performed in `SocialLoginWebView`.
    ///
    /// Discourse's own OAuth routes are used rather than a User API Key: the
    /// provider round-trip ends with the site setting its normal session
    /// cookies in the web view, so the only work left is to move those cookies
    /// into URLSession's jar and pick up a matching CSRF token. From there the
    /// app is in exactly the state a username/password login leaves it in.
    func completeProviderLogin(cookies: [HTTPCookie]) async throws {
        guard cookies.contains(where: { $0.name == "_t" }) else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }

        // Start from a clean slate so a previous account's cookies can't mix
        // with the new session, then adopt the web view's. `adoptSessionCookies`
        // fetches a fresh CSRF token, so dropping the old one here costs
        // nothing and keeps this from being the broken half-state described on
        // `resetAuthState`.
        resetAuthState()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        try await adoptSessionCookies()
    }

    /// Signs in with Discourse's User API Key flow, run in the system browser.
    ///
    /// The other paths all end with a session *cookie*; this one ends with a
    /// key that goes in the `User-Api-Key` header instead. `applyAuth` already
    /// prefers that header when it is set and `isAuthenticated` already counts
    /// it, so nothing downstream changes — the request layer has always
    /// supported this, only the acquisition was missing.
    ///
    /// The username is read back from `session/current` because the flow never
    /// asks for one: the reader may have signed in with any provider, and the
    /// app needs the name for its own screens.
    func loginWithUserAPIKey() async throws {
        let key = try await UserAPIKeyAuth.authorize()

        // A clean slate first, for the reason spelled out on `resetAuthState`:
        // leaving a previous session's cookie and CSRF token in place alongside
        // a new key is the half-authenticated state that makes the server take
        // the wrong branch.
        resetAuthState()
        DiscourseAuth.shared.userApiKey = key
        Keychain.set(key, for: keychainKey)

        guard let response = try? await DiscourseClient().currentUser() else {
            // The key didn't work, so don't keep it — otherwise the app looks
            // signed in and every request fails.
            resetAuthState()
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }
        let username = response.currentUser.username
        DiscourseAuth.shared.username = username
        Keychain.set(username, for: keychainUser)
        AppLanguage.accountChoice = nil
    }

    /// Completes a native Sign in with Apple.
    ///
    /// The endpoint answers by setting the same session cookie a web login
    /// would, so once it returns there is nothing provider-specific left — the
    /// tail is shared with `completeProviderLogin`.
    ///
    /// Rethrows the transport error untouched so the caller can tell "endpoint
    /// not deployed" (404 / 501) from a real failure and fall back to the web
    /// flow.
    func completeNativeAppleLogin(_ credential: AppleSignInCredential) async throws {
        // Everything, not just the cookies: the endpoint decides between
        // *signing in* and *linking to the caller* by whether the request looks
        // authenticated, so any leftover CSRF token would send it down the
        // linking path against a session that is already gone.
        resetAuthState()

        try await DiscourseClient().nativeAppleLogin(credential)

        guard HTTPCookieStorage.shared.cookies(for: DiscourseConfig.baseURL)?
            .contains(where: { $0.name == "_t" }) == true
        else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }

        try await adoptSessionCookies()
    }

    /// Turns session cookies already in the jar into a persisted login.
    private func adoptSessionCookies() async throws {
        // The CSRF token is per-session, so it has to be fetched *after* the
        // session cookies are in place.
        let csrf = try await fetchCSRFToken()
        DiscourseAuth.shared.sessionCookie = currentCookieHeader()
        DiscourseAuth.shared.csrfToken = csrf

        guard let current = try? await DiscourseClient().currentUser() else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }
        try persistWebsiteSession(csrf: csrf, username: current.currentUser.username)
    }
}

private struct CSRFResponse: Decodable {
    let csrf: String
}

/// `POST /session`. On success the body carries the user; on failure — wrong
/// password, unactivated, 2FA required, no local password — it carries a
/// message, both under HTTP 200.
private struct SessionLoginResponse: Decodable {
    let error: String?
    let failed: String?
    /// "invalid_second_factor" when the account has 2FA and the token was
    /// missing or wrong.
    let reason: String?
    let totpEnabled: Bool?
    let backupEnabled: Bool?
    let user: LoggedInUser?

    struct LoggedInUser: Decodable {
        let username: String
    }
}

private struct SignupResponse: Decodable {
    let success: Bool?
    let active: Bool?
    let message: String?
    /// Present only when `hide_email_address_taken` is off, so its absence
    /// means nothing — see the note at the end of `signup`. Kept for the DEBUG
    /// log and for the day that setting changes.
    let userId: Int?
}

/// `/session/hp.json` — Discourse's signup honeypot.
private struct SignupChallenge: Decodable {
    let value: String
    let challenge: String
}

private struct AuthMessageResponse: Decodable {
    let message: String?
    let error: String?
    let reason: String?
    let errors: [String]?
}

// MARK: - Keychain

enum Keychain {
    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
