//
//  AppleSignIn.swift
//  nodeloc
//
//  Native Sign in with Apple, and the request it hands the server.
//
//  Discourse can't take this on its own: its Apple provider is a stock OmniAuth
//  OAuth2 strategy driven by a browser round-trip
//  (`plugins/discourse-apple-auth`), with no endpoint that accepts an identity
//  token. So the credential goes to the companion plugin, which verifies it and
//  answers with an ordinary session cookie — see `SERVER_TASKS_APPLE_SIGNIN.md`.
//
//  Until that endpoint exists the caller falls back to the web flow, so this
//  can ship before the server side does.
//

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// One completed Apple authorization, in the shape the server endpoint wants.
struct AppleSignInCredential: Sendable {
    /// Apple's signed JWT.
    let identityToken: String
    /// The *unhashed* nonce. Apple stores the SHA256 of it in the token, so the
    /// server compares its hash — which means it needs the original.
    let nonce: String
    let authorizationCode: String?
    /// Apple sends these on the *first* authorization only, never again.
    let email: String?
    let fullName: String?
}

@MainActor
enum AppleSignIn {
    /// Presents the native authorization sheet and returns what the server
    /// needs. Nil means the person cancelled — not an error.
    ///
    /// The controller is driven here rather than by `SignInWithAppleButton`
    /// because the button is a custom one (see `NativeAppleSignInButton`), and
    /// SwiftUI's control is the only thing that would otherwise run it.
    ///
    /// Apple is given the *hash* of the nonce and the server needs the original
    /// to check the token against, which is why the nonce is generated here and
    /// travels back out in the credential.
    static func authorize() async throws -> AppleSignInCredential? {
        let nonce = randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        guard let authorization = try await AuthorizationCoordinator().run(request) else {
            return nil
        }
        return credential(from: authorization, nonce: nonce)
    }

    /// Pulls what the server needs out of an authorization result.
    static func credential(
        from authorization: ASAuthorization,
        nonce: String
    ) -> AppleSignInCredential? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else { return nil }

        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        return AppleSignInCredential(
            identityToken: identityToken,
            nonce: nonce,
            authorizationCode: credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) },
            email: credential.email,
            fullName: name.isEmpty ? nil : name
        )
    }

    /// 32 bytes of randomness, hex-encoded.
    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // `SystemRandomNumberGenerator` is the CSPRNG here; `SecRandomCopyBytes`
        // would do the same with an error path that can't be handled usefully.
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Bridges `ASAuthorizationController`'s delegate callbacks to an await.
///
/// It retains *itself* for the duration of the sheet: the controller's delegate
/// is a weak reference, and once `run` suspends nothing else on the stack holds
/// either object, so both would be deallocated before Apple could call back.
@MainActor
private final class AuthorizationCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<ASAuthorization?, any Error>?
    private var controller: ASAuthorizationController?
    private var retain: AuthorizationCoordinator?

    func run(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorization? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.retain = self

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization?, any Error>) {
        // Nil-out first: resuming twice traps, and the callbacks are not
        // guaranteed to arrive only once.
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        retain = nil
        continuation.resume(with: result)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        // Backing out of the sheet is a choice, not a failure.
        if (error as? ASAuthorizationError)?.code == .canceled {
            finish(.success(nil))
        } else {
            finish(.failure(error))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
    }
}
