//
//  CaptchaChallenge.swift
//  nodeloc
//
//  人机验证 (accounts.md「人机验证」「App 接入人机验证」). The server decides
//  everything: whether it's on, the provider (hCaptcha, Turnstile or
//  reCAPTCHA), the site key and which actions need it — `GET
//  /api/v1/auth/captcha`. The widget is that provider's own web component in
//  a small web view loaded as the site's origin, so the site key's domain
//  check passes; the token it hands back goes into the request's `captcha`
//  field untouched, once.
//

import SwiftUI
import WebKit
import HCaptcha

/// `GET /api/v1/auth/captcha`.
nonisolated struct CaptchaConfig: Decodable, Sendable, Equatable {
    let enabled: Bool
    let provider: String?
    let siteKey: String?
    let script: String?
    let actions: [String: Bool]?
    let loginMode: String?
    let loginAfterFailures: Int?
    let registerPassSeconds: Int?

    static let off = CaptchaConfig(
        enabled: false, provider: nil, siteKey: nil, script: nil, actions: nil,
        loginMode: nil, loginAfterFailures: nil, registerPassSeconds: nil
    )

    /// Whether `action` needs a token up front. Login in `after_failures`
    /// mode doesn't: the server says so (`fields.captcha`) when it does.
    func requiresUpFront(_ action: CaptchaAction) -> Bool {
        guard enabled, let key = siteKey, !key.isEmpty, actions?[action.rawValue] == true else { return false }
        if action == .login { return loginMode != "after_failures" }
        return true
    }

    var isUsable: Bool { enabled && !(siteKey ?? "").isEmpty }
}

nonisolated enum CaptchaAction: String, Sendable {
    case login
    case register
    case registerCode = "register_code"
    case passwordReset = "password_reset"
}

/// The config, fetched fresh before a submit (cached briefly), as the spec
/// asks: an admin can change provider or key at any time.
@MainActor
final class CaptchaConfigStore {
    static let shared = CaptchaConfigStore()
    private var cached: (config: CaptchaConfig, at: Date)?

    func current(force: Bool = false) async -> CaptchaConfig {
        if !force, let cached, Date().timeIntervalSince(cached.at) < 180 { return cached.config }
        guard let config: CaptchaConfig = try? await DiscourseClient().get("api/v1/auth/captcha") else {
            // Unreachable: let the request go; the server answers
            // `captcha_required` if it wanted one, and that re-asks.
            return cached?.config ?? .off
        }
        cached = (config, Date())
        return config
    }
}

// MARK: - Gate

/// One per screen that submits. `token(for:)` shows the widget when the
/// action needs it and returns the token, nil when it doesn't apply, or
/// throws `CancellationError` when the reader closed it.
@MainActor
@Observable
final class CaptchaGate {
    struct Request: Identifiable {
        let id = UUID()
        let config: CaptchaConfig
    }

    var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<String?, Never>?

    /// A token for `action`, or nil when this action doesn't need one.
    func token(for action: CaptchaAction, force: Bool = false) async throws -> String? {
        let config = await CaptchaConfigStore.shared.current(force: force)
        guard config.isUsable, force || config.requiresUpFront(action) else { return nil }
        let token = await challenge(config)
        guard let token else { throw CancellationError() }
        return token
    }

    private func challenge(_ config: CaptchaConfig) async -> String? {
        // Keyboard down first: left up, it covered the challenge (seen on
        // the phone after tapping 登录 with the password field focused).
        await dismissKeyboard()
        // hCaptcha through its own native SDK (accounts.md「App 接入人机验证」);
        // Turnstile and reCAPTCHA have none, so they keep the web view.
        if (config.provider ?? "hcaptcha") == "hcaptcha", let key = config.siteKey {
            return await HCaptchaNative.token(siteKey: key)
        }
        continuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            request = Request(config: config)
        }
    }

    func finish(_ token: String?) {
        request = nil
        continuation?.resume(returning: token)
        continuation = nil
    }
}

extension View {
    /// Presents the gate's widget.
    func captchaGate(_ gate: CaptchaGate) -> some View {
        sheet(item: Binding(
            get: { gate.request },
            set: { if $0 == nil { gate.finish(nil) } }
        )) { request in
            CaptchaSheet(config: request.config) { gate.finish($0) }
                .presentationDetents([.height(420), .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Sheet

struct CaptchaSheet: View {
    let config: CaptchaConfig
    let onFinish: (String?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var message: String?
    @State private var reloadID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(AppString("完成下面的验证后继续。"))
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CaptchaWebView(config: config, dark: colorScheme == .dark) { event in
                    switch event {
                    case .token(let token): onFinish(token)
                    case .expired:
                        message = AppString("验证已过期，请重新验证。")
                        reloadID = UUID()
                    case .failed:
                        message = AppString("验证没有完成，请重试。")
                    }
                }
                .id(reloadID)
                .frame(maxWidth: .infinity, minHeight: 300)
                if let message {
                    Text(message)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(AppString("人机验证"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onFinish(nil) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(AppString("关闭"))
                }
            }
        }
    }
}

enum CaptchaEvent {
    case token(String)
    case expired
    case failed
}

/// The provider's widget, rendered explicitly and reporting back through a
/// script message.
struct CaptchaWebView: UIViewRepresentable {
    let config: CaptchaConfig
    let dark: Bool
    let onEvent: (CaptchaEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "captcha")
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: DiscourseConfig.baseURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "captcha")
    }

    private var language: String { AppLanguage.resolved.acceptLanguageHeader.split(separator: ",").first.map(String.init) ?? "zh-CN" }

    /// One page for the three providers; the server's own script URL when it
    /// sent one (it names `nlCaptchaLoaded` as the onload).
    private var html: String {
        let provider = config.provider ?? "hcaptcha"
        let key = (config.siteKey ?? "").replacingOccurrences(of: "'", with: "")
        let theme = dark ? "dark" : "light"
        let lang = language
        let script: String
        let render: String
        switch provider {
        case "turnstile":
            script = config.script ?? "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=nlCaptchaLoaded"
            render = "turnstile.render('#w',{sitekey:'\(key)',theme:'\(theme)',language:'\(lang)',callback:t=>post({token:t}),'expired-callback':()=>post({expired:1}),'error-callback':e=>post({error:String(e)})});"
        case "recaptcha":
            script = (config.script ?? "https://www.google.com/recaptcha/api.js?render=explicit&onload=nlCaptchaLoaded") + "&hl=\(lang)"
            render = "grecaptcha.render('w',{sitekey:'\(key)',theme:'\(theme)',callback:t=>post({token:t}),'expired-callback':()=>post({expired:1}),'error-callback':()=>post({error:'error'})});"
        default:
            script = (config.script ?? "https://js.hcaptcha.com/1/api.js?render=explicit&onload=nlCaptchaLoaded") + "&hl=\(lang)"
            render = "hcaptcha.render('w',{sitekey:'\(key)',theme:'\(theme)',callback:t=>post({token:t}),'expired-callback':()=>post({expired:1}),'chalexpired-callback':()=>post({expired:1}),'error-callback':e=>post({error:String(e)})});"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;background:transparent}body{display:flex;justify-content:center;padding-top:8px}</style>
        <script>
        function post(m){window.webkit.messageHandlers.captcha.postMessage(m)}
        function nlCaptchaLoaded(){try{\(render)}catch(e){post({error:String(e)})}}
        </script>
        <script src="\(script)" async defer></script>
        </head><body><div id="w"></div></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onEvent: (CaptchaEvent) -> Void
        init(onEvent: @escaping (CaptchaEvent) -> Void) { self.onEvent = onEvent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let token = body["token"] as? String, !token.isEmpty {
                onEvent(.token(token))
            } else if body["expired"] != nil {
                onEvent(.expired)
            } else {
                onEvent(.failed)
            }
        }

        /// The challenge's own links (privacy, terms) open outside, not in
        /// the widget's frame.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Login

/// Password login with the captcha the server asks for: a token up front
/// when `login_mode` is `always`; otherwise (or when the 2FA step outlived
/// the server's 10 minutes) on its `captcha_required`, once.
@MainActor
enum CaptchaLogin {
    static func login(
        gate: CaptchaGate,
        identifier: String,
        password: String,
        secondFactorToken: String?,
        secondFactorMethod: Int
    ) async throws {
        // The 2FA step is covered by the first step's check.
        let upFront = secondFactorToken == nil ? try await gate.token(for: .login) : nil
        do {
            try await DiscourseLogin.shared.login(
                identifier: identifier, password: password,
                secondFactorToken: secondFactorToken, secondFactorMethod: secondFactorMethod,
                captcha: upFront
            )
        } catch AuthError.captchaRequired {
            let token = try await gate.token(for: .login, force: true)
            try await DiscourseLogin.shared.login(
                identifier: identifier, password: password,
                secondFactorToken: secondFactorToken, secondFactorMethod: secondFactorMethod,
                captcha: token
            )
        }
    }
}


// MARK: - hCaptcha native SDK

/// hCaptcha's iOS SDK (HCaptcha-ios-sdk): the challenge over the top screen,
/// in the app's language and appearance, with the site key from the server
/// and the site as its base URL, so the key's domain check passes.
@MainActor
enum HCaptchaNative {
    /// Held while a challenge is up: the SDK's object must outlive the call.
    private static var current: HCaptcha?
    private static weak var webView: WKWebView?

    static func token(siteKey: String) async -> String? {
        current?.stop()
        guard let host = topViewController()?.view else { return nil }
        let dark = host.traitCollection.userInterfaceStyle == .dark
        let language = AppLanguage.resolved.acceptLanguageHeader.split(separator: ",").first.map(String.init) ?? "zh-CN"
        guard let captcha = try? HCaptcha(
            apiKey: siteKey,
            baseURL: DiscourseConfig.baseURL,
            locale: Locale(identifier: language),
            size: .invisible,
            theme: dark ? "dark" : "light"
        ) else { return nil }
        current = captcha
        captcha.configureWebView { view in
            view.frame = host.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView = view
        }
        let token: String? = await withCheckedContinuation { continuation in
            var finished = false
            captcha.validate(on: host, resetOnError: false) { result in
                guard !finished else { return }
                finished = true
                // A closed challenge (`challengeClosed`) or any error is nil:
                // nothing is submitted.
                continuation.resume(returning: try? result.dematerialize())
            }
        }
        captcha.stop()
        webView?.removeFromSuperview()
        current = nil
        return token
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}


/// Ends editing anywhere and waits for the keyboard to go, so whatever is
/// presented next isn't covered by it.
@MainActor
func dismissKeyboard() async {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    try? await Task.sleep(for: .milliseconds(350))
}
