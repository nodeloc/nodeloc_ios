//
//  AccountStatusPage.swift
//  nodeloc
//
//  账号状态 (App-iOS-Status) — every penalty in force on this account, and one
//  appeal each (App-iOS-Appeal). `GET /api/v1/me/restrictions`, appealed
//  through `POST /api/v1/me/restrictions/{kind}/{id}/appeal`.
//
//  The same page serves an account that can't sign in (login answered 403
//  `suspended`, App-iOS-LoginSuspended): it reads and appeals with the
//  username and password instead (`POST /api/v1/restrictions/lookup`,
//  `POST /api/v1/restrictions/{kind}/{id}/appeal`).
//
//  Penalty and appeal notifications route to `/appeal`, which opens this page.
//  Whether a penalty may be appealed is the server's call (`can_appeal`).
//

import SwiftUI

@MainActor
@Observable
final class AccountStatusStore {
    struct Credentials: Sendable {
        let login: String
        let password: String
    }

    private let client = DiscourseClient()
    let credentials: Credentials?

    private(set) var restrictions: [NLRestrictions.Restriction] = []
    private(set) var isLoading = false
    private(set) var errorText: String?

    init(credentials: Credentials? = nil) {
        self.credentials = credentials
    }

    func load() async {
        isLoading = restrictions.isEmpty
        errorText = nil
        defer { isLoading = false }
        do {
            if let credentials {
                restrictions = try await client.lookupRestrictions(login: credentials.login, password: credentials.password)
            } else {
                restrictions = try await client.myRestrictions()
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Returns nil when it went through, else the server's words to show.
    func appeal(
        _ restriction: NLRestrictions.Restriction,
        reason: DiscourseClient.AppealReason,
        text: String
    ) async -> String? {
        do {
            if let credentials {
                try await client.appealRestriction(
                    login: credentials.login, password: credentials.password,
                    kind: restriction.kind, id: restriction.penaltyID, reason: reason, text: text
                )
            } else {
                try await client.appealRestriction(kind: restriction.kind, id: restriction.penaltyID, reason: reason, text: text)
            }
            ToastCenter.shared.show(AppString("申诉已提交，管理人员会处理"))
            await load()
            return nil
        } catch {
            // Already appealed, still pending or already over: the page is
            // out of date, so it reloads; the message still says why.
            if let code = (error as? DiscourseError)?.serverCode,
               ["already_appealed", "appeal_pending", "penalty_expired"].contains(code) {
                await load()
            }
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AccountStatusPage: View {
    var credentials: AccountStatusStore.Credentials?
    let onClose: () -> Void

    @State private var store: AccountStatusStore
    @State private var appealing: NLRestrictions.Restriction?

    init(credentials: AccountStatusStore.Credentials? = nil, onClose: @escaping () -> Void) {
        self.credentials = credentials
        self.onClose = onClose
        _store = State(initialValue: AccountStatusStore(credentials: credentials))
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: credentials == nil ? AppString("账号状态") : AppString("处罚和申诉"), onBack: onClose)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.isLoading, store.restrictions.isEmpty {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    } else if let errorText = store.errorText, store.restrictions.isEmpty {
                        VStack(spacing: 12) {
                            Text(errorText)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                                .multilineTextAlignment(.center)
                            Button(AppString("重试")) {
                                Task { await store.load() }
                            }
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else if store.restrictions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.seal")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Theme.success)
                            Text(AppString("你的账号一切正常"))
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    } else {
                        Text(AppString("你的账号现在有 \(store.restrictions.count) 项处罚生效。每项处罚可以申诉一次，结果会通知你。"))
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                        ForEach(store.restrictions) { restriction in
                            card(restriction)
                        }
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .refreshable { await store.load() }
        }
        .background(AdminTheme.pageBg.ignoresSafeArea())
        .task { await store.load() }
        .sheet(item: $appealing) { restriction in
            RestrictionAppealSheet(restriction: restriction) { reason, text in
                await store.appeal(restriction, reason: reason, text: text)
            }
        }
    }

    // MARK: Card

    private func card(_ restriction: NLRestrictions.Restriction) -> some View {
        let wording = RestrictionWording(restriction)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: wording.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(wording.tone.text)
                    .frame(width: 40, height: 40)
                    .background(wording.tone.fill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(wording.title)
                            .font(Theme.body(17, weight: .bold))
                            .foregroundStyle(Theme.text)
                        AdminBadge(text: wording.source)
                    }
                    Text(wording.effect)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(wording.until)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(wording.untilIsPending ? Theme.text : AdminTone.orange.text)
                if let reason = restriction.reason, !reason.isEmpty {
                    Text(AppString("原因：\(reason)"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let clawed = restriction.clawed, clawed > 0 {
                    Text(AppString("追回 \(clawed) 能量"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                Text(AppString("处理人：\(wording.handler)"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 12)

            if restriction.appeal != nil || restriction.canAppeal == true {
                Rectangle().fill(AdminTheme.separator).frame(height: 1).padding(.vertical, 14)
                appealRow(restriction)
            }
        }
        .padding(16)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func appealRow(_ restriction: NLRestrictions.Restriction) -> some View {
        if let appeal = restriction.appeal {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                switch appeal.status {
                case "accepted":
                    AdminBadge(text: AppString("申诉通过"), tone: .green, icon: "checkmark")
                case "rejected":
                    AdminBadge(text: AppString("申诉没通过"), tone: .neutral, icon: "xmark")
                default:
                    AdminBadge(text: AppString("申诉处理中"), tone: .amber, icon: "hourglass")
                }
                Group {
                    if appeal.status == "pending" || appeal.status == nil {
                        Text(AppString("\(Self.day(appeal.createdAt)) 提交，等待答复"))
                    } else if let note = appeal.note, !note.isEmpty {
                        Text(AppString("答复：\(note)"))
                    } else {
                        Text(Self.day(appeal.resolvedAt))
                    }
                }
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if restriction.canAppeal == true {
            HStack {
                Text(AppString("觉得处理有误，可以申诉一次"))
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                Button { appealing = restriction } label: {
                    Text(AppString("申诉"))
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 20)
                        .frame(height: 40)
                        .background(Theme.text, in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
    }

    static func day(_ string: String?) -> String {
        guard let date = DiscourseFormat.date(string) else { return "" }
        return date.formatted(.dateTime.month().day().locale(AppLanguage.resolved.locale))
    }
}

// MARK: - Wording

/// How a restriction reads: its title, what it stops, until when.
struct RestrictionWording {
    let title: String
    let effect: String
    let source: String
    let icon: String
    let tone: AdminTone
    let until: String
    let untilIsPending: Bool
    let handler: String

    init(_ restriction: NLRestrictions.Restriction) {
        let node = restriction.node.map { "n/\($0.slug)" }
        switch restriction.type {
        case "suspend":
            title = AppString("封禁"); effect = AppString("不能登录"); icon = "nosign"; tone = .orange
        case "mute":
            title = AppString("\(node ?? "") 节点内禁言"); effect = AppString("不能在 \(node ?? "") 发帖和回复"); icon = "text.bubble"; tone = .amber
        case "ban":
            title = AppString("\(node ?? "") 节点内封禁"); effect = AppString("不能进入 \(node ?? "")"); icon = "nosign"; tone = .orange
        case "reset":
            title = AppString("清零"); effect = AppString("近 90 天的签到能量被追回"); icon = "arrow.counterclockwise"; tone = .orange
        case "restrict":
            title = AppString("限制"); effect = AppString("每天只能点赞 5 次，不能拿节点主奖励"); icon = "slider.horizontal.3"; tone = .neutral
        default:
            title = AppString("禁言"); effect = AppString("不能发帖、回帖和私信"); icon = "text.bubble"; tone = .orange
        }
        switch restriction.kind {
        case "risk": source = AppString("风控")
        case "node": source = AppString("节点")
        case "legacy": source = AppString("旧站")
        default: source = AppString("管理员")
        }
        switch restriction.by {
        case "risk": handler = AppString("系统自动处置")
        case "node_owner": handler = AppString("节点主")
        case "node_moderator": handler = AppString("节点版主")
        default: handler = AppString("管理人员")
        }
        if let ends = DiscourseFormat.date(restriction.endsAt), ends.timeIntervalSinceNow < 100 * 365 * 86_400 {
            let left = max(0, Int(ceil(ends.timeIntervalSinceNow / 86_400)))
            until = AppString("到 \(ends.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.resolved.locale)))，还有 \(left) 天")
            untilIsPending = false
        } else if restriction.kind == "risk", restriction.type == "reset" || restriction.type == "restrict" {
            until = AppString("等待处理")
            untilIsPending = true
        } else {
            until = AppString("永久")
            untilIsPending = false
        }
    }
}

// MARK: - Appeal sheet (App-iOS-Appeal)

struct RestrictionAppealSheet: View {
    let restriction: NLRestrictions.Restriction
    /// Returns nil when it went through, else what to show.
    let onSubmit: (DiscourseClient.AppealReason, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var reason: DiscourseClient.AppealReason = .wrong
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var canSubmit: Bool { (10...2000).contains(count) && !isSubmitting }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ModSheetHeader(title: AppString("申诉"), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let wording = RestrictionWording(restriction)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(wording.title) · \(wording.until)")
                            .font(Theme.body(14, weight: .bold))
                            .foregroundStyle(Theme.text)
                        if let reason = restriction.reason, !reason.isEmpty {
                            Text(AppString("原因：\(reason)"))
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        ModSectionLabel(title: AppString("你想说的是"))
                        HStack(spacing: 10) {
                            choice(.wrong, detail: AppString("我没有做这件事，或者情况不是这样"))
                            choice(.willImprove, detail: AppString("确实做了，以后不会再这样"))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ModSectionLabel(title: AppString("说明"), note: AppString("10–2000 字"))
                        TextField(AppString("说说经过"), text: $text, axis: .vertical)
                            .font(Theme.body(16))
                            .lineLimit(4...10)
                            .padding(14)
                            .overlay(alignment: .bottomTrailing) {
                                Text("\(count) / 2000")
                                    .font(Theme.body(11))
                                    .foregroundStyle(count > 2000 ? Theme.danger : Theme.textFaint)
                                    .monospacedDigit()
                                    .padding(10)
                            }
                            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(AdminTheme.separator, lineWidth: 1)
                            }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(AppString("每项处罚只能申诉一次，一天最多申诉 5 次。"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .primaryToolbarAction(AppString("提交"), isEnabled: canSubmit, isWorking: isSubmitting) {
            Task {
                isSubmitting = true
                errorText = await onSubmit(reason, text.trimmingCharacters(in: .whitespacesAndNewlines))
                isSubmitting = false
                if errorText == nil { dismiss() }
            }
        }
        .standardSheet([.large])
            }
    }

    private func choice(_ value: DiscourseClient.AppealReason, detail: String) -> some View {
        let selected = reason == value
        return Button {
            reason = value
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? AdminTone.green.text : Theme.textFaint)
                    Text(value.title)
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                Text(detail)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? AdminTone.green.text : AdminTheme.separator, lineWidth: selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
