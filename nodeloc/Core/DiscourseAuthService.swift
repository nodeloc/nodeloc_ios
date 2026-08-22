//
//  DiscourseAuthService.swift
//  nodeloc
//
//  Implements Discourse's "User API Key" login flow — the same mechanism the
//  official Discourse mobile app uses:
//    1. generate an RSA keypair on device
//    2. open /user-api-key/new in a web-auth session
//    3. the user logs in & authorizes; Discourse redirects to nodeloc://auth
//       with an RSA-encrypted payload
//    4. decrypt with the private key → per-user `User-Api-Key`, stored in Keychain
//
//  Requires the site admin to have added `nodeloc://auth` to
//  `allowed user api auth redirects` and enabled `allow user api keys`.
//

import Foundation
import AuthenticationServices
import Security
import UIKit

enum DiscourseScopes {
    static let value = "session_info,read,write,notifications,push,message_bus,chat"
}

enum AuthError: Error, LocalizedError {
    case keyGeneration
    case missingPayload
    case decryptFailed
    case nonceMismatch
    case cancelled
    case missingCredentials
    case loginFailed(String)
    case signupFailed(String)
    case signupNeedsActivation(String)

    var errorDescription: String? {
        switch self {
        case .keyGeneration: return "Couldn't generate the security keys."
        case .missingPayload: return "The login response was incomplete."
        case .decryptFailed: return "Couldn't verify the login response."
        case .nonceMismatch: return "Login verification failed. Please try again."
        case .cancelled: return "Login was cancelled."
        case .missingCredentials: return "Please fill in all required fields."
        case .loginFailed(let message): return message
        case .signupFailed(let message): return message
        case .signupNeedsActivation(let message): return message
        }
    }
}

enum SignupResult {
    case signedIn
    case needsActivation(String)
}

@MainActor
final class DiscourseLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DiscourseLogin()

    private var session: ASWebAuthenticationSession?
    private var privateKey: SecKey?
    private var nonce = ""

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
        return true
    }

    func signOut() {
        Keychain.delete(keychainKey)
        Keychain.delete(keychainSession)
        Keychain.delete(keychainCSRF)
        Keychain.delete(keychainUser)
        clearCookies()
        DiscourseAuth.shared.userApiKey = nil
        DiscourseAuth.shared.sessionCookie = nil
        DiscourseAuth.shared.csrfToken = nil
        DiscourseAuth.shared.username = nil
    }

    // MARK: Username/password auth

    func login(identifier rawIdentifier: String, password rawPassword: String) async throws {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !password.isEmpty else { throw AuthError.missingCredentials }

        signOut()
        let csrf = try await fetchCSRFToken()
        let (data, _) = try await postForm(
            "session",
            form: [
                "login": identifier,
                "password": password,
                "second_factor_method": "1",
                "timezone": TimeZone.current.identifier,
            ],
            csrf: csrf
        )

        // Discourse answers HTTP 200 even when the login fails — the outcome is
        // in the body. A wrong password, an unactivated account, a required
        // second factor, or a social-only account (no password) all come back
        // here as `{ "error": … }`, so the status code alone can't be trusted.
        // On success it renders the signed-in user, so `user.username` is the
        // authoritative "logged in" signal — no follow-up request needed.
        let result = try? decode(SessionLoginResponse.self, from: data)
        if let message = result?.error ?? result?.failed {
            throw AuthError.loginFailed(message)
        }
        guard let username = result?.user?.username else {
            throw AuthError.loginFailed("登录未完成，请重试。")
        }

        try persistWebsiteSession(csrf: csrf, username: username)
    }

    func signup(
        username rawUsername: String,
        name rawName: String,
        email rawEmail: String,
        password rawPassword: String
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
        let (data, response) = try await postForm(
            "users",
            form: [
                "username": username,
                "name": name.isEmpty ? username : name,
                "email": email,
                "password": password,
                "timezone": TimeZone.current.identifier,
            ],
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

        throw AuthError.signupNeedsActivation(message)
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

    // MARK: Website app authorization

    func start() async throws {
        guard let keyPair = Self.generateKeyPair() else { throw AuthError.keyGeneration }
        privateKey = keyPair.private
        nonce = Self.randomNonce()

        guard let publicPEM = Self.publicKeyPEM(keyPair.public) else { throw AuthError.keyGeneration }

        var components = URLComponents(
            url: DiscourseConfig.baseURL.appending(path: "user-api-key/new"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            .init(name: "application_name", value: DiscourseConfig.appName),
            .init(name: "client_id", value: DiscourseConfig.clientID()),
            .init(name: "scopes", value: DiscourseScopes.value),
            .init(name: "public_key", value: publicPEM),
            .init(name: "nonce", value: nonce),
            .init(name: "auth_redirect", value: DiscourseConfig.authRedirect),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: "nodeloc"
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.missingPayload)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }

        try handleCallback(callback)
        await fetchUsername()
    }

    private func handleCallback(_ url: URL) throws {
        guard
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "payload" })?.value,
            let priv = privateKey
        else { throw AuthError.missingPayload }

        // Base64 may arrive with '+' turned into spaces by URL decoding.
        let base64 = raw.replacingOccurrences(of: " ", with: "+")
        guard
            let encrypted = Data(base64Encoded: base64),
            let clear = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, encrypted as CFData, nil) as Data?
        else { throw AuthError.decryptFailed }

        struct Payload: Decodable { let key: String; let nonce: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: clear) else {
            throw AuthError.decryptFailed
        }
        guard payload.nonce == nonce else { throw AuthError.nonceMismatch }

        Keychain.set(payload.key, for: keychainKey)
        DiscourseAuth.shared.userApiKey = payload.key
    }

    private func fetchUsername() async {
        guard let current = try? await DiscourseClient().currentUser() else { return }
        DiscourseAuth.shared.username = current.currentUser.username
        Keychain.set(current.currentUser.username, for: keychainUser)
    }

    // MARK: Identifiers

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: Presentation

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        preconditionFailure("ASWebAuthenticationSession requires an active window scene.")
    }

    // MARK: RSA

    private static func generateKeyPair() -> (private: SecKey, public: SecKey)? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        guard
            let priv = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
            let pub = SecKeyCopyPublicKey(priv)
        else { return nil }
        return (priv, pub)
    }

    /// Discourse expects an X.509 SubjectPublicKeyInfo ("PUBLIC KEY") PEM, but
    /// SecKey exports RSA keys as PKCS#1; wrap it in the SPKI header.
    private static func publicKeyPEM(_ key: SecKey) -> String? {
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }

        let rsaOID: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48,
                               0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        var bitString = Data([0x00]) + pkcs1
        bitString = Data([0x03]) + encodeLength(bitString.count) + bitString
        var sequence = Data(rsaOID) + bitString
        sequence = Data([0x30]) + encodeLength(sequence.count) + sequence

        let base64 = sequence.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n"
    }

    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
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
    let user: LoggedInUser?

    struct LoggedInUser: Decodable {
        let username: String
    }
}

private struct SignupResponse: Decodable {
    let success: Bool?
    let active: Bool?
    let message: String?
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
