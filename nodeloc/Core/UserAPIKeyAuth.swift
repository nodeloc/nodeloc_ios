//
//  UserAPIKeyAuth.swift
//  nodeloc
//
//  Discourse's User API Key flow, run in the *system* browser.
//
//  Why this exists. The provider round-trip used to run in a `WKWebView`
//  (`SocialLoginView`), whose cookie jar is the app's own — so a Google session
//  already in Safari was invisible and every sign-in started from an empty
//  browser. Only `ASWebAuthenticationSession` and `SFSafariViewController` share
//  Safari's session, and neither lets the app read cookies back out. So the old
//  trick of lifting Discourse's `_t` cookie out of the web view can't work
//  there, and the flow has to end with a credential *in the callback URL*
//  instead. That is exactly what Discourse's User API Key flow is for.
//
//  How it runs:
//    1. generate an RSA keypair, kept in the keychain for the round-trip
//    2. open `/user-api-key/new?…&auth_redirect=nodeloc://auth_redirect` in
//       `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession`
//       *false* — that one flag is what shares Safari's session, and therefore
//       what makes the Google account picker appear
//    3. Discourse sends an anonymous visitor to its own login page first, where
//       every provider button is available, then to the authorize screen
//    4. it redirects to `nodeloc://auth_redirect?payload=<base64>`, RSA-encrypted
//       to our public key
//    5. decrypt, check the nonce, keep the key
//
//  Verified against the running server (Discourse 2026.9.0-latest):
//    * `UserApiKey::DeviceAuth::Crypto.encrypt!` uses PKCS#1 v1.5 by default and
//      OAEP (SHA-1) when `padding=oaep`; both modes are in
//      `ALLOWED_PADDING_MODES`. OAEP is requested here.
//    * `allow_user_api_key_scopes` includes `write`, whose route matcher has
//      `actions: nil` — unrestricted, so every plugin route the app uses
//      (custom-feeds, node/*, mobile/*, message-bus) works with this key.
//    * `allowed_user_api_auth_redirects` contains `nodeloc://auth_redirect`.
//      `WildcardUrlChecker` requires a scheme *and* a host, which is why the
//      callback is `nodeloc://auth_redirect` and not `nodeloc:auth_redirect`.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum UserAPIKeyAuthError: Error, LocalizedError {
    case cancelled
    case keyGeneration
    case noPayload
    /// The reply decrypted but its nonce wasn't the one we sent — a replayed or
    /// mismatched response, which must not be trusted.
    case nonceMismatch
    case decryptionFailed
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .keyGeneration: return AppString("无法在本机生成密钥，请重试。")
        case .noPayload: return AppString("登录没有完成，请重试。")
        case .nonceMismatch: return AppString("登录校验失败，请重试。")
        case .decryptionFailed: return AppString("无法解密服务器返回的凭据，请重试。")
        case .malformedPayload: return AppString("服务器返回了无法识别的凭据。")
        }
    }
}

@MainActor
enum UserAPIKeyAuth {
    /// Must match an entry in the site's `allowed_user_api_auth_redirects`.
    /// The `//` is not cosmetic: Discourse's `WildcardUrlChecker` rejects any
    /// redirect without a host component.
    static let callbackURL = "nodeloc://auth_redirect"
    static let callbackScheme = "nodeloc"

    /// `write` alone would do — its matcher is unrestricted — but the narrower
    /// ones are listed too so the authorize screen tells the reader what the
    /// app actually does, rather than just "write".
    ///
    /// `push` and `one_time_password` are deliberately absent: the app polls
    /// for notifications rather than using Discourse's push gateway, and an OTP
    /// would be a second credential with nothing to do.
    static let scopes = ["read", "write", "message_bus", "notifications", "session_info"]

    /// Runs the whole flow and returns the key. Throws `.cancelled` if the
    /// reader backed out, which callers should treat as a no-op rather than an
    /// error worth showing.
    static func authorize() async throws -> String {
        let keyPair = try RSAKeyPair.generate()
        // 32 hex characters. The payload has to fit inside one RSA block —
        // OAEP/SHA-1 on a 2048-bit key leaves 214 bytes, and the rest of the
        // JSON is ~110 — so a long nonce is the one thing that could overflow
        // it. The server says as much in `validate_payload_size!`.
        let nonce = Self.randomNonce()

        var components = URLComponents(
            url: DiscourseConfig.baseURL.appending(path: "user-api-key/new"),
            resolvingAgainstBaseURL: false
        )!
        // Encoded by hand rather than through `queryItems`, which leaves `+`
        // alone. A raw `+` in a query is decoded by Rack as a *space*, and the
        // public key is base64 — so a key containing `+` arrived with those
        // bytes replaced, `OpenSSL::PKey::RSA.new` rejected it, and
        // Discourse rescues that into "we can't issue a user API key, this may
        // have been disabled by the site administrator". A misleading message
        // for a mangled parameter, so this is worth getting right rather than
        // debugging twice.
        components.percentEncodedQuery = [
            ("application_name", DiscourseConfig.appName),
            ("client_id", DiscourseConfig.clientID),
            ("scopes", scopes.joined(separator: ",")),
            ("public_key", keyPair.publicKeyPEM),
            ("nonce", nonce),
            ("padding", "oaep"),
            ("auth_redirect", callbackURL),
        ]
        .map { "\(percentEncoded($0.0))=\(percentEncoded($0.1))" }
        .joined(separator: "&")

        guard let url = components.url else { throw UserAPIKeyAuthError.keyGeneration }

        let callback = try await WebAuthSession.run(url: url, callbackScheme: callbackScheme)

        guard let payload = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "payload" })?
            .value
        else { throw UserAPIKeyAuthError.noPayload }

        return try decrypt(payload: payload, using: keyPair, expecting: nonce)
    }

    /// Decrypts the reply and returns the key.
    ///
    /// The nonce check is the point of the nonce: it ties this reply to the
    /// request this app just made, so a payload captured from another attempt
    /// can't be replayed into a session.
    private static func decrypt(
        payload: String,
        using keyPair: RSAKeyPair,
        expecting nonce: String
    ) throws -> String {
        // Ruby's `Base64.encode64` inserts newlines every 60 characters, and
        // the value arrives percent-decoded — so both the line breaks and any
        // stray whitespace have to go before decoding.
        let cleaned = payload.filter { !$0.isWhitespace }
        guard let cipherText = Data(base64Encoded: cleaned) else {
            throw UserAPIKeyAuthError.malformedPayload
        }
        guard let plainText = keyPair.decrypt(cipherText) else {
            throw UserAPIKeyAuthError.decryptionFailed
        }
        guard let reply = try? JSONDecoder().decode(Payload.self, from: plainText) else {
            throw UserAPIKeyAuthError.malformedPayload
        }
        guard reply.nonce == nonce else { throw UserAPIKeyAuthError.nonceMismatch }
        return reply.key
    }

    /// What Discourse encrypts: `{ key, nonce, push, api }`, plus `expires_at`
    /// when the site sets an expiry. Only the first two are load-bearing here.
    private struct Payload: Decodable {
        let key: String
        let nonce: String
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set.
    ///
    /// Deliberately stricter than `URLQueryItem`: `+`, `/` and `=` all occur in
    /// base64 and all mean something else in a query string.
    private static func percentEncoded(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keypair

/// An ephemeral RSA keypair for one authorization.
///
/// Not persisted: it exists only long enough to decrypt one reply, and keeping
/// it would be storing a decryption key for a credential we already hold in
/// plaintext.
private struct RSAKeyPair {
    let privateKey: SecKey
    let publicKeyPEM: String

    /// OAEP with SHA-1, matching the server's `padding=oaep` branch — its size
    /// arithmetic (`key_size - 2*20 - 2`) is what identifies the digest as
    /// SHA-1 rather than SHA-256.
    static let algorithm = SecKeyAlgorithm.rsaEncryptionOAEPSHA1

    static func generate() throws -> RSAKeyPair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            // 2048 leaves 214 payload bytes under OAEP/SHA-1, comfortably more
            // than the ~110 the server sends.
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw UserAPIKeyAuthError.keyGeneration }

        return RSAKeyPair(
            privateKey: privateKey,
            publicKeyPEM: pem(fromPKCS1: der)
        )
    }

    func decrypt(_ cipherText: Data) -> Data? {
        var error: Unmanaged<CFError>?
        return SecKeyCreateDecryptedData(
            privateKey,
            Self.algorithm,
            cipherText as CFData,
            &error
        ) as Data?
    }

    /// Wraps the key as a SubjectPublicKeyInfo PEM, which is what
    /// `OpenSSL::PKey::RSA.new` on the server expects.
    ///
    /// `SecKeyCopyExternalRepresentation` hands back a bare PKCS#1 RSAPublicKey
    /// — just modulus and exponent — with no algorithm identifier. OpenSSL will
    /// not read that as a public key, so the DER has to be re-wrapped in the
    /// SPKI header by hand. This is the step that silently produces
    /// "invalid public_key" if skipped.
    private static func pem(fromPKCS1 pkcs1: Data) -> String {
        // AlgorithmIdentifier for rsaEncryption, then a BIT STRING holding the
        // PKCS#1 key.
        let rsaOID: [UInt8] = [
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
        ]
        var bitString = Data([0x00])
        bitString.append(pkcs1)

        var body = Data(rsaOID)
        body.append(derElement(tag: 0x03, contents: bitString))

        let spki = derElement(tag: 0x30, contents: body)
        let base64 = spki.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----\n"
    }

    /// One DER element: tag, length in definite form, contents.
    private static func derElement(tag: UInt8, contents: Data) -> Data {
        var element = Data([tag])
        let count = contents.count
        if count < 0x80 {
            element.append(UInt8(count))
        } else {
            // Long form: how many length bytes follow, then the length itself,
            // big-endian and without leading zeros.
            var lengthBytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xff), at: 0)
                remaining >>= 8
            }
            element.append(UInt8(0x80 | lengthBytes.count))
            element.append(contentsOf: lengthBytes)
        }
        element.append(contents)
        return element
    }
}

// MARK: - Web auth session

/// `ASWebAuthenticationSession` as an await.
@MainActor
private final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var retain: WebAuthSession?

    static func run(url: URL, callbackScheme: String) async throws -> URL {
        let runner = WebAuthSession()
        return try await runner.start(url: url, callbackScheme: callbackScheme)
    }

    private func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // Retains itself for the duration, as the Apple flow does: nothing
            // else holds this object once `start` suspends.
            retain = self
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callback, error in
                self?.session = nil
                self?.retain = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: UserAPIKeyAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? UserAPIKeyAuthError.noPayload)
                }
            }
            session.presentationContextProvider = self
            // The whole point of the exercise: false means the session shares
            // Safari's cookies, so a Google (or GitHub, or X) login already on
            // this device is offered as an account to pick instead of a form to
            // fill in. Setting this true would reproduce the isolated web view
            // this flow replaced.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}
