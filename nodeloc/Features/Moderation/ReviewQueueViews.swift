//
//  ReviewQueueViews.swift
//  nodeloc
//
//  The review queue after the risk-control scheme's artboards
//  (App-iOS-Queue, -Queue2, -QueueAI, -QueueAppeal, -Report):
//
//  - chips by what an item is: 全部 · AI 判定 · 待审 · 举报 · 申诉, counted
//    from `kind_counts`;
//  - one card per item with its own decisions: an AI rule verdict is 不成立 /
//    复核无误, a held post 删除 / 通过, a report 不成立 / 隐藏 / 删除, an
//    appeal 维持 / 解除处罚 (恢复显示); the rest under ⋯;
//  - the AI's reason and confidence on the card, and what happened since
//    (the author's edits and each re-judgement);
//  - 作者改好了，重新判定通过，已恢复显示 across the top for the items the
//    system closed itself (`author_fixed`).
//
//  Every decision is the server's `resolve` with the action named in
//  docs/specs/mobile-api.md and risk-control.md; nothing is decided here.
//

import SwiftUI

// MARK: - Categories

/// The chips: what an item is, coarser than `kind`.
enum ReviewCategory: String, CaseIterable, Identifiable {
    case all, ai, held, reports, appeals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppString("全部")
        case .ai: AppString("AI 判定")
        case .held: AppString("待审")
        case .reports: AppString("举报")
        case .appeals: AppString("申诉")
        }
    }

    static func of(_ kind: String) -> ReviewCategory {
        if kind.contains("appeal") { return .appeals }
        switch kind {
        case "risk_flag": return .ai
        case "pending_post": return .held
        default: return .reports
        }
    }

    init(_ group: ReviewGroup) {
        switch group {
        case .review: self = .all
        case .reports: self = .reports
        case .appeals: self = .appeals
        }
    }
}

extension NLReviewQueue.Item {
    var category: ReviewCategory { ReviewCategory.of(kind) }

    /// A risk-control verdict on a post (`risk_flag`, `target_type = post`).
    var isAIPost: Bool { kind == "risk_flag" && targetType == "post" }
    /// A risk-control account item (`risk_flag`, `target_type = user`).
    var isRiskAccount: Bool { kind == "risk_flag" && targetType != "post" }
    /// `rule` (breaks the posting rules) or `spam`; old items have no verdict
    /// and count as spam.
    var aiVerdict: String { payload?["verdict"]?.string ?? "spam" }
    var aiReason: String? { payload?["reason"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    var aiConfidence: Int? { payload?["confidence"]?.int }
    /// `review` only queued it (still showing); `auto` hid it.
    var aiHidden: Bool { postHidden == true || payload?["mode"]?.string != "review" }
}

// MARK: - Page

struct ReviewQueuePage: View {
    let onClose: () -> Void

    @State private var store: ReviewQueueStore
    @State private var category: ReviewCategory
    /// The item whose detail is pushed. A Hashable wrapper so the push is an
    /// `item` destination: one value, one page, cleared by the system back.
    @State private var detailRoute: DetailRoute?
    /// The notification's item is opened once per page. `.task` runs again
    /// every time the queue reappears — after backing out of that very
    /// detail — and without this it pushed the detail again, so back looped.
    @State private var focusConsumed = false

    private struct DetailRoute: Hashable, Identifiable {
        let item: NLReviewQueue.Item
        var id: Int { item.id }
        static func == (lhs: DetailRoute, rhs: DetailRoute) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    @State private var deleteRequest: DeleteRequest?
    @State private var pendingDecision: PendingReviewDecision?
    @State private var penaltyTarget: PenaltySheet.Target?
    @State private var fixed: [NLReviewQueue.Item] = []
    /// The item a notification pointed at, opened once the queue is up.
    private let focusItem: Int?

    /// 删除 or 隐藏, through the reason and reputation sheet.
    private struct DeleteRequest: Identifiable {
        let id = UUID()
        let item: NLReviewQueue.Item
        var action = "delete_post"
    }

    init(
        scope: DiscourseClient.ReviewScope,
        initialGroup: ReviewGroup = .review,
        focusItem: Int? = nil,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.focusItem = focusItem
        _store = State(initialValue: ReviewQueueStore(scope: scope))
        _category = State(initialValue: ReviewCategory(initialGroup))
    }

    private let statuses = ["pending", "approved", "rejected", "ignored"]
    private var isPending: Bool { store.status == "pending" }

    private var visible: [NLReviewQueue.Item] {
        category == .all ? store.items : store.items.filter { $0.category == category }
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("审核队列"), onBack: onClose) {
                statusMenu
            }
            chips
            content
        }
        .background(AdminTheme.pageBg)
        .task {
            await store.load()
            await openFocusItem()
            await loadFixed()
        }
        .navigationDestination(item: $detailRoute) { route in
            ReviewItemDetailRouter(item: route.item, store: store) { target in
                penaltyTarget = target
            }
        }
        .sheet(item: $deleteRequest) { request in
            ReputationPenaltySheet(
                maximum: store.reputationPenaltyMax ?? 0,
                title: Self.sheetTitle(request.action, isTopic: request.item.isTopicPost == true),
                action: request.action,
                onConfirm: { penalty, note in
                    await store.resolve(request.item, action: request.action, note: note, reputationPenalty: penalty)
                }
            )
        }
        .reviewDecisionConfirmation($pendingDecision) { decision in
            perform(decision.item, decision.action)
        }
        .sheet(item: $penaltyTarget) { target in
            PenaltySheet(target: target)
                .standardSheet([.large])
        }
    }

    // MARK: Header

    private var statusMenu: some View {
        Menu {
            Picker(AppString("状态"), selection: Binding(
                get: { store.status },
                set: { value in Task { await store.load(status: value) } }
            )) {
                ForEach(statuses, id: \.self) { value in
                    Text(Self.statusTitle(value)).tag(value)
                }
            }
        } label: {
            // The system bar draws the glass; a circle of its own doubled it.
            BarIcon(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel(AppString("筛选状态"))
    }

    static func statusTitle(_ value: String) -> String {
        switch value {
        case "approved": AppString("已成立")
        case "rejected": AppString("不成立")
        case "ignored": AppString("已忽略")
        default: AppString("待处理")
        }
    }

    private func count(_ category: ReviewCategory) -> Int {
        if store.kindCounts.isEmpty {
            return category == .all ? store.items.count : store.items.filter { $0.category == category }.count
        }
        if category == .all { return store.kindCounts.values.reduce(0, +) }
        return store.kindCounts.filter { ReviewCategory.of($0.key) == category }.values.reduce(0, +)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !isPending {
                    // Looking at settled items: the way back to the live queue.
                    Button {
                        Task { await store.load(status: "pending") }
                    } label: {
                        HStack(spacing: 5) {
                            Text(Self.statusTitle(store.status))
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        }
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(AdminTone.green.text)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(AdminTone.green.fill, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
                ForEach(ReviewCategory.allCases) { option in
                    let selected = option == category
                    Button {
                        withAnimation(.quicker) { category = option }
                    } label: {
                        Text(verbatim: "\(option.title) \(count(option))")
                            .font(Theme.body(14, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? Theme.bg : Theme.text)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(selected ? Theme.text : .clear, in: Capsule())
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
            .padding(.horizontal, AdminTheme.inset)
        }
        .scrollClipDisabled()
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.items.isEmpty {
            AdminStatePlaceholder(isLoading: true)
            Spacer(minLength: 0)
        } else if let errorText = store.errorText, store.items.isEmpty {
            AdminStatePlaceholder(isLoading: false, errorText: errorText) {
                Task { await store.load() }
            }
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isPending, category == .all || category == .ai {
                        ForEach(fixed) { item in fixedBanner(item) }
                    }
                    ForEach(visible) { item in
                        ReviewCard(
                            item: item,
                            isPending: isPending,
                            isBusy: store.busyIDs.contains(item.id),
                            onOpen: { detailRoute = DetailRoute(item: item) },
                            onDecide: { decide(item, $0) },
                            onRefund: { Task { await store.refundReputation(item) } }
                        )
                    }
                    if visible.isEmpty, !store.hasMore {
                        emptyState
                    }
                    if store.hasMore {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .task(id: store.items.count) { await store.loadMore() }
                    }
                }
                .padding(.horizontal, AdminTheme.inset)
                .padding(.bottom, 24)
            }
            .refreshable {
                await store.load()
                await loadFixed()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AdminTone.green.text)
            Text(isPending ? AppString("没有待处理的项") : AppString("暂无内容"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    /// 作者改好了，重新判定通过，已恢复显示 · n/dev · 刚刚
    private func fixedBanner(_ item: NLReviewQueue.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
            Text(AppString("作者改好了，重新判定通过，已恢复显示"))
                .font(Theme.body(14))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text([item.nodeSlug.map { "n/\($0)" }, ModerationTime.ago(item.resolvedAt)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.body(12))
                .opacity(0.8)
                .lineLimit(1)
        }
        .foregroundStyle(AdminTone.green.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AdminTone.green.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Opens the item a notification named, whatever its status: settled
    /// ones show how they were settled. A node's item the reader can only
    /// reach site-wide (staff) is tried there too.
    private func openFocusItem() async {
        guard let focusItem, !focusConsumed else { return }
        focusConsumed = true
        let client = DiscourseClient()
        var scopes = [store.scope]
        if case .node = store.scope { scopes.append(.site) }
        var lastError: Error?
        for scope in scopes {
            do {
                let queue = try await client.reviewQueue(scope, item: focusItem)
                if let item = queue.items.first {
                    // Let the queue's own push finish first: a second push
                    // in the same moment was dropped, leaving a page that
                    // never came up.
                    try? await Task.sleep(for: .milliseconds(450))
                    detailRoute = DetailRoute(item: item)
                    return
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            ToastCenter.shared.showError(lastError)
        } else {
            ToastCenter.shared.show(AppString("这一项已经不在队列里了"))
        }
    }

    /// The items the system closed in the last day because the author fixed
    /// the post and the re-judgement passed.
    private func loadFixed() async {
        guard let queue = try? await DiscourseClient().reviewQueue(store.scope, status: "approved", kind: "risk_flag", limit: 10)
        else { return }
        let day = Date().addingTimeInterval(-86_400)
        fixed = Array(queue.items.filter {
            $0.resolution == "author_fixed" && (DiscourseFormat.date($0.resolvedAt) ?? .distantPast) > day
        }.prefix(2))
    }

    // MARK: Decisions

    static func sheetTitle(_ action: String, isTopic: Bool) -> String {
        if action == "hide_post" { return isTopic ? AppString("隐藏主题") : AppString("隐藏回复") }
        return isTopic ? AppString("删除主题") : AppString("删除回复")
    }

    /// Removing or hiding content goes through the reason and reputation
    /// sheet; every other decision asks first. Nothing is sent on one tap.
    private func decide(_ item: NLReviewQueue.Item, _ action: String) {
        switch action {
        case "delete_post", "hide_post":
            deleteRequest = DeleteRequest(item: item, action: action)
        default:
            pendingDecision = PendingReviewDecision(item: item, action: action)
        }
    }

    private func perform(_ item: NLReviewQueue.Item, _ action: String) {
        switch action {
        case "confirm" where item.isRiskAccount:
            // 成立，去处理: record the finding, then the penalty form.
            Task {
                if await store.resolve(item, action: "confirm"), let id = item.targetUserId {
                    penaltyTarget = PenaltySheet.Target(
                        userID: id,
                        username: item.targetUsername ?? "",
                        subtitle: ReviewCard.authorDetail(item)
                    )
                }
            }
        default:
            Task { await store.resolve(item, action: action) }
        }
    }
}

// MARK: - Card

struct ReviewCard: View {
    let item: NLReviewQueue.Item
    let isPending: Bool
    var isBusy = false
    let onOpen: () -> Void
    let onDecide: (String) -> Void
    var onRefund: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    topRow
                        .padding(.bottom, 10)
                    authorRow
                    textBlock
                        .padding(.top, 8)
                    if item.isAIPost {
                        ReviewAIBox(item: item)
                            .padding(.top, 10)
                    }
                    if let history = Self.historySummary(item) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12))
                            Text(history)
                                .font(Theme.body(12))
                                .lineLimit(2)
                        }
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 8)
                    }
                    let tags = Self.holdTags(item)
                    if !tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                                AdminBadge(text: tag.text, tone: tag.tone)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            actions
                .padding(.top, 12)
        }
        .padding(14)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isBusy ? 0.5 : 1)
        .disabled(isBusy)
    }

    // MARK: Header

    private var topRow: some View {
        HStack(spacing: 8) {
            let badge = Self.badge(item)
            AdminBadge(text: badge.text, tone: badge.tone, icon: badge.icon)
                .layoutPriority(1)
            Text(Self.meta(item))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AdminTheme.chevron)
        }
    }

    private var authorRow: some View {
        HStack(spacing: 8) {
            let name = item.targetUsername ?? AppString("系统")
            AdminLetterAvatar(letter: String(name.prefix(1)).uppercased(), color: reviewAvatarColor(name), size: 24)
            Text(verbatim: "u/\(name)")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let detail = Self.authorDetail(item) {
                Text(verbatim: "· \(detail)")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var textBlock: some View {
        let preview = item.previewText
        if item.isTopicPost != false, let title = item.topicTitle, !title.isEmpty, !item.kind.contains("appeal") {
            Text(title)
                .font(Theme.body(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        } else if !preview.isEmpty {
            Text(preview)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .lineLimit(item.kind.contains("appeal") ? 2 : 3)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if !isPending {
            settled
        } else if item.ownAction == true {
            note(AppString("这是对你自己做出的处罚的申诉，需要其他管理人员处理"))
        } else {
            let set = ReviewActionSet.for(item)
            if set.primary.isEmpty {
                note(AppString("这一项需要在对应的管理页面处理"))
            } else {
                HStack(spacing: 8) {
                    ForEach(set.primary, id: \.action) { decision in
                        ModPillButton(title: decision.title, style: decision.style) { onDecide(decision.action) }
                    }
                    if !set.more.isEmpty {
                        ModMoreMenu {
                            ForEach(set.more, id: \.action) { decision in
                                Button(role: decision.style == .brickOutline ? .destructive : nil) {
                                    onDecide(decision.action)
                                } label: {
                                    Text(decision.title)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var settled: some View {
        let parts = [item.resolvedBy, ReviewDecisions.resolutionTitle(item.resolution),
                     item.resolvedAt.map { ModerationTime.ago($0) }].compactMap { $0 }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            if !parts.isEmpty { note(parts.joined(separator: " · ")) }
            if item.payload?["reputation_penalty"]?.int ?? 0 > 0,
               item.payload?["reputation_refunded"] != .bool(true), let onRefund {
                ModPillButton(title: AppString("只返还声望"), style: .grey, action: onRefund)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(13))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Wording

    static func badge(_ item: NLReviewQueue.Item) -> (text: String, tone: AdminTone, icon: String) {
        if item.isAIPost {
            return item.aiVerdict == "rule"
                ? (AppString("AI · 违反发帖规则"), .amber, "cpu")
                : (AppString("AI · 垃圾内容"), .orange, "cpu")
        }
        switch item.kind {
        case "risk_flag": return (AppString("风险账号"), .orange, "exclamationmark.triangle")
        case "pending_post": return (AppString("待审帖子"), .blue, "hourglass")
        case "content_appeal": return (AppString("内容申诉"), .purple, "scalemass")
        case "penalty_appeal": return (AppString("处罚申诉"), .purple, "scalemass")
        case "node_restriction_appeal": return (AppString("节点处罚申诉"), .purple, "scalemass")
        case "link_report": return (AppString("链接举报"), .amber, "link")
        case "node_report": return (AppString("节点举报"), .amber, "flag")
        default:
            let count = item.reportCount ?? item.reports?.count ?? 0
            return (count > 0 ? AppString("举报 · \(count) 人") : AppString("举报"), .amber, "flag")
        }
    }

    /// The muted line after the badge.
    static func meta(_ item: NLReviewQueue.Item) -> String {
        var parts: [String] = []
        let node = item.nodeSlug.flatMap { $0.isEmpty ? nil : "n/\($0)" }
        let post: String? = item.isTopicPost.map { $0 ? AppString("主题") : AppString("回复") }
        switch item.kind {
        case "risk_flag" where item.isAIPost:
            parts += [node, post].compactMap { $0 }
            parts.append(item.aiHidden ? AppString("已隐藏") : AppString("没有隐藏，只等复核"))
        case "risk_flag":
            parts.append(AppString("风控"))
            if let level = item.payload?["level"]?.int { parts.append(AppString("处置到第 \(level) 级")) }
        case "pending_post":
            parts += [node, post].compactMap { $0 }
            if item.isNewcomerHold { parts.append(AppString("新注册账号")) }
            if item.holdCode == "observed" { parts.append(AppString("观察中")) }
        case "penalty_appeal", "node_restriction_appeal":
            if let type = item.payload?["type"]?.string {
                parts.append(ReviewAppealWording.penaltyTitle(type: type, payload: item.payload))
            }
            if let by = item.payload?["by"]?.string { parts.append(ReviewAppealWording.byTitle(by)) }
            if let kind = item.payload?["kind"]?.string { parts.append(ReviewAppealWording.appealKind(kind)) }
        case "content_appeal":
            parts.append(ReviewAppealWording.removalTitle(item.payload?["removal_kind"]?.string))
        default:
            parts += [node, post].compactMap { $0 }
            var tally: [(String, Int)] = []
            for report in item.reports ?? [] {
                let label = report.reasonLabel ?? report.reason ?? AppString("其他")
                if let index = tally.firstIndex(where: { $0.0 == label }) { tally[index].1 += 1 } else { tally.append((label, 1)) }
            }
            parts += tally.prefix(2).map { "\($0.0) \($0.1)" }
        }
        let time = ModerationTime.ago(item.createdAt)
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    /// 注册 3 天 · 白银
    static func authorDetail(_ item: NLReviewQueue.Item) -> String? {
        var parts: [String] = []
        if let age = ModerationTime.accountAge(item.author?.createdAt) { parts.append(AppString("注册 \(age)")) }
        if let tier = item.author?.tierName, !tier.isEmpty { parts.append(tier) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 作者 10:41 改过一次，重新判定仍不符合
    static func historySummary(_ item: NLReviewQueue.Item) -> String? {
        guard let history = item.history, !history.isEmpty else { return nil }
        let edits = history.filter { $0.action == "author_edit" }
        let last = history.last { $0.action.hasPrefix("rejudge_") }
        var text = ""
        if let edit = edits.last, let date = DiscourseFormat.date(edit.createdAt) {
            let time = date.formatted(.dateTime.hour().minute().locale(AppLanguage.resolved.locale))
            text = edits.count == 1 ? AppString("作者 \(time) 改过一次") : AppString("作者改过 \(edits.count) 次，最近 \(time)")
        }
        if let last {
            let result: String
            switch last.action {
            case "rejudge_ok": result = AppString("重新判定通过")
            case "rejudge_rule": result = AppString("重新判定仍不符合")
            default: result = AppString("重新判定为垃圾内容")
            }
            text = text.isEmpty ? result : text + AppString("，") + result
        }
        return text.isEmpty ? nil : text
    }

    /// The held post's reasons, kept from the old cards.
    static func holdTags(_ item: NLReviewQueue.Item) -> [(text: String, tone: AdminTone)] {
        guard item.kind == "pending_post" else { return [] }
        var tags: [(String, AdminTone)] = []
        if item.hasExternalLinks { tags.append((AppString("含外链"), .amber)) }
        if item.isKeywordHold { tags.append((AppString("命中关键词"), .orange)) }
        if item.holdCode == "channel" { tags.append((AppString("频道同步"), .neutral)) }
        if item.holdCode == nil, let reason = item.payload?["reason"]?.string, !reason.isEmpty {
            tags.append((reason, .neutral))
        }
        return tags
    }
}

/// The AI's verdict: what it found, how sure, and its one sentence.
struct ReviewAIBox: View {
    let item: NLReviewQueue.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                Text(item.aiVerdict == "rule" ? AppString("AI 判定：违反发帖规则") : AppString("AI 判定：垃圾内容"))
                    .font(Theme.body(13, weight: .bold))
                Spacer(minLength: 6)
                if let confidence = item.aiConfidence {
                    Text(AppString("置信度 \(confidence)"))
                        .font(Theme.body(13, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(AdminTone.amber.text)
            Text(item.aiReason ?? AppString("原因暂时取不到"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Action sets

/// What each kind of item can be settled with, per the specs, split into the
/// card's buttons and its ⋯.
struct ReviewActionSet {
    struct Decision {
        let action: String
        let title: String
        let style: ModPillButton.Style
    }

    var primary: [Decision] = []
    var more: [Decision] = []

    static func `for`(_ item: NLReviewQueue.Item) -> ReviewActionSet {
        switch item.kind {
        case "risk_flag" where item.isAIPost && item.aiVerdict == "rule":
            return ReviewActionSet(
                primary: [.init(action: "reject", title: AppString("不成立"), style: .outline),
                          .init(action: "confirm", title: AppString("复核无误"), style: .ink)],
                more: [.init(action: "delete_post", title: AppString("删除内容"), style: .brickOutline),
                       .init(action: "hide_post", title: AppString("改为管理员隐藏"), style: .outline),
                       .init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        case "risk_flag" where item.isAIPost:
            return ReviewActionSet(
                primary: [.init(action: "reject", title: AppString("不成立"), style: .outline),
                          .init(action: "delete_post", title: AppString("删除"), style: .brickOutline)],
                more: [.init(action: "hide_post", title: AppString("隐藏"), style: .outline),
                       .init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        case "risk_flag":
            return ReviewActionSet(primary: [
                .init(action: "ignore", title: AppString("忽略"), style: .outline),
                .init(action: "confirm", title: AppString("成立，去处理"), style: .ink),
            ])
        case "pending_post":
            return ReviewActionSet(primary: [
                .init(action: "delete_post", title: AppString("删除"), style: .brickOutline),
                .init(action: "approve", title: AppString("通过"), style: .green),
            ])
        case "content_appeal":
            return ReviewActionSet(
                primary: [.init(action: "uphold", title: AppString("维持"), style: .outline),
                          .init(action: "restore", title: AppString("恢复显示"), style: .ink)],
                more: [.init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        case "penalty_appeal", "node_restriction_appeal":
            return ReviewActionSet(
                primary: [.init(action: "uphold", title: AppString("维持"), style: .outline),
                          .init(action: "lift", title: AppString("解除处罚"), style: .ink)],
                more: [.init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        case "link_report":
            return ReviewActionSet(
                primary: [.init(action: "reject", title: AppString("不成立"), style: .outline),
                          .init(action: "flag_link", title: AppString("标为不安全"), style: .brickOutline)],
                more: [.init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        case "report":
            return ReviewActionSet(
                primary: [.init(action: "reject", title: AppString("不成立"), style: .outline),
                          .init(action: "hide_post", title: AppString("隐藏"), style: .grey),
                          .init(action: "delete_post", title: AppString("删除"), style: .brickOutline)],
                more: [.init(action: "ignore", title: AppString("忽略"), style: .outline)]
            )
        default:
            return ReviewActionSet()
        }
    }
}

// MARK: - Appeal wording

enum ReviewAppealWording {
    /// 禁言 7 天 (from the penalty's start and end), or 永久封禁.
    static func penaltyTitle(type: String, payload: JSONValue?) -> String {
        let word: String
        switch type {
        case "suspend", "ban": word = AppString("封禁")
        case "reset": word = AppString("清零")
        case "restrict": word = AppString("限制")
        default: word = AppString("禁言")
        }
        guard let ends = DiscourseFormat.date(payload?["ends_at"]?.string), ends.timeIntervalSinceNow < 100 * 365 * 86_400 else {
            return type == "reset" || type == "restrict" ? word : AppString("永久\(word)")
        }
        guard let starts = DiscourseFormat.date(payload?["started_at"]?.string) else { return word }
        let days = max(1, Int((ends.timeIntervalSince(starts) / 86_400).rounded()))
        return AppString("\(word) \(days) 天")
    }

    static func byTitle(_ by: String) -> String {
        switch by {
        case "risk": AppString("风控")
        case "staff": AppString("管理员")
        case "node_owner": AppString("节点主")
        case "node_moderator": AppString("节点版主")
        default: by
        }
    }

    static func appealKind(_ kind: String) -> String {
        kind == "will_improve" ? AppString("我会改") : AppString("判错了")
    }

    static func removalTitle(_ kind: String?) -> String {
        switch kind {
        case "hide": AppString("管理员隐藏")
        case "topic": AppString("主题被删除")
        default: AppString("帖子被删除")
        }
    }
}

/// A steady colour per name for the letter avatars.
func reviewAvatarColor(_ name: String) -> Color {
    let palette: [UInt32] = [0x8A4FFF, 0xC2185B, 0xE8590C, 0x2B8A80, 0x1F5FBF, 0x007A52, 0xD9822B]
    let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return Color(hex: palette[abs(sum) % palette.count])
}
