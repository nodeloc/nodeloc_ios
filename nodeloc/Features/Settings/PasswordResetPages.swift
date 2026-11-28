//
//  PasswordResetPages.swift
//  nodeloc
//
//  忘记密码, in the app, on the backend's existing endpoints
//  (internal/account/security_handlers.go):
//  1. `POST /api/v1/auth/password-reset` `{email, captcha}` sends a mail whose
//     link is `https://www.nodeloc.com/reset-password?token=…` (one hour,
//     single use). Once the captcha passes the answer is always "sent",
//     registered or not. Limits: 3 an hour per address, 10 per IP.
//  2. That link is a universal link the app owns (not excluded in the site's
//     apple-app-site-association), so it opens here, on `ResetPasswordPage`,
//     which sets the password with `PUT /api/v1/auth/password-reset`
//     `{token, password}` (10–200 characters). It doesn't sign in.
//

import SwiftUI

struct ResetPasswordToken: Identifiable, Hashable {
    let value: String
    var id: String { value }
}

// MARK: - Request

struct ForgotPasswordPage: View {
    var initialEmail: String = ""
    /// Back to the login page.
    let onBackToLogin: () -> Void

    @State private var email = ""
    @State private var sentTo: String?
    @State private var resendIn = 0
    @State private var isSending = false
    @State private var errorText: String?
    @State private var captchaGate = CaptchaGate()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppString("找回密码"))
                    .font(Theme.heading(28, weight: .bold))
                    .padding(.bottom, 6)
                Text(AppString("填写注册时用的邮箱，我们会发一封重设密码的邮件。"))
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)

                Text(AppString("邮箱")).font(Theme.body(14, weight: .bold)).padding(.bottom, 8)
                AuthInputField(
                    "you@example.com", text: $email,
                    keyboard: .emailAddress, contentType: .emailAddress,
                    submitLabel: .send, onSubmit: send,
                    leadingSymbol: "envelope"
                )

                if let errorText {
                    FieldErrorText(message: errorText).padding(.top, 8)
                }

                if let sentTo {
                    Label {
                        Text(AppString("重设密码的邮件已发到 \(sentTo)。点邮件里的链接（1 小时内有效）会回到 App 设置新密码；没收到的话看看垃圾邮件。"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "envelope.badge")
                    }
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 14)
                }

                Button(action: send) {
                    ZStack {
                        Text(buttonTitle).opacity(isSending ? 0 : 1)
                        if isSending { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthPrimaryPillStyle(disabled: !canSend))
                .disabled(!canSend || isSending)
                .padding(.top, 18)

                Button(AppString("返回登录"), action: onBackToLogin)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .captchaGate(captchaGate)
        .onAppear { if email.isEmpty, initialEmail.contains("@") { email = initialEmail } }
        .task(id: resendIn) {
            guard resendIn > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            resendIn -= 1
        }
    }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool { trimmed.contains("@") && trimmed.contains(".") && resendIn == 0 }

    private var buttonTitle: String {
        if resendIn > 0 { return AppString("\(resendIn) 秒后重发") }
        return sentTo == nil ? AppString("发送重设邮件") : AppString("重新发送")
    }

    private func send() {
        guard canSend, !isSending else { return }
        isSending = true
        errorText = nil
        Task {
            defer { isSending = false }
            let client = DiscourseClient()
            do {
                let token = try await captchaGate.token(for: .passwordReset)
                do {
                    try await client.requestPasswordReset(email: trimmed, captcha: token)
                } catch let error as DiscourseError where CaptchaFailure.isCaptcha(error) {
                    let fresh = try await captchaGate.token(for: .passwordReset, force: true)
                    try await client.requestPasswordReset(email: trimmed, captcha: fresh)
                }
                sentTo = trimmed
                resendIn = 60
            } catch is CancellationError {
            } catch {
                errorText = Self.message(for: error, failure: AppString("发送失败，请稍后重试"))
            }
        }
    }

    /// The server's own reason when it gave one; a 5xx as the failed step
    /// with its status, never the raw "Internal server error".
    static func message(for error: Error, failure: String) -> String {
        if let field = ServerFieldErrors.last().first(where: { $0.key != "captcha" })?.value { return field }
        if let status = (error as? DiscourseError)?.statusCode, status >= 500 {
            return failure + " (\(status))"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Set the new password

struct ResetPasswordPage: View {
    let token: String
    let onDone: () -> Void

    @Environment(AppState.self) private var app
    @State private var password = ""
    @State private var confirm = ""
    @State private var isSaving = false
    @State private var errorText: String?

    private static let minimum = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppString("设置新密码"))
                    .font(Theme.heading(28, weight: .bold))
                    .padding(.bottom, 14)

                Text(AppString("新密码")).font(Theme.body(14, weight: .bold))
                AuthInputField(
                    AppString("至少 \(Self.minimum) 位"), text: $password,
                    secure: true, contentType: .newPassword, leadingSymbol: "lock"
                )
                Text(AppString("再输一次")).font(Theme.body(14, weight: .bold)).padding(.top, 8)
                AuthInputField(
                    AppString("和上面一样"), text: $confirm,
                    secure: true, contentType: .newPassword,
                    submitLabel: .done, onSubmit: save, leadingSymbol: "lock"
                )
                if !confirm.isEmpty, confirm != password {
                    FieldErrorText(message: AppString("两次输入的密码不一样"))
                }
                if let errorText {
                    FieldErrorText(message: errorText)
                }

                Button(action: save) {
                    ZStack {
                        Text(AppString("保存新密码")).opacity(isSaving ? 0 : 1)
                        if isSaving { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AuthPrimaryPillStyle(disabled: !canSave))
                .disabled(!canSave || isSaving)
                .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onDone) { Image(systemName: "xmark") }
                    .accessibilityLabel(AppString("关闭"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSave: Bool { password.count >= Self.minimum && password == confirm }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorText = nil
        Task {
            defer { isSaving = false }
            do {
                try await DiscourseClient().resetPassword(token: token, password: password)
                ToastCenter.shared.show(AppString("密码已重设，请用新密码登录"))
                onDone()
                // Straight on to logging in, unless someone is signed in here.
                if app.isGuest, !app.authed {
                    try? await Task.sleep(for: .milliseconds(400))
                    presentAuth(app, mode: .login)
                }
            } catch {
                // `invalid_token`: 链接无效或已过期 — the server's words.
                errorText = ForgotPasswordPage.message(for: error, failure: AppString("保存失败，请稍后重试"))
            }
        }
    }
}
