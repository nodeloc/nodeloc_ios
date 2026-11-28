//
//  AuthSheet.swift
//  nodeloc
//
//  In-place auth: a guest tapping 登录 gets this overlay over whatever they
//  were reading, instead of being thrown back to the app's entry screen
//  (AuthView, which remains the cold-start flow).
//
//  Native chrome throughout: a NavigationStack pushes the signup steps
//  (邮箱 → 用户名 → 密码 → 性别 → 兴趣节点), system text fields with proper
//  content types (so passwords get the keychain/Face ID save prompt), and
//  bordered-prominent continue buttons. One Discourse difference from the
//  Reddit flow this mirrors: email verification is an activation *link* in
//  the mail, not a 6-digit code, so signup ends on a check-your-inbox note.
//

import SwiftUI

private enum SignupStep: Hashable {
    /// App-iOS-Register: the single sign-up page.
    case register
    /// 忘记密码: ask for the reset mail.
    case forgot
    case email
    case username
    case password
    case gender
    case interests
    case activation
}

struct AuthFlowOverlay: View {
    /// How to get off screen. Defaults to clearing the app-level overlay,
    /// which is how MainView presents this; screens that present it locally
    /// (the node page, which itself can live inside a full-screen cover)
    /// pass their own dismissal instead.
    var onDismiss: (() -> Void)?

    @Environment(AppState.self) private var app

    @State private var path: [SignupStep] = []

    // Login
    @State private var loginIdentifier = ""
    @State private var loginPassword = ""
    /// The server asked for a 2FA code; the login page shows the OTP field.
    @State private var needsSecondFactor = false
    @State private var otpCode = ""
    /// TOTP by default; toggled to a backup code (method 2) when the
    /// authenticator isn't at hand.
    @State private var usingBackupCode = false
    @FocusState private var otpFocused: Bool
    /// Set to a view id to scroll it into view on the next layout pass.
    @State private var scrollTarget: String?

    // Signup
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var usernameAvailable: Bool?
    @State private var usernameSuggestion: String?
    @State private var usernameCheck: Task<Void, Never>?
    /// The admin's required profile fields, loaded from `site.json`. Replaces
    /// a hardcoded gender step whose values were stored only on the device and
    /// never reached Discourse — which is why signups started failing when a
    /// required "Gender" dropdown was added to the site.
    @State private var userFields = SignupUserFieldsModel()
    /// Every node (subcategory) available, shuffled once — the 换一批 pool.
    @State private var nodePool: [InterestNode] = []
    /// The handful currently on offer.
    @State private var nodeBatch: [InterestNode] = []
    /// Picks, in the order they were made. Capped at `maxInterestNodes`.
    @State private var selectedNodes: [InterestNode] = []
    /// Server message shown on the activation step.
    @State private var activationMessage = ""

    @State private var isBusy = false
    /// The server-driven 人机验证 widget, when a submit needs a token.
    @State private var captchaGate = CaptchaGate()
    @State private var errorText: String?
    /// Login said the account is suspended: the message, and the
    /// credentials the account status page reads with.
    @State private var suspendedMessage: String?
    @State private var suspendedCredentials: AccountStatusStore.Credentials?
    /// Social sign-in options from site.json, and the one being run.
    @State private var socialProviders: [SocialAuthProvider] = []
    @State private var activeProvider: SocialAuthProvider?

    /// Apple is drawn by its own native control rather than as one of the
    /// provider rows.
    private var appleProvider: SocialAuthProvider? {
        // Native only where the server can take Apple's identity token;
        // otherwise Apple is one of the browser's options.
        NodelocAuthCapabilities.appleNative ? socialProviders.first(where: { $0.name == "apple" }) : nil
    }

    /// Everything else the site advertises — used only to decide whether the
    /// browser route is worth offering, and to pick its fallback.
    private var webProviders: [SocialAuthProvider] {
        socialProviders.filter { $0.name != "apple" || !NodelocAuthCapabilities.appleNative }
    }

    private let client = DiscourseClient()

    private struct InterestNode: Identifiable {
        let id: Int
        let name: String
        let slug: String
    }

    var body: some View {
        NavigationStack(path: $path) {
            loginPage
                .navigationDestination(for: SignupStep.self) { step in
                    signupPage(step)
                }
        }
        .tint(Theme.accent)
        .captchaGate(captchaGate)
        // 注册 from anywhere opens straight on the sign-up page.
        .onAppear { if app.authMode == .signup, path.isEmpty { path = [.register] } }
        .task { await userFields.load() }
        .fullScreenCover(item: Binding(
            get: { suspendedCredentials.map { SuspendedCredentialsBox(credentials: $0) } },
            set: { if $0 == nil { suspendedCredentials = nil } }
        )) { box in
            // Its own stack here (it's a cover, not a pushed page): the
            // system bar with a close button.
            NavigationStack {
                AccountStatusPage(credentials: box.credentials) { suspendedCredentials = nil }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { suspendedCredentials = nil } label: { Image(systemName: "xmark") }
                                .accessibilityLabel(AppString("关闭"))
                        }
                    }
            }
        }
    }

    // MARK: - Login (root)

    private var loginPage: some View {
        page {
            VStack(alignment: .leading, spacing: 0) {
                // App-iOS-Login: the title to the left, the way to 注册 under
                // it, labelled fields, and the other methods after them.
                Text(AppString("登录 nodeloc"))
                    .font(Theme.heading(28, weight: .bold))
                    .padding(.bottom, 6)

                HStack(spacing: 4) {
                    Text(AppString("还没有账号？"))
                        .foregroundStyle(Theme.textMuted)
                    Button(AppString("免费注册")) {
                        errorText = nil
                        path = [.register]
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.accent)
                }
                .font(Theme.body(15))
                .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppString("用户名或邮箱"))
                        .font(Theme.body(14, weight: .bold))
                    AuthInputField(
                        AppString("比如 lin_ops 或 you@example.com"),
                        text: $loginIdentifier,
                        keyboard: .emailAddress,
                        contentType: .username,
                        submitLabel: .next
                    )
                    Text(AppString("密码"))
                        .font(Theme.body(14, weight: .bold))
                        .padding(.top, 8)
                    AuthInputField(
                        AppString("输入密码"),
                        text: $loginPassword,
                        secure: true,
                        contentType: .password,
                        submitLabel: .go,
                        onSubmit: { if canContinueLogin { submitLogin() } }
                    )

                    if needsSecondFactor {
                        AuthInputField(
                            usingBackupCode ? AppString("备用码") : AppString("两步验证码"),
                            text: $otpCode,
                            keyboard: usingBackupCode ? .asciiCapable : .numberPad,
                            contentType: .oneTimeCode,
                            onSubmit: { if canContinueLogin { submitLogin() } },
                            focus: $otpFocused
                        )
                        .id(Self.otpFieldID)

                        HStack {
                            Label("此账号已开启两步验证", systemImage: "lock.shield")
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 8)
                            Button(usingBackupCode ? AppString("使用验证器") : AppString("使用备用码")) {
                                usingBackupCode.toggle()
                                otpCode = ""
                            }
                            .font(Theme.body(12, weight: .semibold))
                        }
                    }
                }

                Button(AppString("忘记密码？")) {
                    errorText = nil
                    path.append(.forgot)
                }
                .font(Theme.body(14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 12)

                // In the page flow, not pinned above the keyboard.
                Button {
                    submitLogin()
                } label: {
                    continueLabel("登录")
                }
                .buttonStyle(AuthPrimaryPillStyle(disabled: !canContinueLogin))
                .disabled(isBusy || !canContinueLogin)
                .padding(.top, 14)

                // Nothing to separate if the site offers no providers at all.
                if appleProvider != nil || !webProviders.isEmpty {
                    HStack(spacing: 12) {
                        Rectangle().fill(Theme.divider).frame(height: 1)
                        Text(AppString("或者用这些方式"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize()
                        Rectangle().fill(Theme.divider).frame(height: 1)
                    }
                    .padding(.vertical, 18)

                    // Apple keeps its own native control; the rest of the
                    // site's providers sit behind one button, because the
                    // browser flow lands on the site's own sign-in page.
                    VStack(spacing: 10) {
                        if let apple = appleProvider {
                            NativeAppleSignInButton(
                                perform: { await signInWithApple($0) },
                                onFallbackToWeb: { activeProvider = apple },
                                height: SocialAuthButtonStyle.height
                            )
                            .disabled(isBusy)
                        }

                        // Each provider straight to its own sign-in, the same
                        // row as the sign-up page; the passkey beside them.
                        SocialIconRow(
                            providers: webProviders,
                            onProvider: { provider in signInWithSystemBrowser(fallingBackTo: provider, provider: provider.name) },
                            onPasskey: { signInWithPasskey() }
                        )
                        .disabled(isBusy)
                        .padding(.top, 4)
                    }
                }

                Text(AuthLegalCopy.attributedCompact)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .tint(Theme.accent)
                    .padding(.top, 18)

                inlineError
            }
        } continueButton: {
            // 登录 sits in the page, under 忘记密码 (above).
            EmptyView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSocialProviders() }
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

    /// The site's enabled providers. `site.json` is already cached by
    /// `SiteResources`, so this is normally free.
    private func loadSocialProviders() async {
        guard socialProviders.isEmpty else { return }
        let providers = await SiteResources.shared.siteResponse()?.authProviders ?? []
        socialProviders = providers.map { SocialAuthProvider(name: $0.name) }
    }

    /// Native Apple sign-in. Returns false when the endpoint isn't deployed so
    /// the button can fall back to the web flow.
    private func signInWithApple(_ credential: AppleSignInCredential) async -> Bool {
        errorText = nil
        do {
            try await DiscourseLogin.shared.completeNativeAppleLogin(credential)
            await applyPendingNodeJoins()
            completeAuth()
            return true
        } catch let error as DiscourseError {
            if case .badResponse(let code, let message, _) = error {
                // Not deployed — let the caller use the web flow.
                if code == 404 || code == 501 { return false }
                // 403 means it can't finish natively; escalate to the web flow,
                // which carries Discourse's own TOTP prompt. The message goes
                // out first so a 403 for an unrelated reason isn't a silent
                // jump into a web view.
                if code == 403 {
                    if let message, !message.isEmpty { ToastCenter.shared.show(message) }
                    return false
                }
                // The server recognised the Apple id but wants the account
                // linked deliberately: signing in would otherwise have to
                // guess, and guessing wrong means a duplicate account.
                if code == 409 {
                    errorText = AppString("这个 Apple ID 还没有绑定账号。请先用原有方式登录，再到「设置 → 关联账户」里绑定。")
                    return true
                }
            }
            errorText = error.errorDescription
            return true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return true
        }
    }

    private func finishProviderLogin(cookies: [HTTPCookie]) {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            do {
                try await DiscourseLogin.shared.completeProviderLogin(cookies: cookies)
                await applyPendingNodeJoins()
                completeAuth()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    private var canContinueLogin: Bool {
        guard !loginIdentifier.trimmingCharacters(in: .whitespaces).isEmpty,
              !loginPassword.isEmpty else { return false }
        return !needsSecondFactor || !otpCode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Signup steps

    @ViewBuilder
    private func signupPage(_ step: SignupStep) -> some View {
        switch step {
        case .register:
            RegisterPage(
                onLogin: { path = [] },
                onSignedIn: { completeAuth() },
                onPending: { message in
                    activationMessage = message
                    path.append(.activation)
                },
                providers: webProviders,
                onProvider: { provider in signInWithSystemBrowser(fallingBackTo: provider, provider: provider.name) },
                onPasskey: { signInWithPasskey() }
            )
            .navigationBarTitleDisplayMode(.inline)
        case .forgot:
            ForgotPasswordPage(initialEmail: loginIdentifier) { path.removeLast() }
                .navigationBarTitleDisplayMode(.inline)
        case .email: emailPage
        case .username: usernamePage
        case .password: passwordPage
        case .gender: genderPage
        case .interests: interestsPage
        case .activation: activationPage
        }
    }

    private var emailPage: some View {
        page {
            VStack(spacing: 0) {
                Text(AppString("注册 nodeloc"))
                    .font(Theme.heading(28, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                HStack(spacing: 4) {
                    Text(AppString("已经有账号了？"))
                        .foregroundStyle(Theme.textMuted)
                    Button(AppString("去登录")) { path = [] }
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.accent)
                }
                .font(Theme.body(15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 18)
                stepHeader("输入你的电子邮件", subtitle: "我们会向这个地址发送账户激活邮件。")

                AuthInputField(
                    AppString("电子邮件"),
                    text: $email,
                    keyboard: .emailAddress,
                    contentType: .emailAddress,
                    submitLabel: .next,
                    onSubmit: { if canContinueEmail { path.append(.username) } }
                )

                inlineError
            }
        } continueButton: {
            Button {
                path.append(.username)
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinueEmail)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canContinueEmail: Bool {
        email.contains("@") && email.contains(".")
    }

    private var usernamePage: some View {
        page {
            VStack(spacing: 0) {
                stepHeader(
                    "创建用户名",
                    subtitle: "挑选一个要在 NODELOC 上使用的名字。请谨慎选择，选定后无法修改。"
                )

                AuthInputField(
                    AppString("用户名"),
                    text: $username,
                    contentType: .username,
                    submitLabel: .next,
                    onSubmit: { if canContinueUsername { path.append(.password) } }
                )
                .onChange(of: username) { _, newValue in
                    scheduleUsernameCheck(newValue)
                }

                if let usernameAvailable, !username.isEmpty {
                    Label(
                        usernameAvailable
                            ? AppString("好名字！它还没被占用，现在归你了。")
                            : (usernameSuggestion.map { AppString("已被占用，试试 \($0)？") } ?? AppString("这个用户名已被占用。")),
                        systemImage: usernameAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(Theme.body(13))
                    .foregroundStyle(usernameAvailable ? Theme.success : Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }

                inlineError
            }
        } continueButton: {
            Button {
                path.append(.password)
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinueUsername)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canContinueUsername: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && usernameAvailable != false
    }

    private var passwordPage: some View {
        page {
            VStack(spacing: 0) {
                stepHeader("设置密码", subtitle: nil)

                AuthInputField(
                    AppString("密码"),
                    text: $password,
                    secure: true,
                    // .newPassword is what triggers the system's strong-password
                    // suggestion and the keychain/Face ID save prompt.
                    contentType: .newPassword,
                    submitLabel: .next,
                    onSubmit: { if canContinuePassword { advancePastPassword() } }
                )

                Label(
                    AppString("密码必须至少包含 10 个字符"),
                    systemImage: canContinuePassword ? "checkmark.circle.fill" : "info.circle"
                )
                .font(Theme.body(13))
                .foregroundStyle(canContinuePassword ? Theme.success : Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

                inlineError
            }
        } continueButton: {
            Button {
                advancePastPassword()
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinuePassword)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canContinuePassword: Bool {
        password.count >= 10
    }

    /// Straight to interests when the site requires no custom fields, so the
    /// step doesn't appear as an empty page.
    private func advancePastPassword() {
        path.append(userFields.isEmpty ? .interests : .gender)
    }

    private var genderPage: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                stepHeader("完善你的资料", subtitle: "这些是本站注册时必填的信息。")

                SignupUserFieldsSection(model: userFields)
            }
        } continueButton: {
            Button {
                path.append(.interests)
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!userFields.isComplete)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let maxInterestNodes = 3
    private static let interestBatchSize = 8

    private var interestsPage: some View {
        page {
            VStack(spacing: 0) {
                stepHeader(
                    "选择感兴趣的节点",
                    subtitle: "最多挑选 \(Self.maxInterestNodes) 个节点，登录后自动加入。"
                )

                // The random offering.
                FlowLayout(spacing: 10, alignment: .leading) {
                    ForEach(nodeBatch) { node in
                        Button("n/\(node.slug)") {
                            pick(node)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedNodes.count >= Self.maxInterestNodes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if nodeBatch.isEmpty && nodePool.isEmpty {
                    ProgressView()
                        .padding(.top, 24)
                } else {
                    Button {
                        withAnimation(.quick) { refreshNodeBatch() }
                    } label: {
                        Label("换一批", systemImage: "arrow.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 16)
                }

                // The picks, removable.
                if !selectedNodes.isEmpty {
                    Divider()
                        .padding(.vertical, 18)

                    Text("已选择 \(selectedNodes.count)/\(Self.maxInterestNodes)")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 10)

                    FlowLayout(spacing: 10, alignment: .leading) {
                        ForEach(selectedNodes) { node in
                            Button {
                                withAnimation(.quick) {
                                    selectedNodes.removeAll { $0.id == node.id }
                                }
                            } label: {
                                Label("n/\(node.slug)", systemImage: "xmark")
                                    .labelStyle(TrailingXLabelStyle())
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                inlineError
            }
        } continueButton: {
            Button {
                submitSignup()
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInterestNodes() }
    }

    private var activationPage: some View {
        page {
            VStack(spacing: 0) {
                stepHeader(
                    "验证你的电子邮件",
                    subtitle: activationMessage.isEmpty
                        ? "我们已向 \(email) 发送激活邮件，点击其中的链接完成注册，然后回来登录。"
                        : nil,
                    verbatimSubtitle: activationMessage.isEmpty ? nil : activationMessage
                )

                Image(systemName: "envelope.badge")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 18)
            }
        } continueButton: {
            Button {
                loginIdentifier = email
                loginPassword = ""
                path = []
            } label: {
                continueLabel("返回登录")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Page scaffold

    /// Scrollable content with the continue button pinned to the bottom,
    /// shared by every step.
    private func page<Content: View, Footer: View>(
        // Escaping: ScrollViewReader's builder outlives this call.
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder continueButton: @escaping () -> Footer
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The step's button follows its content, scrolling with it —
                // not floating above the keyboard.
                VStack(spacing: 0) {
                    content()
                    continueButton()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg.ignoresSafeArea())
            // A field that appears below the fold (the 2FA code) has to be
            // scrolled to, or it stays hidden behind the keyboard.
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
        }
    }

    private static let otpFieldID = "otp-field"

    /// `LocalizedStringKey`, not `String`: a String argument is rendered
    /// verbatim and never looked up in the catalog.
    private func stepHeader(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey?,
        /// Server-supplied copy, shown as-is (already in the site's language).
        verbatimSubtitle: String? = nil
    ) -> some View {
        VStack(spacing: 0) {
            AuthWordmark(height: 32)
                .padding(.bottom, 18)

            Text(title)
                .font(Theme.heading(26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, subtitle == nil && verbatimSubtitle == nil ? 18 : 8)

            if let subtitle {
                subtitleText(Text(subtitle))
            } else if let verbatimSubtitle {
                subtitleText(Text(verbatimSubtitle))
            }
        }
    }

    private func subtitleText(_ text: Text) -> some View {
        text
            .font(Theme.body(14))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.bottom, 18)
    }

    private func continueLabel(_ title: LocalizedStringKey) -> some View {
        Group {
            if isBusy {
                ProgressView()
            } else {
                Text(title)
                    .font(Theme.body(16, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var inlineError: some View {
        if let suspendedMessage {
            SuspendedLoginNotice(message: suspendedMessage) {
                suspendedCredentials = .init(login: loginIdentifier, password: loginPassword)
            }
            .padding(.top, 16)
        }
        if let errorText {
            Text(errorText)
                .font(Theme.body(13))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
        }
    }

    // MARK: - Actions

    /// Signs in through the *system* browser, so a provider session already on
    /// this device (a Google login in Safari, say) is offered as an account to
    /// pick rather than a form to fill in. See `UserAPIKeyAuth`.
    ///
    /// Every provider button lands here: Discourse's own login page is what the
    /// session opens on, and that page carries all of them. One extra tap than
    /// the old in-app web view, in exchange for not retyping a password —
    /// and the old view is still the fallback if this can't complete.
    private func signInWithPasskey() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            defer { isBusy = false }
            do {
                try await DiscourseLogin.shared.loginWithPasskey()
                completeAuth()
            } catch {
                // Cancelled or no passkey here: the page stays as it was.
            }
        }
    }

    private func signInWithSystemBrowser(fallingBackTo provider: SocialAuthProvider, provider name: String? = nil) {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            defer { isBusy = false }
            do {
                try await DiscourseLogin.shared.loginWithSystemBrowser(provider: name)
                completeAuth()
            } catch SocialAuthError.cancelled {
                // Backing out of the sheet is a choice, not a failure.
            } catch {
                // Most likely the site hasn't whitelisted our callback. The
                // in-app web view still works, so offer that rather than a
                // dead end.
                activeProvider = provider
            }
        }
    }

    private func submitLogin() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        suspendedMessage = nil
        Task {
            do {
                let token = otpCode.trimmingCharacters(in: .whitespaces)
                try await CaptchaLogin.login(
                    gate: captchaGate,
                    identifier: loginIdentifier,
                    password: loginPassword,
                    secondFactorToken: needsSecondFactor && !token.isEmpty ? token : nil,
                    secondFactorMethod: usingBackupCode ? 2 : 1
                )
                await applyPendingNodeJoins()
                completeAuth()
            } catch is CancellationError {
                // Closed the 人机验证 widget: nothing sent, nothing to say.
            } catch AuthError.suspended(let message) {
                suspendedMessage = message
            } catch AuthError.secondFactorRequired {
                withAnimation(.quick) { needsSecondFactor = true }
                otpFocused = true
                scrollTarget = Self.otpFieldID
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    private func submitSignup() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            do {
                let result = try await DiscourseLogin.shared.signup(
                    username: username,
                    name: username,
                    email: email,
                    password: password,
                    userFields: userFields.values
                )
                switch result {
                case .signedIn:
                    await joinSelectedNodes()
                    completeAuth()
                case .needsActivation(let message):
                    savePendingNodeJoins()
                    // Server prose, which arrives as HTML — see
                    // `plainTextParagraphs`. Stored decoded so the page can
                    // keep showing it verbatim.
                    activationMessage = DiscourseFormat.plainTextParagraphs(message)
                    path.append(.activation)
                }
            } catch AuthError.signupNeedsActivation(let message) {
                savePendingNodeJoins()
                activationMessage = DiscourseFormat.plainTextParagraphs(message)
                path.append(.activation)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    private func dismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            withAnimation(.overlayPush) { app.overlay = nil }
        }
    }

    private func completeAuth() {
        app.authed = true
        app.isGuest = false
        app.onboardingDone = true
        dismiss()
    }

    // MARK: - Username availability

    private func scheduleUsernameCheck(_ value: String) {
        usernameCheck?.cancel()
        usernameAvailable = nil
        usernameSuggestion = nil
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return }
        usernameCheck = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            guard let response = try? await client.checkUsername(trimmed) else { return }
            guard !Task.isCancelled else { return }
            usernameAvailable = response.available ?? false
            usernameSuggestion = response.suggestion
        }
    }

    // MARK: - Interest nodes

    /// Nodes are the user-created subcategories (discourse-community), not the
    /// top-level sections — those are just containers.
    private func loadInterestNodes() async {
        guard nodePool.isEmpty else { return }
        guard let response = try? await client.categories(includeSubcategories: true) else { return }
        let categories = response.categoryList.categories
        let nodes = (categories + categories.flatMap { $0.subcategoryList ?? [] })
            .filter { $0.parentCategoryId != nil }
        nodePool = nodes
            .map { InterestNode(id: $0.id, name: $0.name, slug: $0.slug) }
            .shuffled()
        refreshNodeBatch()
    }

    /// Deals the next random handful, skipping what's already picked.
    private func refreshNodeBatch() {
        let selectedIDs = Set(selectedNodes.map(\.id))
        nodeBatch = Array(
            nodePool
                .shuffled()
                .filter { !selectedIDs.contains($0.id) }
                .prefix(Self.interestBatchSize)
        )
    }

    private func pick(_ node: InterestNode) {
        guard selectedNodes.count < Self.maxInterestNodes,
              !selectedNodes.contains(where: { $0.id == node.id }) else { return }
        withAnimation(.quick) {
            selectedNodes.append(node)
            nodeBatch.removeAll { $0.id == node.id }
        }
    }

    /// Joins picked nodes right away when signup produced a session.
    private func joinSelectedNodes() async {
        for node in selectedNodes {
            _ = try? await client.joinNode(categoryID: node.id)
        }
    }

    /// Activation pending: stash the picks; they're applied on the next
    /// successful login through this flow.
    private func savePendingNodeJoins() {
        guard !selectedNodes.isEmpty else { return }
        UserDefaults.standard.set(selectedNodes.map(\.id), forKey: Self.pendingJoinsKey)
    }

    private func applyPendingNodeJoins() async {
        let pending = UserDefaults.standard.array(forKey: Self.pendingJoinsKey) as? [Int] ?? []
        guard !pending.isEmpty else { return }
        for id in pending {
            _ = try? await client.joinNode(categoryID: id)
        }
        UserDefaults.standard.removeObject(forKey: Self.pendingJoinsKey)
    }

    private static let pendingJoinsKey = "nodeloc.pending_node_joins"

    private func openWebsite(path: String) {
        guard let url = URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL else { return }
        UIApplication.shared.open(url)
    }
}

/// Text first, the xmark trailing — for the removable picked-node chips.
private struct TrailingXLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.system(size: 11, weight: .bold))
        }
    }
}
