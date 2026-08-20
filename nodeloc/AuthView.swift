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
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var noticeText: String?

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .animation(.spring(duration: 0.28), value: stageKey)
        .onChange(of: app.authMode) { _, _ in
            resetMessages()
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

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 18) {
                AuthWordmark()

                Text("自由、平等、友好、开放、有趣")
                    .font(Theme.heading(25, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 36)
            }
            .padding(.top, 34)

            AuthHeroScene()
                .frame(maxWidth: .infinity)
                .frame(height: 390)
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
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture { stage = .welcome }

            VStack(spacing: 18) {
                Text(app.authMode == .login ? "Log in" : "Sign up")
                    .font(Theme.heading(28, weight: .semibold))
                    .padding(.top, 26)

                VStack(spacing: 10) {
                    methodButton("Continue with Google", icon: "g.circle.fill") {
                        authenticateWithWebsite()
                    }
                    methodButton("Continue with Apple", icon: "apple.logo") {
                        authenticateWithWebsite()
                    }
                    methodButton("Continue with Telegram", icon: "paperplane") {
                        authenticateWithWebsite()
                    }
                    methodButton(app.authMode == .login ? "Use email or username" : "Use email") {
                        stage = .credentials
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
            .background(Theme.bg)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous))
        }
    }

    private func methodButton(
        _ title: String,
        icon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 30)
                } else {
                    Image(systemName: "person")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 30)
                }

                Text(title)
                    .font(Theme.heading(16, weight: .semibold))
                    .frame(maxWidth: .infinity)

                Color.clear.frame(width: 30, height: 1)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.text.opacity(0.46), lineWidth: 1.25))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: - Credentials

    private var credentialsScreen: some View {
        VStack(spacing: 0) {
            credentialsHeader

            ScrollView {
                VStack(spacing: 0) {
                    AuthMark()
                        .frame(width: 48, height: 48)
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
                    }

                    if app.authMode == .login {
                        VStack(alignment: .leading, spacing: 12) {
                            authSmallPill("Forgot password?") {
                                openWebsite(path: "password-reset")
                            }
                            authSmallPill("Email me a login link instead") {
                                openWebsite(path: "login")
                            }
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
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private func authSmallPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.vertical, 9)
                .padding(.horizontal, 14)
                .background(Theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.text.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Activation

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
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Spacer(minLength: 34)

            AuthMark()
                .frame(width: 48, height: 48)
                .padding(.bottom, 34)

            Text("Verify your email")
                .font(Theme.heading(30, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

            Text(message.isEmpty ? "Check your inbox and follow the confirmation link to activate your account." : message)
                .font(Theme.body(20))
                .foregroundStyle(Theme.text.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 38)

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

    // MARK: - Shared

    private var termsText: some View {
        Text("By continuing, you agree to our **Terms** and acknowledge that you understand the **Privacy Policy**.")
            .font(Theme.body(13))
            .foregroundStyle(Theme.text.opacity(0.82))
            .multilineTextAlignment(.leading)
    }

    private var canSubmit: Bool {
        switch app.authMode {
        case .login:
            return !loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .signup:
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    try await DiscourseLogin.shared.login(identifier: loginIdentifier, password: password)
                    completeAuth()
                case .signup:
                    let result = try await DiscourseLogin.shared.signup(
                        username: username,
                        name: displayName,
                        email: email,
                        password: password
                    )
                    switch result {
                    case .signedIn:
                        completeAuth()
                    case .needsActivation(let message):
                        stage = .activation(message)
                    }
                }
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

    private func authenticateWithWebsite() {
        guard !isBusy else { return }
        isBusy = true
        resetMessages()
        Task {
            do {
                try await DiscourseLogin.shared.start()
                completeAuth()
            } catch AuthError.cancelled {
                // user dismissed the browser
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stage = .credentials
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

private struct AuthWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            AuthMark()
                .frame(width: 46, height: 46)
            Text("NODELOC")
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(Theme.accent700)
        }
    }
}

private struct AuthMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
            Circle()
                .fill(Theme.bg)
                .frame(width: 14, height: 14)
                .offset(x: -9, y: -4)
            Circle()
                .fill(Theme.bg)
                .frame(width: 14, height: 14)
                .offset(x: 9, y: -4)
            Capsule()
                .fill(Theme.bg)
                .frame(width: 24, height: 8)
                .offset(y: 10)
        }
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

private struct AuthInputField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false, keyboard: UIKeyboardType = .default) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.keyboard = keyboard
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(Theme.body(18))
            .textFieldStyle(.plain)
            .tint(Color(hex: 0x3366FF))
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Theme.neutral300.opacity(0.8), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(text.isEmpty ? Color.clear : Theme.text, lineWidth: text.isEmpty ? 0 : 1.2)
        }
    }
}

private struct AuthPrimaryPillStyle: ButtonStyle {
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
