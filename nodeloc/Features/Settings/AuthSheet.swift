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
    case email
    case username
    case password
    case gender
    case interests
    case activation
}

struct AuthFlowOverlay: View {
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

    // Signup
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var usernameAvailable: Bool?
    @State private var usernameSuggestion: String?
    @State private var usernameCheck: Task<Void, Never>?
    @State private var gender = ""
    /// Every node (subcategory) available, shuffled once — the 换一批 pool.
    @State private var nodePool: [InterestNode] = []
    /// The handful currently on offer.
    @State private var nodeBatch: [InterestNode] = []
    /// Picks, in the order they were made. Capped at `maxInterestNodes`.
    @State private var selectedNodes: [InterestNode] = []
    /// Server message shown on the activation step.
    @State private var activationMessage = ""

    @State private var isBusy = false
    @State private var errorText: String?

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
    }

    // MARK: - Login (root)

    private var loginPage: some View {
        page {
            VStack(spacing: 0) {
                AuthMark()
                    .frame(width: 44, height: 44)
                    .padding(.bottom, 18)

                Text("登录")
                    .font(Theme.heading(26, weight: .bold))
                    .padding(.bottom, 8)

                Text("继续操作即表示您同意我们的用户协议并确认已了解隐私政策。")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)

                Button {
                    authenticateWithWebsite()
                } label: {
                    Label("通过 NodeLoc 网站继续", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy)
                .padding(.bottom, 16)

                HStack(spacing: 12) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                    Text("或")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.5))
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                .padding(.bottom, 16)

                VStack(spacing: 12) {
                    TextField("电子邮件地址或用户名", text: $loginIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)

                    SecureField("密码", text: $loginPassword)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { if canContinueLogin { submitLogin() } }

                    if needsSecondFactor {
                        TextField(usingBackupCode ? "备用码" : "两步验证码", text: $otpCode)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.oneTimeCode)
                            .keyboardType(usingBackupCode ? .asciiCapable : .numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { if canContinueLogin { submitLogin() } }

                        HStack {
                            Label("此账号已开启两步验证", systemImage: "lock.shield")
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.muted(0.55))
                            Spacer(minLength: 8)
                            Button(usingBackupCode ? "使用验证器" : "使用备用码") {
                                usingBackupCode.toggle()
                                otpCode = ""
                            }
                            .font(Theme.body(12, weight: .semibold))
                        }
                    }
                }

                Button("忘记了密码？") {
                    openWebsite(path: "password-reset")
                }
                .font(Theme.body(14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)

                inlineError
            }
        } continueButton: {
            Button {
                submitLogin()
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy || !canContinueLogin)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.overlayPush) { app.overlay = nil }
                } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("注册") {
                    errorText = nil
                    path = [.email]
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
                stepHeader("输入你的电子邮件", subtitle: "我们会向这个地址发送账户激活邮件。")

                TextField("电子邮件", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { if canContinueEmail { path.append(.username) } }

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

                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onChange(of: username) { _, newValue in
                        scheduleUsernameCheck(newValue)
                    }
                    .onSubmit { if canContinueUsername { path.append(.password) } }

                if let usernameAvailable, !username.isEmpty {
                    Label(
                        usernameAvailable
                            ? "好名字！它还没被占用，现在归你了。"
                            : (usernameSuggestion.map { "已被占用，试试 \($0)？" } ?? "这个用户名已被占用。"),
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

                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    // .newPassword is what triggers the system's strong-password
                    // suggestion and the keychain/Face ID save prompt.
                    .textContentType(.newPassword)
                    .submitLabel(.next)
                    .onSubmit { if canContinuePassword { path.append(.gender) } }

                Label(
                    "密码必须至少包含 10 个字符",
                    systemImage: canContinuePassword ? "checkmark.circle.fill" : "info.circle"
                )
                .font(Theme.body(13))
                .foregroundStyle(canContinuePassword ? Theme.success : Theme.muted(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

                inlineError
            }
        } continueButton: {
            Button {
                path.append(.gender)
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

    private var genderPage: some View {
        page {
            VStack(spacing: 0) {
                stepHeader("你的性别是？", subtitle: "用于优化向你推荐的内容，之后可以随时更改。")

                Picker("性别", selection: $gender) {
                    ForEach(["男", "女", "其他", "不愿透露"], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        } continueButton: {
            Button {
                UserDefaults.standard.set(gender, forKey: "nodeloc.profile.gender")
                path.append(.interests)
            } label: {
                continueLabel("继续")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(gender.isEmpty)
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
                        .foregroundStyle(Theme.muted(0.55))
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
                        : activationMessage
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
        @ViewBuilder content: () -> Content,
        @ViewBuilder continueButton: () -> Footer
    ) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 24)
                .padding(.top, 18)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            continueButton()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private func stepHeader(_ title: String, subtitle: String?) -> some View {
        VStack(spacing: 0) {
            AuthMark()
                .frame(width: 44, height: 44)
                .padding(.bottom, 18)

            Text(title)
                .font(Theme.heading(26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, subtitle == nil ? 18 : 8)

            if let subtitle {
                Text(subtitle)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.muted(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 18)
            }
        }
    }

    private func continueLabel(_ title: String) -> some View {
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
        if let errorText {
            Text(errorText)
                .font(Theme.body(13))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
        }
    }

    // MARK: - Actions

    private func submitLogin() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            do {
                let token = otpCode.trimmingCharacters(in: .whitespaces)
                try await DiscourseLogin.shared.login(
                    identifier: loginIdentifier,
                    password: loginPassword,
                    secondFactorToken: needsSecondFactor && !token.isEmpty ? token : nil,
                    secondFactorMethod: usingBackupCode ? 2 : 1
                )
                await applyPendingNodeJoins()
                completeAuth()
            } catch AuthError.secondFactorRequired {
                withAnimation(.quick) { needsSecondFactor = true }
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
                    password: password
                )
                switch result {
                case .signedIn:
                    await joinSelectedNodes()
                    completeAuth()
                case .needsActivation(let message):
                    savePendingNodeJoins()
                    activationMessage = message
                    path.append(.activation)
                }
            } catch AuthError.signupNeedsActivation(let message) {
                savePendingNodeJoins()
                activationMessage = message
                path.append(.activation)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    private func authenticateWithWebsite() {
        guard !isBusy else { return }
        isBusy = true
        errorText = nil
        Task {
            do {
                try await DiscourseLogin.shared.start()
                await applyPendingNodeJoins()
                completeAuth()
            } catch AuthError.cancelled {
                // User dismissed the browser.
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isBusy = false
        }
    }

    private func completeAuth() {
        app.authed = true
        app.isGuest = false
        app.onboardingDone = true
        withAnimation(.overlayPush) {
            app.overlay = nil
        }
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
