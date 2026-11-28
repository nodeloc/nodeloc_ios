//
//  ModerationSheets.swift
//  nodeloc
//
//  The sheets of the risk-control and moderation scheme, after the updated
//  iOS artboards:
//
//  - 举报这个帖子 (App-iOS-UserReport): reasons from the server.
//  - 处理帖子和作者 (App-iOS-Moderate, App-iOS-ModConflict): for someone who
//    manages the post, in place of reporting it; 延长 / 替换 when the author
//    already has that penalty.
//  - 处罚 u/名字 (App-iOS-Ban, App-iOS-BanConfirm).
//
//  All judgement is the server's: these show what it allows and send what was
//  chosen.
//

import SwiftUI

// MARK: - Pieces

/// The artboards' capsule buttons: outline, ink, brick outline, green, grey.
struct ModPillButton: View {
    enum Style { case outline, ink, brickOutline, brick, green, grey }

    let title: String
    var style: Style = .outline
    var height: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(15, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(background, in: Capsule())
                .overlay {
                    if let border { Capsule().strokeBorder(border, lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }

    private static let brickText = Color(light: 0xA33A00, dark: 0xFF9F6B)
    static let brickFill = Color(light: 0xA33A00, dark: 0xC2410C)

    private var foreground: Color {
        switch style {
        case .outline, .grey: Theme.text
        case .ink: Theme.bg
        case .brickOutline: Self.brickText
        case .brick, .green: .white
        }
    }

    private var background: Color {
        switch style {
        case .outline, .brickOutline: .clear
        case .ink: Theme.text
        case .brick: Self.brickFill
        case .green: Theme.accentFill
        case .grey: Theme.chip
        }
    }

    private var border: Color? {
        switch style {
        case .outline: Color(light: 0xC9D3D8, dark: 0x3A4440)
        case .brickOutline: Color(light: 0xE7B9A0, dark: 0x6B3A22)
        default: nil
        }
    }
}

/// The grey ⋯ next to a card's two buttons: the decisions that don't get one.
struct ModMoreMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 40)
                .background(Theme.chip, in: Capsule())
        }
        .accessibilityLabel(AppString("更多处理"))
    }
}

/// A section label with its muted note, as the sheets have them.
struct ModSectionLabel: View {
    let title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
            if let note, !note.isEmpty {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Wrapping chips, one selected (ink): reasons and durations.
struct ModChoiceChips<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    withAnimation(.quicker) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Theme.body(14, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.bg : Theme.text)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(selected ? Theme.text : Theme.bg, in: Capsule())
                        .overlay {
                            if !selected {
                                Capsule().strokeBorder(Color(light: 0xC9D3D8, dark: 0x3A4440), lineWidth: 1)
                            }
                        }
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// − 20 + : how much reputation to take, in fives up to the reader's cap.
struct ModReputationStepper: View {
    @Binding var value: Int
    let maximum: Int
    var caption: String?

    var body: some View {
        HStack(spacing: 14) {
            stepButton("minus", enabled: value > 0) { value = max(0, value - 5) }
            Text("\(value)")
                .font(Theme.body(22, weight: .bold))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .frame(minWidth: 40)
            stepButton("plus", enabled: value < maximum) { value = min(maximum, value + 5) }
            Spacer(minLength: 8)
            if let caption {
                Text(caption)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(width: 40, height: 40)
                .background(Theme.bg, in: Circle())
                .overlay(Circle().strokeBorder(Color(light: 0xC9D3D8, dark: 0x3A4440), lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
    }
}

/// 取消 on the left, the title centred: the artboards' sheet header.
struct ModSheetHeader: View {
    let title: String
    let onCancel: () -> Void

    /// A standard sheet bar: the title inline and 取消 as the cancellation
    /// action, on the sheet's own `NavigationStack` (see `ModSheetContainer`).
    var body: some View {
        Color.clear
            .frame(height: 0)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppString("取消"), action: onCancel)
                }
            }
    }
}

/// The reasons the server hands out, as chips; 「其他」 opens a field.
struct ModReasonPicker: View {
    let reasons: [NLReason]
    @Binding var selected: NLReason?
    @Binding var otherText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModChoiceChips(
                options: reasons.map { ($0, $0.label) },
                selection: $selected
            )
            if selected?.isOther == true {
                TextField(AppString("写清楚原因，对方会看到"), text: $otherText, axis: .vertical)
                    .font(Theme.body(15))
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(light: 0xC9D3D8, dark: 0x3A4440), lineWidth: 1)
                    }
            }
        }
    }

    /// The reason as the server stores it: the picked value, or what was
    /// written for 「其他」.
    static func reasonText(_ selected: NLReason?, other: String) -> String {
        guard let selected else { return "" }
        if selected.isOther {
            return other.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selected.value
    }
}

/// How long a penalty runs, by the artboards' chips.
enum ModDuration {
    static let all = [1, 3, 7, 30, 0]

    /// The chips the reader may use: up to `maxDays` (0 = no limit,
    /// permanent allowed).
    static func options(maxDays: Int) -> [(value: Int, title: String)] {
        all.filter { maxDays == 0 || ($0 > 0 && $0 <= maxDays) }
            .map { ($0, title($0)) }
    }

    static func title(_ days: Int) -> String {
        days == 0 ? AppString("永久") : AppString("\(days) 天")
    }

    /// 禁言 7 天 / 永久封禁.
    static func phrase(kind: String, days: Int) -> String {
        let word = kind == "suspend" || kind == "ban" ? AppString("封禁") : AppString("禁言")
        return days == 0 ? AppString("永久\(word)") : AppString("\(word) \(days) 天")
    }
}

// MARK: - Report or handle

/// What a post's 举报 opens. For someone who manages the post the server
/// says so (`GET …/moderate`), and the handling dialog opens instead;
/// for everyone else, and on 403, the report sheet.
struct PostReportFlow: View {
    let target: FlagTarget

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case report(postID: Int)
        case moderate(postID: Int, options: NLPostModerateOptions)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 240)
            case .report(let postID):
                ReportPostSheet(postID: postID, isTopic: target.isTopic)
            case .moderate(let postID, let options):
                PostModerateSheet(postID: postID, options: options)
            case .failed(let text):
                NavigationStack {
                    VStack(spacing: 12) {
                        ModSheetHeader(title: AppString("举报"), onCancel: { dismiss() })
                        Text(text)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textMuted)
                            .padding(24)
                        Spacer()
                    }
                }
            }
        }
        .background(AdminTheme.pageBg)
        .task { await resolve() }
        }

    private func resolve() async {
        let client = DiscourseClient()
        do {
            let postID = target.isTopic ? try await client.firstPostID(ofTopic: target.id) : target.id
            if DiscourseAuth.shared.isAuthenticated,
               let options = try? await client.postModerateOptions(postID: postID) {
                phase = .moderate(postID: postID, options: options)
            } else {
                phase = .report(postID: postID)
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - 举报这个帖子 (App-iOS-UserReport)

struct ReportPostSheet: View {
    let postID: Int
    var isTopic = false

    @Environment(\.dismiss) private var dismiss
    @State private var reasons: [NLReason] = []
    @State private var selected: NLReason?
    @State private var note = ""
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ModSheetHeader(title: AppString("举报这个帖子"), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        reasonList
                        noteField
                        if let errorText {
                            Text(errorText)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(AppString("举报不会告诉对方是谁提交的。处理有结论时会通知你。"))
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .primaryToolbarAction(AppString("提交"), isEnabled: selected != nil && !isLoading, isWorking: isSubmitting) {
            Task { await submit() }
        }
        .task { await load() }
            }
    }

    private var reasonList: some View {
        VStack(spacing: 0) {
            ForEach(Array(reasons.enumerated()), id: \.element.id) { index, reason in
                Button {
                    selected = reason
                    errorText = nil
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.label)
                                .font(Theme.body(16, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            if let detail = reason.description, !detail.isEmpty {
                                Text(detail)
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if reason.isOther {
                                Text(AppString("在下面写清楚"))
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: selected == reason ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected == reason ? Theme.accent : Theme.textFaint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == reason ? .isSelected : [])
                if index < reasons.count - 1 {
                    Rectangle().fill(AdminTheme.separator).frame(height: 1).padding(.leading, 16)
                }
            }
        }
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous))
    }

    private var noteField: some View {
        TextField(
            selected?.isOther == true ? AppString("补充说明") : AppString("补充说明（可选）"),
            text: $note,
            axis: .vertical
        )
        .font(Theme.body(15))
        .lineLimit(3...6)
        .padding(14)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous)
                .strokeBorder(AdminTheme.separator, lineWidth: 1)
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            reasons = try await DiscourseClient().reportReasons()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit() async {
        guard let selected else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await DiscourseClient().reportPost(postID: postID, reason: selected.key, note: note)
            ToastCenter.shared.show(AppString("举报已提交"))
            dismiss()
        } catch {
            // 422 names the field; the message is the server's own words.
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 处理帖子和作者 (App-iOS-Moderate)

struct PostModerateSheet: View {
    let postID: Int
    let options: NLPostModerateOptions
    /// The author's registration and tier, when the caller knows them.
    var authorSubtitle: String?
    /// Told after a successful submit (the queue drops the item).
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var request = PostModerateRequest(postAction: "delete")
    @State private var reasons: [NLReason] = []
    @State private var reason: NLReason?
    @State private var otherText = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var conflict: NLPenaltyConflict?

    private var authorName: String { options.author?.username ?? "" }
    private var maxDays: Int { options.maxDays ?? 0 }
    private var reputationMax: Int { options.reputationPenaltyMax ?? 0 }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ModSheetHeader(title: AppString("处理帖子和作者"), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    postSection
                    if options.canPenalize != false, options.author != nil {
                        authorSection
                    }
                    if !request.postAction.isEmpty, reputationMax > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            ModSectionLabel(title: AppString("扣声望"))
                            ModReputationStepper(
                                value: $request.reputationPenalty,
                                maximum: reputationMax,
                                caption: AppString("最多 \(reputationMax)")
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ModSectionLabel(title: AppString("理由"), note: AppString("选项由服务端下发，对方会看到"))
                        ModReasonPicker(reasons: reasons, selected: $reason, otherText: $otherText)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ModPillButton(title: summary, style: .brick, height: 50) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .opacity(canSubmit ? 1 : 0.45)
                    Text(AppString("对方会收到带原因的通知。可以申诉。操作记入服务日志。"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .task {
            if options.hidden == true, request.postAction == "hide" { request.postAction = "" }
            if let list = try? await DiscourseClient().moderationReasonList() { reasons = list }
            if maxDays > 0, request.days > maxDays { request.days = maxDays }
        }
        .alert(conflictTitle, isPresented: conflictBinding, presenting: conflict) { _ in
            Button(AppString("延长到 \(extendedEnd)")) { resend("extend") }
            Button(AppString("替换为到 \(replacedEnd)")) { resend("replace") }
            Button(AppString("取消"), role: .cancel) {}
        } message: { conflict in
            Text(conflictMessage(conflict))
        }
            }
    }

    // MARK: Sections

    private var postSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModSectionLabel(title: AppString("帖子"), note: options.firstPost == true ? AppString("首帖：删除就是删除整个主题") : nil)
            AdminSegmented(selection: $request.postAction, options: [
                ("", AppString("不处理")),
                ("hide", options.hidden == true ? AppString("已隐藏") : AppString("隐藏")),
                ("delete", AppString("删除")),
            ])
            .disabled(isSubmitting)
        }
    }

    private var authorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModSectionLabel(
                title: AppString("作者 u/\(authorName)"),
                note: [authorSubtitle, options.isNodeScope ? options.node.map { AppString("仅 n/\($0)") } : nil]
                    .compactMap { $0 }.joined(separator: " · ")
            )
            AdminSegmented(selection: $request.userAction, options: [
                ("", AppString("不处罚")),
                ("silence", AppString("禁言")),
                ("suspend", AppString("封禁")),
            ])
            if !request.userAction.isEmpty {
                ModChoiceChips(
                    options: ModDuration.options(maxDays: maxDays),
                    selection: Binding(get: { request.days }, set: { request.days = $0 ?? 7 })
                )
            }
        }
    }

    // MARK: Rules

    private var reasonText: String { ModReasonPicker.reasonText(reason, other: otherText) }

    private var canSubmit: Bool {
        (!request.postAction.isEmpty || !request.userAction.isEmpty) && !reasonText.isEmpty
    }

    /// 删除帖子，禁言 7 天，扣 20 声望
    private var summary: String {
        var parts: [String] = []
        switch request.postAction {
        case "delete": parts.append(options.firstPost == true ? AppString("删除主题") : AppString("删除帖子"))
        case "hide": parts.append(AppString("隐藏帖子"))
        default: break
        }
        if !request.userAction.isEmpty {
            parts.append(ModDuration.phrase(kind: request.userAction, days: request.days))
        }
        if !request.postAction.isEmpty, request.reputationPenalty > 0 {
            parts.append(AppString("扣 \(request.reputationPenalty) 声望"))
        }
        return parts.isEmpty ? AppString("请选择处理方式") : parts.joined(separator: AppString("，"))
    }

    // MARK: Submit

    private func submit() async {
        var body = request
        body.reason = reasonText
        if request.postAction.isEmpty { body.reputationPenalty = 0 }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            let result = try await DiscourseClient().moderatePost(postID: postID, request: body)
            var parts: [String] = [AppString("已处理")]
            if let closed = result.closedItems?.count, closed > 1 { parts.append(AppString("关掉了 \(closed) 项")) }
            ToastCenter.shared.show(parts.joined(separator: " · "))
            onDone?()
            dismiss()
        } catch {
            if (error as? DiscourseError)?.serverCode == "penalty_exists", let found = NLPenaltyConflict.fromLastError() {
                conflict = found
                return
            }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func resend(_ choice: String) {
        request.onConflict = choice
        Task {
            await submit()
            request.onConflict = ""
        }
    }

    // MARK: Conflict (App-iOS-ModConflict)

    private var conflictBinding: Binding<Bool> {
        Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })
    }

    private var conflictTitle: String {
        let word = conflict?.existing?.kind == "suspend" || conflict?.existing?.kind == "ban" ? AppString("封禁") : AppString("禁言")
        return AppString("\(authorName)已经在\(word)中")
    }

    private func conflictMessage(_ conflict: NLPenaltyConflict) -> String {
        let days = request.days
        if conflict.permanent == true || conflict.existing?.endsAt == nil {
            return AppString("现有的处罚是永久的。替换是从现在重新算\(ModDuration.title(days))。")
        }
        let end = Self.dayText(conflict.existing?.endsAt ?? conflict.until)
        let left = Self.daysLeft(conflict.existing?.endsAt ?? conflict.until)
        return AppString("现有的到 \(end)，还有 \(left) 天。延长是把\(ModDuration.title(days))接在后面，替换是从现在重新算\(ModDuration.title(days))。")
    }

    /// max(existing end, now + days), as the server computes 延长.
    private var extendedEnd: String {
        guard request.days > 0 else { return AppString("永久") }
        let now = Date()
        let mine = now.addingTimeInterval(Double(request.days) * 86_400)
        guard let existing = DiscourseFormat.date(conflict?.existing?.endsAt ?? conflict?.until) else {
            return conflict?.permanent == true ? AppString("永久") : Self.format(mine)
        }
        return Self.format(max(existing, mine))
    }

    private var replacedEnd: String {
        guard request.days > 0 else { return AppString("永久") }
        return Self.format(Date().addingTimeInterval(Double(request.days) * 86_400))
    }

    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(AppLanguage.resolved.locale))
    }

    static func dayText(_ string: String?) -> String {
        DiscourseFormat.date(string).map(format) ?? "—"
    }

    static func daysLeft(_ string: String?) -> Int {
        guard let date = DiscourseFormat.date(string) else { return 0 }
        return max(0, Int(ceil(date.timeIntervalSinceNow / 86_400)))
    }
}

// MARK: - 处罚 u/名字 (App-iOS-Ban, App-iOS-BanConfirm)

/// A penalty on a person: site-wide (`admin.users`) or inside one node.
struct PenaltySheet: View {
    struct Target: Identifiable {
        let userID: Int
        let username: String
        /// 注册 3 天 · 白银, when known.
        var subtitle: String?
        /// Offered as 仅 n/slug when the reader manages it.
        var nodeSlug: String?
        /// Whether 全站 is offered (needs `admin.users`).
        var allowsSite = true
        var id: Int { userID }
    }

    let target: Target
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var siteWide = true
    @State private var kind = "silence"
    @State private var days = 7
    @State private var reasons: [NLReason] = []
    @State private var reason: NLReason?
    @State private var otherText = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var confirmingPermanent = false
    @State private var confirmText = ""
    @State private var conflict: NLPenaltyConflict?

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            ModSheetHeader(title: AppString("处罚 u/\(target.username)"), onCancel: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if target.allowsSite, let slug = target.nodeSlug {
                        VStack(alignment: .leading, spacing: 10) {
                            ModSectionLabel(title: AppString("范围"))
                            AdminSegmented(selection: $siteWide, options: [
                                (true, AppString("全站")),
                                (false, AppString("仅 n/\(slug)")),
                            ])
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ModSectionLabel(title: AppString("处罚"), note: target.subtitle)
                        AdminSegmented(selection: $kind, options: [
                            ("", AppString("不处罚")),
                            ("silence", AppString("禁言")),
                            ("suspend", AppString("封禁")),
                        ])
                        if !kind.isEmpty {
                            ModChoiceChips(
                                options: ModDuration.options(maxDays: isNodeScope ? 0 : 0),
                                selection: Binding(get: { days }, set: { days = $0 ?? 7 })
                            )
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ModSectionLabel(title: AppString("理由"), note: AppString("选项由服务端下发，对方会看到"))
                        ModReasonPicker(reasons: reasons, selected: $reason, otherText: $otherText)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ModPillButton(title: summary, style: .brick, height: 50) {
                        if kind == "suspend", days == 0, siteWide || target.nodeSlug == nil {
                            confirmText = ""
                            confirmingPermanent = true
                        } else {
                            Task { await submit(onConflict: nil) }
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                    .opacity(canSubmit ? 1 : 0.45)
                    Text(AppString("对方会收到带原因的通知。可以申诉。操作记入服务日志。"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .task {
            siteWide = target.allowsSite || target.nodeSlug == nil
            if let list = try? await DiscourseClient().moderationReasonList() { reasons = list }
        }
        // App-iOS-BanConfirm: typing 封禁 is the confirmation.
        .alert(AppString("永久封禁\(target.username)？"), isPresented: $confirmingPermanent) {
            TextField(AppString("输入“封禁”以确认"), text: $confirmText)
            Button(AppString("取消"), role: .cancel) {}
            Button(AppString("封禁"), role: .destructive) {
                Task { await submit(onConflict: nil) }
            }
            .disabled(confirmText.trimmingCharacters(in: .whitespaces) != AppString("封禁"))
        } message: {
            Text(AppString("这个账号将不能再登录 nodeloc。封禁可以在操作日志里撤销，对方也可以申诉。"))
        }
        .alert(AppString("\(target.username)已经在\(kind == "suspend" ? AppString("封禁") : AppString("禁言"))中"),
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { _ in
            Button(AppString("延长")) { Task { await submit(onConflict: "extend") } }
            Button(AppString("替换")) { Task { await submit(onConflict: "replace") } }
            Button(AppString("取消"), role: .cancel) {}
        } message: { conflict in
            Text(conflict.message ?? "")
        }
            }
    }

    private var isNodeScope: Bool { !siteWide && target.nodeSlug != nil }

    private var reasonText: String { ModReasonPicker.reasonText(reason, other: otherText) }

    private var canSubmit: Bool { !kind.isEmpty && !reasonText.isEmpty }

    private var summary: String {
        guard !kind.isEmpty else { return AppString("请选择处罚") }
        return ModDuration.phrase(kind: kind, days: days)
    }

    private func submit(onConflict: String?) async {
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        let client = DiscourseClient()
        do {
            if isNodeScope, let slug = target.nodeSlug {
                try await client.restrictInNode(
                    slug: slug,
                    username: target.username,
                    type: kind == "suspend" ? "ban" : "mute",
                    reason: reasonText,
                    days: days,
                    onConflict: onConflict
                )
            } else {
                try await client.penalizeUser(
                    id: target.userID,
                    type: kind,
                    reason: reasonText,
                    hours: days * 24,
                    onConflict: onConflict
                )
            }
            ToastCenter.shared.show(AppString("已\(summary)"))
            onDone?()
            dismiss()
        } catch {
            if (error as? DiscourseError)?.serverCode == "penalty_exists", let found = NLPenaltyConflict.fromLastError() {
                conflict = found
                return
            }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
