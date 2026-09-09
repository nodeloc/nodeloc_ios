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
        modifier(AppPresentationHostModifier(app: app))
    }
}

private struct AppPresentationHostModifier: ViewModifier {
    let app: AppState

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
            .environment(\.openPostReference, OpenPostReferenceAction { reference = $0 })
            // Inline links in post bodies are attributed-string link runs that
            // SwiftUI opens itself, so there is no per-link callback —
            // intercepting the environment action is what catches them all.
            .routesLinksInApp(
                app: app,
                browser: browser,
                openReference: { reference = $0 }
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
    }
}
