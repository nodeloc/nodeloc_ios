//
//  NativeAppleSignInButton.swift
//  nodeloc
//
//  The Apple row in the provider list.
//
//  A custom Sign in with Apple button, not `SignInWithAppleButton`. Apple's
//  guidelines provide for this, and the first reason they list for it is the
//  reason here: wanting to "align logos across multiple sign-in buttons". The
//  system control centres its logo with its title and sizes the logo to suit
//  itself, so in a column of rows whose marks sit on the leading edge it was
//  the one that didn't line up.
//
//  Building the button means also driving the request, which
//  `SignInWithAppleButton` would otherwise do — see `AppleSignIn.authorize()`.
//  The constraints Apple does impose live in `SocialAuthButtonStyle`.
//
//  Two things the system control gave us for free and this has to carry
//  itself: the title's translations (`SocialAuthProvider.title` — any new
//  language must use Apple's own wording for "Continue with Apple") and the
//  VoiceOver label, which the title text supplies.
//
//  Falls back to the existing `/auth/apple` web flow when the native exchange
//  endpoint isn't deployed, so this ships safely ahead of the server work. See
//  `SERVER_TASKS_APPLE_SIGNIN.md`.
//

import SwiftUI

struct NativeAppleSignInButton: View {
    /// Does something with the credential — sign in, or link it to the account
    /// already signed in. Returns false when the endpoint isn't deployed, which
    /// is the signal to fall back to the web.
    ///
    /// Injected rather than branched on a mode flag: signing in has to clear
    /// the session first and linking must not, so the two are genuinely
    /// different operations that happen to share this control.
    let perform: (AppleSignInCredential) async -> Bool
    /// The native path isn't available; open the web flow instead.
    let onFallbackToWeb: () -> Void

    /// Height of the neighbouring rows, so a column still reads as one list.
    var height: CGFloat = SocialAuthButtonStyle.height

    @State private var isWorking = false

    var body: some View {
        // The same row as every other provider, by construction rather than by
        // resemblance.
        SocialProviderButton(
            provider: SocialAuthProvider(name: "apple"),
            height: height,
            action: start
        )
        .disabled(isWorking)
        .opacity(isWorking ? 0.6 : 1)
    }

    private func start() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                // Nil is a cancellation: leave the screen as it was.
                guard let credential = try await AppleSignIn.authorize() else { return }
                if await perform(credential) == false { onFallbackToWeb() }
            } catch {
                // Apple's side failing — most likely the capability missing
                // from the App ID — so the web flow is a better answer than an
                // error message.
                onFallbackToWeb()
            }
        }
    }
}
