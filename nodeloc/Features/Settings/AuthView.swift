//
//  AuthView.swift
//  nodeloc
//

import SwiftUI

private enum AuthStage {
    case welcome
    case methods
    case credentials
    case activation(String)
}

struct AuthView: View {
    @Environment(AppState.self) private var app

    @State private var stage: AuthStage = .welcome
    @State private var loginIdentifier = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    /// The server asked for a 2FA code; the login form shows the OTP field.
    @State private var needsSecondFactor = false
    @State private var otpCode = ""
    @State private var usingBackupCode = false
    @FocusState private var otpFocused: Bool
    /// Set to a view id to scroll it into view on the next layout pass.
    @State private var scrollTarget: String?
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var isResendingActivation = false
    @State private var didResendActivation = false
    /// The site's required custom profile fields, from `site.json`.
    @State private var userFields = SignupUserFieldsModel()
    @State private var noticeText: String?
    /// Social sign-in options from site.json, and the one being run.
    @State private var socialProviders: [SocialAuthProvider] = []
    @State private var activeProvider: SocialAuthProvider?

    /// Apple is drawn by its own native control, so it is taken out of the
    /// provider list rather than rendered as one of them.
    private var appleProvider: SocialAuthProvider? {
        socialProviders.first { $0.name == "apple" }
    }

    /// Everything else the site advertises. Only used to decide whether to
    /// offer the browser route at all, and to pick a fallback for it — the
    /// flow itself isn't per-provider.
    private var webProviders: [SocialAuthProvider] {
        socialProviders.filter { $0.name != "apple" }
    }

    var body: some View {
        @Bindable var app = app

        ZStack {
            switch stage {
            case .welcome, .methods:
                welcomeScreen
            case .credentials:
                credentialsScreen
            case .activation(let message):
                activationScreen(message)
            }

            if case .methods = stage {
                methodSheet
                    // Slide only. Cross-fading an opaque panel forces it into
                    // an offscreen pass for the length of the animation, and
                    // buys nothing once it is sliding.
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .animation(.spring(duration: 0.28), value: stageKey)
        .onChange(of: app.authMode) { _, _ in
            resetMessages()
        }
        .task { await loadSocialProviders() }
        .task { await userFields.load() }
        .sheet(item: $activeProvider) { provider in
            SocialLoginView(
                provider: provider,
                onAuthenticated: { cookies in
                    activeProvider = nil
                    finishProviderLogin(cookies: cookies)
                },
                onCancel: { activeProvider = nil }
            )
        }
    }

    private var stageKey: Int {
        switch stage {
        case .welcome: 0
        case .methods: 1
        case .credentials: 2
        case .activation: 3
        }
    }

    // MARK: - Welcome

    /// The illustration is the only thing on this screen that can give up
    /// room, so on a short screen a smaller one is chosen rather than pushing
    /// the buttons off the bottom.
    ///
    /// At the full 390 this screen wants ~729pt and an iPhone SE offers 647,
    /// which put "Browse as guest" and half of the second pill below the
    /// glass. It took the method sheet's Cancel with it too: the `ZStack` in
    /// `body` adopts its tallest child's height, and the sheet is aligned to
    /// the bottom of that.
    ///
    /// `ViewThatFits` rather than a computed reserve: it measures the real
    /// layout, so this keeps working if the buttons or the motto change, which
    /// a hand-tuned constant would not.
    private var welcomeScreen: some View {
        ViewThatFits(in: .vertical) {
            welcomeContent(heroHeight: 390)
            welcomeContent(heroHeight: 340)
            welcomeContent(heroHeight: 300)
            welcomeContent(heroHeight: 240)
        }
    }

    private func welcomeContent(heroHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 18) {
                AuthWordmark()

                Text("自由、平等、友好、开放、有趣")
                    .font(Theme.heading(19, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    // The motto must read in full — "…开放、…" says nothing.
                    // Shrinks to fit rather than truncating.
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 34)

            AuthHeroScene()
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .padding(.top, 18)

            Spacer(minLength: 14)

            VStack(spacing: 14) {
                Button {
                    app.authMode = .signup
                    stage = .methods
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthPrimaryPillStyle())

                Button {
                    app.authMode = .login
                    stage = .methods
                } label: {
                    Text("I already have an account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthOutlinePillStyle())

                Button("Browse as guest") { app.isGuest = true }
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Method sheet

    private var methodSheet: some View {
        ZStack(alignment: .bottom) {
            // No dim. Fading a full-screen black layer in and out on every
            // open is a whole-screen composite on each frame of the slide,
            // and it read as a stutter. The panel's own shadow separates it
            // from the screen behind instead — see the background below,
            // which matters here because both are `Theme.bg`.
            //
            // This layer stays only to catch a tap outside the panel.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { stage = .welcome }

            VStack(spacing: 18) {
                Text(app.authMode == .login ? "Log in" : "Sign up")
                    .font(Theme.heading(28, weight: .semibold))
                    .padding(.top, 26)

                VStack(spacing: 10) {
                    // Apple stays its own button: it is native, needs no
                    // browser at all, and is the privacy-preserving option
                    // guideline 4.8 asks for alongside third-party sign-in.
                    if let apple = appleProvider {
                        NativeAppleSignInButton(
                            perform: { await signInWithApple($0) },
                            onFallbackToWeb: { activeProvider = apple },
                            height: SocialAuthButtonStyle.height
                        )
                        .disabled(isBusy)
                    }

                    // Email is the only route that is wholly in-app, and the
                    // only one where "sign up" really means signing up — the
                    // browser flow below always lands on Discourse's *login*
                    // page. So it sits above it.
                    Button {
                        stage = .credentials
                    } label: {
                        AuthButtonLabel(
                            title: app.authMode == .login
                                ? AppString("Use email or username")
                                : AppString("Use email")
                        ) {
                            AuthButtonSymbol(name: "person.crop.circle")
                        }
                    }
                    .buttonStyle(SocialAuthButtonStyle(filled: false))
                    .disabled(isBusy)

                    // One button for every other provider the site offers,
                    // rather than one each.
                    //
                    // They would all do the same thing: the flow opens
                    // Discourse's own login page, and *that* page carries the
                    // Google/GitHub/X buttons. Five identical buttons claiming
                    // to be five different things is worse than one honest one.
                    //
                    // Worded neutrally on purpose. `redirect_anonymous_to_login`
                    // always sends an anonymous visitor to `/login`, never
                    // `/signup`, so a button promising "sign up" would open a
                    // login form. On Discourse a provider button registers you
                    // anyway if you have no account, so "continue" is true in
                    // both modes.
                    if let fallback = webProviders.first {
                        Button {
                            signInWithSystemBrowser(fallingBackTo: fallback)
                        } label: {
                            AuthButtonLabel(title: AppString("使用其他方式继续")) {
                                AuthButtonSymbol(name: "globe")
                            }
                        }
                        .buttonStyle(SocialAuthButtonStyle(filled: false))
                        .disabled(isBusy)
                    }
                }

                termsText
                    .padding(.top, 2)

                Button("Cancel") { stage = .welcome }
                    .font(Theme.heading(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            // Only the fill reaches past the safe area, not the whole panel:
            // rounding and extending the entire layer would drag the content
            // down with it, so the bottom inset then had to be added back onto
            // Cancel by hand. Extending just the background keeps the content
            // laid out inside the safe area — where it belongs — while the
            // white runs to the physical bottom edge, with no dimmed strip
            // showing beneath it.
            .background(alignment: .top) {
                Theme.bg
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 26,
                            topTrailingRadius: 26,
                            style: .continuous
                        )
                    )
                    // Carries the whole separation from the screen behind now
                    // that nothing is dimmed. Upward only: a sheet is lit from
                    // above, and there is nothing below it to cast onto.
                    .shadow(color: .black.opacity(0.14), radius: 16, y: -3)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }


    // MARK: - Credentials

    private static let otpFieldID = "otp-field"

    private var credentialsScreen: some View {
        VStack(spacing: 0) {
            credentialsHeader

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    AuthWordmark(height: 34)
                        .padding(.bottom, 28)

                    Text(app.authMode == .login ? "Log in to NODELOC" : "Create your account")
                        .font(Theme.heading(30, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.bottom, 42)

                    VStack(spacing: 18) {
                        if app.authMode == .signup {
                            AuthInputField("Username", text: $username)
                            AuthInputField("Name", text: $displayName)
                            AuthInputField("Email", text: $email, keyboard: .emailAddress)
                        } else {
                            AuthInputField("Email or username", text: $loginIdentifier, keyboard: .emailAddress)
                        }

                        AuthInputField("Password", text: $password, secure: true)

                        // Whatever this site requires at registration. Absent
                        // from the form until now, which is why signing up from
                        // the cold-start screen failed once a required "Gender"
                        // field was added — see `SignupUserFieldsModel`.
                        if app.authMode == .signup {
                            SignupUserFieldsSection(model: userFields)
                        }

                        if app.authMode == .login, needsSecondFactor {
                            AuthInputField(
                                usingBackupCode ? AppString("备用码") : AppString("两步验证码"),
                                text: $otpCode,
                                focus: $otpFocused
                            )
                            .id(Self.otpFieldID)
                            HStack {
                                Text("此账号已开启两步验证")
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.muted(0.6))
                                Spacer(minLength: 8)
                                Button(usingBackupCode ? AppString("使用验证器") : AppString("使用备用码")) {
                                    usingBackupCode.toggle()
                                    otpCode = ""
                                }
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            }
                        }
                    }

                    if app.authMode == .login {
                        // Resetting the password works: it happens on the web
                        // and the new password is then used here.
                        //
                        // "Email me a login link" used to sit below this and
                        // was removed, because it couldn't work. It only
                        // opened `/login`, and the link Discourse mails back
                        // establishes a *browser* session — the app adopts
                        // cookies from one place only, the provider web view
                        // in `SocialLoginView`. Worse, if the link did open the
                        // app, `ContentView` routes deep links only once
                        // `authed || isGuest`, which is false for precisely the
                        // person following a login link.
                        authSmallPill("Forgot password?") {
                            openWebsite(path: "password-reset")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 26)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 18)
                    }

                    if let noticeText {
                        Text(noticeText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 18)
                    }

                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // The 2FA field appears below the fold; without this it stays
            // hidden behind the keyboard.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
            }

            Button {
                submit()
            } label: {
                if isBusy {
                    ProgressView()
                        .tint(Theme.neutral600)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(app.authMode == .login ? "Continue" : "Create account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(AuthPrimaryPillStyle(disabled: !canSubmit))
            .disabled(isBusy || !canSubmit)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var credentialsHeader: some View {
        HStack {
            Button {
                resetMessages()
                stage = .methods
            } label: {
                Image(systemName: app.authMode == .login ? "xmark" : "chevron.left")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Theme.text.opacity(0.76))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.pressable)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private func authSmallPill(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.text.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Activation

    /// Falls back to our own sentence when the server sent nothing, or when
    /// its message was nothing but markup.
    private func activationText(_ message: String) -> String {
        let text = DiscourseFormat.plainTextParagraphs(message)
        guard !text.isEmpty else {
            return AppString("Check your inbox and follow the confirmation link to activate your account.")
        }
        return text
    }

    private func activationScreen(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    stage = .credentials
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.pressable)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer(minLength: 34)

            AuthWordmark(height: 34)
                .padding(.bottom, 34)

            Text("Verify your email")
                .font(Theme.heading(30, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

            // The server's wording, not ours — but it arrives as HTML
            // (`<p>…<b>email</b>…`), and rendering it raw put the tags on
            // screen. Paragraph-aware, because Discourse sends this as two
            // paragraphs and the second one is the "check your spam folder"
            // advice.
            Text(activationText(message))
                .font(Theme.body(20))
                .foregroundStyle(Theme.text.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 38)

            // The message itself says "if it doesn't arrive, check your spam
            // folder" — and if it still hasn't, this is the only way forward
            // short of signing up again. Discourse won't let the account log
            // in until it's activated, so there is nowhere else to ask from.
            Button {
                resendActivation()
            } label: {
                if isResendingActivation {
                    ProgressView().tint(Theme.accent)
                } else {
                    Text("Resend activation email")
                }
            }
            .font(Theme.body(16, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .disabled(isResendingActivation || didResendActivation)
            .padding(.top, 22)

            if didResendActivation {
                Text("Sent again. If it still doesn't arrive, the address may be unreachable — try signing up with another one.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.muted(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 38)
                    .padding(.top, 10)
            }

            Spacer()

            Button("Back to login") {
                app.authMode = .login
                stage = .credentials
            }
            .buttonStyle(AuthPrimaryPillStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    /// Asks the server to send the activation mail again.
    ///
    /// Reports success even on failure of the *reason* kind: Discourse answers
    /// 200 with no body here, and a network error is worth showing, but "we
    /// already sent one recently" is not something to alarm anyone with.
    /// Signs in through the *system* browser, so a provider session already on
    /// this device (a Google login in Safari, say) is offered as an account to
    /// pick rather than a form to fill in. See `UserAPIKeyAuth`.
    ///
    /// Every provider button lands here: Discourse's own login page is what the
    /// session opens on, and that page carries all of them. One extra tap than
    /// the old in-app web view, in exchange for not retyping a password —
    /// and the old view is still the fallback if this can't complete.
    private func signInWithSystemBrowser(fallingBackTo provider: SocialAuthProvider) {
        guard !isBusy else { return }
        isBusy = true
        resetMessages()
        Task {
            defer { isBusy = false }
            do {
                try await DiscourseLogin.shared.loginWithUserAPIKey()
                completeAuth()
            } catch UserAPIKeyAuthError.cancelled {
                // Backing out of the sheet is a choice, not a failure.
            } catch {
                // Most likely the site hasn't whitelisted our callback. The
                // in-app web view still works, so offer that rather than a
                // dead end.
                activeProvider = provider
            }
        }
    }

    private func resendActivation() {
        guard !isResendingActivation else { return }
        isResendingActivation = true
        Task {
            defer { isResendingActivation = false }
            do {
                try await DiscourseClient().resendActivationEmail(username: username)
                didResendActivation = true
            } catch {
                errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Shared

    private var termsText: some View {
        Text(AuthLegalCopy.attributed)
            .font(Theme.body(13))
            .foregroundStyle(Theme.text.opacity(0.82))
            .multilineTextAlignment(.leading)
            .tint(Theme.accent)
    }

    private var canSubmit: Bool {
        switch app.authMode {
        case .login:
            return !loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsSecondFactor || !otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .signup:
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Better to keep the button disabled than to let the server reject
            // the whole registration for a missing field.
            && userFields.isComplete
        }
    }

    private func submit() {
        guard !isBusy else { return }
        isBusy = true
        resetMessages()
        Task {
            do {
                switch app.authMode {
                case .login:
                    let token = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await DiscourseLogin.shared.login(
                        identifier: loginIdentifier,
                        password: password,
                        secondFactorToken: needsSecondFactor && !token.isEmpty ? token : nil,
                        secondFactorMethod: usingBackupCode ? 2 : 1
                    )
                    completeAuth()
                case .signup:
                    let result = try await DiscourseLogin.shared.signup(
                        username: username,
                        name: displayName,
                        email: email,
                        password: password,
                        userFields: userFields.values
                    )
                    switch result {
                    case .signedIn:
                        completeAuth()
                    case .needsActivation(let message):
                        stage = .activation(message)
                    }
                }
            } catch AuthError.secondFactorRequired {
                needsSecondFactor = true
                otpFocused = true
                scrollTarget = Self.otpFieldID
            } catch AuthError.signupNeedsActivation(let message) {
                stage = .activation(message)
            } catch AuthError.cancelled {
                // user dismissed the browser
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    /// The site's enabled providers; `site.json` is cached, so usually free.
    private func loadSocialProviders() async {
        guard socialProviders.isEmpty else { return }
        let providers = await SiteResources.shared.siteResponse()?.authProviders ?? []
        socialProviders = providers.map { SocialAuthProvider(name: $0.name) }
    }

    /// Native Apple sign-in. Returns false when the endpoint isn't deployed so
    /// the button can fall back to the web flow.
    private func signInWithApple(_ credential: AppleSignInCredential) async -> Bool {
        resetMessages()
        do {
            try await DiscourseLogin.shared.completeNativeAppleLogin(credential)
            completeAuth()
            return true
        } catch let error as DiscourseError {
            if case .badResponse(let code, let message) = error {
                if code == 404 || code == 501 { return false }
                // 403 is the endpoint saying it can't finish natively. The
                // native button has replaced the web Apple row, so leaving the
                // reader here would be a dead end — escalate to the web flow,
                // which carries Discourse's own TOTP prompt.
                //
                // The message is shown on the way out rather than swallowed: a
                // 403 for some *other* reason (a suspended account) would
                // otherwise bounce the reader into a web view with no
                // explanation.
                if code == 403 {
                    if let message, !message.isEmpty { ToastCenter.shared.show(message) }
                    return false
                }
                // Recognised, but not yet bound to an account. Signing in would
                // mean guessing which account, and a wrong guess is a duplicate.
                if code == 409 {
                    errorText = AppString("这个 Apple ID 还没有绑定账号。请先用原有方式登录，再到「设置 → 关联账户」里绑定。")
                    stage = .methods
                    return true
                }
            }
            errorText = error.errorDescription
            stage = .methods
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .methods
            return true
        }
    }

    private func finishProviderLogin(cookies: [HTTPCookie]) {
        guard !isBusy else { return }
        isBusy = true
        resetMessages()
        Task {
            do {
                try await DiscourseLogin.shared.completeProviderLogin(cookies: cookies)
                completeAuth()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stage = .methods
            }
            isBusy = false
        }
    }

    private func openWebsite(path: String) {
        guard let url = URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL else { return }
        UIApplication.shared.open(url)
    }

    private func resetMessages() {
        errorText = nil
        noticeText = nil
    }

    private func completeAuth() {
        app.authed = true
        app.isGuest = false
        app.onboardingDone = true
    }
}

// MARK: - Auth UI pieces

/// The 服务条款 / 隐私政策 sentence, with both documents as real tappable links.
///
/// Guideline 1.2 expects the terms a signup agrees to be readable *before*
/// signing up, and the sidebar that carries them is behind the auth gate. The
/// links are markdown, so `ContentView`'s root `openURL` handler routes them
/// through `LinkRouter` into the in-app browser like any other link — `/tos`
/// splits to the segment "tos", so it isn't mistaken for a `/t/` topic.
///
/// The URLs are interpolated rather than written into the catalog: a
/// translator should be handed the sentence, not a link target to copy
/// correctly. Returns an `AttributedString` instead of a `Text` so each auth
/// screen keeps its own font and alignment.
///
/// Shared by both auth flows, which is why it isn't private.
enum AuthLegalCopy {
    /// English-source wording, for the cold-start `AuthView`.
    static var attributed: AttributedString {
        parse(AppString(
            "By continuing, you agree to our [Terms](\(tosURL)) and acknowledge that you understand the [Privacy Policy](\(privacyURL))."
        ))
    }

    /// The shorter Chinese-source wording the in-place `AuthSheet` uses.
    static var attributedCompact: AttributedString {
        parse(AppString(
            "继续操作即表示您同意我们的[用户协议](\(tosURL))并确认已了解[隐私政策](\(privacyURL))。"
        ))
    }

    private static var tosURL: String {
        DiscourseConfig.baseURL.appending(path: "tos").absoluteString
    }

    private static var privacyURL: String {
        DiscourseConfig.baseURL.appending(path: "privacy").absoluteString
    }

    /// Falls back to the plain sentence rather than losing the notice entirely
    /// if a translation ever arrives with broken markdown.
    private static func parse(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

/// The real brand wordmark, rather than a mark-plus-text imitation. Shared
/// by both auth flows, which is why it isn't private.
struct AuthWordmark: View {
    var height: CGFloat = 42

    var body: some View {
        Image("NodelocWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("NodeLoc")
    }
}

private struct AuthHeroScene: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Theme.accent100.opacity(0.55),
                        Color(hex: 0xEAF7FF),
                        Color(hex: 0xCDEB9F),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(hex: 0xB6D87B))
                    .frame(width: geo.size.width * 1.18, height: 120)
                    .offset(y: 76)

                HStack(alignment: .bottom, spacing: 12) {
                    AuthHeroCharacter(color: Color(hex: 0x7B5A48), shirt: Color(hex: 0x23B7B7), eye: Color(hex: 0xF762B7))
                        .frame(width: geo.size.width * 0.34, height: 170)
                        .offset(y: 12)
                    AuthHeroCharacter(color: Color(hex: 0x6A4238), shirt: Color(hex: 0xF48165), eye: Color(hex: 0xFF6434))
                        .frame(width: geo.size.width * 0.34, height: 185)
                    AuthHeroCharacter(color: Color(hex: 0xFFFFFF), shirt: Color(hex: 0x37B1E5), eye: Color(hex: 0x25D9C3))
                        .frame(width: geo.size.width * 0.28, height: 160)
                        .offset(y: 22)
                }
                .padding(.bottom, 34)
            }
            .clipShape(Rectangle())
        }
    }
}

private struct AuthHeroCharacter: View {
    let color: Color
    let shirt: Color
    let eye: Color

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Capsule()
                    .fill(shirt)
                    .frame(width: size * 0.7, height: size * 0.54)
                    .offset(y: size * 0.34)
                Circle()
                    .fill(color)
                    .frame(width: size * 0.72, height: size * 0.72)
                Circle()
                    .fill(eye)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: -size * 0.14, y: -size * 0.04)
                Circle()
                    .fill(eye)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: size * 0.14, y: -size * 0.04)
                Circle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .offset(y: size * 0.14)
                Capsule()
                    .stroke(color, lineWidth: 7)
                    .frame(width: size * 0.18, height: size * 0.38)
                    .offset(x: -size * 0.2, y: -size * 0.43)
                Circle()
                    .fill(Color(hex: 0xF8E6C3))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .offset(x: -size * 0.26, y: -size * 0.56)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The auth form's field shape.
///
/// Shared, so a control that isn't an `AuthInputField` — the signup form's
/// dropdowns and checkboxes, which come from the site's own configuration —
/// can sit in the same column without the two slowly drifting apart.
struct AuthFieldCapsule: ViewModifier {
    /// Outlined once there's an answer, the same way the text fields are.
    var isFilled: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(height: 64)
            .background(Theme.neutral300.opacity(0.8), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isFilled ? Theme.text : Color.clear, lineWidth: isFilled ? 1.2 : 0)
            }
    }
}

struct AuthInputField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    /// Passed through because it is load-bearing, not decoration:
    /// `.newPassword` is what triggers the system's strong-password suggestion
    /// and the keychain save prompt, and `.oneTimeCode` is what lets a texted
    /// code autofill. A field without it looks identical and quietly loses
    /// both.
    var contentType: UITextContentType?
    var submitLabel: SubmitLabel = .return
    var onSubmit: (() -> Void)?
    /// Optional, so callers that never move focus don't have to own a
    /// `FocusState` just to use the field.
    var focus: FocusState<Bool>.Binding?

    /// The field's own focus, so tapping the capsule can put the caret in it
    /// whether or not the caller supplied a binding — only one of the six call
    /// sites does.
    @FocusState private var isFocused: Bool
    /// Password revealed. Off every time the field appears; never remembered.
    @State private var isRevealed = false

    init(
        _ placeholder: String,
        text: Binding<String>,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil,
        submitLabel: SubmitLabel = .return,
        onSubmit: (() -> Void)? = nil,
        focus: FocusState<Bool>.Binding? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.keyboard = keyboard
        self.contentType = contentType
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.focus = focus
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if secure, !isRevealed {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(Theme.body(18))
            .textFieldStyle(.plain)
            .tint(Color(hex: 0x3366FF))
            .keyboardType(keyboard)
            .textContentType(contentType)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
            .modifier(OptionalFocus(focus: focus))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                .buttonStyle(.pressable)
            }

            // Typing a password blind is where people give up. Trailing edge,
            // which is where iOS puts its own reveal control.
            if secure {
                Button {
                    isRevealed.toggle()
                    // Swapping `SecureField` for `TextField` is a different
                    // view, so it loses first responder and the keyboard drops
                    // mid-entry. Put focus back on the next turn, once the
                    // replacement exists.
                    Task { @MainActor in
                        isFocused = true
                        focus?.wrappedValue = true
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.75))
                        // A fixed box, so the capsule's contents don't shift
                        // sideways when the glyph swaps.
                        .frame(width: 24)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isRevealed ? AppString("隐藏密码") : AppString("显示密码"))
            }
        }
        .modifier(AuthFieldCapsule(isFilled: !text.isEmpty))
        // The whole capsule takes the tap, not just the glyphs inside it. A
        // text field's live area is the text it draws, so on an empty 64pt
        // capsule that was a thin strip beside the placeholder — the same
        // reason the auth buttons needed `.contentShape`.
        //
        // `.contentShape` alone wouldn't do it: it would make the capsule
        // hit-testable without giving the tap anywhere to go, so the gesture
        // is what actually moves the caret.
        .contentShape(Capsule())
        .onTapGesture {
            isFocused = true
            focus?.wrappedValue = true
        }
    }
}

struct AuthPrimaryPillStyle: ButtonStyle {
    var disabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(17, weight: .semibold))
            .foregroundStyle(disabled ? Theme.neutral500 : Theme.bg)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(disabled ? Theme.neutral300 : Theme.text, in: Capsule())
            .opacity(configuration.isPressed && !disabled ? 0.82 : 1)
            .contentShape(Capsule())
    }
}

private struct AuthOutlinePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.heading(17, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 15)
            .padding(.horizontal, 20)
            .background(Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.text.opacity(0.46), lineWidth: 1.2))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Capsule())
    }
}

/// Applies `.focused` only when the caller supplied a binding.
private struct OptionalFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus)
        } else {
            content
        }
    }
}
