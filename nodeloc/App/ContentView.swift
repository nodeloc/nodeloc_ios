//
//  ContentView.swift
//  nodeloc
//
//  Root flow: Auth → Onboarding → Main app.
//

import SwiftUI

struct ContentView: View {
    @State private var app = AppState()
    @State private var browser = BrowserState.shared
    /// Drives the app-wide colour scheme; read here so a change redraws
    /// everything below.
    private var preferences = UserPreferencesStore.shared
    /// Resolved from `app.routedNodeSlug`; a link only carries the slug.
    @State private var resolvedNode: SidebarNodeSummary?

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
        // Theme's colours are already light/dark pairs, so overriding the
        // scheme here is all "深色/浅色" needs. `.auto` passes nil and follows
        // the system.
        .preferredColorScheme(preferences.colorMode.colorScheme)
        // One handler for the whole app: inline links in post bodies are
        // AttributedString link runs that SwiftUI opens itself, so there is no
        // per-link callback — intercepting here is what catches them all.
        .routesLinksInApp(app: app, browser: browser)
        .fullScreenCover(isPresented: browserPresented) {
            if let url = browser.url {
                BrowserView(url: url) { browser.close() }
            }
        }
        // Native destinations for internal links, presented here so they work
        // from any screen — a mention inside a post, the sidebar, anywhere.
        .fullScreenCover(item: $app.routedProfile) { target in
            PublicProfileOverlay(target: target) { app.routedProfile = nil }
                .environment(app)
        }
        .fullScreenCover(item: routedNode) { node in
            NodeDetailOverlay(node: node) { app.routedNodeSlug = nil }
                .environment(app)
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
