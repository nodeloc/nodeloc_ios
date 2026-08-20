//
//  ContentView.swift
//  nodeloc
//
//  Root flow: Auth → Onboarding → Main app.
//

import SwiftUI

struct ContentView: View {
    @State private var app = AppState()

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
        .environment(app)
        .task {
            // Restore a previously signed-in session.
            if DiscourseLogin.shared.restore() {
                app.authed = true
                app.onboardingDone = true
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.authed)
        .animation(.easeInOut(duration: 0.25), value: app.isGuest)
        .animation(.easeInOut(duration: 0.25), value: app.onboardingDone)
    }
}

#Preview {
    ContentView()
}
