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
    /// Resolved from `app.routedNodeSlug`; a link only carries the slug.
    @State private var resolvedNode: SidebarNodeSummary?
    /// A topic opened from a root-level cover (the custom feed page). Presented
    /// here for the same reason that page is: `app.overlay` draws in `MainView`,
    /// underneath these covers.
    @State private var openedPost: Post?
    @Namespace private var rootReaderNamespace

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
        .overlay(alignment: .top) { ToastHost() }
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
        // `Text` resolves its key against the environment's locale at render
        // time, so overriding it here re-localizes everything below without a
        // relaunch. Arabic and Persian also need the mirrored layout, which
        // does not follow from the locale on its own.
        .environment(\.locale, appLocale.locale)
        .environment(\.layoutDirection, appLocale.layoutDirection)
        // The root's link handling, in-app browser and reference sheet. Every
        // cover below re-establishes its own — see `appPresentationHost`.
        .routesLinksInApp(app: app, browser: browser)
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
        .fullScreenCover(item: $app.routedProfile) { target in
            PublicProfileOverlay(target: target) { app.routedProfile = nil }
                .appPresentationHost(app: app)
        }
        .fullScreenCover(item: routedNode) { node in
            NodeDetailOverlay(node: node) { app.routedNodeSlug = nil }
                .appPresentationHost(app: app)
        }
        .fullScreenCover(item: $app.routedCustomFeed) { target in
            CustomFeedView(
                target: target,
                // Presented from inside this cover for the usual reason:
                // `app.overlay` draws in `MainView`, behind it.
                onOpenPost: { post in
                    app.markTopicOpened(id: post.id)
                    app.selectedPost = post
                    openedPost = post
                },
                onOpenNode: { node in
                    app.routedCustomFeed = nil
                    app.openNode(slug: node.slug)
                },
                onDeleted: { app.routedCustomFeed = nil }
            )
            .appPresentationHost(app: app)
        }
        .fullScreenCover(item: $openedPost) { _ in
            ZStack {
                Theme.bg.ignoresSafeArea()
                PostDetailOverlay(
                    postTransitionNamespace: rootReaderNamespace,
                    onClose: { openedPost = nil }
                )
            }
            .environment(\.mediaAutoplayEnabled, true)
            .appPresentationHost(app: app)
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
                resolvedNode = nil
                return
            }
            resolvedNode = await NodeCatalog.shared.node(slug: slug)
            // Unknown slug: fall back to the web page rather than doing nothing.
            if resolvedNode == nil,
               let url = URL(string: "/n/\(slug)", relativeTo: DiscourseConfig.baseURL)?.absoluteURL {
                app.routedNodeSlug = nil
                browser.open(url)
            }
        }
        .environment(app)
        .environment(browser)
        // The root's reference handler, matching the sheet above. Covers
        // override this with their own so the nearest one presents.
        .environment(\.openPostReference, OpenPostReferenceAction { app.routedReference = $0 })
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
        // The forum's language preference wins over the device's, so pick it up
        // whenever a session appears — at launch and again after signing in.
        .task(id: app.authed) {
            guard app.authed else { return }
            await appLocale.syncFromAccount()
            // The account's own block list is authoritative: someone blocked on
            // the website should be hidden here too, and someone unblocked
            // there should come back. See `BlockedUsersStore.loadFromServer`.
            await BlockedUsersStore.shared.loadFromServer()
        }
        // A tapped push banner routes exactly like a tapped in-app link.
        .task(id: push.routedURL) {
            guard let url = push.routedURL else { return }
            push.routedURL = nil
            LinkRouter.open(url, app: app, browser: browser)
        }
        // A universal link — tapped in Telegram, Messages, Mail, anywhere.
        // `onOpenURL` is the entire entry point: SwiftUI hands universal links
        // over as plain URLs rather than as an `NSUserActivity`, so
        // `onContinueUserActivity` would never fire for one.
        //
        // Buffered rather than routed on the spot, see the task below.
        .onOpenURL { url in pendingLink = url }
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
            app.routedProfile = nil
            app.routedNodeSlug = nil
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
    }

    private var browserPresented: Binding<Bool> {
        Binding(
            get: { browser.url != nil },
            set: { if !$0 { browser.close() } }
        )
    }

    /// Clearing the binding also clears the slug, so the same node can be
    /// opened again after being dismissed.
    private var routedNode: Binding<SidebarNodeSummary?> {
        Binding(
            get: { resolvedNode },
            set: { newValue in
                resolvedNode = newValue
                if newValue == nil { app.routedNodeSlug = nil }
            }
        )
    }
}

#Preview {
    ContentView()
}
