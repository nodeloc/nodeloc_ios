//
//  AppPresentationHost.swift
//  nodeloc
//
//  Everything a screen needs in order to *present* things, packaged so it can
//  be re-established inside a full-screen cover.
//
//  The problem this solves. `ContentView` owns the app-level presentations —
//  the in-app browser, the reference sheet — and the `openURL` handler that
//  feeds them. A `fullScreenCover` renders above `ContentView` and starts its
//  own environment context, so a screen inside one gets neither: its links fall
//  through to the *system* handler and open Safari, and anything `ContentView`
//  presents appears behind the cover where nobody can see it. That is the same
//  shape of bug as an `app.overlay` opening under a cover, and it had shown up
//  in several places.
//
//  Each host owns a *separate* `BrowserState` rather than sharing
//  `BrowserState.shared`. Two covers bound to one piece of state would both try
//  to present it; giving the nested context its own keeps the innermost one in
//  charge, which is what a reader expects — the browser opens over what they
//  were looking at.
//

import SwiftUI

// MARK: - Reference action

/// Opens an `@user` / `#node` / `#tag` reference, resolved to whichever host is
/// nearest. Mirrors `openURL`: the callee doesn't know or care who presents it.
struct OpenPostReferenceAction {
    var handler: (PostReference) -> Void

    func callAsFunction(_ reference: PostReference) {
        handler(reference)
    }
}

extension EnvironmentValues {
    @Entry var openPostReference = OpenPostReferenceAction { _ in }
}

// MARK: - Host

extension View {
    /// Re-establishes the app's shared environment and presentations for
    /// content shown in its own context (a cover or a sheet).
    ///
    /// Apply this to the *content* of every cover that can show post bodies,
    /// node pages or profiles. Without it, links there escape to Safari.
    func appPresentationHost(app: AppState) -> some View {
        modifier(AppPresentationHostModifier(app: app, hostsOverlays: true))
    }
}

private struct AppPresentationHostModifier: ViewModifier {
    let app: AppState
    /// Whether task overlays (`app.overlay = .compose` and the like) opened
    /// while this context is on top present from here. False only for the
    /// cover that *is* such an overlay.
    let hostsOverlays: Bool

    @Namespace private var overlayNamespace

    /// The task overlay this host owns, if any — see `AppState.overlayHost`.
    private var hostedOverlay: Binding<Overlay?> {
        Binding(
            get: {
                guard hostsOverlays, let overlay = app.overlay, overlay.presentsFromTopHost,
                      app.overlayHost == ObjectIdentifier(browser) else { return nil }
                return overlay
            },
            set: { newValue in
                if newValue == nil, app.overlayHost == ObjectIdentifier(browser),
                   app.overlay?.presentsFromTopHost == true {
                    app.overlay = nil
                }
            }
        )
    }

    @ViewBuilder
    private func overlayContent(_ overlay: Overlay) -> some View {
        switch overlay {
        case .compose: ComposeOverlay()
        case .createNode: CreateNodeOverlay()
        case .notifications: NotificationsOverlay()
        case .auth: AuthFlowOverlay()
        case .search:
            SearchOverlay(postTransitionNamespace: overlayNamespace, initialQuery: app.searchInitialQuery)
                .onDisappear { app.searchInitialQuery = "" }
        case .sidebar, .post, .browseNodes: EmptyView()
        }
    }

    /// The login flow as this context's own cover: the app-wide overlay
    /// draws under covers, out of sight.
    @State private var showsAuth = false

    private func openAuth(_ mode: AuthMode) {
        app.authMode = mode
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            showsAuth = true
        }
    }

    /// This context's own browser, deliberately not `BrowserState.shared`.
    @State private var browser = BrowserState()
    /// This context's own reference sheet.
    @State private var reference: PostReference?

    func body(content: Content) -> some View {
        content
            .environment(app)
            .environment(browser)
            .environment(EmojiImageStore.shared)
            .environment(VideoMuteState.shared)
            .environment(VideoPosterStore.shared)
            .environment(\.openPostReference, OpenPostReferenceAction { found in
                if found.kind == .tag { app.pushPage(.tag(found.slug)) } else { reference = found }
            })
            // Inline links in post bodies are attributed-string link runs that
            // SwiftUI opens itself, so there is no per-link callback —
            // intercepting the environment action is what catches them all.
            .routesLinksInApp(
                app: app,
                browser: browser,
                openReference: { found in
                    if found.kind == .tag { app.pushPage(.tag(found.slug)) } else { reference = found }
                }
            )
            .fullScreenCover(isPresented: Binding(
                get: { browser.url != nil },
                set: { if !$0 { browser.close() } }
            )) {
                if let url = browser.url {
                    BrowserView(url: url) { browser.close() }
                }
            }
            .sheet(item: $reference) { target in
                PostReferenceSheet(reference: target) { reference = nil }
                    .appPresentationHost(app: app)
                    .standardSheet()
            }
            // Pages opened without an environment (`openWeb`) come here while
            // this context is on screen, not to the root under it.
            // The guest login prompt, from this context while it's on top.
            .sheet(item: Binding(
                get: { BrowserState.shared.isTop(browser) ? app.loginPrompt : nil },
                set: { app.loginPrompt = $0 }
            )) { context in
                LoginPromptSheet(context: context, onLogin: { openAuth(.login) }, onSignup: { openAuth(.signup) })
            }
            .sheet(item: Binding(
                get: { BrowserState.shared.isTop(browser) ? app.resetPasswordToken : nil },
                set: { app.resetPasswordToken = $0 }
            )) { token in
                NavigationStack { ResetPasswordPage(token: token.value) { app.resetPasswordToken = nil } }
                    .environment(app)
            }
            .fullScreenCover(isPresented: $showsAuth) {
                AuthFlowOverlay(onDismiss: { showsAuth = false })
            }
            // The composer, search, login and the other task overlays, when
            // opened while this context is the top one.
            .fullScreenCover(item: hostedOverlay) { overlay in
                overlayContent(overlay)
                    .modifier(AppPresentationHostModifier(app: app, hostsOverlays: false))
            }
            .overlay(alignment: .top) { if BrowserState.shared.isTop(browser) { ToastHost() } }
            .penaltyAlert(app: app, isActive: BrowserState.shared.isTop(browser))
            .onAppear { BrowserState.shared.register(browser, hostsOverlays: hostsOverlays) }
            .onDisappear {
                BrowserState.shared.unregister(browser)
                // Taken down with its parent (the page stack closing): don't
                // leave the overlay set for the root to draw afterwards.
                if hostsOverlays, app.overlayHost == ObjectIdentifier(browser),
                   app.overlay?.presentsFromTopHost == true {
                    app.overlay = nil
                }
            }
            // Last, so it reaches this host's own sheets and covers too. A
            // cover doesn't inherit the root's environment.
            .environment(\.locale, AppLocaleStore.shared.locale)
            .environment(\.layoutDirection, AppLocaleStore.shared.layoutDirection)
    }
}

// MARK: - Penalty alert

extension View {
    /// App-iOS-Blocked: a penalty stopped an action. Attached to the root and
    /// to every host; only the one on top (`isActive`) presents it.
    func penaltyAlert(app: AppState, isActive: Bool) -> some View {
        alert(
            AppString("暂时不能这样做"),
            isPresented: Binding(
                get: { isActive && PenaltyAlertCenter.shared.message != nil },
                set: { if !$0 { PenaltyAlertCenter.shared.message = nil } }
            )
        ) {
            Button(AppString("知道了"), role: .cancel) {}
            Button(AppString("查看账号状态")) { app.pushPage(.accountStatus) }
        } message: {
            Text(PenaltyAlertCenter.shared.message ?? "")
        }
    }
}
