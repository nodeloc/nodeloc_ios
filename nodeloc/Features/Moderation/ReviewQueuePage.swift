//
//  ReviewQueuePage.swift
//  nodeloc
//
//  审核队列 — the site-wide queue for staff, and a node's own queue for its
//  owner and moderators. Both endpoints answer the same shape, so one page
//  serves both and only the scope differs.
//
//  Two things are deliberately the server's call rather than this page's:
//
//  - How much reputation this reader may take in one go arrives as
//    `reputationPenaltyMax` (1000 with the site-wide permission, 20 for
//    someone who is only a node's owner or moderator). Hard-coding either
//    would produce a picker whose top entries always 422.
//  - Whether an item can be acted on at all: `ownAction` marks an appeal
//    against the reader's own penalty, which only a site administrator may
//    settle.
//
//  Layout follows the App-iOS-Queue artboard: a segmented 待审核 / 举报 / 申诉
//  over filter chips, one white card per item with 拒绝 / 通过, swipe actions,
//  and long-press multi-select. The server only filters by a single `kind`,
//  so the three groups (each several kinds) are split on this side from the
//  status's list, and their counts come from `kind_counts`.
//

import SwiftUI

// MARK: - Shared vocabulary (also used by the dashboard)

/// The three tabs of the queue, each a family of the server's kinds.
enum ReviewGroup: String, CaseIterable, Identifiable {
    /// Posts held before publishing, and risk flags.
    case review
    /// Reports on posts, links, nodes…
    case reports
    /// Content, penalty and node-restriction appeals.
    case appeals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: AppString("待审核")
        case .reports: AppString("举报")
        case .appeals: AppString("申诉")
        }
    }

    static func of(_ kind: String) -> ReviewGroup {
        if kind.contains("appeal") { return .appeals }
        if kind == "pending_post" || kind == "risk_flag" { return .review }
        return .reports
    }
}

/// The chips under the segmented control. All three read the hold details
/// a `pending_post` carries since 2026-11-25 (`reason_code`, `has_links`,
/// `matched_words`); items held before that only have the sentence.
enum ReviewTagFilter: String, CaseIterable, Identifiable {
    case all, newcomer, links, keywords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppString("全部")
        case .newcomer: AppString("新用户")
        case .links: AppString("含外链")
        case .keywords: AppString("命中关键词")
        }
    }

    func matches(_ item: NLReviewQueue.Item) -> Bool {
        switch self {
        case .all: true
        case .newcomer: item.isNewcomerHold || item.author?.trustLevel == 0
        case .links: item.hasExternalLinks
        case .keywords: item.isKeywordHold
        }
    }
}

extension NLReviewQueue.Item {
    var reviewGroup: ReviewGroup { ReviewGroup.of(kind) }

    /// Why a pending post was held (content/service.go `Hold…`).
    var holdCode: String? { payload?["reason_code"]?.string }
    var isNewcomerHold: Bool { holdCode == "newcomer" }
    var hasExternalLinks: Bool { payload?["has_links"] == .bool(true) }
    var matchedWords: [String] {
        guard case .array(let words)? = payload?["matched_words"] else { return [] }
        return words.compactMap(\.string)
    }
    var isKeywordHold: Bool { holdCode == "watched_word" || !matchedWords.isEmpty }

    /// True for a topic's first post, false for a reply, nil when the item
    /// isn't about a post at all.
    var isTopicPost: Bool? {
        guard targetType == "post" || postNumber != nil else { return nil }
        return (postNumber ?? 1) <= 1
    }

    /// The text the card previews: the post, or an appeal's own words.
    var previewText: String {
        if let html = postHtml, !html.isEmpty { return DiscourseFormat.plainText(html) }
        if let text = payload?["text"]?.string, !text.isEmpty { return text }
        return payload?["reason"]?.string ?? ""
    }
}

/// The Chinese relative times the artboards use (刚刚, 48 分钟前,
/// 2 小时 10 分前), which `DiscourseFormat.relative`'s "2h" doesn't give.
enum ModerationTime {
    static func ago(_ string: String?) -> String {
        guard let date = DiscourseFormat.date(string) else { return "" }
        return ago(date)
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(max(0, Date().timeIntervalSince(date)) / 60)
        if minutes < 1 { return AppString("刚刚") }
        if minutes < 60 { return AppString("\(minutes) 分钟前") }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? AppString("\(hours) 小时前") : AppString("\(hours) 小时 \(rest) 分前")
        }
        let days = hours / 24
        if days < 7 { return AppString("\(days) 天前") }
        return date.formatted(.dateTime.month().day().locale(AppLanguage.resolved.locale))
    }

    /// How long something has waited: 12 分钟, 2 小时, 3 天.
    static func span(since date: Date) -> String {
        let minutes = max(1, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 60 { return AppString("\(minutes) 分钟") }
        let hours = minutes / 60
        if hours < 48 { return AppString("\(hours) 小时") }
        return AppString("\(hours / 24) 天")
    }

    /// An account's age for "注册 2 天": 天 under a month, then 个月, then 年.
    static func accountAge(_ string: String?) -> String? {
        guard let date = DiscourseFormat.date(string) else { return nil }
        let days = max(0, Int(Date().timeIntervalSince(date) / 86_400))
        if days < 1 { return AppString("今天") }
        if days < 31 { return AppString("\(days) 天") }
        if days < 365 { return AppString("\(days / 30) 个月") }
        return AppString("\(days / 365) 年")
    }
}

// MARK: - Store

@MainActor
@Observable
final class ReviewQueueStore {
    private let client = DiscourseClient()

    let scope: DiscourseClient.ReviewScope

    private(set) var items: [NLReviewQueue.Item] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var kindCounts: [String: Int] = [:]
    /// What this reader may take per decision. Nil until the first load, and
    /// 0 would mean "may not deduct at all".
    private(set) var reputationPenaltyMax: Int?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorText: String?
    private(set) var busyIDs: Set<Int> = []
    var status = "pending"
    private var nextBefore: Int?
    /// Bumped by every fresh load, so a slow answer for a filter the reader
    /// has already left can't land on top of the new one.
    private var generation = 0

    init(scope: DiscourseClient.ReviewScope) {
        self.scope = scope
    }

    var hasMore: Bool { nextBefore != nil }

    func load(status: String? = nil) async {
        if let status, status != self.status {
            self.status = status
            items = []
            kindCounts = [:]
            nextBefore = nil
        }
        generation += 1
        let current = generation
        isLoading = items.isEmpty
        errorText = nil
        defer { if current == generation { isLoading = false } }
        do {
            let queue = try await client.reviewQueue(scope, status: self.status)
            guard current == generation else { return }
            items = queue.items
            counts = queue.counts ?? [:]
            kindCounts = queue.kindCounts ?? [:]
            reputationPenaltyMax = queue.reputationPenaltyMax
            nextBefore = queue.nextBefore
        } catch {
            guard current == generation, !(error is CancellationError) else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoading, !isLoadingMore else { return }
        let current = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let queue = try? await client.reviewQueue(scope, status: status, before: before),
              current == generation else { return }
        let known = Set(items.map(\.id))
        items += queue.items.filter { !known.contains($0.id) }
        nextBefore = queue.nextBefore
    }

    /// Items of one group under the current status — `kind_counts` when the
    /// server sent them, otherwise what has loaded.
    func count(of group: ReviewGroup) -> Int {
        if !kindCounts.isEmpty {
            return kindCounts.filter { ReviewGroup.of($0.key) == group }.values.reduce(0, +)
        }
        return items.filter { $0.reviewGroup == group }.count
    }

    func visibleItems(group: ReviewGroup, filter: ReviewTagFilter) -> [NLReviewQueue.Item] {
        items.filter { $0.reviewGroup == group && filter.matches($0) }
    }

    /// Settles an item and drops it from the list — it no longer belongs under
    /// the current filter.
    @discardableResult
    func resolve(
        _ item: NLReviewQueue.Item,
        action: String,
        note: String? = nil,
        reputationPenalty: Int? = nil,
        announce: Bool = true
    ) async -> Bool {
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            try await client.resolveReviewItem(
                scope, id: item.id, action: action, note: note, reputationPenalty: reputationPenalty
            )
            withAnimation(.quicker) { items.removeAll { $0.id == item.id } }
            if let pending = counts["pending"], pending > 0 { counts["pending"] = pending - 1 }
            if let left = kindCounts[item.kind], left > 0 { kindCounts[item.kind] = left - 1 }
            if announce { ToastCenter.shared.show(AppString("已处理")) }
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// Several decisions in a row (multi-select). Stops reporting after the
    /// first failure's toast; the rest still run.
    func resolveAll(_ decisions: [(NLReviewQueue.Item, String)], note: String?, reputationPenalty: Int?) async {
        var done = 0
        for (item, action) in decisions {
            // The server takes a penalty only alongside a finding against the
            // author; sending it with anything else is 422.
            let penalty = ["delete_post", "hide_post", "confirm"].contains(action) ? reputationPenalty : nil
            if await resolve(item, action: action, note: note, reputationPenalty: penalty, announce: false) {
                done += 1
            }
        }
        if done > 0 { ToastCenter.shared.show(AppString("已处理 \(done) 项")) }
    }

    /// Returns reputation without touching the decision or the post.
    func refundReputation(_ item: NLReviewQueue.Item) async {
        do {
            let refunded = try await client.refundReviewReputation(scope, id: item.id)
            ToastCenter.shared.show(AppString("已返还 \(refunded) 声望"))
            await load()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

// MARK: - Decisions

/// One way to settle an item.
struct ReviewDecision: Hashable {
    let action: String
    let title: String
    /// Finds against the author or the content.
    let destructive: Bool
}

enum ReviewDecisions {
    /// Which decisions this kind of item accepts. Appeals are upheld or not;
    /// everything else is founded or not.
    static func all(for item: NLReviewQueue.Item) -> [ReviewDecision] {
        switch item.kind {
        case "content_appeal":
            [.init(action: "ignore", title: AppString("忽略"), destructive: false),
             .init(action: "uphold", title: AppString("维持原处理"), destructive: true),
             .init(action: "restore", title: AppString("恢复内容"), destructive: false)]
        case "penalty_appeal", "node_restriction_appeal":
            [.init(action: "ignore", title: AppString("忽略"), destructive: false),
             .init(action: "uphold", title: AppString("维持原处罚"), destructive: true),
             .init(action: "lift", title: AppString("解除处罚"), destructive: false)]
        case "pending_post":
            [.init(action: "delete_post", title: AppString("删除"), destructive: true),
             .init(action: "approve", title: AppString("通过"), destructive: false)]
        case "link_report":
            [.init(action: "ignore", title: AppString("忽略"), destructive: false),
             .init(action: "flag_link", title: AppString("标为不安全"), destructive: true),
             .init(action: "reject", title: AppString("不成立"), destructive: false)]
        case "risk_flag" where item.targetType != "post":
            // An account the risk system already acted on: the decision only
            // records whether it was right.
            [.init(action: "ignore", title: AppString("忽略"), destructive: false),
             .init(action: "confirm", title: AppString("成立"), destructive: true)]
        case "report", "risk_flag":
            // A post report. "Unfounded" also puts an auto-hidden post back.
            [.init(action: "reject", title: AppString("不成立"), destructive: false),
             .init(action: "hide_post", title: AppString("隐藏"), destructive: true),
             .init(action: "delete_post", title: AppString("删除"), destructive: true)]
        default:
            []
        }
    }

    /// The card's 拒绝 / 通过 pair: 通过 lets the content (or the appeal)
    /// stand, 拒绝 finds against it. Nil for kinds handled elsewhere.
    static func pair(for item: NLReviewQueue.Item) -> (reject: String, approve: String)? {
        switch item.kind {
        case "pending_post": ("delete_post", "approve")
        case "content_appeal": ("uphold", "restore")
        case "penalty_appeal", "node_restriction_appeal": ("uphold", "lift")
        case "link_report": ("flag_link", "reject")
        case "risk_flag" where item.targetType != "post": ("confirm", "ignore")
        case "report", "risk_flag": ("delete_post", "reject")
        default: nil
        }
    }

    static func canAct(on item: NLReviewQueue.Item) -> Bool {
        item.ownAction != true && pair(for: item) != nil
    }

    static func resolutionTitle(_ resolution: String?) -> String? {
        guard let resolution, !resolution.isEmpty else { return nil }
        switch resolution {
        case "approve": return AppString("已通过")
        case "delete_post": return AppString("已删除")
        case "hide_post": return AppString("已隐藏")
        case "reject": return AppString("举报不成立")
        case "ignore": return AppString("已忽略")
        case "restore": return AppString("已恢复内容")
        case "lift": return AppString("已解除处罚")
        case "uphold": return AppString("维持原处理")
        case "confirm": return AppString("判定成立")
        case "flag_link": return AppString("链接标为不安全")
        case "author_fixed": return AppString("作者改好了，重新判定通过，已恢复显示")
        case "restore_post": return AppString("已恢复帖子")
        case "false_positive": return AppString("误判")
        case "lenient": return AppString("从宽")
        case "post_rejected": return AppString("帖子判为不成立")
        default: return resolution
        }
    }

    static func kindTitle(_ item: NLReviewQueue.Item) -> String {
        if let topic = item.isTopicPost, item.kind == "pending_post" || item.kind == "report" || item.kind == "risk_flag" {
            return topic ? AppString("主题") : AppString("回复")
        }
        switch item.kind {
        case "content_appeal": return AppString("内容申诉")
        case "penalty_appeal": return AppString("处罚申诉")
        case "node_restriction_appeal": return AppString("节点处罚申诉")
        case "risk_flag": return AppString("风控")
        case "link_report": return AppString("链接")
        case "node_report": return AppString("节点")
        default: return AppString("举报")
        }
    }

    /// The tinted badges under a card: 新用户首帖, 含外链, 命中关键词, 6 人举报 …
    static func tags(for item: NLReviewQueue.Item) -> [(text: String, tone: AdminTone)] {
        var tags: [(String, AdminTone)] = []
        if item.priority == true { tags.append((AppString("优先处理"), .orange)) }
        if item.isNewcomerHold {
            tags.append(((item.author?.posts ?? 0) <= 1 ? AppString("新用户首帖") : AppString("新用户"), .blue))
        }
        if item.hasExternalLinks { tags.append((AppString("含外链"), .amber)) }
        if item.isKeywordHold { tags.append((AppString("命中关键词"), .orange)) }
        switch item.holdCode {
        case "observed": tags.append((AppString("观察中"), .purple))
        case "channel": tags.append((AppString("频道同步"), .neutral))
        default: break
        }
        // An item held before the codes existed only has the sentence.
        if item.kind == "pending_post", item.holdCode == nil,
           let reason = item.payload?["reason"]?.string, !reason.isEmpty {
            tags.append((reason, .neutral))
        }
        if let reports = item.reportCount, reports > 0 {
            tags.append((AppString("\(reports) 人举报"), .orange))
            let reasons = (item.reports ?? []).compactMap { $0.reasonLabel ?? $0.reason }
            var seen = Set<String>()
            for reason in reasons where seen.insert(reason).inserted && seen.count <= 2 {
                tags.append((reason, .neutral))
            }
        }
        if item.kind == "risk_flag" { tags.append((AppString("风控"), .purple)) }
        return tags
    }
}

/// Badges that wrap onto a second line instead of running off the card.
private struct ReviewTagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Delete sheet (App-iOS-Delete)

/// Deleting through the queue takes a reason the author sees and may also
/// cost the author reputation. The cap comes from the queue response — the
/// reader's own standing decides it — and "don't deduct" is the default.
struct ReputationPenaltySheet: View {
    let maximum: Int
    var title: String = AppString("删除")
    var confirmTitle: String?
    /// `delete_post` or `hide_post`: both take a reason the author sees and
    /// an optional deduction (`POST …/review/{id}/resolve`).
    var action: String = "delete_post"
    let onConfirm: (Int?, String?) async -> Void

    @State private var penalty = 0
    @State private var reasons: [String] = []
    @State private var reason: String?
    @State private var note = ""
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    /// The web's presets, minus any the reader's cap puts out of reach.
    private var presets: [Int] { [5, 10, 20, 50, 100].filter { $0 <= maximum } }

    /// What the server stores as the decision's note: the picked reason,
    /// then the reader's own words.
    private var composedNote: String? {
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (reason, extra.isEmpty) {
        case (let reason?, true): return reason
        case (let reason?, false): return "\(reason)：\(extra)"
        case (nil, false): return extra
        case (nil, true): return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.horizontal, 90)
                HStack {
                    Button(AppString("取消")) { dismiss() }
                        .font(Theme.body(17))
                        .foregroundStyle(AdminTone.green.text)
                    Spacer()
                }
            }
            .padding(.horizontal, AdminTheme.inset)
            .frame(height: 56)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !reasons.isEmpty {
                        AdminSection(title: action == "hide_post" ? AppString("隐藏理由（作者会看到）") : AppString("删除理由（作者会看到）")) {
                            ForEach(Array(reasons.enumerated()), id: \.element) { index, value in
                                AdminRow(
                                    title: value,
                                    showsChevron: false,
                                    isLast: index == reasons.count - 1,
                                    action: { reason = reason == value ? nil : value }
                                ) {
                                    if reason == value {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(AdminTone.green.text)
                                    }
                                }
                            }
                        }
                    }

                    TextField(reasons.isEmpty ? AppString("处理理由（可选）") : AppString("补充说明（可选）"), text: $note, axis: .vertical)
                        .font(Theme.body(17))
                        .lineLimit(1...4)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.listRadius, style: .continuous))
                        .padding(.horizontal, AdminTheme.inset)

                    if maximum > 0 {
                        AdminSection(footer: AppString("每次最多扣 \(maximum) 声望；扣除的声望之后可以在审核队列里返还。")) {
                            Menu {
                                Button(AppString("不扣")) { penalty = 0 }
                                ForEach(presets, id: \.self) { value in
                                    Button(AppString("扣 \(value) 声望")) { penalty = value }
                                }
                            } label: {
                                AdminRow(
                                    title: AppString("同时扣除作者声望"),
                                    value: penalty == 0 ? AppString("不扣") : AppString("\(penalty) 声望"),
                                    isLast: true
                                ) {
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AdminTheme.chevron)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    AdminActionButton(
                        // The summary of what will happen: 隐藏帖子，扣 20 声望.
                        title: confirmTitle ?? (penalty > 0 ? AppString("\(title)，扣 \(penalty) 声望") : title),
                        icon: action == "hide_post" ? "eye.slash" : "trash",
                        solid: Color(hex: 0xA33A00),
                        height: 50
                    ) {
                        guard !isSubmitting else { return }
                        Task {
                            isSubmitting = true
                            await onConfirm(penalty > 0 ? penalty : nil, composedNote)
                            isSubmitting = false
                            dismiss()
                        }
                    }
                    .opacity(isSubmitting ? 0.6 : 1)
                    .overlay {
                        if isSubmitting { ProgressView().tint(.white) }
                    }
                    .padding(.horizontal, AdminTheme.inset)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(AdminTheme.pageBg)
        .presentationDragIndicator(.visible)
        .task {
            // The site's configured picklist; without it the free-text field
            // alone carries the reason.
            if reasons.isEmpty, let list = try? await DiscourseClient().moderationReasons() {
                reasons = list
            }
        }
    }
}


// MARK: - One-tap decisions, confirmed

/// A decision that doesn't remove or hide content, waiting for 确认.
struct PendingReviewDecision: Identifiable {
    let item: NLReviewQueue.Item
    let action: String
    var id: String { "\(item.id)-\(action)" }

    /// What the confirmation says will happen.
    var copy: (title: String, message: String, destructive: Bool) {
        let isRule = item.kind == "risk_flag" && item.targetType == "post"
        switch action {
        case "reject" where isRule:
            return (AppString("不成立，恢复显示？"), AppString("帖子恢复显示并通知作者。"), false)
        case "reject":
            return (AppString("判定举报不成立？"), AppString("帖子保持显示；如果它被自动隐藏，会恢复显示。"), false)
        case "ignore":
            return (AppString("忽略这一项？"), AppString("不做处理，这一项移出待处理。"), false)
        case "approve":
            return (AppString("通过这个帖子？"), AppString("帖子会公开显示。"), false)
        case "confirm" where item.isRiskAccount:
            return (AppString("判定成立？"), AppString("记为成立，接着填写对账号的处罚。"), true)
        case "confirm":
            return (AppString("复核无误？"), AppString("帖子继续隐藏，作者改好后会自动恢复。"), true)
        case "uphold":
            return (AppString("维持原处理？"), AppString("申诉被驳回，原处理不变，作者会收到通知。"), true)
        case "restore":
            return (AppString("恢复显示？"), AppString("内容恢复显示，作者会收到通知。"), false)
        case "lift":
            return (AppString("解除处罚？"), AppString("处罚立即解除，作者会收到通知。"), false)
        case "flag_link":
            return (AppString("标为不安全？"), AppString("这个链接会被标为不安全。"), true)
        default:
            return (AppString("确定这样处理？"), "", false)
        }
    }

    var confirmTitle: String {
        switch action {
        case "reject": AppString("不成立")
        case "ignore": AppString("忽略")
        case "approve": AppString("通过")
        case "confirm": item.isRiskAccount ? AppString("成立") : AppString("复核无误")
        case "uphold": AppString("维持")
        case "restore": AppString("恢复显示")
        case "lift": AppString("解除处罚")
        case "flag_link": AppString("标为不安全")
        default: AppString("确定")
        }
    }
}

extension View {
    /// The native confirmation for a pending one-tap decision.
    func reviewDecisionConfirmation(
        _ pending: Binding<PendingReviewDecision?>,
        perform: @escaping (PendingReviewDecision) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue?.copy.title ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { decision in
            Button(decision.confirmTitle, role: decision.copy.destructive ? .destructive : nil) { perform(decision) }
            Button(AppString("取消"), role: .cancel) {}
        } message: { decision in
            if !decision.copy.message.isEmpty { Text(decision.copy.message) }
        }
    }
}
