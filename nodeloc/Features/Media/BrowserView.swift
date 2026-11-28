//
//  BrowserView.swift
//  nodeloc
//
//  In-app browser. Every link tapped anywhere in the app arrives here rather
//  than kicking the reader out to Safari — except nodeloc's own topic and
//  profile URLs, which are routed to the native screens instead (see
//  `LinkRouter`), and social sign-in, which runs in its own web view so the
//  session cookies it produces can be read back (see `SocialLoginView`).
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
        /// `/tag/<slug>` — the native tag topic list.
        case tag(slug: String)
        /// `/f/<username>/<slug>` — discourse-community's custom feed.
        case customFeed(username: String, slug: String)
        /// `/apps/<slug>` — a mini app's page. Guideline 4.7.4 wants a
        /// universal link per app, so this has to resolve natively rather than
        /// fall through to the web view.
        case app(slug: String)
        /// A group's PM inbox (staff/moderators), where group-message
        /// notifications point; opens the inbox filtered to that group.
        case groupInbox(group: String)
        /// `/rank`, `/points`, `/invites` — 财富榜, 能量明细, 邀请好友.
        case leaderboard, energy, invites
        /// `/review[?item=N]` (the site queue, as `/admin/review`) and
        /// `/n/<slug>/manage#review[?item=N]` (a node's queue): where
        /// moderation notifications point.
        case reviewQueue(node: String?, item: Int?)
        /// `/appeal` — the account status page, where penalty and appeal
        /// notifications point.
        case accountStatus
        /// `/reset-password?token=…` — the link in the password-reset email;
        /// set the new password natively.
        case resetPassword(token: String)
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
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // /go?u=… and /leave?url=… are the site's leave-the-site interstitial.
        // When what they wrap is the site itself, open that natively; anything
        // else keeps the interstitial, which is the site's own safety check.
        if segments.count == 1, segments[0] == "go" || segments[0] == "leave",
           let inner = query.first(where: { $0.name == "u" || $0.name == "url" })?.value,
           let innerURL = URL(string: inner), isNodeloc(innerURL) {
            return destination(for: innerURL)
        }

        // /t/<slug>/<id> and /t/topic/<id>, plus the bare /t/<id> form.
        if segments.first == "t" {
            // The id is the last numeric segment: later components can be a
            // post number, as in /t/slug/123/45.
            let numbers = segments.dropFirst().compactMap(Int.init)
            if let id = numbers.first {
                // The number after the id, when present, is the post number;
                // the site's own links put it in `?post=N` or `#post-N`.
                let postNumber = numbers.count > 1
                    ? numbers[1]
                    : query.first(where: { $0.name == "post" })?.value.flatMap { Int($0) }
                        ?? url.fragment.flatMap { fragment in
                            fragment.hasPrefix("post-") ? Int(fragment.dropFirst(5)) : nil
                        }
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

        // /apps/<slug>. "directory" is the index page and "installs" is the
        // sandboxed runner document, neither of which is an app slug.
        if segments.first == "apps", segments.count >= 2 {
            let slug = segments[1]
            if slug != "directory", slug != "installs" {
                return .app(slug: slug)
            }
        }

        // The review queues: /review and /admin/review site-wide,
        // /n/<slug>/manage#review for a node; `item` opens one item.
        let item = query.first(where: { $0.name == "item" })?.value.flatMap { Int($0) }
        if segments == ["review"] || segments == ["admin", "review"] {
            return .reviewQueue(node: nil, item: item)
        }
        if segments.first == "n", segments.count >= 3, segments[2] == "manage",
           url.fragment == "review" || item != nil {
            return .reviewQueue(node: segments[1], item: item)
        }
        if segments == ["appeal"] {
            return .accountStatus
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

        // /f/<username>/<slug> — a custom feed. Exactly two segments follow, so
        // anything deeper is left to the web view rather than guessed at.
        if segments.first == "f", segments.count == 3 {
            return .customFeed(username: segments[1], slug: segments[2])
        }

        // /rank, /points and /invites have native pages. Notifications about
        // energy and invite rewards point at the last two.
        if segments.count == 1, segments[0] == "reset-password",
           let token = query.first(where: { $0.name == "token" })?.value, !token.isEmpty {
            return .resetPassword(token: token)
        }

        if segments.count == 1 {
            switch segments[0] {
            case "rank": return .leaderboard
            case "points": return .energy
            case "invites": return .invites
            default: break
            }
        }

        // /tag/<slug>[/<id>] — cooked `#tag` hrefs, and the same shape when one
        // is shared as a plain link.
        if segments.first == "tag", segments.count >= 2 {
            let slugs = segments.dropFirst().filter { Int($0) == nil }
            if let slug = slugs.last {
                return .tag(slug: slug)
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

    /// The browsers of the presentation hosts on screen (covers and sheets,
    /// see `appPresentationHost`), innermost last.
    ///
    /// Code that opens a page without a view's environment (`openWeb`) used
    /// to open the root's browser, whose cover then knocked down whatever
    /// cover was showing — 关联账户's 连接 popped back to 设置 and came back.
    /// The shared browser now hands the page to the innermost host.
    private var hosts: [BrowserState] = []

    func open(_ url: URL) {
        if self === Self.shared, let host = hosts.last {
            host.url = url
        } else {
            self.url = url
        }
    }

    func close() { url = nil }

    /// Hosts that present the app's task overlays (`Overlay.presentsFromTopHost`).
    /// A host that *is* one of those overlays doesn't, so it isn't listed here.
    private var overlayHosts: [ObjectIdentifier] = []

    func register(_ host: BrowserState, hostsOverlays: Bool = true) {
        guard self === Self.shared, !hosts.contains(where: { $0 === host }) else { return }
        hosts.append(host)
        if hostsOverlays { overlayHosts.append(ObjectIdentifier(host)) }
    }

    func unregister(_ host: BrowserState) {
        hosts.removeAll { $0 === host }
        overlayHosts.removeAll { $0 == ObjectIdentifier(host) }
    }

    /// The host an app overlay opened now should present from: the innermost
    /// one that presents overlays, or nil for the root (`MainView`).
    var topOverlayHost: ObjectIdentifier? {
        let ids = Set(overlayHosts)
        return hosts.last(where: { ids.contains(ObjectIdentifier($0)) }).map(ObjectIdentifier.init)
    }

    /// Whether this host is the innermost one on screen; the root (no
    /// hosts) when `host` is nil. Used for anything only the top screen
    /// should present, like the guest login prompt.
    func isTop(_ host: BrowserState?) -> Bool {
        guard let host else { return hosts.isEmpty }
        return hosts.last === host
    }
}

extension LinkRouter {
    /// Routes a URL to its native screen or the in-app browser. Returns false
    /// for external schemes (mailto:, tel:) that only the system can open.
    /// Shared by the root openURL handler and push-notification taps.
    /// `openReference` lets the *nearest* presentation host show a tag rather
    /// than the root one; a tag has no full-screen page of its own, so it goes
    /// through the same half sheet a `#tag` badge does. Nil falls back to app
    /// state, which is right for the root.
    @discardableResult
    static func open(
        _ url: URL,
        app: AppState,
        browser: BrowserState,
        openReference: ((PostReference) -> Void)? = nil
    ) -> Bool {
        switch destination(for: url) {
        case .topic(let id, let postNumber):
            // Onto the page stack when it's up — the reader overlay draws
            // under it and would open out of sight.
            app.openTopicPage(id: id, postNumber: postNumber)
        case .profile(let username):
            app.openProfile(username: username)
        case .node(let slug):
            app.openNode(slug: slug)
        case .customFeed(let username, let slug):
            app.openCustomFeed(username: username, slug: slug)
        case .tag(let slug):
            // Its own page now (App-iOS-Tag), not a reference sheet.
            app.pushPage(.tag(slug))
        case .app(let slug):
            app.openApp(slug: slug)
        case .groupInbox(let group):
            app.openGroupInbox(group: group)
        case .reviewQueue(let node, let item):
            app.pushPage(.reviewQueue(node: node, item: item))
        case .accountStatus:
            app.pushPage(.accountStatus)
        case .leaderboard:
            app.pushPage(.leaderboard)
        case .energy:
            app.pushPage(.energy)
        case .invites:
            app.pushPage(.invite)
        case .resetPassword(let token):
            app.resetPasswordToken = ResetPasswordToken(value: token)
        case .web(let url):
            browser.open(url)
        case .external:
            return false
        }
        return true
    }
}

extension View {
    /// Sends every link tapped inside this view through `LinkRouter`, so text
    /// links, oneboxes and buttons all behave the same way.
    func routesLinksInApp(
        app: AppState,
        browser: BrowserState,
        openReference: ((PostReference) -> Void)? = nil
    ) -> some View {
        environment(\.openURL, OpenURLAction { url in
            LinkRouter.open(
                url,
                app: app,
                browser: browser,
                openReference: openReference
            ) ? .handled : .systemAction
        })
    }
}

// MARK: - Browser

struct BrowserView: View {
    let url: URL
    let onClose: () -> Void

    @State private var model = BrowserWebModel()

    var body: some View {
        ZStack(alignment: .top) {
            // The web content owns the whole surface; the chrome floats on top
            // and gets out of the way while reading.
            //
            // Laid out below the chrome's row rather than under it: a site's
            // own sticky header sat behind the glass and couldn't be read or
            // tapped. A content inset wouldn't help there — fixed-position
            // elements ignore it — so the web view simply starts lower.
            BrowserWebView(url: url, model: model)
                .ignoresSafeArea(edges: .bottom)
                .padding(.top, chromeRowHeight)

            if let loadError = model.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                    Text(AppString("页面加载失败"))
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(loadError)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                    Button(AppString("重试")) { model.retry(fallback: url) }
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.accent700)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .padding(.top, chromeRowHeight)
            }

            if model.estimatedProgress < 1 {
                ProgressView(value: model.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .padding(.top, chromeRowHeight)
            }

            topChrome
        }
        .overlay(alignment: .bottom) { bottomToolbar }
        .background(Theme.bg)
    }

    // MARK: Floating chrome

    /// The top row's full height: 8pt above a 48pt glass control.
    private let chromeRowHeight: CGFloat = 56

    /// Telegram-style top row: close — full-width host capsule — ellipsis menu.
    /// While reading, the buttons fade out (keeping their layout slots, so the
    /// capsule stays centred) and the capsule shrinks.
    private var topChrome: some View {
        HStack(spacing: 8) {
            HeaderIconButton(systemName: "xmark", accessibilityLabel: AppString("关闭"), action: onClose)
                .opacity(model.chromeHidden ? 0 : 1)
                .offset(y: model.chromeHidden ? -12 : 0)
                .allowsHitTesting(!model.chromeHidden)

            hostCapsule
                // A flexible middle slot: the capsule fills it by default and
                // stays centred in it once collapsed to hug the host text.
                .frame(maxWidth: .infinity)

            browserMenu
                .opacity(model.chromeHidden ? 0 : 1)
                .offset(y: model.chromeHidden ? -12 : 0)
                .allowsHitTesting(!model.chromeHidden)
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.top, 8)
    }

    /// Glass capsule with the host name. Its background fills from the left
    /// with the page's scroll progress; tapping it brings the buttons back.
    private var hostCapsule: some View {
        Button {
            model.revealChrome()
        } label: {
            HStack(spacing: 4) {
                // A padlock is a security claim, so only show it when the
                // connection actually is encrypted.
                if model.currentURL?.scheme == "https" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textMuted)
                }
                Text(model.currentURL?.host ?? url.host ?? "")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: model.chromeHidden ? 28 : FloatingHeader.controlHeight)
            .frame(maxWidth: model.chromeHidden ? nil : .infinity)
            .frame(minWidth: 120)
            // `.glass` buttons add 7pt above/below their 34pt label for a 48pt
            // capsule; reproduce that so the capsule matches the buttons'
            // height by default. Collapsed drops it to shrink into a pill.
            .padding(.vertical, model.chromeHidden ? 0 : 7)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: proxy.size.width * model.scrollProgress)
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        // `.interactive()` is what gives glass its press response (the same
        // grow-on-touch the neighbouring `.glass` buttons get for free).
        .glassSurface(tint: FloatingHeader.glassTint, interactive: true)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .accessibilityLabel("显示浏览器按钮")
    }

    /// The ellipsis (…) dropdown: text size, open in Safari, reload, share,
    /// copy link — the browser actions that aren't worth a toolbar slot.
    private var browserMenu: some View {
        Menu {
            ControlGroup {
                Button {
                    model.zoomOut()
                } label: {
                    Label("缩小文字", systemImage: "textformat.size.smaller")
                }
                Button {
                    model.resetZoom()
                } label: {
                    Text(model.zoomPercent)
                }
                Button {
                    model.zoomIn()
                } label: {
                    Label("放大文字", systemImage: "textformat.size.larger")
                }
            }

            if let current = model.currentURL {
                Button {
                    UIApplication.shared.open(current)
                } label: {
                    Label("在 Safari 中打开", systemImage: "safari")
                }
            }

            Divider()

            Button { model.reload() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            if let current = model.currentURL {
                ShareLink(item: current) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button {
                    copyLink(current)
                } label: {
                    Label("拷贝链接", systemImage: "doc.on.doc")
                }
            }
        } label: {
            FloatingHeaderIcon(systemName: "ellipsis")
        }
        .glassButton(tint: FloatingHeader.glassTint, shape: .circle)
        .accessibilityLabel("更多")
    }

    /// 返回 / 分享 / 刷新 / 在默认浏览器打开, floating over the page bottom.
    /// Slides away while reading down; returns on a scroll up or at either end.
    private var bottomToolbar: some View {
        HStack(spacing: 14) {
            toolButton("chevron.left", label: AppString("返回"), enabled: model.canGoBack) {
                model.goBack()
            }

            toolButton("chevron.right", label: AppString("前进"), enabled: model.canGoForward) {
                model.goForward()
            }

            if let current = model.currentURL {
                ShareLink(item: current) {
                    toolIcon("square.and.arrow.up", enabled: true)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("分享")
            } else {
                toolIcon("square.and.arrow.up", enabled: false)
            }

            toolButton("arrow.clockwise", label: AppString("刷新"), enabled: true) {
                model.reload()
            }

            toolButton("safari", label: AppString("在默认浏览器打开"), enabled: model.currentURL != nil) {
                if let current = model.currentURL {
                    UIApplication.shared.open(current)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassSurface(tint: FloatingHeader.glassTint, interactive: true)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
        .padding(.bottom, 10)
        .opacity(model.chromeHidden ? 0 : 1)
        .offset(y: model.chromeHidden ? 90 : 0)
        .allowsHitTesting(!model.chromeHidden)
    }

    private func toolButton(
        _ systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolIcon(systemName, enabled: enabled)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func toolIcon(_ systemName: String, enabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
    }
}

/// Navigation state the SwiftUI chrome reads.
@MainActor
@Observable
final class BrowserWebModel {
    var title = ""
    var currentURL: URL?
    var canGoBack = false
    var canGoForward = false
    var estimatedProgress: Double = 0

    /// How far down the page the reader is (0…1) — the host capsule's fill.
    var scrollProgress: Double = 0
    /// True while reading down the page; hides everything but the host capsule.
    var chromeHidden = false

    private var lastScrollOffset: CGFloat = 0

    fileprivate weak var webView: WKWebView?

    /// Why the last navigation failed to load at all, shown over the blank
    /// web view; nil while a page is loading or loaded.
    var loadError: String?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { retry(fallback: nil) }

    /// Reloads, or — when the very first load failed and the web view has no
    /// page to reload — loads the URL the browser was opened with.
    func retry(fallback: URL?) {
        loadError = nil
        guard let webView else { return }
        if webView.url == nil, let target = currentURL ?? fallback {
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
    }

    // MARK: Text size

    /// Page zoom (WKWebView.pageZoom), stepped 50%…200% from the … menu.
    private(set) var pageZoom: CGFloat = 1

    var zoomPercent: String { "\(Int((pageZoom * 100).rounded()))%" }

    func zoomIn() { setZoom(min(pageZoom + 0.1, 2)) }
    func zoomOut() { setZoom(max(pageZoom - 0.1, 0.5)) }
    func resetZoom() { setZoom(1) }

    private func setZoom(_ value: CGFloat) {
        pageZoom = value
        webView?.pageZoom = value
    }

    func revealChrome() { setChrome(hidden: false) }

    /// Follows the page's scroll: fills the capsule, hides the chrome while
    /// reading down, and restores it on a scroll up or at either end.
    fileprivate func trackScroll(of scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let offsetY = scrollView.contentOffset.y + inset.top
        let viewport = scrollView.bounds.height - inset.top - inset.bottom
        let maxOffset = scrollView.contentSize.height - viewport

        guard maxOffset > 0 else {
            // Shorter than the screen: nothing to scroll, keep everything.
            scrollProgress = 0
            setChrome(hidden: false)
            return
        }
        scrollProgress = min(max(Double(offsetY / maxOffset), 0), 1)

        let delta = offsetY - lastScrollOffset
        lastScrollOffset = offsetY

        // Both ends restore the buttons: the top is the initial state, and the
        // bottom is where the reader is done and ready to act.
        if offsetY <= 0 || offsetY >= maxOffset - 24 {
            setChrome(hidden: false)
            return
        }
        // A small threshold so slow drift doesn't flicker the chrome.
        if delta > 6 {
            setChrome(hidden: true)
        } else if delta < -6 {
            setChrome(hidden: false)
        }
    }

    private func setChrome(hidden: Bool) {
        guard chromeHidden != hidden else { return }
        withAnimation(.spring(duration: 0.32)) {
            chromeHidden = hidden
        }
    }
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
                // Scroll position drives the capsule's progress fill and the
                // hide-while-reading chrome. KVO rather than the scroll-view
                // delegate, which WebKit reserves for itself.
                webView.scrollView.observe(\.contentOffset, options: [.new]) { [model] scrollView, _ in
                    Task { @MainActor in model.trackScroll(of: scrollView) }
                },
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations = []
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor [model] in model.loadError = nil }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // A navigation replaced by another (a redirect, a second tap) or
            // handed off to another app isn't a failure the reader should see.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            let message = nsError.localizedDescription
            Task { @MainActor [model] in model.loadError = message }
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
