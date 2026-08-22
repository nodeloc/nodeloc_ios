//
//  BrowserView.swift
//  nodeloc
//
//  In-app browser. Every link tapped anywhere in the app arrives here rather
//  than kicking the reader out to Safari — except nodeloc's own topic and
//  profile URLs, which are routed to the native screens instead (see
//  `LinkRouter`), and the OAuth flow, which needs a real
//  `ASWebAuthenticationSession` to share cookies with the system browser.
//

import SwiftUI
import WebKit

// MARK: - Routing

/// Decides what a tapped URL should do.
///
/// Centralised because inline links inside post bodies are `AttributedString`
/// link runs that SwiftUI opens on its own — there is no per-link callback to
/// hook. One `environment(\.openURL)` handler at the root catches all of them.
enum LinkRouter {
    enum Destination: Equatable {
        /// A nodeloc topic; open the native post detail. `postNumber`, when the
        /// URL carries one (/t/slug/id/45), scrolls to that reply.
        case topic(id: Int, postNumber: Int?)
        /// A nodeloc user; open the native profile.
        case profile(username: String)
        /// A nodeloc node; open the native node page.
        case node(slug: String)
        /// A group's PM inbox (staff/moderators), where group-message
        /// notifications point; opens the inbox filtered to that group.
        case groupInbox(group: String)
        /// Anything else, including nodeloc pages with no native equivalent.
        case web(URL)
        /// Not openable in a web view (mailto:, tel:, custom schemes).
        case external(URL)
    }

    static func destination(for url: URL) -> Destination {
        guard let scheme = url.scheme?.lowercased() else { return .external(url) }
        guard scheme == "http" || scheme == "https" else { return .external(url) }
        guard isNodeloc(url) else { return .web(url) }

        let segments = url.pathComponents.filter { $0 != "/" }

        // /t/<slug>/<id> and /t/topic/<id>, plus the bare /t/<id> form.
        if segments.first == "t" {
            // The id is the last numeric segment: later components can be a
            // post number, as in /t/slug/123/45.
            let numbers = segments.dropFirst().compactMap(Int.init)
            if let id = numbers.first {
                // The number after the id, when present, is the post number.
                let postNumber = numbers.count > 1 ? numbers[1] : nil
                return .topic(id: id, postNumber: postNumber)
            }
        }

        // /u/<username> and its public profile tabs open natively. Deeper
        // routes like /u/<name>/messages/group/<g> (where staff/group-message
        // notifications point) are inboxes with no native screen, so they fall
        // through to the in-app browser rather than being mistaken for a profile.
        if segments.first == "u", segments.count >= 2 {
            // /u/<name>/messages/group/<g> (or /messages/<g>) → the group inbox.
            if segments.count >= 4, segments[2] == "messages" {
                let group = (segments[3] == "group" && segments.count >= 5)
                    ? segments[4]
                    : segments[3]
                return .groupInbox(group: group)
            }
            let profileTabs: Set<String> = ["summary", "activity", "badges"]
            if segments.count == 2 || profileTabs.contains(segments[2]) {
                return .profile(username: segments[1])
            }
        }

        // /n/<slug> — discourse-community's node route, which appears in real
        // post bodies. /c/<slug>/<id> is core Discourse's equivalent.
        if segments.first == "n", segments.count >= 2 {
            return .node(slug: segments[1])
        }
        if segments.first == "c", segments.count >= 2 {
            // The last segment is the category id; the slug precedes it.
            let slugs = segments.dropFirst().filter { Int($0) == nil }
            if let slug = slugs.last {
                return .node(slug: slug)
            }
        }

        return .web(url)
    }

    private static func isNodeloc(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard let base = DiscourseConfig.baseURL.host?.lowercased() else { return false }
        // www.nodeloc.com and nodeloc.com are the same site.
        let strip: (String) -> String = { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return strip(host) == strip(base)
    }
}

// MARK: - Presentation

/// The URL the in-app browser is showing, if any.
@MainActor
@Observable
final class BrowserState {
    static let shared = BrowserState()

    var url: URL?

    func open(_ url: URL) { self.url = url }
    func close() { url = nil }
}

extension View {
    /// Sends every link tapped inside this view through `LinkRouter`, so text
    /// links, oneboxes and buttons all behave the same way.
    func routesLinksInApp(app: AppState, browser: BrowserState) -> some View {
        environment(\.openURL, OpenURLAction { url in
            switch LinkRouter.destination(for: url) {
            case .topic(let id, let postNumber):
                app.openTopic(id: id, postNumber: postNumber)
                return .handled
            case .profile(let username):
                app.openProfile(username: username)
                return .handled
            case .node(let slug):
                app.openNode(slug: slug)
                return .handled
            case .groupInbox(let group):
                app.openGroupInbox(group: group)
                return .handled
            case .web(let url):
                browser.open(url)
                return .handled
            case .external:
                // mailto:, tel: and app schemes have no in-app equivalent.
                return .systemAction
            }
        })
    }
}

// MARK: - Browser

struct BrowserView: View {
    let url: URL
    let onClose: () -> Void

    @State private var model = BrowserWebModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                BrowserWebView(url: url, model: model)
                if model.estimatedProgress < 1 {
                    ProgressView(value: model.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                }
            }
            // The web content owns the bottom edge; the header keeps the
            // status-bar inset so it doesn't collide with the island.
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.bg)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                HeaderIconButton(systemName: "xmark", accessibilityLabel: "关闭", action: onClose)

                VStack(spacing: 1) {
                    // Falls back to "载入中…" rather than the host, which the
                    // line below already shows.
                    Text(model.title.isEmpty ? "载入中…" : model.title)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        // A padlock is a security claim, so only show it when
                        // the connection actually is encrypted.
                        if model.currentURL?.scheme == "https" {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.muted(0.5))
                        }
                        Text(model.currentURL?.host ?? url.host ?? "")
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)

                Menu {
                    if let current = model.currentURL {
                        ShareLink(item: current) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIApplication.shared.open(current)
                        } label: {
                            Label("在 Safari 中打开", systemImage: "safari")
                        }
                        Button {
                            UIPasteboard.general.url = current
                        } label: {
                            Label("拷贝链接", systemImage: "doc.on.doc")
                        }
                    }
                    Button { model.reload() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                } label: {
                    FloatingHeaderIcon(systemName: "ellipsis")
                }
                .buttonStyle(.glass(.regular.tint(FloatingHeader.glassTint)))
                .buttonBorderShape(.circle)
                .accessibilityLabel("更多")
            }

            HStack(spacing: 22) {
                navButton("chevron.left", enabled: model.canGoBack, label: "后退") { model.goBack() }
                navButton("chevron.right", enabled: model.canGoForward, label: "前进") { model.goForward() }
                Spacer()
            }
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func navButton(
        _ systemName: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.muted(0.25))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Navigation state the SwiftUI header reads.
@MainActor
@Observable
final class BrowserWebModel {
    var title = ""
    var currentURL: URL?
    var canGoBack = false
    var canGoForward = false
    var estimatedProgress: Double = 0

    fileprivate weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

private struct BrowserWebView: UIViewRepresentable {
    let url: URL
    let model: BrowserWebModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // A general browser, unlike the games web view, keeps text selection
        // and the swipe-back gesture — people expect to read and copy here.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.observe(webView)
        model.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: BrowserWebModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserWebModel) {
            self.model = model
        }

        func observe(_ webView: WKWebView) {
            // KVO rather than delegate callbacks: progress and the back/forward
            // stack have no navigation-delegate equivalents.
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [model] view, _ in
                    Task { @MainActor in model.estimatedProgress = view.estimatedProgress }
                },
                webView.observe(\.title, options: [.new]) { [model] view, _ in
                    Task { @MainActor in model.title = view.title ?? "" }
                },
                webView.observe(\.url, options: [.new]) { [model] view, _ in
                    Task { @MainActor in model.currentURL = view.url }
                },
                webView.observe(\.canGoBack, options: [.new]) { [model] view, _ in
                    Task { @MainActor in model.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.new]) { [model] view, _ in
                    Task { @MainActor in model.canGoForward = view.canGoForward }
                },
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations = []
        }

        /// `target="_blank"` links return a nil web view from WebKit and would
        /// otherwise do nothing at all; load them in place instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// Schemes WebKit can't load (mailto:, tel:, app links) still need to
        /// leave the app, or the tap silently fails.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow)
                return
            }
            if scheme == "http" || scheme == "https" || scheme == "about" {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }
}
