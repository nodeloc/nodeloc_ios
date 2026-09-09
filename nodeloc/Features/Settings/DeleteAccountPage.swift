//
//  DeleteAccountPage.swift
//  nodeloc
//
//  账号注销 — App Store guideline 5.1.1(v).
//

import SwiftUI

/// Deletes the account, or asks staff to.
///
/// Discourse only lets a member delete themselves while they have almost nothing
/// posted (`delete_user_self_max_post_count`, and never for admins), and
/// `current_user.can_delete_account` says which case this is. Apple requires the
/// *initiation* to be in the app either way, so when self-service is refused
/// this sends a private message to staff rather than pointing at a website.
struct DeleteAccountPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var canSelfDelete: Bool?
    @State private var isWorking = false
    @State private var isConfirmingDelete = false
    @State private var reason = ""
    @State private var requestSent = false
    @State private var errorText: String?

    /// Who a deletion request goes to. Discourse's staff group receives group
    /// messages, which is what its own "contact staff" flows use.
    private static let staffRecipient = "staff"

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: AppString("注销账号"), onClose: onClose)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    warning

                    if canSelfDelete == false {
                        requestSection
                    } else {
                        deleteSection
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .disabled(isWorking)
        .task { await resolveCapability() }
        .confirmationDialog(
            AppString("确定注销账号？"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久注销", role: .destructive) {
                Task { await deleteNow() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账号和你发布的内容会被永久删除，此操作无法撤销。")
        }
        .alert("已提交", isPresented: $requestSent) {
            Button("好") { onClose() }
        } message: {
            Text("注销申请已发送给管理员，处理结果会通过私信通知你。")
        }
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("注销后无法恢复", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.danger)

            Text("注销会删除你的账号资料，并按站点规则处理你发布的主题、回复和聊天记录。此操作不可撤销，请先备份需要保留的内容。")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    /// Self-service: the account is new enough that the server will do it.
    private var deleteSection: some View {
        SettingsSection(
            title: AppString("注销"),
            footer: AppString("点击后需要再次确认。")
        ) {
            Button {
                isConfirmingDelete = true
            } label: {
                rowLabel(
                    canSelfDelete == nil ? AppString("检查中…") : AppString("永久注销账号"),
                    icon: "trash",
                    isBusy: canSelfDelete == nil
                )
            }
            .buttonStyle(.pressable)
            .disabled(canSelfDelete == nil)
        }
    }

    /// The server won't self-delete this account, so the request goes to staff.
    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(
                title: AppString("提交注销申请"),
                footer: AppString("你的账号已有发布内容，需要管理员处理。申请会以私信发送给管理团队。")
            ) {
                TextField("补充说明（可选）", text: $reason, axis: .vertical)
                    .font(Theme.body(15))
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Button {
                    Task { await sendRequest() }
                } label: {
                    rowLabel(AppString("发送注销申请"), icon: "paperplane", isBusy: isWorking)
                }
                .buttonStyle(.pressable)
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 22)
            }
            Text(title)
                .font(Theme.body(15, weight: .medium))
                .foregroundStyle(Theme.danger)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Asks the server which of the two flows applies. Unknown (a failed call)
    /// is treated as "can't", because offering a button that 403s is worse than
    /// offering the slower path that always works.
    private func resolveCapability() async {
        let current = try? await DiscourseClient().currentUser().currentUser
        canSelfDelete = current?.canDeleteAccount ?? false
    }

    private func deleteNow() async {
        guard let username = DiscourseAuth.shared.username else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await DiscourseClient().deleteAccount(username: username)
            ToastCenter.shared.show(AppString("账号已注销"))
            // Same teardown the 退出登录 row performs: the session is dead
            // server-side, so anything still holding it would only 403.
            DiscourseLogin.shared.signOut()
            app.overlay = nil
            app.onboardingDone = false
            app.isGuest = false
            app.authed = false
        } catch {
            // The most likely refusal is the post-count rule changing under us;
            // fall through to the request flow rather than dead-ending.
            canSelfDelete = false
            errorText = AppString("无法直接注销，请通过下方申请由管理员处理。")
        }
    }

    private func sendRequest() async {
        guard let username = DiscourseAuth.shared.username else { return }
        isWorking = true
        defer { isWorking = false }

        let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = """
        用户 @\(username) 通过 iOS App 申请注销账号。

        \(note.isEmpty ? AppString("（未填写补充说明）") : note)
        """
        do {
            try await DiscourseClient().createPrivateMessage(
                recipient: Self.staffRecipient,
                title: AppString("账号注销申请：@\(username)"),
                raw: body
            )
            requestSent = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
