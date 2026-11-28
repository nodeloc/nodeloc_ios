//
//  ReviewDetailPages.swift
//  nodeloc
//
//  One review item in full, per kind:
//
//  - an AI verdict on a post (App-iOS-QueueAI): the post, the verdict and
//    its reason, 经过 (the author's edits and each re-judgement), how to
//    choose;
//  - an appeal (App-iOS-QueueAppeal): who, the penalty or removal appealed,
//    their words, and a reply they will read on their account status page;
//  - everything else (App-iOS-Report): the post, the reports, the author's
//    record, and 处理帖子和作者 into the handling dialog.
//

import SwiftUI

/// Picks the page for the item's kind.
struct ReviewItemDetailRouter: View {
    let item: NLReviewQueue.Item
    let store: ReviewQueueStore
    /// Opens the penalty form for an account (成立，去处理).
    var onPenalize: (PenaltySheet.Target) -> Void = { _ in }

    var body: some View {
        if item.isAIPost {
            AIReviewDetailPage(item: item, store: store)
        } else if item.kind.contains("appeal") {
            AppealReviewDetailPage(item: item, store: store)
        } else {
            ReportReviewDetailPage(item: item, store: store, onPenalize: onPenalize)
        }
    }
}

// MARK: - Shared pieces

/// The bottom of a detail page: two buttons, then a row of quieter ones.
private struct ReviewDetailBar: View {
    let primary: [ReviewActionSet.Decision]
    let secondary: [ReviewActionSet.Decision]
    let onDecide: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(AdminTheme.separator).frame(height: 1)
            HStack(spacing: 10) {
                ForEach(primary, id: \.action) { decision in
                    ModPillButton(title: decision.title, style: decision.style, height: 48) {
                        onDecide(decision.action)
                    }
                }
            }
            .padding(.horizontal, AdminTheme.inset)
            if !secondary.isEmpty {
                HStack(spacing: 0) {
                    ForEach(secondary, id: \.action) { decision in
                        Button {
                            onDecide(decision.action)
                        } label: {
                            Text(decision.title)
                                .font(Theme.body(14, weight: .bold))
                                .foregroundStyle(decision.style == .brickOutline ? AdminTone.orange.text : Theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
            }
        }
        .padding(.bottom, 6)
        .background(AdminTheme.card)
    }
}

/// The post as the item shows it: author, title, text.
private struct ReviewPostCard: View {
    let item: NLReviewQueue.Item
    var lineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let name = item.targetUsername ?? AppString("系统")
                AdminLetterAvatar(letter: String(name.prefix(1)).uppercased(), color: reviewAvatarColor(name), size: 28)
                Text(verbatim: "u/\(name)")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let detail = ReviewCard.authorDetail(item) {
                    Text(verbatim: "· \(detail)")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if item.isTopicPost == true, let title = item.topicTitle, !title.isEmpty {
                Text(title)
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let body = item.postHtml.map { DiscourseFormat.plainTextParagraphs($0) } ?? ""
            if !body.isEmpty {
                Text(body)
                    .font(Theme.body(15))
                    .foregroundStyle(lineLimit == nil ? Theme.text : Theme.textMuted)
                    .lineSpacing(3)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
            }
            if item.isTopicPost == false, let topic = item.topicTitle, !topic.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.system(size: 14))
                    Text(AppString("回复于《\(topic)》"))
                        .font(Theme.body(14))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(AdminTheme.pageBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Settles the item from a detail page and closes it when that worked.
@MainActor
private func settle(
    _ item: NLReviewQueue.Item,
    _ action: String,
    note: String? = nil,
    store: ReviewQueueStore,
    dismiss: DismissAction
) {
    Task {
        if await store.resolve(item, action: action, note: note) { dismiss() }
    }
}

// MARK: - AI verdict (App-iOS-QueueAI)

struct AIReviewDetailPage: View {
    let item: NLReviewQueue.Item
    let store: ReviewQueueStore

    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var hiding = false
    @State private var pending: PendingReviewDecision?

    private var isPending: Bool { (item.status ?? store.status) == "pending" }
    private var isRule: Bool { item.aiVerdict == "rule" }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("AI 判定"), onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        ReviewPostCard(item: item, lineLimit: 3)
                        HStack(spacing: 6) {
                            AdminBadge(text: item.isTopicPost == false ? AppString("回复") : AppString("主题"))
                            if item.aiHidden {
                                AdminBadge(text: AppString("已隐藏"), tone: .amber, icon: "eye.slash")
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                    }
                    ReviewAIBox(item: item)
                    timeline
                    if isPending {
                        Text(isRule
                             ? AppString("怎么选：确实违规点“复核无误”，帖子继续隐藏，作者改好后会自动恢复；AI 判错了点“不成立”，帖子恢复显示并通知作者。")
                             : AppString("怎么选：是垃圾内容点“删除”，这时才给作者记风控信号；不是就点“不成立”，帖子恢复显示，因这一帖记的信号一并撤销。"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    } else {
                        settledNote
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            if isPending, item.ownAction != true {
                ReviewDetailBar(
                    primary: isRule
                        ? [.init(action: "reject", title: AppString("不成立，恢复显示"), style: .outline),
                           .init(action: "confirm", title: AppString("复核无误"), style: .ink)]
                        : [.init(action: "reject", title: AppString("不成立"), style: .outline),
                           .init(action: "delete_post", title: AppString("删除"), style: .brick)],
                    secondary: isRule
                        ? [.init(action: "delete_post", title: AppString("删除内容"), style: .brickOutline),
                           .init(action: "hide_post", title: AppString("改为管理员隐藏"), style: .outline),
                           .init(action: "ignore", title: AppString("忽略"), style: .outline)]
                        : [.init(action: "hide_post", title: AppString("隐藏"), style: .outline),
                           .init(action: "ignore", title: AppString("忽略"), style: .outline)]
                ) { action in
                    switch action {
                    case "delete_post": deleting = true
                    case "hide_post": hiding = true
                    default: pending = PendingReviewDecision(item: item, action: action)
                    }
                }
                .disabled(store.busyIDs.contains(item.id))
            }
        }
        .background(AdminTheme.pageBg)
        .sheet(isPresented: $deleting) {
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                title: item.isTopicPost == true ? AppString("删除主题") : AppString("删除回复"),
                onConfirm: { penalty, note in
                    if await store.resolve(item, action: "delete_post", note: note, reputationPenalty: penalty) { dismiss() }
                }
            )
        }
        .sheet(isPresented: $hiding) {
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                title: item.isTopicPost == true ? AppString("隐藏主题") : AppString("隐藏回复"),
                action: "hide_post",
                onConfirm: { penalty, note in
                    if await store.resolve(item, action: "hide_post", note: note, reputationPenalty: penalty) { dismiss() }
                }
            )
        }
        .reviewDecisionConfirmation($pending) { decision in
            settle(decision.item, decision.action, store: store, dismiss: dismiss)
        }
    }

    /// 经过: the verdict, then every edit and re-judgement, oldest first.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppString("经过"))
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 10)
            let entries = timelineEntries
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(entry.tone == .neutral ? Theme.textMuted : entry.tone.text)
                            .frame(width: 9, height: 9)
                            .padding(.top, 5)
                        if index < entries.count - 1 {
                            Rectangle().fill(AdminTheme.separator).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.title)
                                .font(Theme.body(14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 8)
                            Text(entry.time)
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.textMuted)
                        }
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, index < entries.count - 1 ? 14 : 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private struct Entry {
        let title: String
        let detail: String?
        let time: String
        let tone: AdminTone
    }

    private var timelineEntries: [Entry] {
        var entries: [Entry] = [Entry(
            title: isRule ? AppString("AI 判定：违反发帖规则") : AppString("AI 判定：垃圾内容"),
            detail: item.aiHidden
                ? (isRule ? AppString("帖子隐藏，作者收到带原因的通知") : AppString("帖子隐藏"))
                : AppString("只送审，帖子照常显示"),
            time: Self.clock(item.createdAt),
            tone: .amber
        )]
        for event in item.history ?? [] {
            switch event.action {
            case "author_edit":
                entries.append(Entry(title: AppString("作者编辑了帖子"), detail: event.note, time: Self.clock(event.createdAt), tone: .neutral))
            case "rejudge_ok":
                entries.append(Entry(title: AppString("重新判定：通过，已恢复显示"), detail: nil, time: Self.clock(event.createdAt), tone: .green))
            case "rejudge_rule":
                entries.append(Entry(title: AppString("重新判定：仍不符合"), detail: event.note, time: Self.clock(event.createdAt), tone: .amber))
            case "rejudge_spam":
                entries.append(Entry(title: AppString("重新判定：垃圾内容"), detail: event.note, time: Self.clock(event.createdAt), tone: .orange))
            default:
                break
            }
        }
        if item.resolution == "author_fixed" {
            entries.append(Entry(
                title: AppString("作者改好了，重新判定通过，已恢复显示"), detail: nil,
                time: Self.clock(item.resolvedAt), tone: .green
            ))
        }
        return entries
    }

    /// 10:24 today, 11月26日 otherwise.
    static func clock(_ string: String?) -> String {
        guard let date = DiscourseFormat.date(string) else { return "" }
        return Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute().locale(AppLanguage.resolved.locale))
            : date.formatted(.dateTime.month().day().locale(AppLanguage.resolved.locale))
    }

    private var settledNote: some View {
        let parts = [item.resolvedBy, ReviewDecisions.resolutionTitle(item.resolution),
                     item.resolvedAt.map { ModerationTime.ago($0) }].compactMap { $0 }.filter { !$0.isEmpty }
        return Text(parts.joined(separator: " · "))
            .font(Theme.body(13))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 4)
    }
}

// MARK: - Appeal (App-iOS-QueueAppeal)

struct AppealReviewDetailPage: View {
    let item: NLReviewQueue.Item
    let store: ReviewQueueStore

    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var pending: PendingReviewDecision?

    private var isPending: Bool { (item.status ?? store.status) == "pending" }
    private var isContent: Bool { item.kind == "content_appeal" }

    private var title: String {
        switch item.kind {
        case "content_appeal": AppString("内容申诉")
        case "node_restriction_appeal": AppString("节点处罚申诉")
        default: AppString("处罚申诉")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: title, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    userCard
                    appealedCard
                    appealText
                    if isPending, item.ownAction != true {
                        VStack(alignment: .leading, spacing: 8) {
                            ModSectionLabel(title: AppString("给用户的答复"), note: AppString("会显示在对方的账号状态页"))
                            TextField(AppString("写一句处理说明"), text: $reply, axis: .vertical)
                                .font(Theme.body(15))
                                .lineLimit(3...6)
                                .padding(14)
                                .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(AdminTheme.separator, lineWidth: 1)
                                }
                        }
                    } else {
                        let parts = item.ownAction == true && isPending
                            ? [AppString("这是对你自己做出的处罚的申诉，需要其他管理人员处理")]
                            : [item.resolvedBy, ReviewDecisions.resolutionTitle(item.resolution),
                               item.resolvedAt.map { ModerationTime.ago($0) }].compactMap { $0 }.filter { !$0.isEmpty }
                        Text(parts.joined(separator: " · "))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            if isPending, item.ownAction != true {
                ReviewDetailBar(
                    primary: isContent
                        ? [.init(action: "uphold", title: AppString("维持处理"), style: .outline),
                           .init(action: "restore", title: AppString("恢复显示"), style: .ink)]
                        : [.init(action: "uphold", title: AppString("维持处罚"), style: .outline),
                           .init(action: "lift", title: AppString("解除处罚"), style: .ink)],
                    secondary: [.init(action: "ignore", title: AppString("忽略"), style: .outline)]
                ) { action in
                    pending = PendingReviewDecision(item: item, action: action)
                }
                .disabled(store.busyIDs.contains(item.id))
            }
        }
        .background(AdminTheme.pageBg)
        .reviewDecisionConfirmation($pending) { decision in
            let note = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            settle(item, decision.action, note: note.isEmpty ? nil : note, store: store, dismiss: dismiss)
        }
    }

    private var userCard: some View {
        HStack(spacing: 10) {
            let name = item.targetUsername ?? AppString("系统")
            AdminLetterAvatar(letter: String(name.prefix(1)).uppercased(), color: reviewAvatarColor(name), size: 28)
            Text(verbatim: "u/\(name)")
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let detail = ReviewCard.authorDetail(item) {
                Text(verbatim: "· \(detail)")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let reported = item.author?.timesReported, reported > 0 {
                AdminBadge(text: AppString("被举报 \(reported) 次"))
            }
        }
        .padding(14)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 被申诉的处罚: 禁言 7 天 · 风控 / 到 12 月 4 日 10:24，还有 6 天 / 原因
    private var appealedCard: some View {
        let payload = item.payload
        let heading: String
        var lines: [String] = []
        if isContent {
            heading = ReviewAppealWording.removalTitle(payload?["removal_kind"]?.string)
            if let at = DiscourseFormat.date(payload?["removed_at"]?.string) {
                lines.append(AppString("处理于 \(at.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.resolved.locale)))"))
            }
            if let reason = payload?["removal_reason"]?.string, !reason.isEmpty {
                lines.append(AppString("原因：\(reason)"))
            }
        } else {
            let type = payload?["type"]?.string ?? ""
            var parts = [ReviewAppealWording.penaltyTitle(type: type, payload: payload)]
            if let by = payload?["by"]?.string { parts.append(ReviewAppealWording.byTitle(by)) }
            if let node = payload?["node_name"]?.string ?? payload?["node_slug"]?.string { parts.append(node) }
            heading = parts.joined(separator: " · ")
            // A far-future end is how some penalties store "permanent".
            if let ends = DiscourseFormat.date(payload?["ends_at"]?.string), ends.timeIntervalSinceNow < 100 * 365 * 86_400 {
                let left = max(0, Int(ceil(ends.timeIntervalSinceNow / 86_400)))
                lines.append(AppString("到 \(ends.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.resolved.locale)))，还有 \(left) 天"))
            } else if type == "reset" || type == "restrict" {
                lines.append(AppString("等待处理"))
            } else {
                lines.append(AppString("永久"))
            }
            if let reason = payload?["reason"]?.string, !reason.isEmpty {
                lines.append(AppString("原因：\(reason)"))
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(isContent ? AppString("被申诉的处理") : AppString("被申诉的处罚"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            Text(heading)
                .font(Theme.body(17, weight: .bold))
                .foregroundStyle(Theme.text)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var appealText: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let kind = item.payload?["kind"]?.string, !isContent {
                    AdminBadge(text: ReviewAppealWording.appealKind(kind), tone: .purple, icon: "scalemass")
                } else {
                    AdminBadge(text: AppString("申诉"), tone: .purple, icon: "scalemass")
                }
                Text(AppString("\(ModerationTime.ago(item.createdAt))提交"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            Text(item.payload?["text"]?.string ?? "")
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Report and the rest (App-iOS-Report)

struct ReportReviewDetailPage: View {
    let item: NLReviewQueue.Item
    let store: ReviewQueueStore
    var onPenalize: (PenaltySheet.Target) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var hiding = false
    @State private var pending: PendingReviewDecision?
    @State private var moderate: ModerateRequest?
    @State private var isOpeningModerate = false

    private struct ModerateRequest: Identifiable {
        let id = UUID()
        let postID: Int
        let options: NLPostModerateOptions
    }

    private var isPending: Bool { (item.status ?? store.status) == "pending" }

    private var title: String {
        switch item.kind {
        case "pending_post": AppString("待审帖子")
        case "risk_flag": AppString("风险账号")
        default: AppString("举报详情")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: title, onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ReviewPostCard(item: item)
                    if !item.matchedWords.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(item.matchedWords, id: \.self) { word in AdminBadge(text: word, tone: .orange) }
                        }
                    }
                    if let reports = item.reports, !reports.isEmpty {
                        reportsSection(reports)
                    }
                    if let author = item.author {
                        authorCard(author)
                    }
                    if !isPending || item.ownAction == true {
                        let parts = [item.resolvedBy, ReviewDecisions.resolutionTitle(item.resolution),
                                     item.resolvedAt.map { ModerationTime.ago($0) }].compactMap { $0 }.filter { !$0.isEmpty }
                        Text(item.ownAction == true && isPending
                             ? AppString("这是对你自己做出的处罚的申诉，需要其他管理人员处理")
                             : parts.joined(separator: " · "))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            if isPending, item.ownAction != true {
                bar
                    .disabled(store.busyIDs.contains(item.id) || isOpeningModerate)
            }
        }
        .background(AdminTheme.pageBg)
        .sheet(isPresented: $deleting) {
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                title: item.isTopicPost == true ? AppString("删除主题") : AppString("删除回复"),
                onConfirm: { penalty, note in
                    if await store.resolve(item, action: "delete_post", note: note, reputationPenalty: penalty) { dismiss() }
                }
            )
        }
        .sheet(isPresented: $hiding) {
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                title: item.isTopicPost == true ? AppString("隐藏主题") : AppString("隐藏回复"),
                action: "hide_post",
                onConfirm: { penalty, note in
                    if await store.resolve(item, action: "hide_post", note: note, reputationPenalty: penalty) { dismiss() }
                }
            )
        }
        .reviewDecisionConfirmation($pending) { decision in
            perform(decision)
        }
        .sheet(item: $moderate) { request in
            PostModerateSheet(
                postID: request.postID,
                options: request.options,
                authorSubtitle: ReviewCard.authorDetail(item),
                onDone: {
                    Task { await store.load() }
                    dismiss()
                }
            )
            .standardSheet([.large])
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch item.kind {
        case "report" where item.targetType == "post" || item.postNumber != nil:
            ReviewDetailBar(
                primary: [.init(action: "reject", title: AppString("不成立"), style: .outline),
                          .init(action: "moderate", title: AppString("处理帖子和作者"), style: .brick)],
                secondary: [.init(action: "delete_post", title: AppString("只删除内容"), style: .brickOutline),
                            .init(action: "hide_post", title: AppString("只隐藏"), style: .outline),
                            .init(action: "ignore", title: AppString("忽略"), style: .outline)],
                onDecide: decide
            )
        default:
            let set = ReviewActionSet.for(item)
            if !set.primary.isEmpty {
                ReviewDetailBar(primary: set.primary, secondary: set.more, onDecide: decide)
            }
        }
    }

    /// Removing or hiding content goes through the reason and reputation
    /// sheet; everything else asks first.
    private func decide(_ action: String) {
        switch action {
        case "delete_post":
            deleting = true
        case "hide_post":
            hiding = true
        case "moderate":
            openModerate()
        default:
            pending = PendingReviewDecision(item: item, action: action)
        }
    }

    private func perform(_ decision: PendingReviewDecision) {
        if decision.action == "confirm", item.isRiskAccount {
            Task {
                if await store.resolve(item, action: "confirm"), let id = item.targetUserId {
                    dismiss()
                    onPenalize(PenaltySheet.Target(userID: id, username: item.targetUsername ?? "", subtitle: ReviewCard.authorDetail(item)))
                }
            }
        } else {
            settle(item, decision.action, store: store, dismiss: dismiss)
        }
    }

    /// 处理帖子和作者: the server says what the reader may do with the post.
    private func openModerate() {
        guard let postID = item.targetId else { return }
        isOpeningModerate = true
        Task {
            defer { isOpeningModerate = false }
            do {
                let options = try await DiscourseClient().postModerateOptions(postID: postID)
                moderate = ModerateRequest(postID: postID, options: options)
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    /// 6 人举报 · 广告推广 5 · 垃圾信息 1, then one row per report.
    private func reportsSection(_ reports: [NLReviewQueue.Report]) -> some View {
        var tally: [(String, Int)] = []
        for report in reports {
            let label = report.reasonLabel ?? report.reason ?? AppString("其他")
            if let index = tally.firstIndex(where: { $0.0 == label }) { tally[index].1 += 1 } else { tally.append((label, 1)) }
        }
        let header = ([AppString("\(item.reportCount ?? reports.count) 人举报")] + tally.map { "\($0.0) \($0.1)" })
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(reports.enumerated()), id: \.offset) { index, report in
                    let name = report.reporter ?? AppString("匿名")
                    HStack(spacing: 12) {
                        AdminLetterAvatar(letter: String(name.prefix(1)).uppercased(), color: reviewAvatarColor(name), size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(name) · \(report.reasonLabel ?? report.reason ?? "")")
                                .font(Theme.body(16))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            let detail = [report.note.flatMap { $0.isEmpty ? nil : "“\($0)”" },
                                          ModerationTime.ago(report.createdAt)].compactMap { $0 }.filter { !$0.isEmpty }
                            if !detail.isEmpty {
                                Text(detail.joined(separator: " · "))
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    if index < reports.count - 1 {
                        Rectangle().fill(AdminTheme.separator).frame(height: 1).padding(.leading, 56)
                    }
                }
            }
            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// 作者情况: account age, posts, removed, reported.
    private func authorCard(_ author: NLReviewQueue.Author) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppString("作者情况"))
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
            HStack(spacing: 0) {
                stat(ModerationTime.accountAge(author.createdAt) ?? "–", AppString("注册"), alert: false)
                stat(author.posts.map(String.init) ?? "–", AppString("发帖"), alert: false)
                stat(author.deletedPosts.map(String.init) ?? "–", AppString("被删"), alert: (author.deletedPosts ?? 0) > 0)
                stat(author.timesReported.map(String.init) ?? "–", AppString("被举报"), alert: (author.timesReported ?? 0) > 0)
            }
        }
        .padding(14)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ value: String, _ label: String, alert: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.body(20, weight: .bold))
                .foregroundStyle(alert ? AdminTone.orange.text : Theme.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
