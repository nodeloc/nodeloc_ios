//
//  ContentView.swift
//  nodeloc
//
//  Root flow: Auth → Onboarding → Main app.
//

import SwiftUI

/// Composite task id, so a buffered universal link is reconsidered when either
/// the link itself or the app's readiness to show it changes.
private struct PendingLink: Equatable {
    let url: URL?
    let isReady: Bool
}

struct ContentView: View {
    @State private var app = AppState()
    @State private var browser = BrowserState.shared
    /// Drives the app-wide colour scheme; read here so a change redraws
    /// everything below.
    private var preferences = UserPreferencesStore.shared
    /// Watched for the deep link a tapped push banner carries.
    private var push = PushNotificationService.shared
    /// Drives the interface language; read here so switching redraws the tree.
    private var appLocale = AppLocaleStore.shared
    /// The wordmark-writing launch animation, shown once per cold start.
    @State private var isShowingSplash = true
    /// A universal link that arrived before the app was ready to show it.
    @State private var pendingLink: URL?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            Group {
                if !app.authed && !app.isGuest {
                    AuthView()
                } else if app.authed && !app.onboardingDone {
                    OnboardingView()
                } else {
                    MainView()
                }
            }
            .transition(.opacity)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        // Friendly failure notices for actions that have no other surface.
        // Both only while nothing is presented over the root: a cover or sheet
        // shows its own (see `appPresentationHost`), since anything drawn here
        // is underneath it.
        .overlay(alignment: .top) { if BrowserState.shared.isTop(nil) { ToastHost() } }
        .penaltyAlert(app: app, isActive: BrowserState.shared.isTop(nil))
        // Over everything, and only on a cold start: the app keeps loading
        // behind it, so the animation costs no time it wasn't already using.
        .overlay {
            if isShowingSplash {
                SplashView { isShowingSplash = false }
                    .transition(.opacity)
            }
        }
        // Theme's colours are already light/dark pairs, so overriding the
        // scheme here is all "深色/浅色" needs. `.auto` passes nil and follows
        // the system.
        .preferredColorScheme(preferences.colorMode.colorScheme)
        // The root's link handling, in-app browser and reference sheet. Every
        // cover below re-establishes its own — see `appPresentationHost`.
        .routesLinksInApp(app: app, browser: browser)
        .sheet(item: Binding(
            get: { BrowserState.shared.isTop(nil) ? app.resetPasswordToken : nil },
            set: { app.resetPasswordToken = $0 }
        )) { token in
            NavigationStack { ResetPasswordPage(token: token.value) { app.resetPasswordToken = nil } }
                .environment(app)
        }
        // The guest login prompt, when no cover is up (covers show their own).
        .sheet(item: Binding(
            get: { BrowserState.shared.isTop(nil) ? app.loginPrompt : nil },
            set: { app.loginPrompt = $0 }
        )) { context in
            LoginPromptSheet(
                context: context,
                onLogin: { Task { try? await Task.sleep(for: .milliseconds(350)); presentAuth(app, mode: .login) } },
                onSignup: { Task { try? await Task.sleep(for: .milliseconds(350)); presentAuth(app, mode: .signup) } }
            )
        }
        .fullScreenCover(isPresented: browserPresented) {
            if let url = browser.url {
                BrowserView(url: url) { browser.close() }
            }
        }
        // Native destinations for internal links, presented here so they work
        // from any screen — a mention inside a post, the sidebar, anywhere.
        //
        // Full-screen covers, so they arrive from the bottom rather than the
        // trailing edge. That reads as a modal for what is really a page, and a
        // `NavigationStack` around the tabs was tried to fix it — but
        // `.searchable` + `.tabViewSearchActivation` only produce the tab bar's
        // search pill while the `TabView` is a *top-level* container, so
        // nesting it lost the search field and the search tab outright.
        // Presenting from here is also what lets these open from any depth: the
        // post reader draws in `MainView`, under every cover.
        //
        // Each gets its own presentation host: a cover renders above this view
        // and starts a fresh environment, so without one their links would
        // escape to Safari and their sheets would open behind the cover.
        .fullScreenCover(item: cover($app.routedProfile)) { target in
            PublicProfileOverlay(target: target) { app.routedProfile = nil }
                .appPresentationHost(app: app)
        }
        .fullScreenCover(item: routedNodeCover) { node in
            NodeDetailOverlay(node: node) { app.routedNodeSlug = nil }
                .appPresentationHost(app: app)
        }
        // The routed page stack: profiles, nodes, posts, custom feeds, apps and
        // group inboxes opened from anywhere, one cover, one navigation stack —
        // see `AppState.pageStack`.
        .fullScreenCover(isPresented: Binding(
            get: { !app.pageStack.isEmpty },
            set: { if !$0 { app.pageStack.removeAll() } }
        )) {
            RoutedPageStack()
                .appPresentationHost(app: app)
                // Clear, so the stack's base shows the screen underneath and
                // the first page arrives with a push, not a cover.
                .presentationBackground(.clear)
        }
        // A badge tapped at the root. Half height rather than full screen:
        // following a reference is a glance sideways, and the sheet leaves the
        // paragraph it came from visible behind it.
        .sheet(item: $app.routedReference) { reference in
            PostReferenceSheet(reference: reference) { app.routedReference = nil }
                .appPresentationHost(app: app)
                .standardSheet()
        }
        .task(id: app.routedNodeSlug) {
            guard let slug = app.routedNodeSlug else {
                withAnimation(.overlayPush) { app.routedNode = nil }
                return
            }
            let node = await NodeCatalog.shared.node(slug: slug)
            // Off the pinned-sidebar column, a node goes onto the page stack
            // like every other routed page.
            if let node, !app.routedPageInColumn {
                app.routedNodeSlug = nil
                app.pushPage(.node(node))
                return
            }
            withAnimation(.overlayPush) { app.routedNode = node }
            // Unknown slug: fall back to the web page rather than doing nothing.
            if node == nil,
               let url = URL(string: "/n/\(slug)", relativeTo: DiscourseConfig.baseURL)?.absoluteURL {
                app.routedNodeSlug = nil
                browser.open(url)
            }
        }
        .environment(app)
        .environment(browser)
        // The root's reference handler, matching the sheet above. Covers
        // override this with their own so the nearest one presents.
        // A #tag opens its tag page on the stack (App-iOS-Tag); other
        // references keep their sheet.
        .environment(\.openPostReference, OpenPostReferenceAction { reference in
            if reference.kind == .tag { app.pushPage(.tag(reference.slug)) } else { app.routedReference = reference }
        })
        // Shared across every rendered post so inline emoji are fetched once.
        .environment(EmojiImageStore.shared)
        // Mute is a single app-wide preference, like Reddit's.
        .environment(VideoMuteState.shared)
        // First frames are decoded once per clip and reused across screens.
        .environment(VideoPosterStore.shared)
        .task {
            // Restore a previously signed-in session.
            if DiscourseLogin.shared.restore() {
                app.authed = true
                app.onboardingDone = true
            }
        }
        #if DEBUG
        // App Store screenshot capture. Compiled out of Release.
        .task {
            guard ScreenshotMode.isActive else { return }
            isShowingSplash = false
            app.isGuest = true
            app.onboardingDone = true
            switch ScreenshotMode.tab {
            case "nodes": app.tab = .nodes
            case "chat": app.tab = .chat
            case "profile": app.tab = .profile
            case "search": app.tab = .search
            default: app.tab = .home
            }
            if ScreenshotMode.showsSidebar {
                app.overlay = .sidebar
            }
            if let topicID = ScreenshotMode.topicID {
                // The feed needs a moment to load before a topic reads well on
                // top of it.
                try? await Task.sleep(for: .seconds(3))
                app.openTopic(id: topicID)
            }
        }
        #endif
        // Read once per launch, before either gated feature can be reached.
        .task { await FeatureFlags.shared.refresh() }
        // Tag colours and icons, for the chips on topic rows and node pages.
        .task { await TagLookStore.shared.loadIfNeeded() }
        // The forum's language preference wins over the device's, so pick it up
        // whenever a session appears — at launch and again after signing in.
        .task(id: app.authed) {
            guard app.authed else { return }
            // Independent, so run together. The locale and the block list both
            // read your own profile; started at once, they share one request.
            async let locale: Void = appLocale.syncFromAccount()
            // The account's own block list is authoritative: someone blocked on
            // the website should be hidden here too, and someone unblocked
            // there should come back. See `BlockedUsersStore.loadFromServer`.
            async let blocks = BlockedUsersStore.shared.loadFromServer()
            // A device token issued before the session was restored has
            // nowhere to go; this is the retry. See `syncRegistration`.
            async let push: Void = PushNotificationService.shared.syncRegistration()
            _ = await (locale, blocks, push)
        }
        // A tapped push banner routes exactly like a universal link: buffered
        // until the app proper is on screen (a cold start from a banner lands
        // while the splash is up and before `MainView` exists, so routing on
        // the spot opened the post into nothing), and with any cover left from
        // before cleared so the post doesn't open invisibly behind it.
        .task(id: push.routedURL) {
            guard let url = push.routedURL else { return }
            push.routedURL = nil
            pendingLink = url
        }
        // A universal link — tapped in Telegram, Messages, Mail, anywhere.
        // `onOpenURL` is the entire entry point: SwiftUI hands universal links
        // over as plain URLs rather than as an `NSUserActivity`, so
        // `onContinueUserActivity` would never fire for one.
        //
        // Buffered rather than routed on the spot, see the task below.
        .onOpenURL { url in
            // A reset link is for someone who can't sign in: open it at once,
            // not after the app is past its welcome screen.
            if case .resetPassword(let token) = LinkRouter.destination(for: url) {
                app.resetPasswordToken = ResetPasswordToken(value: token)
            } else {
                pendingLink = url
            }
        }
        // Routed only once the app proper is on screen.
        //
        // A cold start from a link delivers the URL while the splash is still
        // up and before the root has chosen between `AuthView` and `MainView`.
        // `.post` is an overlay *inside* `MainView`, so routing any earlier
        // sets state that nothing is presenting — which looks exactly like
        // "the link opens the app but not the post".
        .task(id: PendingLink(url: pendingLink, isReady: app.authed || app.isGuest)) {
            guard let url = pendingLink, app.authed || app.isGuest else { return }
            pendingLink = nil
            // The splash covers `MainView`'s overlay layer, so leaving it up
            // would hide the post that was just opened.
            isShowingSplash = false
            // So would a cover left over from before the app went to the
            // background: the reader would return from Telegram to the page
            // they had already been looking at, with the new post opened
            // invisibly behind it — the same symptom by a different route.
            // Cleared before routing, so a link that wants one of these can
            // still set it.
            browser.close()
            app.pageStack.removeAll()
            app.routedProfile = nil
            app.routedNodeSlug = nil
            app.routedCustomFeed = nil
            app.routedReference = nil
            LinkRouter.open(url, app: app, browser: browser)
        }
        .task {
            // Trim the image cache once per launch, at low priority so it never
            // competes with the first screen's own loading.
            await Task(priority: .background) {
                await RemoteImageDiskCache.shared.prune()
            }.value
        }
        .animation(.easeInOut(duration: 0.25), value: app.authed)
        .animation(.easeInOut(duration: 0.25), value: app.isGuest)
        .animation(.easeInOut(duration: 0.25), value: app.onboardingDone)
        // `Text` resolves its key against the environment's locale at render
        // time, so overriding it here re-localizes everything below without a
        // relaunch. Arabic and Persian also need the mirrored layout, which
        // does not follow from the locale on its own.
        //
        // Last in the chain on purpose: an environment value only reaches
        // what it wraps, and the sheets and covers above are modifiers. Set
        // before them, it stopped at the root screen — the composer, login,
        // pages and every sheet opened from them kept the system language.
        .environment(\.locale, appLocale.locale)
        .environment(\.layoutDirection, appLocale.layoutDirection)
    }

    private var browserPresented: Binding<Bool> {
        Binding(
            get: { browser.url != nil },
            set: { if !$0 { browser.close() } }
        )
    }

    /// Clearing the binding also clears the slug, so the same node can be
    /// opened again after being dismissed.
    private var routedNodeCover: Binding<SidebarNodeSummary?> {
        cover(Binding(
            get: { app.routedNode },
            set: { newValue in
                app.routedNode = newValue
                if newValue == nil { app.routedNodeSlug = nil }
            }
        ))
    }

    /// A routed page's binding, emptied while `MainView` is drawing that page in
    /// its content column instead (`AppState.routedPageInColumn`). One piece of
    /// state, two possible presenters, and never both at once.
    private func cover<Value>(_ source: Binding<Value?>) -> Binding<Value?> {
        Binding(
            get: { app.routedPageInColumn ? nil : source.wrappedValue },
            set: { source.wrappedValue = $0 }
        )
    }
}

#Preview {
    ContentView()
}
