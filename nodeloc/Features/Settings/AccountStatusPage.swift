//
//  AccountStatusPage.swift
//  nodeloc
//
//  账号状态 — every penalty currently on this account, and one appeal each.
//  `GET /api/v1/me/restrictions`, appealed through
//  `POST /api/v1/me/restrictions/{kind}/{id}/appeal`.
//
//  Penalty and appeal notifications both route to `/appeal`, which opens this
//  page. An account in good standing sees an empty state, which is the common
//  case and worth saying plainly rather than leaving blank.
//
//  Whether a penalty may be appealed is the server's call (`can_appeal`): it
//  knows about the one-appeal-ever rule, the five-a-day limit and penalties
//  that have already lapsed. Re-deriving any of that here would only produce
//  buttons that fail.
//

import SwiftUI

@MainActor
@Observable
final class AccountStatusStore {
    private let client = DiscourseClient()

    private(set) var restrictions: [NLRestrictions.Restriction] = []
    private(set) var isLoading = false
    private(set) var errorText: String?

    func load() async {
        isLoading = restrictions.isEmpty
        errorText = nil
        defer { isLoading = false }
        do {
            restrictions = try await client.myRestrictions()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func appeal(
        _ restriction: NLRestrictions.Restriction,
        reason: DiscourseClient.AppealReason,
        text: String
    ) async -> Bool {
        do {
            _ = try await client.appealRestriction(
                kind: restriction.kind, id: restriction.penaltyID, reason: reason, text: text
            )
            ToastCenter.shared.show(AppString("申诉已提交，管理人员会处理"))
            await load()
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }
}

struct AccountStatusPage: View {
    let onClose: () -> Void

    @State private var store = AccountStatusStore()
    @State private var appealing: NLRestrictions.Restriction?
    @State private var appealReason: DiscourseClient.AppealReason = .wrong

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: AppString("账号状态"), onClose: onClose)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.isLoading, store.restrictions.isEmpty {
                        ProgressView()
                            .tint(Theme.accent)
                            .padding(.vertical, 44)
                    } else if let errorText = store.errorText, store.restrictions.isEmpty {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.muted(0.55))
                            .padding(.vertical, 44)
                    } else if store.restrictions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Theme.success)
                            Text(AppString("你的账号一切正常"))
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.muted(0.55))
                        }
                        .padding(.vertical, 56)
                    } else {
                        ForEach(store.restrictions) { restriction in
                            card(restriction)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .task { await store.load() }
        .sheet(item: $appealing) { restriction in
            AppealSheet(
                title: AppString("申诉"),
                note: AppString("说明你认为这次处罚不妥的理由。一次处罚只能申诉一次，管理人员会复核。"),
                minimum: 10,
                limit: 2000,
                reasons: DiscourseClient.AppealReason.allCases,
                onSubmit: { text in
                    await store.appeal(restriction, reason: appealReason, text: text)
                },
                onPickReason: { appealReason = $0 }
            )
        }
    }

    private func card(_ restriction: NLRestrictions.Restriction) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(title(for: restriction))
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Text(duration(for: restriction))
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.45))
            }

            if let reason = restriction.reason, !reason.isEmpty {
                Text(AppString("原因：\(reason)"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only risk control's "reset" claws energy back.
            if let clawed = restriction.clawed, clawed > 0 {
                Text(AppString("追回 \(clawed) 能量"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
            }

            Text(source(for: restriction))
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.45))

            if let appeal = restriction.appeal {
                appealState(appeal)
            } else if restriction.canAppeal == true {
                Button { appealing = restriction } label: {
                    Text(AppString("我要申诉"))
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.accent700)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func appealState(_ appeal: NLRestrictions.Appeal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText(appeal.status))
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(statusColor(appeal.status))
            // What the handler wrote back, when they wrote anything.
            if let note = appeal.note, !note.isEmpty {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "accepted": AppString("申诉通过")
        // An ignored appeal is reported as rejected too.
        case "rejected": AppString("申诉未通过，维持原处罚")
        default: AppString("申诉处理中")
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "accepted": Theme.success
        case "rejected": Theme.danger
        default: Theme.muted(0.55)
        }
    }

    private func title(for restriction: NLRestrictions.Restriction) -> String {
        if let node = restriction.node {
            return restriction.type == "ban"
                ? AppString("在节点 \(node.name ?? node.slug) 被封禁")
                : AppString("在节点 \(node.name ?? node.slug) 被禁言")
        }
        switch restriction.type {
        case "suspend": return AppString("账号已被封禁")
        case "silence": return AppString("账号已被禁言")
        case "reset": return AppString("账号被清零")
        case "restrict": return AppString("账号被限制")
        default: return AppString("账号受到限制")
        }
    }

    /// A null end means it doesn't lapse by itself — for risk control's
    /// `reset` and `restrict` that means "until someone looks at it".
    private func duration(for restriction: NLRestrictions.Restriction) -> String {
        guard let endsAt = restriction.endsAt else {
            return restriction.kind == "risk" ? AppString("待处理") : AppString("永久")
        }
        return AppString("至 \(DiscourseFormat.relative(endsAt))")
    }

    private func source(for restriction: NLRestrictions.Restriction) -> String {
        switch restriction.by {
        case "risk": AppString("由风控系统处置")
        case "node_owner": AppString("由节点主处理")
        case "node_moderator": AppString("由节点版主处理")
        default: AppString("由管理人员处理")
        }
    }
}
