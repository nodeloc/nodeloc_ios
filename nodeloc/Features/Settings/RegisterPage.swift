//
//  RegisterPage.swift
//  nodeloc
//
//  App-iOS-Register: the one sign-up page, from the welcome screen's 注册 and
//  from the in-app login sheet's 免费注册 alike.
//
//  Follows the backend (mobile-api.md 注册, accounts.md):
//  - the email gets a 6-digit code first (`POST auth/register/email-code`);
//    registering with it verifies the email and signs in when no approval
//    is needed (`logged_in`);
//  - 人机验证 comes from the server's config: sending the code takes a token
//    when `register_code` is on; registering then needs none for that email
//    within `register_pass_seconds` — otherwise it takes its own;
//  - the username is checked as it's typed (`auth/username-check`);
//  - the invite code is optional; a wrong one fails the registration;
//  - 申请理由 appears only when the server asks for it (registration review
//    on, answered as a `reason` field error) — there is no public flag;
//  - the password rule is the server's: at least 10 characters.
//

import SwiftUI

struct RegisterPage: View {
    /// 已经有账号了？去登录.
    let onLogin: () -> Void
    /// Signed in (code verified, no review).
    let onSignedIn: () -> Void
    /// Registered but not signed in: under review, or the link route.
    let onPending: (String) -> Void
    /// The site's other ways in, and the passkey.
    var providers: [SocialAuthProvider] = []
    var onProvider: ((SocialAuthProvider) -> Void)?
    var onPasskey: (() -> Void)?

    @State private var email = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var reason = ""
    @State private var agreed = false
    /// The server asked for 申请理由.
    @State private var needsReason = false

    @State private var usernameState: UsernameState = .idle
    @State private var usernameCheck: Task<Void, Never>?
    /// Seconds until 重新发送; 0 when the button is live.
    @State private var resendIn = 0
    @State private var codeSent = false
    @State private var isSending = false
    @State private var isSubmitting = false
    @State private var fieldErrors: [String: String] = [:]
    @State private var errorText: String?
    @State private var captchaGate = CaptchaGate()

    private enum UsernameState: Equatable {
        case idle, checking, available
        case unavailable(String)
    }

    private static let passwordMinimum = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppString("注册 nodeloc"))
                    .font(Theme.heading(28, weight: .bold))
                    .padding(.bottom, 6)
                HStack(spacing: 4) {
                    Text(AppString("已经有账号了？")).foregroundStyle(Theme.textMuted)
                    Button(AppString("去登录"), action: onLogin)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.accent)
                }
                .font(Theme.body(15))
                .padding(.bottom, 22)

                fields

                agreement
                    .padding(.top, 18)

                if let errorText {
                    FieldErrorText(message: errorText)
                        .padding(.top, 10)
                }

                Button(action: submit) {
                    ZStack {
                        Text(AppString("注册")).opacity(isSubmitting ? 0 : 1)
                        if isSubmitting { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthPrimaryPillStyle(disabled: !canSubmit))
                .disabled(!canSubmit || isSubmitting)
                .padding(.top, 18)

                otherWays
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .captchaGate(captchaGate)
        .onChange(of: username) { _, value in scheduleUsernameCheck(value) }
        .onChange(of: email) { _, _ in
            // A code belongs to the address it was sent to.
            codeSent = false
            fieldErrors["email"] = nil
        }
        .task(id: resendIn) {
            guard resendIn > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            resendIn -= 1
        }
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            label(AppString("邮箱"))
            AuthInputField(
                "you@example.com", text: $email,
                keyboard: .emailAddress, contentType: .emailAddress,
                leadingSymbol: "envelope"
            )
            fieldError("email")

            label(AppString("邮箱验证码")).padding(.top, 8)
            HStack(spacing: 10) {
                AuthInputField(
                    AppString("6 位数字"), text: $code,
                    keyboard: .numberPad, contentType: .oneTimeCode,
                    leadingSymbol: "checkmark.shield"
                )
                Button(action: sendCode) {
                    Group {
                        if isSending {
                            ProgressView()
                        } else if resendIn > 0 {
                            Text(AppString("\(resendIn) 秒后重发")).monospacedDigit()
                        } else {
                            Text(codeSent ? AppString("重新发送") : AppString("发送验证码"))
                        }
                    }
                    .font(Theme.body(15, weight: .bold))
                    .foregroundStyle(canSendCode ? Theme.text : Theme.textMuted)
                    .padding(.horizontal, 16)
                    .frame(height: AuthMetrics.controlHeight)
                    .background(Theme.neutral300.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(!canSendCode)
                .fixedSize()
            }
            if codeSent, fieldErrors["email_code"] == nil {
                Text(AppString("验证码已发送到 \(email)，10 分钟内有效。"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            fieldError("email_code")

            label(AppString("用户名")).padding(.top, 8)
            AuthInputField(
                AppString("3–20 位字母、数字或下划线"), text: $username,
                contentType: .username, leadingSymbol: "person"
            )
            usernameStatus
            fieldError("username")

            label(AppString("密码")).padding(.top, 8)
            AuthInputField(
                AppString("至少 \(Self.passwordMinimum) 位"), text: $password,
                secure: true, contentType: .newPassword, leadingSymbol: "lock"
            )
            fieldError("password")

            label(AppString("邀请码（选填）")).padding(.top, 8)
            AuthInputField(
                AppString("有的话填上"), text: $inviteCode,
                leadingSymbol: "gift"
            )
            Text(AppString("填了邀请码，你和邀请人都能得到能量奖励。"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            fieldError("invite_code")

            if needsReason {
                label(AppString("申请理由")).padding(.top, 8)
                TextField(AppString("说说你怎么知道 nodeloc、想在这里做什么"), text: $reason, axis: .vertical)
                    .lineLimit(3...6)
                    .font(Theme.body(16))
                    .padding(16)
                    .background(Theme.neutral300.opacity(0.8), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text(AppString("现在注册需要管理员审核，通过后会邮件通知你。"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                fieldError("reason")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.body(14, weight: .bold))
    }

    @ViewBuilder
    private func fieldError(_ key: String) -> some View {
        if let message = fieldErrors[key] { FieldErrorText(message: message) }
    }

    @ViewBuilder
    private var usernameStatus: some View {
        switch usernameState {
        case .idle: EmptyView()
        case .checking:
            Text(AppString("正在检查…")).font(Theme.body(12)).foregroundStyle(Theme.textMuted)
        case .available:
            Label(AppString("可以使用"), systemImage: "checkmark.circle.fill")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
        case .unavailable(let message):
            FieldErrorText(message: message)
        }
    }

    private var agreement: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(agreed ? Theme.accent : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppString("同意服务条款和隐私政策"))
            .accessibilityValue(agreed ? AppString("已选") : AppString("未选"))
            Text(AuthLegalCopy.registerAgreement)
                .font(Theme.body(14))
                .foregroundStyle(Theme.text.opacity(0.82))
                .tint(Theme.accent)
        }
    }

    @ViewBuilder
    private var otherWays: some View {
        // Apple has its own native button where the server takes it.
        let shown = providers.filter { $0.name != "apple" || !NodelocAuthCapabilities.appleNative }
        if !shown.isEmpty || onPasskey != nil {
            HStack(spacing: 12) {
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text(AppString("或者用这些方式"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            .padding(.vertical, 18)

            SocialIconRow(providers: shown, onProvider: onProvider, onPasskey: onPasskey)
        }
    }

    // MARK: State

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSendCode: Bool {
        !isSending && resendIn == 0 && trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    private var canSubmit: Bool {
        agreed
            && trimmedEmail.contains("@")
            && code.trimmingCharacters(in: .whitespaces).count == 6
            && (3...20).contains(username.trimmingCharacters(in: .whitespaces).count)
            && password.count >= Self.passwordMinimum
            && usernameState != .checking
            && !(needsReason && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: Actions

    private func sendCode() {
        guard canSendCode else { return }
        isSending = true
        fieldErrors["email"] = nil
        fieldErrors["email_code"] = nil
        errorText = nil
        Task {
            defer { isSending = false }
            do {
                let token = try await captchaGate.token(for: .registerCode)
                do {
                    try await DiscourseLogin.shared.requestSignupEmailCode(email: trimmedEmail, captcha: token)
                } catch AuthError.captchaRequired {
                    let fresh = try await captchaGate.token(for: .registerCode, force: true)
                    try await DiscourseLogin.shared.requestSignupEmailCode(email: trimmedEmail, captcha: fresh)
                }
                codeSent = true
                resendIn = 60
            } catch is CancellationError {
            } catch {
                show(error, defaultField: "email", failure: AppString("发送失败，请稍后重试"))
            }
        }
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        fieldErrors = [:]
        errorText = nil
        Task {
            defer { isSubmitting = false }
            do {
                // The code's own check covers registration for 10 minutes;
                // a token only when the server says otherwise.
                let result: SignupResult
                do {
                    result = try await signup(captcha: nil)
                } catch AuthError.captchaRequired {
                    let token = try await captchaGate.token(for: .register, force: true)
                    result = try await signup(captcha: token)
                }
                switch result {
                case .signedIn: onSignedIn()
                case .needsActivation(let message): onPending(DiscourseFormat.plainTextParagraphs(message))
                }
            } catch AuthError.signupNeedsActivation(let message) {
                onPending(DiscourseFormat.plainTextParagraphs(message))
            } catch is CancellationError {
            } catch {
                show(error, defaultField: nil, failure: AppString("注册失败，请稍后重试"))
            }
        }
    }

    private func signup(captcha: String?) async throws -> SignupResult {
        try await DiscourseLogin.shared.signup(
            username: username,
            name: "",
            email: trimmedEmail,
            password: password,
            emailCode: code.trimmingCharacters(in: .whitespaces),
            inviteCode: inviteCode,
            reason: needsReason ? reason : nil,
            captcha: captcha
        )
    }

    /// Field errors under their fields; the rest above the button. A
    /// `reason` error is the server saying registration is under review.
    private func show(_ error: Error, defaultField: String?, failure: String? = nil) {
        let fields = ServerFieldErrors.last()
        if fields["reason"] != nil, !needsReason {
            needsReason = true
        }
        var placed = false
        for (key, message) in fields where key != "captcha" {
            fieldErrors[key] = message
            placed = true
        }
        var message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // A server failure: what failed, in words, and the status small at
        // the end for a report — never the raw "Internal server error".
        if let status = (error as? DiscourseError)?.statusCode, status >= 500 {
            message = (failure ?? AppString("请求失败，请稍后重试")) + " (\(status))"
        }
        if !placed {
            if let defaultField { fieldErrors[defaultField] = message } else { errorText = message }
        }
    }

    private func scheduleUsernameCheck(_ value: String) {
        usernameCheck?.cancel()
        fieldErrors["username"] = nil
        let name = value.trimmingCharacters(in: .whitespaces)
        guard name.count >= 3 else { usernameState = .idle; return }
        usernameState = .checking
        usernameCheck = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                let result = try await DiscourseClient().checkUsername(name)
                guard !Task.isCancelled else { return }
                usernameState = result.available == true ? .available : .unavailable(AppString("这个用户名已被占用"))
            } catch {
                guard !Task.isCancelled else { return }
                let message = ServerFieldErrors.last()["username"]
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? AppString("这个用户名不可用")
                usernameState = .unavailable(message)
            }
        }
    }
}

extension SocialAuthProvider {
    /// The bare brand name, for the row of chips under 注册.
    var shortTitle: String {
        switch name {
        case "google_oauth2", "google": return "Google"
        case "github": return "GitHub"
        case "twitter": return "X"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "linkedin": return "LinkedIn"
        default: return name.capitalized
        }
    }
}

/// The third-party sign-in buttons, icon only, one centred row — the same on
/// the login and sign-up pages. Each calls the community's own sign-in for
/// that provider; the name is the accessibility label.
struct SocialIconRow: View {
    let providers: [SocialAuthProvider]
    var onProvider: ((SocialAuthProvider) -> Void)?
    var onPasskey: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(providers) { provider in
                Button { onProvider?(provider) } label: {
                    Group {
                        if let asset = provider.assetName {
                            Image(asset).resizable().scaledToFit().frame(width: 22, height: 22)
                        } else {
                            // A provider we ship no mark for still gets a button.
                            Image(systemName: provider.fallbackSymbol).font(.system(size: 19, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: AuthMetrics.controlHeight, height: AuthMetrics.controlHeight)
                    .background(Theme.neutral300.opacity(0.35), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
                    .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(provider.title)
            }
            if let onPasskey {
                Button(action: onPasskey) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .frame(width: AuthMetrics.controlHeight, height: AuthMetrics.controlHeight)
                        .background(Theme.neutral300.opacity(0.35), in: Circle())
                        .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(AppString("用通行密钥登录"))
            }
        }
        .frame(maxWidth: .infinity)
    }
}
