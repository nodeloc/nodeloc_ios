//
//  NodelocSocialAuth.swift
//  nodeloc
//
//  The platform halves of two sign-in flows whose network halves live in
//  `DiscourseLogin` (Core/Kit):
//
//  - Social sign-in in the *system* browser (`ASWebAuthenticationSession`),
//    so a provider session already on this device is offered as an account to
//    pick. The site sends the browser back to `nodeloc://auth?code=…` and the
//    one-time code is exchanged for an app session.
//  - Passkeys, through the platform's credential sheet. The relying party is
//    the site's domain, which the app is associated with through
//    `webcredentials:` in its entitlements.
//

import AuthenticationServices
import Foundation
import UIKit

enum SocialAuthError: Error, LocalizedError {
    case cancelled
    /// The server has no app hand-off; the caller falls back to the in-app web
    /// view, which adopts the site's session cookie instead.
    case unavailable
    case noCode

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .unavailable: return AppString("暂时无法通过浏览器登录，请稍后重试。")
        case .noCode: return AppString("登录没有完成，请重试。")
        }
    }
}

@MainActor
enum NodelocSocialAuth {
    /// Signs in through the system browser. `provider` picks one directly;
    /// nil opens the site's own sign-in page with every option.
    static func signIn(provider: String? = nil) async throws {
        let login = DiscourseLogin.shared
        // A server that lists providers for apps also runs the hand-off; one
        // that doesn't would strand the browser on the site after sign-in.
        guard (try? await DiscourseClient().authProviders()) != nil else { throw SocialAuthError.unavailable }

        let pkce = NodelocPKCE.make()
        let url = login.socialSignInURL(provider: provider, pkce: pkce)
        let callback = try await WebAuthSession.run(url: url, callbackScheme: DiscourseConfig.callbackScheme)
        let code: String
        do {
            code = try DiscourseLogin.socialCallback(callback)
        } catch AuthError.cancelled {
            // "取消" on the site's "sign in to the app as @…?" page.
            throw SocialAuthError.cancelled
        }
        try await login.completeSocialCode(code, codeVerifier: pkce.verifier)
    }
}

extension DiscourseLogin {
    /// The system-browser sign-in the welcome screen offers first.
    func loginWithSystemBrowser(provider: String? = nil) async throws {
        try await NodelocSocialAuth.signIn(provider: provider)
    }

    /// Passkey sign-in: challenge from the server, assertion from the
    /// platform sheet, session from the server.
    func loginWithPasskey() async throws {
        let challenge = try await beginPasskeyLogin()
        let assertion = try await PasskeySheet.assert(challenge: challenge)
        try await finishPasskeyLogin(challengeID: challenge.challengeID, assertion: assertion)
    }
}

// MARK: - Passkey sheet

@MainActor
private final class PasskeySheet: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<PasskeyAssertion, Error>?
    private var retain: PasskeySheet?

    static func assert(challenge: PasskeyChallenge) async throws -> PasskeyAssertion {
        let sheet = PasskeySheet()
        return try await sheet.run(challenge)
    }

    private func run(_ challenge: PasskeyChallenge) async throws -> PasskeyAssertion {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            retain = self
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: challenge.relyingPartyID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge.challenge)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { retain = nil }
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            continuation?.resume(throwing: AuthError.loginFailed(AppString("登录没有完成，请重试。")))
            continuation = nil
            return
        }
        continuation?.resume(returning: PasskeyAssertion(
            credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData,
            signature: credential.signature,
            userHandle: credential.userID
        ))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { retain = nil }
        if (error as? ASAuthorizationError)?.code == .canceled {
            continuation?.resume(throwing: AuthError.cancelled)
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        keyWindow()
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
                    continuation.resume(throwing: SocialAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SocialAuthError.noCode)
                }
            }
            session.presentationContextProvider = self
            // Shares Safari's cookies, so an existing provider login is offered
            // as an account to pick instead of a form to fill in.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        keyWindow()
    }
}

@MainActor
private func keyWindow() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
        ?? ASPresentationAnchor()
}
