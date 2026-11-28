//
//  ModerationDashboardPage.swift
//  nodeloc
//
//  管理台 — the front page of moderation: what is waiting and how long it has
//  waited, the few items worth doing first, what was done today, and the way
//  into the queue and the log. Site-wide for staff, one node's for its owner
//  and moderators — and, for someone who manages several nodes, all of them
//  at once (全部节点) or one at a time, as on the App-iOS-Dash artboard.
//
//  There is no dashboard endpoint. Everything here is read from the review
//  queue and the moderation log (and `/me/nodes` for the node chips), so the
//  numbers always agree with the pages they open.
//

import SwiftUI

@MainActor
@Observable
final class ModerationDashboardStore {
    private let client = DiscourseClient()

    /// The scope the dashboard was opened for.
    let scope: DiscourseClient.ReviewScope

    /// What the chips select: the opening scope, one managed node, or every
    /// managed node together.
    enum Selection: Hashable {
        case scope(DiscourseClient.ReviewScope)
        case allNodes
    }

    /// A pending item and the queue it lives in.
    struct Pending: Identifiable {
        let scope: DiscourseClient.ReviewScope
        let item: NLReviewQueue.Item
        var id: String { "\(scope)-\(item.id)" }
    }

    /// One scope's share of the numbers.
    private struct Slice {
        let scope: DiscourseClient.ReviewScope
        var items: [NLReviewQueue.Item] = []
        var total = 0
        var kindCounts: [String: Int] = [:]
        /// Every pending item was read (the oldest wait is exact).
        var complete = false
        var today: [NLModerationLog.Entry] = []
        var error: String?
    }

    var selection: Selection
    private(set) var managedNodes: [NLManagedNodes.Node] = []
    private var slices: [Slice] = []
    private(set) var isLoading = false
    private(set) var errorText: String?
    private var generation = 0

    init(scope: DiscourseClient.ReviewScope) {
        self.scope = scope
        selection = .scope(scope)
    }

    /// The scopes the current selection reads.
    private var scopes: [DiscourseClient.ReviewScope] {
        switch selection {
        case .scope(let scope): [scope]
        case .allNodes: managedNodes.map { .node($0.slug) }
        }
    }

    func load() async {
        generation += 1
        let current = generation
        isLoading = slices.isEmpty
        errorText = nil
        defer { if current == generation { isLoading = false } }

        // Node chips only make sense for a node's managers; staff on the
        // site dashboard already see every node in one queue.
        if case .node = scope, let nodes = try? await client.managedNodes() {
            managedNodes = nodes
        }

        let tasks = scopes.map { scope in Task { await self.read(scope) } }
        var result: [Slice] = []
        for task in tasks { result.append(await task.value) }
        guard current == generation else { return }
        slices = result
        let failures = result.compactMap(\.error)
        errorText = failures.count == result.count ? failures.first : nil
    }

    func select(_ selection: Selection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        slices = []
        await load()
    }

    /// One scope: every pending item (up to 250, so the oldest wait is
    /// real), and today's log entries.
    private func read(_ scope: DiscourseClient.ReviewScope) async -> Slice {
        var slice = Slice(scope: scope)
        do {
            var queue = try await client.reviewQueue(scope, status: "pending", limit: 50)
            slice.items = queue.items
            slice.total = queue.counts?["pending"] ?? queue.items.count
            slice.kindCounts = queue.kindCounts ?? [:]
            var pages = 1
            while let before = queue.nextBefore, pages < 5 {
                queue = try await client.reviewQueue(scope, status: "pending", before: before, limit: 50)
                let known = Set(slice.items.map(\.id))
                slice.items += queue.items.filter { !known.contains($0.id) }
                pages += 1
            }
            slice.complete = queue.nextBefore == nil
        } catch {
            if !(error is CancellationError) {
                slice.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        // The log only feeds the 今天 numbers; a failure there leaves them at
        // zero rather than failing the page. Newest first, so read on until a
        // page reaches yesterday.
        var before: Int?
        for _ in 0..<6 {
            guard let log = try? await client.moderationLog(scope, before: before, limit: 50) else { break }
            let today = log.items.filter { Self.isToday($0.createdAt) }
            slice.today += today
            guard today.count == log.items.count, let next = log.nextBefore else { break }
            before = next
        }
        return slice
    }

    static func isToday(_ string: String?) -> Bool {
        DiscourseFormat.date(string).map(Calendar.current.isDateInToday) ?? false
    }

    // MARK: Numbers

    var hasLoaded: Bool { !slices.isEmpty }

    var pending: [Pending] {
        slices.flatMap { slice in slice.items.map { Pending(scope: slice.scope, item: $0) } }
    }

    var pendingTotal: Int { slices.map(\.total).reduce(0, +) }

    func count(_ group: ReviewGroup) -> Int {
        slices.map { count(group, in: $0) }.reduce(0, +)
    }

    private func count(_ group: ReviewGroup, in slice: Slice) -> Int {
        if !slice.kindCounts.isEmpty {
            return slice.kindCounts.filter { ReviewGroup.of($0.key) == group }.values.reduce(0, +)
        }
        return slice.items.filter { $0.reviewGroup == group }.count
    }

    /// "最早的等了 2 小时" — "超过" when some pending items weren't read.
    var oldestWait: String? {
        guard let oldest = pending.compactMap({ DiscourseFormat.date($0.item.createdAt) }).min() else { return nil }
        let span = ModerationTime.span(since: oldest)
        return slices.allSatisfy(\.complete) ? span : AppString("超过 \(span)")
    }

    /// "3 个节点", "n/indie" or "全站" after 待处理.
    var whereLabel: String {
        switch selection {
        case .allNodes:
            return AppString("\(slices.filter { $0.total > 0 }.count) 个节点")
        case .scope(.node(let slug)):
            return "n/\(slug)"
        case .scope(.site):
            let nodes = Set(pending.compactMap(\.item.nodeSlug))
            if slices.allSatisfy(\.complete), !nodes.isEmpty { return AppString("\(nodes.count) 个节点") }
            return AppString("全站")
        }
    }

    /// The queue to open for a group: the one scope, or the node with the
    /// most of it.
    func bestScope(for group: ReviewGroup?) -> DiscourseClient.ReviewScope {
        let ranked = slices.max { a, b in
            let x = group.map { count($0, in: a) } ?? a.total
            let y = group.map { count($0, in: b) } ?? b.total
            return x < y
        }
        return ranked?.scope ?? scopes.first ?? scope
    }

    /// The first tab that has something in it.
    var firstBusyGroup: ReviewGroup {
        ReviewGroup.allCases.first { count($0) > 0 } ?? .review
    }

    // MARK: 需要尽快处理

    struct Urgent: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let scope: DiscourseClient.ReviewScope
        let group: ReviewGroup
    }

    var urgent: [Urgent] {
        var rows: [Urgent] = []

        // The most-reported item: priority reporters first, then the count,
        // then whatever has waited longest.
        let reported = pending.filter { $0.item.reviewGroup == .reports && ($0.item.reportCount ?? 0) > 0 }
        if let top = reported.sorted(by: { a, b in
            if (a.item.priority ?? false) != (b.item.priority ?? false) { return a.item.priority ?? false }
            if (a.item.reportCount ?? 0) != (b.item.reportCount ?? 0) { return (a.item.reportCount ?? 0) > (b.item.reportCount ?? 0) }
            return (a.item.createdAt ?? "") < (b.item.createdAt ?? "")
        }).first {
            let item = top.item
            let what: String = switch item.isTopicPost {
            case true?: AppString("一个主题")
            case false?: AppString("一条回复")
            case nil: item.kind == "node_report" ? AppString("一个节点") : AppString("一项内容")
            }
            var parts: [String] = []
            if let slug = item.nodeSlug { parts.append("n/\(slug)") }
            if let reason = item.reports?.first.flatMap({ $0.reasonLabel ?? $0.reason }) { parts.append(reason) }
            parts.append(ModerationTime.ago(item.createdAt))
            rows.append(Urgent(
                id: "report", icon: "exclamationmark.triangle", tint: Color(hex: 0xA33A00),
                title: AppString("\(what)被 \(item.reportCount ?? 0) 人举报"),
                subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                scope: top.scope, group: .reports
            ))
        }

        // Held posts that have waited more than two hours.
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        let stale = pending.filter {
            $0.item.kind == "pending_post" && (DiscourseFormat.date($0.item.createdAt).map { $0 < cutoff } ?? false)
        }
        if let first = stale.first {
            var parts: [String] = []
            var slugs: [String] = []
            for entry in stale { if let slug = entry.item.nodeSlug, !slugs.contains(slug) { slugs.append(slug) } }
            if !slugs.isEmpty {
                parts.append(slugs.prefix(2).map { "n/\($0)" }.joined(separator: "、") + (slugs.count > 2 ? AppString(" 等") : ""))
            }
            // The commonest reason they were held.
            let labels = stale.compactMap { ReviewDecisions.tags(for: $0.item).first(where: { $0.tone != .neutral })?.text }
            if let common = Dictionary(grouping: labels, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
                parts.append(common)
            }
            rows.append(Urgent(
                id: "stale", icon: "clock", tint: Color(hex: 0xD9822B),
                title: AppString("\(stale.count) 个新帖等待超过 2 小时"),
                subtitle: parts.joined(separator: " · "),
                scope: first.scope, group: .review
            ))
        }

        // Appeals: a person waiting on a decision about themselves.
        let appeals = pending.filter { $0.item.reviewGroup == .appeals && $0.item.ownAction != true }
        if let oldest = appeals.min(by: { ($0.item.createdAt ?? "") < ($1.item.createdAt ?? "") }) {
            var parts: [String] = []
            if let slug = oldest.item.nodeSlug { parts.append("n/\(slug)") }
            if let date = DiscourseFormat.date(oldest.item.createdAt) {
                parts.append(AppString("最早的等了 \(ModerationTime.span(since: date))"))
            }
            rows.append(Urgent(
                id: "appeals", icon: "hand.raised", tint: Color(hex: 0x2F5BEA),
                title: AppString("\(appeals.count) 条申诉等待处理"),
                subtitle: parts.joined(separator: " · "),
                scope: oldest.scope, group: .appeals
            ))
        }
        return rows
    }

    // MARK: 今天

    private var todayEntries: [NLModerationLog.Entry] { slices.flatMap(\.today) }

    var handledToday: Int { todayEntries.count }
    var removedToday: Int { todayEntries.filter { ModerationLogCategory.of($0.action) == .removal }.count }
    var bannedToday: Int {
        todayEntries.filter { ["user.suspend", "restrict.ban"].contains($0.action.lowercased()) }.count
    }
}

struct ModerationDashboardPage: View {
    let scope: DiscourseClient.ReviewScope
    let onClose: () -> Void

    @State private var store: ModerationDashboardStore
    @State private var queueRoute: QueueRoute?
    @State private var showsLog = false
    @State private var logFilter: LogFilter?

    private struct LogFilter: Identifiable, Hashable {
        let category: ModerationLogCategory
        var id: String { category.rawValue }
    }
    @State private var nodeTool: NodeTool?
    @State private var manage: NLNodeManage?

    private enum NodeTool: String, Identifiable, Hashable {
        case members, rules
        var id: String { rawValue }
    }

    /// The node the tools act on: the picked chip, or the page's own node.
    private var toolSlug: String? {
        if case .node(let slug) = logScope { return slug }
        return nil
    }

    private struct QueueRoute: Identifiable, Hashable {
        let id = UUID()
        let scope: DiscourseClient.ReviewScope
        let group: ReviewGroup
    }

    init(scope: DiscourseClient.ReviewScope, onClose: @escaping () -> Void) {
        self.scope = scope
        self.onClose = onClose
        _store = State(initialValue: ModerationDashboardStore(scope: scope))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The node chips, the first row under the system bar.
            if store.managedNodes.count > 1 {
                nodeChips
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.isLoading, !store.hasLoaded {
                        AdminStatePlaceholder(isLoading: true)
                    } else if let errorText = store.errorText, store.pending.isEmpty {
                        AdminStatePlaceholder(isLoading: false, errorText: errorText) {
                            Task { await store.load() }
                        }
                    } else {
                        summaryCard
                        if !store.urgent.isEmpty {
                            urgentSection
                        }
                        todaySection
                        toolsSection
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.load() }
        }
        .background(AdminTheme.pageBg)
        .navigationTitle(AppString("管理台"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        // Pushed on the same stack, with the system back button.
        .navigationDestination(item: $queueRoute) { route in
            ReviewQueuePage(scope: route.scope, initialGroup: route.group) { queueRoute = nil }
                .onDisappear { Task { await store.load() } }
        }
        .navigationDestination(item: $logFilter) { request in
            ModerationLogPage(scope: logScope, initialFilter: request.category, todayOnly: true) { logFilter = nil }
        }
        .navigationDestination(isPresented: $showsLog) {
            ModerationLogPage(scope: logScope) { showsLog = false }
                .onDisappear { Task { await store.load() } }
        }
        .navigationDestination(item: $nodeTool) { tool in
            if let slug = toolSlug {
                switch tool {
                case .members: NodeRestrictionsPage(slug: slug) { nodeTool = nil }
                case .rules: NodeRulesPage(rules: manage?.rules ?? []) { nodeTool = nil }
                }
            }
        }
        .task(id: toolSlug) {
            guard let slug = toolSlug else { manage = nil; return }
            manage = try? await DiscourseClient().nodeManage(slug: slug)
        }
    }

    private var logScope: DiscourseClient.ReviewScope {
        if case .scope(let scope) = store.selection { return scope }
        return scope
    }

    // MARK: Header

    private var nodeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                AdminFilterChip(
                    title: AppString("全部节点 · \(store.managedNodes.count)"),
                    isSelected: store.selection == .allNodes
                ) {
                    Task { await store.select(.allNodes) }
                }
                ForEach(store.managedNodes, id: \.slug) { node in
                    AdminFilterChip(
                        title: "n/\(node.slug)",
                        isSelected: store.selection == .scope(.node(node.slug))
                    ) {
                        Task { await store.select(.scope(.node(node.slug))) }
                    }
                }
            }
            .padding(.horizontal, AdminTheme.inset)
        }
    }

    // MARK: Summary

    /// The dark card: 待处理 · where, the oldest wait, the three counts and
    /// the two ways in.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x7FD1B0))
                Text(AppString("待处理 · \(store.whereLabel)"))
                    .font(Theme.body(13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let wait = store.oldestWait {
                    Text(AppString("最早的等了 \(wait)"))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }

            HStack(alignment: .top, spacing: 12) {
                summaryCount(.review, icon: "clock", tint: Color(hex: 0xFFC46B))
                summaryCount(.reports, icon: "flag", tint: Color(hex: 0xFF9D7A))
                summaryCount(.appeals, icon: "pencil.line", tint: Color(hex: 0x9FC4FF))
            }

            HStack(spacing: 8) {
                Button {
                    let group = store.firstBusyGroup
                    queueRoute = QueueRoute(scope: store.bestScope(for: group), group: group)
                } label: {
                    Text(AppString("开始审核"))
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0E1A17))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.pressable)
                Button {
                    queueRoute = QueueRoute(scope: store.bestScope(for: .reports), group: .reports)
                } label: {
                    Text(AppString("看举报"))
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(light: 0x0E1A17, dark: 0x16231F), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color(hex: 0x0B1F18).opacity(0.35), radius: 20, y: 12)
        .padding(.horizontal, AdminTheme.inset)
    }

    private func summaryCount(_ group: ReviewGroup, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(group.title)
                    .font(Theme.body(12))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(verbatim: "\(store.count(group))")
                .font(Theme.body(30, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sections

    private var urgentSection: some View {
        let rows = store.urgent
        return AdminSection(title: AppString("需要尽快处理")) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AdminRow(
                    icon: row.icon,
                    tint: row.tint,
                    title: row.title,
                    subtitle: row.subtitle.isEmpty ? nil : row.subtitle,
                    isLast: index == rows.count - 1
                ) {
                    queueRoute = QueueRoute(scope: row.scope, group: row.group)
                }
            }
        }
    }

    /// 已处理 / 删除 / 封禁 from today's log. The artboard's fourth figure,
    /// 平均响应, has no source: nothing records when an item was first seen.
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppString("今天"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, AdminTheme.inset)
                .padding(.bottom, 7)
            // Each figure opens the log entries it counts: today's, of that kind.
            HStack(spacing: 0) {
                todayStat(store.handledToday, AppString("已处理"), filter: .all)
                todayStat(store.removedToday, AppString("删除"), filter: .removal)
                todayStat(store.bannedToday, AppString("封禁"), filter: .bans)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
            .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.listRadius, style: .continuous))
        }
        .padding(.horizontal, AdminTheme.inset)
    }

    private func todayStat(_ value: Int, _ label: String, filter: ModerationLogCategory) -> some View {
        Button {
            logFilter = LogFilter(category: filter)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: "\(value)")
                    .font(Theme.body(20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                HStack(spacing: 2) {
                    Text(label)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint(AppString("查看今天的这些操作"))
    }

    private var toolsSection: some View {
        AdminSection(title: AppString("工具")) {
            AdminRow(
                icon: "tray.full", tint: Color(hex: 0x2F5BEA), title: AppString("审核队列"),
                value: store.pendingTotal > 0 ? "\(store.pendingTotal)" : nil
            ) {
                queueRoute = QueueRoute(scope: store.bestScope(for: nil), group: store.firstBusyGroup)
            }
            AdminRow(
                icon: "clock.arrow.circlepath", tint: Color(hex: 0x6D6D72), title: AppString("操作日志"),
                isLast: toolSlug == nil
            ) {
                showsLog = true
            }
            if toolSlug != nil {
                AdminRow(
                    icon: "person.2", tint: AdminTheme.IconTint.blue, title: AppString("用户管理"),
                    value: AppString("处罚中的用户")
                ) { nodeTool = .members }
                AdminRow(
                    icon: "line.3.horizontal.decrease", tint: AdminTheme.IconTint.purple, title: AppString("节点规则"),
                    value: manage?.rules.map { AppString("\($0.count) 条") }, isLast: true
                ) { nodeTool = .rules }
            }
        }
    }
}
