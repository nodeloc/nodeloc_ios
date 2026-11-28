//
//  DeleteAccountPage.swift
//  nodeloc
//
//  账号注销 — App Store guideline 5.1.1(v).
//

import SwiftUI

/// Self-service account deletion: `POST /api/v1/me/deletion {"password": …}`.
///
/// The backend confirms with the current password, or — for an account that
/// signed up through a social login and never set one — with the username.
/// It takes effect immediately (no cooling-off period); posts stay, signed by
/// the anonymised account. Staff (admin/moderator) are refused with a 403 and
/// a message explaining why, which is shown as-is.
struct DeleteAccountPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var isWorking = false
    @State private var isConfirmingDelete = false
    @State private var errorText: String?
    /// Whether the account has a password (`GET /api/v1/me/account` →
    /// `has_password`); nil until that answers.
    @State private var hasPassword: Bool?
    @State private var confirmation = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(title: AppString("注销账号"), onClose: onClose)

            Form {
                Group {
                    warning
                    deleteSection

                    if let errorText {
                        Section {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .disabled(isWorking)
        .task { hasPassword = await Self.accountHasPassword() }
        .alert(
            AppString("确定注销账号？"),
            isPresented: $isConfirmingDelete
        ) {
            Button("永久注销", role: .destructive) {
                Task { await deleteNow() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账号会立即注销且无法恢复。你发过的主题和回复会保留，署名变为已注销的账号。")
        }
    }

    private var warning: some View {
        Section {
        VStack(alignment: .leading, spacing: 10) {
            Label("注销后无法恢复", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.danger)

            Text("注销后账号资料会被清空，所有登录失效，关注和屏蔽关系、一对一私信会被删除，并退出群聊和频道。你发过的主题和回复会保留，署名变为已注销的账号。此操作立即生效，不可撤销。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        }
    }

    private var deleteSection: some View {
        SettingsSection(
            title: AppString("注销"),
            footer: AppString("点击后需要再次确认。")
        ) {
            confirmationField

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                rowLabel(
                    hasPassword == nil ? AppString("检查中…") : AppString("永久注销账号"),
                    icon: "trash",
                    isBusy: hasPassword == nil || isWorking
                )
            }
            .disabled(hasPassword == nil || !confirmationIsFilled)
        }
    }

    private var confirmationIsFilled: Bool {
        !confirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The current password, or the username for an account without one.
    @ViewBuilder
    private var confirmationField: some View {
        Group {
            if hasPassword == false {
                TextField(
                    AppString("输入你的用户名 \(DiscourseAuth.shared.username ?? "") 来确认"),
                    text: $confirmation
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
                SecureField(AppString("当前密码"), text: $confirmation)
                    .textContentType(.password)
            }
        }
    }

    private func rowLabel(_ title: String, icon: String, isBusy: Bool) -> some View {
        HStack(spacing: 12) {
            if isBusy {
                ProgressView().controlSize(.small)
                    .frame(width: 22)
            } else {
                Image(systemName: icon)
                    .frame(width: 22)
            }
            Text(title)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private struct AccountEnvelope: Decodable {
        struct Account: Decodable { var hasPassword: Bool? }
        var account: Account?
    }

    /// `GET /api/v1/me/account` → `has_password`. Unknown reads as "has one":
    /// the password is what almost every account confirms with, and a wrong
    /// guess only costs a 422 whose message says to enter the username.
    private static func accountHasPassword() async -> Bool {
        guard let data = try? await DiscourseClient().http.send("GET", "api/v1/me/account"),
              let envelope = try? NodelocJSON.decode(AccountEnvelope.self, from: data)
        else { return true }
        return envelope.account?.hasPassword ?? true
    }

    private func deleteNow() async {
        // The server trims and case-folds the username; a password is sent verbatim.
        let secret = hasPassword == false
            ? confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
            : confirmation
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await DiscourseClient().deleteAccount(password: secret)
            ToastCenter.shared.show(AppString("账号已注销"))
            // Same teardown the 退出登录 row performs: the session is dead
            // server-side, so anything still holding it would only 403.
            DiscourseLogin.shared.signOut()
            app.overlay = nil
            app.pageStack = []
            app.onboardingDone = false
            app.isGuest = false
            app.authed = false
        } catch {
            // Wrong password / username (422), staff refused (403): the
            // server's own message says which.
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
