//
//  DiscourseAuthService.swift
//  nodeloc
//
//  Sign-in against the NodeLoc backend:
//    * username/email + password, with the second factor asked for when the
//      server says so (`second_factor_required`)
//    * registration
//    * social sign-in, either in the system browser ending at
//      `nodeloc://auth?code=…` (exchanged for a session) or hosted in a web
//      view whose session cookie is adopted (`completeProviderLogin`)
//    * native Sign in with Apple (identity token exchanged for a session)
//    * passkeys (`NodelocPasskeyLogin` runs the platform sheet)
//
//  Every path ends the same way: a credential (bearer token, or the website
//  session cookie on servers without app tokens) in `DiscourseAuth` and in the
//  Keychain.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

enum AuthError: Error, LocalizedError {
    case cancelled
    case missingCredentials
    case loginFailed(String)
    /// Credentials were right but the account has 2FA — the UI should ask for
    /// the one-time code and retry.
    case secondFactorRequired
    case signupFailed(String)
    case signupNeedsActivation(String)
    /// The password was right but the account is suspended (403
    /// `suspended`); the message says until when. The login page offers
    /// 查看处罚和申诉 with the same credentials.
    case suspended(String)
    /// 422 `captcha_required` / `captcha_invalid`: show the widget and retry
    /// with a fresh token. The message is the server's, in the reader's language.
    case captchaRequired(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return AppString("登录已取消")
        case .missingCredentials: return AppString("请填写所有必填项")
        case .loginFailed(let message): return DiscourseFormat.plainTextParagraphs(message)
        case .secondFactorRequired: return AppString("此账号已开启两步验证，请输入验证码。")
        case .signupFailed(let message): return DiscourseFormat.plainTextParagraphs(message)
        case .signupNeedsActivation(let message): return DiscourseFormat.plainTextParagraphs(message)
        case .suspended(let message): return message
        case .captchaRequired(let message): return message
        }
    }
}

enum SignupResult {
    case signedIn
    case needsActivation(String)
}

/// Where the session is kept between launches.
nonisolated protocol CredentialStore {
    func get(_ account: String) -> String?
    func set(_ value: String, for account: String)
    func delete(_ account: String)
}

/// The Keychain on Apple platforms; process memory elsewhere (tests).
nonisolated struct DefaultCredentialStore: CredentialStore {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String, for account: String) { Keychain.set(value, for: account) }
    func delete(_ account: String) { Keychain.delete(account) }
}

@MainActor
final class DiscourseLogin {
    static let shared = DiscourseLogin()

    let auth: DiscourseAuth
    let baseURL: URL
    let store: CredentialStore

    /// Runs after any sign-out, for the app's on-disk caches (profile
    /// snapshot, chat history) that belong to the previous account.
    static var onSignOut: (@MainActor () -> Void)?
    /// Runs after any successful sign-in.
    static var onSignIn: (@MainActor () -> Void)?

    private let keychainCredential = "nodeloc.credential"
    private let keychainUser = "nodeloc.username"
    private let keychainCookies = "nodeloc.cookies"
    private let keychainTrust = "nodeloc.trust_token"

    init(auth: DiscourseAuth = .shared, baseURL: URL = DiscourseConfig.baseURL, store: CredentialStore = DefaultCredentialStore()) {
        self.auth = auth
        self.baseURL = baseURL
        self.store = store
        NodelocHTTP.onUnauthorized = { [weak self] in
            guard let self, self.auth.isAuthenticated else { return }
            self.signOut()
        }
        NodelocHTTP.onCookiesChanged = { [weak self] in self?.persistCookies() }
    }

    private var client: DiscourseClient { DiscourseClient(baseURL: baseURL, auth: auth) }

    // MARK: Restore

    /// Restores a stored session on launch. Returns true if signed in.
    @discardableResult
    func restore() -> Bool {
        // Discourse-era sessions mean nothing to the new backend.
        for legacy in ["nodeloc.user_api_key", "nodeloc.session_cookie", "nodeloc.csrf_token"] {
            store.delete(legacy)
        }
        restoreCookies()
        guard let encoded = store.get(keychainCredential),
              let credential = NodelocCredential(encoded: encoded)
        else { return false }
        auth.credential = credential
        auth.username = store.get(keychainUser)
        return true
    }

    /// Fills in a missing username from the server, and persists it.
    @discardableResult
    func resolveUsernameIfNeeded() async -> String? {
        if let existing = auth.username, !existing.isEmpty {
            return existing
        }
        guard auth.isAuthenticated,
              let response = try? await client.currentUser()
        else { return nil }
        let username = response.currentUser.username
        auth.username = username
        store.set(username, for: keychainUser)
        return username
    }

    /// Snapshots a rotated session cookie back into the Keychain. Called on
    /// backgrounding; a no-op for token sessions, which don't rotate.
    func persistRotatedSession() {
        guard let credential = auth.credential else { return }
        store.set(credential.encoded, for: keychainCredential)
        persistCookies()
    }

    private func persistCookies() {
        let cookies = auth.cookies.filter { $0.key != "nl_session" }
        guard let data = try? JSONSerialization.data(withJSONObject: cookies),
              let text = String(data: data, encoding: .utf8) else { return }
        store.set(text, for: keychainCookies)
    }

    private func restoreCookies() {
        guard let text = store.get(keychainCookies),
              let data = text.data(using: .utf8),
              let cookies = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        auth.cookies.merge(cookies) { current, _ in current }
    }

    func signOut() {
        let wasSignedIn = auth.isAuthenticated
        let http = client.http
        let credential = auth.credential
        resetAuthState()
        if wasSignedIn, let credential {
            // Ends the session server-side too, best effort, with the
            // credential that is being dropped.
            let previous = DiscourseAuth()
            previous.credential = credential
            previous.cookies = auth.cookies
            let logout = NodelocHTTP(baseURL: http.baseURL, session: http.session, auth: previous)
            let pushToken = PushTokenStore.token
            Task {
                // The device stops receiving this account's pushes before the
                // session that owns the registration goes away.
                if let pushToken {
                    _ = try? await logout.send("POST", "api/v1/mobile/devices/unregister", body: .json(["push_token": pushToken]))
                }
                _ = try? await logout.send("POST", NodelocAuthPaths.logout)
            }
        }
    }

    /// Drops every trace of the current session, together, always — a half-
    /// cleared state that still "looks" signed in is worse than either.
    private func resetAuthState() {
        store.delete(keychainCredential)
        store.delete(keychainUser)
        auth.credential = nil
        auth.username = nil
        auth.userID = nil
        auth.isStaff = false
        NodelocAdapterState.shared.reset()
        NodelocRealtime.shared.disconnect()
        Self.onSignOut?()
    }

    // MARK: Password

    /// `secondFactorToken` is the TOTP or a backup code for accounts with 2FA;
    /// the first attempt goes without one and throws `secondFactorRequired`
    /// when the server asks for it.
    func login(
        identifier rawIdentifier: String,
        password rawPassword: String,
        secondFactorToken: String? = nil,
        secondFactorMethod: Int = 1,
        captcha: String? = nil
    ) async throws {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword
        guard !identifier.isEmpty, !password.isEmpty else { throw AuthError.missingCredentials }

        if auth.isAuthenticated { signOut() }
        var body: [String: Any] = [
            "login": identifier,
            "password": password,
            "remember": true,
            "device": DeviceName.current,
        ]
        if let secondFactorToken, !secondFactorToken.isEmpty {
            body["code"] = secondFactorToken.trimmingCharacters(in: .whitespacesAndNewlines)
            body["trust_device"] = true
        }
        if let captcha, !captcha.isEmpty { body["captcha"] = captcha }
        var headers: [String: String] = [:]
        if let trust = store.get(keychainTrust) { headers["X-Nodeloc-Trust"] = trust }
        do {
            let result = try await client.http.sendWithResponse("POST", NodelocAuthPaths.login, body: .json(body), headers: headers)
            try await adopt(result.data, response: result.response)
        } catch let error as DiscourseError {
            if error.serverCode == "second_factor_required" { throw AuthError.secondFactorRequired }
            // Also an `invalid_credentials` that names `fields.captcha`: the
            // "after N failures" mode saying every later try needs one.
            if CaptchaFailure.isCaptcha(error) || ServerFieldErrors.last()["captcha"] != nil {
                throw AuthError.captchaRequired(ServerFieldErrors.last()["captcha"] ?? error.errorDescription ?? AppString("请先完成人机验证"))
            }
            if error.serverCode == "suspended" {
                throw AuthError.suspended(error.errorDescription ?? AppString("账号已被封禁"))
            }
            throw AuthError.loginFailed(error.errorDescription ?? AppString("登录未完成，请重试。"))
        }
    }

    // MARK: Registration

    /// `userFields` is kept for source compatibility; the backend has no
    /// custom profile fields.
    func signup(
        username rawUsername: String,
        name rawName: String,
        email rawEmail: String,
        password: String,
        userFields: [Int: String] = [:],
        emailCode: String? = nil,
        inviteCode: String? = nil,
        reason: String? = nil,
        captcha: String? = nil
    ) async throws -> SignupResult {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty else {
            throw AuthError.missingCredentials
        }
        if auth.isAuthenticated { signOut() }

        var body: [String: Any] = [
            "username": username,
            "email": email,
            "password": password,
            "device": DeviceName.current,
        ]
        if !name.isEmpty { body["name"] = name }
        if let emailCode, !emailCode.isEmpty { body["email_code"] = emailCode }
        if let inviteCode = inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines), !inviteCode.isEmpty { body["invite_code"] = inviteCode }
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { body["reason"] = reason }
        if let captcha, !captcha.isEmpty { body["captcha"] = captcha }

        let result: (data: Data, response: HTTPURLResponse)
        do {
            result = try await client.http.sendWithResponse("POST", NodelocAuthPaths.register, body: .json(body))
        } catch let error as DiscourseError {
            if CaptchaFailure.isCaptcha(error) {
                throw AuthError.captchaRequired(ServerFieldErrors.last()["captcha"] ?? error.errorDescription ?? AppString("请先完成人机验证"))
            }
            throw AuthError.signupFailed(error.errorDescription ?? AppString("注册失败，请稍后重试。"))
        }
        let registered = try NodelocJSON.decode(NLAuthResponse.self, from: result.data)
        if registered.loggedIn == true {
            try await adopt(result.data, response: result.response)
            return .signedIn
        }
        if registered.pendingApproval == true {
            throw AuthError.signupNeedsActivation(AppString("注册申请已提交，审核通过后会通过邮件通知你。"))
        }
        // Without an email code the account exists but isn't signed in; when
        // the site doesn't require verification, signing in completes it.
        do {
            try await login(identifier: username, password: password)
            return .signedIn
        } catch {
            throw AuthError.signupNeedsActivation(
                AppString("我们给 \(email) 发了一封验证邮件，点击邮件里的链接完成注册后再登录。")
            )
        }
    }

    /// Sends the 6-digit registration code to an email address.
    func requestSignupEmailCode(email: String, captcha: String? = nil) async throws {
        var body: [String: Any] = ["email": email]
        if let captcha, !captcha.isEmpty { body["captcha"] = captcha }
        do {
            try await client.http.send("POST", NodelocAuthPaths.registerEmailCode, body: .json(body))
        } catch let error as DiscourseError where CaptchaFailure.isCaptcha(error) {
            throw AuthError.captchaRequired(ServerFieldErrors.last()["captcha"] ?? error.errorDescription ?? AppString("请先完成人机验证"))
        }
    }

    // MARK: Social sign-in

    /// Adopts the session a hosted web-view sign-in (`/auth/<provider>`)
    /// ended with.
    func completeProviderLogin(cookies: [HTTPCookie]) async throws {
        guard let session = cookies.first(where: { $0.name == "nl_session" && !$0.value.isEmpty }) else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }
        if auth.isAuthenticated { signOut() }
        for cookie in cookies where NodelocHTTP.keptCookies.contains(cookie.name) && cookie.name != "nl_session" {
            auth.cookies[cookie.name] = cookie.value
        }
        auth.credential = .cookie(session.value)
        try await finishSignIn()
    }

    /// Where the system browser starts a sign-in: a provider's own route, or
    /// the site's sign-in page (every option) when `provider` is nil. Carries
    /// the PKCE challenge whose verifier `completeSocialCode` sends back.
    func socialSignInURL(provider: String?, pkce: NodelocPKCE) -> URL {
        let start = provider.flatMap { NodelocAuthCapabilities.providerURLs[$0] }.flatMap(URL.init(string:))
            ?? baseURL.appending(path: provider.map(NodelocAuthPaths.socialStart(provider:)) ?? "login")
        var components = URLComponents(url: start, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "app", value: "ios"),
            URLQueryItem(name: "redirect_uri", value: "\(DiscourseConfig.callbackScheme)://auth"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
        ]
        return components.url!
    }

    /// Reads the browser's return to `nodeloc://auth`: the one-time code, or
    /// why there isn't one.
    static func socialCallback(_ url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "cancelled" { throw AuthError.cancelled }
            throw AuthError.loginFailed(AppString("登录没有完成，请重试。"))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.loginFailed(AppString("登录没有完成，请重试。"))
        }
        return code
    }

    /// Exchanges the one-time code a system-browser sign-in returned with
    /// (`nodeloc://auth?code=…`) for a session.
    func completeSocialCode(_ code: String, codeVerifier: String?) async throws {
        if auth.isAuthenticated { signOut() }
        var body: [String: Any] = ["code": code, "device": DeviceName.current]
        if let codeVerifier { body["code_verifier"] = codeVerifier }
        do {
            let result = try await client.http.sendWithResponse(
                "POST", NodelocAuthPaths.socialExchange, body: .json(body)
            )
            try await adopt(result.data, response: result.response)
        } catch let error as DiscourseError {
            throw AuthError.loginFailed(error.errorDescription ?? AppString("登录未完成，请重试。"))
        }
    }

    /// Native Sign in with Apple. Rethrows the server's answer untouched so
    /// the caller can tell "not available" (404) from a real failure and fall
    /// back to the web flow.
    func completeNativeAppleLogin(_ credential: AppleSignInCredential) async throws {
        if auth.isAuthenticated { signOut() }
        var body: [String: Any] = [
            "identity_token": credential.identityToken,
            "nonce": credential.nonce,
            "device": DeviceName.current,
        ]
        if let code = credential.authorizationCode { body["authorization_code"] = code }
        if let name = credential.fullName, !name.isEmpty { body["name"] = name }
        do {
            let result = try await client.http.sendWithResponse("POST", NodelocAuthPaths.appleExchange, body: .json(body))
            try await adopt(result.data, response: result.response)
        } catch let error as DiscourseError where error.statusCode == 404 {
            // Not configured on this server: stop offering the native button.
            NodelocAuthCapabilities.appleNative = false
            throw error
        }
    }

    // MARK: Passkeys

    /// Step one of a passkey sign-in: the server's challenge.
    func beginPasskeyLogin() async throws -> PasskeyChallenge {
        let data = try await client.http.send("POST", NodelocAuthPaths.passkeyBegin, body: .json([:]))
        return try PasskeyChallenge(data: data)
    }

    /// Step two: the platform's signed assertion, exchanged for a session.
    func finishPasskeyLogin(challengeID: String, assertion: PasskeyAssertion) async throws {
        if auth.isAuthenticated { signOut() }
        let result = try await client.http.sendWithResponse("POST", NodelocAuthPaths.passkeyFinish, body: .json([
            "challenge_id": challengeID,
            "credential": assertion.json,
            "device": DeviceName.current,
        ]))
        try await adopt(result.data, response: result.response)
    }

    // MARK: Session adoption

    /// Takes the session a sign-in response carried: the token in the body
    /// when there is one, else the `nl_session` cookie.
    private func adopt(_ data: Data, response: HTTPURLResponse) async throws {
        let answer = try NodelocJSON.decode(NLAuthResponse.self, from: data)
        if let token = answer.token, !token.isEmpty {
            auth.credential = .bearer(token)
        } else if let cookie = NodelocHTTP.sessionCookie(in: response) {
            auth.credential = .cookie(cookie)
        } else {
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }
        if let trust = answer.trustToken, !trust.isEmpty { store.set(trust, for: keychainTrust) }
        auth.username = answer.user.username
        auth.userID = answer.user.id
        auth.isStaff = answer.user.isStaff
        NodelocAdapterState.shared.me = answer.user
        persist()
        Self.onSignIn?()
    }

    private func finishSignIn() async throws {
        guard let current = try? await client.currentUser() else {
            resetAuthState()
            throw AuthError.loginFailed(AppString("登录未完成，请重试。"))
        }
        auth.username = current.currentUser.username
        persist()
        Self.onSignIn?()
    }

    private func persist() {
        if let credential = auth.credential { store.set(credential.encoded, for: keychainCredential) }
        if let username = auth.username { store.set(username, for: keychainUser) }
        persistCookies()
    }
}

/// The APNs token this install last registered.
nonisolated enum PushTokenStore {
    private static let key = "nodeloc.push.apns_token"
    static var token: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The device name the server shows in the session list.
nonisolated enum DeviceName {
    static var current: String {
        #if os(iOS)
        return "NodeLoc iOS"
        #else
        return "NodeLoc"
        #endif
    }
}

// MARK: - Passkey payloads

/// `POST /api/v1/auth/passkey/begin` → `{challenge_id, options: {publicKey: …}}`.
nonisolated struct PasskeyChallenge: Sendable {
    let challengeID: String
    /// Raw challenge bytes (decoded from base64url).
    let challenge: Data
    let relyingPartyID: String

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["challenge_id"] as? String,
              let options = object["options"] as? [String: Any],
              let publicKey = options["publicKey"] as? [String: Any],
              let challenge = (publicKey["challenge"] as? String).flatMap(Base64URL.decode),
              let rpID = publicKey["rpId"] as? String
        else { throw DiscourseError.decoding(URLError(.cannotParseResponse)) }
        self.challengeID = id
        self.challenge = challenge
        self.relyingPartyID = rpID
    }
}

/// A WebAuthn assertion as the server's verifier reads it.
nonisolated struct PasskeyAssertion: Sendable {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    let userHandle: Data?

    var json: [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "authenticatorData": Base64URL.encode(authenticatorData),
            "signature": Base64URL.encode(signature),
        ]
        if let userHandle { response["userHandle"] = Base64URL.encode(userHandle) }
        let id = Base64URL.encode(credentialID)
        return ["id": id, "rawId": id, "type": "public-key", "response": response]
    }
}

nonisolated enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Keychain

nonisolated enum Keychain {
    #if canImport(Security)
    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
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
    #else
    nonisolated(unsafe) private static var memory: [String: String] = [:]
    static func set(_ value: String, for account: String) { memory[account] = value }
    static func get(_ account: String) -> String? { memory[account] }
    static func delete(_ account: String) { memory[account] = nil }
    #endif
}
