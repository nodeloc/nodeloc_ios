//
//  ModerationLogPage.swift
//  nodeloc
//
//  操作日志 — every moderation action, newest first, grouped by day, with
//  撤销 on the entries this reader may still reverse. Site-wide for staff, a
//  node's own log for its owner and moderators; the two endpoints answer the
//  same shape, so one page serves both.
//

import SwiftUI

@MainActor
@Observable
final class ModerationLogStore {
    private let client = DiscourseClient()

    let scope: DiscourseClient.ReviewScope

    private(set) var entries: [NLModerationLog.Entry] = []
    private(set) var isLoading = false
    private(set) var errorText: String?
    private(set) var undoingIDs: Set<Int> = []
    private(set) var isLoadingMore = false
    private var nextBefore: Int?

    init(scope: DiscourseClient.ReviewScope) {
        self.scope = scope
    }

    var canLoadMore: Bool { nextBefore != nil }

    func load() async {
        isLoading = entries.isEmpty
        errorText = nil
        defer { isLoading = false }
        do {
            let log = try await client.moderationLog(scope)
            entries = log.items
            nextBefore = log.nextBefore
        } catch {
            guard !(error is CancellationError) else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let log = try? await client.moderationLog(scope, before: before) else { return }
        let known = Set(entries.map(\.id))
        entries += log.items.filter { !known.contains($0.id) }
        nextBefore = log.nextBefore
    }

    /// Reverses one entry, then reloads: the server logs the reversal as an
    /// entry of its own and stamps the original as undone, so both rows change.
    func undo(_ entry: NLModerationLog.Entry) async {
        undoingIDs.insert(entry.id)
        defer { undoingIDs.remove(entry.id) }
        do {
            try await client.undoModerationLog(scope, id: entry.id)
            ToastCenter.shared.show(AppString("已撤销"))
            await load()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

/// How an action is filed, for the filter chips and the row's icon.
enum ModerationLogCategory: String, CaseIterable, Identifiable {
    case all, removal, penalty, bans, review, mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppString("全部")
        case .removal: AppString("删除")
        case .penalty: AppString("处罚")
        case .bans: AppString("封禁")
        case .review: AppString("审核")
        case .mine: AppString("只看我")
        }
    }

    /// The category an entry's action belongs to; `.all` when it is none of
    /// the three (pins, moves, closes and the like).
    static func of(_ action: String) -> ModerationLogCategory {
        let action = action.lowercased()
        if action.hasPrefix("review.") || action.hasPrefix("review_") { return .review }
        if action.hasPrefix("user.") || action.contains("silence") || action.contains("suspend")
            || action.contains("restrict") || action.contains("penalt") || action.contains("watch") {
            return .penalty
        }
        if action.contains("delete") || action.contains("hide") || action.contains("remove") {
            return .removal
        }
        return .all
    }
}

struct ModerationLogPage: View {
    let onClose: () -> Void

    @State private var store: ModerationLogStore
    @State private var filter: ModerationLogCategory = .all
    /// From the dashboard's 今天 figures: the log narrowed to today.
    @State private var todayOnly = false
    @State private var undoTarget: NLModerationLog.Entry?
    @State private var detailEntryID: Int?
    @State private var isSearching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(
        scope: DiscourseClient.ReviewScope,
        initialFilter: ModerationLogCategory = .all,
        todayOnly: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        _store = State(initialValue: ModerationLogStore(scope: scope))
        _filter = State(initialValue: initialFilter)
        _todayOnly = State(initialValue: todayOnly)
    }

    private var scopeSlug: String? {
        if case .node(let slug) = store.scope { return slug }
        return nil
    }

    private var visibleEntries: [NLModerationLog.Entry] {
        var entries: [NLModerationLog.Entry]
        switch filter {
        case .all:
            entries = store.entries
        case .mine:
            let me = DiscourseAuth.shared.username?.lowercased()
            entries = store.entries.filter { $0.actor?.lowercased() == me }
        case .bans:
            // The dashboard's 封禁: suspensions only, as it counts them.
            entries = store.entries.filter { ["user.suspend", "restrict.ban"].contains($0.action.lowercased()) }
        default:
            entries = store.entries.filter { ModerationLogCategory.of($0.action) == filter }
        }
        if todayOnly {
            entries = entries.filter { ModerationDashboardStore.isToday($0.createdAt) }
        }
        // Searches what the row shows — who, what, where and why — over the
        // pages loaded so far.
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            entries = entries.filter {
                (Self.headline($0) + " " + Self.subtitle($0, nodeSlug: scopeSlug)).lowercased().contains(needle)
            }
        }
        return entries
    }

    private struct DaySection: Identifiable {
        let title: String
        var entries: [NLModerationLog.Entry]
        /// The first entry's id: two runs can share a title ("更早").
        var id: Int { entries.first?.id ?? 0 }
    }

    /// Entries grouped under 今天 / 昨天 / a date, in the order they arrive.
    private var sections: [DaySection] {
        var result: [DaySection] = []
        for entry in visibleEntries {
            let title = Self.dayTitle(entry.createdAt)
            if result.last?.title == title {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(DaySection(title: title, entries: [entry]))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("操作日志"), onBack: onClose) {
                AdminCircleButton(
                    systemName: isSearching ? "xmark" : "magnifyingglass",
                    accessibilityLabel: isSearching ? AppString("取消搜索") : AppString("搜索")
                ) {
                    withAnimation(.quicker) {
                        isSearching.toggle()
                        if !isSearching { query = "" }
                    }
                    searchFocused = isSearching
                }
            }

            if isSearching {
                searchField
            }

            filterChips

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.isLoading, store.entries.isEmpty {
                        AdminStatePlaceholder(isLoading: true)
                    } else if let errorText = store.errorText, store.entries.isEmpty {
                        AdminStatePlaceholder(isLoading: false, errorText: errorText) {
                            Task { await store.load() }
                        }
                    } else if visibleEntries.isEmpty {
                        AdminStatePlaceholder(
                            isLoading: false,
                            emptyText: query.isEmpty ? AppString("还没有操作记录") : AppString("没有找到相关记录")
                        )
                        if store.canLoadMore {
                            // A filter or search with nothing on the loaded
                            // pages: keep reading further back.
                            Color.clear.frame(height: 1)
                                .task(id: store.entries.count) { await store.loadMore() }
                        }
                    } else {
                        ForEach(sections) { section in
                            AdminSection(title: section.title) {
                                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                                    // The row opens the entry; 撤销 lives there,
                                    // next to what it would reverse.
                                    Button { detailEntryID = entry.id } label: {
                                        row(entry, isLast: index == section.entries.count - 1)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Color.clear.frame(height: 1)
                            .task(id: store.entries.count) { await store.loadMore() }
                        if store.isLoadingMore {
                            ProgressView().tint(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await store.load() }
        }
        .background(AdminTheme.pageBg)
        .task { await store.load() }
        .navigationDestination(item: $detailEntryID) { id in
            ModerationLogDetailPage(entryID: id, store: store, scopeSlug: scopeSlug)
        }
        .alert(
            AppString("撤销这次操作？"),
            isPresented: Binding(
                get: { undoTarget != nil },
                set: { if !$0 { undoTarget = nil } }
            )
        ) {
            Button(AppString("撤销"), role: .destructive) {
                guard let entry = undoTarget else { return }
                undoTarget = nil
                Task { await store.undo(entry) }
            }
            Button(AppString("取消"), role: .cancel) { undoTarget = nil }
        } message: {
            Text(AppString("会执行相反的操作并记入日志，原记录标为已撤销。"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            TextField(AppString("搜索操作人、对象或理由"), text: $query)
                .font(Theme.body(17))
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, AdminTheme.inset)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                AdminFilterChip(title: AppString("只看今天"), isSelected: todayOnly) {
                    withAnimation(.quicker) { todayOnly.toggle() }
                }
                .accessibilityAddTraits(todayOnly ? .isSelected : [])
                ForEach(ModerationLogCategory.allCases) { category in
                    AdminFilterChip(title: category.title, isSelected: filter == category) {
                        withAnimation(.quicker) { filter = category }
                    }
                    .accessibilityAddTraits(filter == category ? .isSelected : [])
                }
            }
            .padding(.horizontal, AdminTheme.inset)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// Icon · "林见川 禁言了 像素君 7 天" over "n/indie · 广告推广 · 刚刚" ·
    /// 撤销 — the grouped-list row of the artboard.
    private func row(_ entry: NLModerationLog.Entry, isLast: Bool) -> some View {
        let glyph = ModerationLogGlyph.of(entry)
        let undone = entry.undoneAt != nil
        return HStack(spacing: 12) {
            AdminIcon(systemName: glyph.icon, tint: glyph.tint)
                .opacity(undone ? 0.5 : 1)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.headline(entry))
                        .font(Theme.body(17))
                        .foregroundStyle(undone ? Theme.textMuted : Theme.text)
                        .strikethrough(undone, color: Theme.textMuted)
                        .lineLimit(2)
                    Text(Self.subtitle(entry, nodeSlug: scopeSlug))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                    if undone {
                        Text(entry.undoneBy.map { AppString("已被 \($0) 撤销") } ?? AppString("已撤销"))
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdminTheme.chevron)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 16)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(AdminTheme.separator).frame(height: 1)
                }
            }
        }
        .padding(.leading, 16)
    }

    // MARK: Text

    /// "林见川 禁言了 像素君 7 天". The verb comes from the action; an action
    /// this table doesn't know is shown by its code rather than guessed at.
    /// Codes are the backend's: the site log (moderation/service.go `audit`,
    /// content/modtools.go) and a node's (`record` / `LogModAction` in node and
    /// content); the target user is a top-level field, not in `details`.
    static func headline(_ entry: NLModerationLog.Entry) -> String {
        let actor = entry.actor ?? AppString("系统")
        let who = entry.targetUser
        let action = entry.action.lowercased()

        // A reversal names what it reversed (`undo_of`), however it was done.
        if let undoOf = entry.details?["undo_of"]?.string, !undoOf.isEmpty {
            return "\(actor) " + AppString("撤销了一次\(undoneNoun(undoOf))")
        }

        let verb: String
        switch action {
        case "post.delete": verb = AppString("删除了一条回复")
        case "post.hide": verb = AppString("隐藏了一条回复")
        case "post.unhide": verb = AppString("取消隐藏了一条回复")
        case "post.restore": verb = AppString("恢复了一条回复")
        case "post.rollback": verb = AppString("回滚了一条回复")
        case "post.moderate": verb = AppString("在帖子上处罚了") + Self.target(who)
        case "topic.delete": verb = AppString("删除了一个主题")
        case "topic.move":
            if let to = detail(entry, "to_slug") ?? slugForNode(entry, idKey: "to_node_id") {
                verb = AppString("把主题移到了 n/\(to)")
            } else {
                verb = AppString("迁移了一个主题")
            }
        case "topic.pin": verb = AppString("置顶了一个主题")
        case "topic.pin_until": verb = AppString("修改了置顶期限")
        case "topic.unpin": verb = AppString("取消置顶了一个主题")
        case "topic.close": verb = AppString("关闭了一个主题")
        case "topic.open": verb = AppString("重新打开了一个主题")
        case "user.silence", "restrict.mute":
            let span = Self.duration(entry)
            verb = (span.isEmpty ? AppString("永久禁言了") : AppString("禁言了")) + Self.target(who) + span
        case "user.suspend", "restrict.ban":
            let span = Self.duration(entry)
            verb = (span.isEmpty ? AppString("永久封禁了") : AppString("封禁了")) + Self.target(who) + span
        case "user.unsilence": verb = AppString("解除了禁言") + Self.target(who)
        case "user.unsuspend": verb = AppString("解除了封禁") + Self.target(who)
        case "restrict.lift": verb = AppString("解除了处罚") + Self.target(who)
        case "user.extend_penalty", "restrict.extend": verb = AppString("延长了处罚") + Self.target(who)
        case "user.update_penalty": verb = AppString("修改了处罚期限") + Self.target(who)
        case "user.watch", "watch.add": verb = AppString("把") + Self.target(who) + AppString(" 加入观察名单")
        case "user.self_delete": return AppString("\(actor) 注销了自己的账号")
        case "user.delete": verb = AppString("删除了账号") + Self.target(who)
        case "announcement.create": verb = AppString("发布了一条公告")
        case "announcement.update": verb = AppString("修改了一条公告")
        case "announcement.delete": verb = AppString("删除了一条公告")
        case "user.unwatch", "watch.remove": verb = AppString("把") + Self.target(who) + AppString(" 移出观察名单")
        default:
            if action.hasPrefix("review.") {
                // `review.` + the decision (moderation/service.go `Action…`).
                switch action.dropFirst("review.".count) {
                case "approve": verb = AppString("通过了待审帖子")
                case "delete_post": verb = AppString("删除了被举报的帖子")
                case "hide_post": verb = AppString("隐藏了被举报的帖子")
                case "reject": verb = AppString("判定举报不成立")
                case "ignore": verb = AppString("忽略了一项审核")
                case "confirm": verb = AppString("判定风控项成立")
                case "warn_node": verb = AppString("警告了被举报的节点")
                case "read_only_node": verb = AppString("把被举报的节点设为只读")
                case "ban_node": verb = AppString("封禁了被举报的节点")
                case "uphold": verb = AppString("维持了原处理")
                case "restore": verb = AppString("申诉成立，恢复了内容")
                case "lift": verb = AppString("申诉成立，解除了处罚")
                case "reopen": verb = AppString("重新打开了一项审核")
                case "restore_post": verb = AppString("在审核队列里恢复了帖子")
                case "refund": verb = AppString("退回了扣除的声望")
                case "flag_link": verb = AppString("把被举报的链接标为不安全")
                default: verb = AppString("处理了一项审核")
                }
            } else {
                verb = entry.action
            }
        }
        return "\(actor) \(verb)"
    }

    /// "n/indie · 像素君 · 「标题」 · 广告推广 · 1 分钟前". `nodeSlug` is the
    /// log's own node; the site log names one only when the details do.
    static func subtitle(_ entry: NLModerationLog.Entry, nodeSlug: String? = nil) -> String {
        var parts: [String] = []
        let action = entry.action.lowercased()
        if action == "topic.move" {
            // Where it came from; the headline already says where it went.
            if let from = detail(entry, "from_slug") ?? slugForNode(entry, idKey: "from_node_id") {
                parts.append(AppString("原节点 n/\(from)"))
            }
        } else if let slug = nodeSlug ?? detail(entry, "slug") {
            parts.append("n/\(slug)")
        } else if nodeSlug == nil, ModerationLogCategory.of(action) == .penalty, action.hasPrefix("user.") {
            parts.append(AppString("全站"))
        }
        if ModerationLogCategory.of(action) == .removal, let author = entry.targetUser {
            parts.append(author)
        }
        if let title = detail(entry, "title") {
            parts.append("「\(title)」")
        }
        // Penalties, removals and moves write `reason`; review decisions `note`.
        if let reason = detail(entry, "reason") ?? detail(entry, "note") {
            parts.append(ModerationLogDetailPage.reasonText(reason))
        }
        let when = time(entry.createdAt)
        if !when.isEmpty { parts.append(when) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "「」" }
            .joined(separator: " · ")
    }

    /// 刚刚 / 12 分钟前 today; the clock time on earlier days, whose date is
    /// already the section's title.
    private static func time(_ createdAt: String?) -> String {
        guard let date = DiscourseFormat.date(createdAt) else { return "" }
        if Calendar.current.isDateInToday(date) { return ModerationTime.ago(date) }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(AppLanguage.resolved.locale))
    }

    /// The site log records nodes by id (`from_node_id`, `to_node_id`).
    private static func slugForNode(_ entry: NLModerationLog.Entry, idKey: String) -> String? {
        guard let id = entry.details?[idKey]?.int else { return nil }
        return NodelocAdapterState.shared.nodeSlug(forID: id)
    }

    /// What an undo reversed, for "撤销了一次删除".
    private static func undoneNoun(_ action: String) -> String {
        let action = action.lowercased()
        if action.contains("delete") { return AppString("删除") }
        if action.contains("hide") { return AppString("隐藏") }
        if action.contains("silence") || action.contains("mute") { return AppString("禁言") }
        if action.contains("suspend") || action.contains("ban") { return AppString("封禁") }
        if action.contains("watch") { return AppString("观察") }
        if action.hasPrefix("review.") { return AppString("审核") }
        if action.contains("pin") { return AppString("置顶") }
        if action.contains("close") || action.contains("open") { return AppString("关闭") }
        return AppString("处理")
    }

    private static func target(_ who: String?) -> String {
        who.map { " \($0)" } ?? ""
    }

    /// `days` is what the penalty was given for; 0 or missing is permanent.
    static func duration(_ entry: NLModerationLog.Entry) -> String {
        if let days = entry.details?["days"]?.int, days > 0 { return AppString(" \(days) 天") }
        return ""
    }

    private static func detail(_ entry: NLModerationLog.Entry, _ key: String) -> String? {
        guard let value = entry.details?[key] else { return nil }
        if let string = value.string, !string.isEmpty { return string }
        return value.int.map(String.init)
    }

    static func dayTitle(_ createdAt: String?) -> String {
        guard let date = DiscourseFormat.date(createdAt) else { return AppString("更早") }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return AppString("今天") }
        if calendar.isDateInYesterday(date) { return AppString("昨天") }
        return date.formatted(.dateTime.month().day().locale(AppLanguage.resolved.locale))
    }
}

/// The coloured squircle of a log row, by what was done: amber chat bubble
/// for a silence, brick trash for a removal, green check for an approval,
/// blue folder for a move, grey arrow for a reversal, brick 🚫 for a ban.
enum ModerationLogGlyph {
    static let amber = Color(hex: 0xD9822B)
    static let brick = Color(hex: 0xA33A00)
    static let green = Color(hex: 0x007A52)
    static let blue = Color(hex: 0x2F5BEA)
    static let grey = Color(hex: 0x6D6D72)
    static let slate = AdminTheme.IconTint.slate

    static func of(_ entry: NLModerationLog.Entry) -> (icon: String, tint: Color) {
        if entry.details?["undo_of"]?.string != nil { return ("arrow.uturn.backward", grey) }
        switch entry.action.lowercased() {
        case "user.silence", "restrict.mute": return ("exclamationmark.bubble", amber)
        case "user.suspend", "restrict.ban", "review.ban_node": return ("nosign", brick)
        case "post.delete", "topic.delete", "review.delete_post": return ("trash", brick)
        case "post.hide", "review.hide_post": return ("eye.slash", brick)
        case "review.flag_link": return ("link", brick)
        case "review.approve", "review.reject", "review.restore", "review.lift": return ("checkmark", green)
        case "review.confirm", "review.uphold": return ("checkmark.shield", amber)
        case "review.warn_node", "review.read_only_node": return ("exclamationmark.triangle", amber)
        case "review.ignore": return ("minus", slate)
        case "topic.move": return ("folder", blue)
        case "topic.pin", "topic.unpin", "topic.pin_until": return ("pin", green)
        case "topic.close": return ("lock", slate)
        case "topic.open": return ("lock.open", slate)
        case "user.watch", "watch.add": return ("eye", amber)
        case "user.extend_penalty", "restrict.extend", "user.update_penalty": return ("clock", amber)
        case "user.unsilence", "user.unsuspend", "restrict.lift", "user.unwatch", "watch.remove",
             "post.restore", "post.unhide", "post.rollback", "review.reopen", "review.restore_post", "review.refund":
            return ("arrow.uturn.backward", grey)
        default: return ("doc.text", slate)
        }
    }
}


// MARK: - Entry detail

/// One log entry: what was done, by whom and when, to what, why, the penalty
/// and its span, and whether it still stands. 撤销 is here, behind a
/// confirmation, when the server says this reader may still reverse it
/// (`undoable`; `POST …/audit-logs/{id}/undo` or `…/mod-log/{id}/undo`, no
/// body). The entry is read from the store, so an undo shows here and in the
/// list at once.
struct ModerationLogDetailPage: View {
    let entryID: Int
    let store: ModerationLogStore
    let scopeSlug: String?

    @Environment(AppState.self) private var app
    @State private var confirmUndo = false
    /// Names for the node ids a move records (`from_node_id`, `to_node_id`).
    @State private var nodeNames: [Int: String] = [:]

    private var entry: NLModerationLog.Entry? { store.entries.first { $0.id == entryID } }

    private func loadNodeNames() async {
        guard case .object(let object)? = entry?.details else { return }
        for (key, value) in object where key.hasSuffix("_node_id") {
            guard let id = value.int, nodeNames[id] == nil,
                  let node = await NodeCatalog.shared.node(id: id) else { continue }
            nodeNames[id] = node.name.isEmpty ? "n/\(node.slug)" : "\(node.name) · n/\(node.slug)"
        }
    }

    var body: some View {
        ScrollView {
            if let entry {
                VStack(alignment: .leading, spacing: 18) {
                    summary(entry)
                    AdminSection(title: AppString("对象")) { targetRows(entry) }
                    let facts = details(entry)
                    if !facts.isEmpty {
                        AdminSection(title: AppString("详情")) {
                            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                                AdminRow(title: fact.0, value: fact.1, showsChevron: false, isLast: index == facts.count - 1)
                            }
                        }
                    }
                    AdminSection(title: AppString("状态"), footer: stateFooter(entry)) {
                        AdminRow(title: AppString("现在"), value: stateText(entry), showsChevron: false, isLast: true)
                    }
                    if entry.undoable == true, entry.undoneAt == nil {
                        Button(role: .destructive) { confirmUndo = true } label: {
                            HStack {
                                if store.undoingIDs.contains(entry.id) { ProgressView() }
                                Text(AppString("撤销这次操作")).fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(Theme.danger)
                        .disabled(store.undoingIDs.contains(entry.id))
                        .padding(.horizontal, AdminTheme.inset)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            } else {
                AdminStatePlaceholder(isLoading: false, emptyText: AppString("这条记录不在列表里了"))
            }
        }
        .background(AdminTheme.pageBg)
        .navigationTitle(AppString("操作详情"))
        .task(id: entryID) { await loadNodeNames() }
        .navigationBarTitleDisplayMode(.inline)
        .alert(AppString("撤销这次操作？"), isPresented: $confirmUndo) {
            Button(AppString("撤销"), role: .destructive) {
                guard let entry else { return }
                Task { await store.undo(entry) }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(entry.map { AppString("将撤销「\(ModerationLogPage.headline($0))」：执行相反的操作并记入日志，原记录标为已撤销。") } ?? "")
        }
    }

    private func summary(_ entry: NLModerationLog.Entry) -> some View {
        let glyph = ModerationLogGlyph.of(entry)
        return HStack(alignment: .top, spacing: 12) {
            AdminIcon(systemName: glyph.icon, tint: glyph.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(ModerationLogPage.headline(entry))
                    .font(Theme.body(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ModerationLogPage.subtitle(entry, nodeSlug: scopeSlug))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AdminTheme.inset)
    }

    @ViewBuilder
    private func targetRows(_ entry: NLModerationLog.Entry) -> some View {
        let user = entry.targetUser
        let topicID = entry.details?["topic_id"]?.int ?? (entry.targetType == "topic" ? entry.targetId : nil)
        let postNumber = entry.details?["post_number"]?.int
        let node = entry.details?["node_slug"]?.string ?? entry.details?["slug"]?.string ?? scopeSlug
        let rows = targetList(entry, user: user, topicID: topicID, postNumber: postNumber, node: node)
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if let open = row.open {
                AdminRow(title: row.title, value: row.value, isLast: index == rows.count - 1, action: open)
            } else {
                AdminRow(title: row.title, value: row.value, showsChevron: false, isLast: index == rows.count - 1)
            }
        }
    }

    private typealias TargetRow = (title: String, value: String, open: (() -> Void)?)

    private func targetList(_ entry: NLModerationLog.Entry, user: String?, topicID: Int?, postNumber: Int?, node: String?) -> [TargetRow] {
        var rows: [TargetRow] = []
        if let user {
            rows.append((AppString("用户"), "u/\(user)", { app.openProfile(username: user) }))
        }
        if let topicID {
            let title = entry.details?["title"]?.string ?? entry.details?["topic_title"]?.string ?? entry.targetTitle ?? "#\(topicID)"
            let floor: Int? = (postNumber ?? 0) > 1 ? postNumber : nil
            rows.append((AppString("帖子"), title, { app.openTopicPage(id: topicID, postNumber: floor) }))
        }
        if let node {
            rows.append((AppString("节点"), "n/\(node)", { app.openNode(slug: node) }))
        }
        if let actor = entry.actor, !actor.isEmpty {
            rows.append((AppString("操作人"), actor, { app.openProfile(username: actor) }))
        }
        if let at = entry.createdAt {
            let when = DiscourseFormat.date(at).map(Self.shortTime) ?? at
            rows.append((AppString("时间"), when, nil))
        }
        return rows
    }

    /// Reason, note, penalty and span first, then anything else the server
    /// recorded, by its own key.
    private func details(_ entry: NLModerationLog.Entry) -> [(String, String)] {
        guard case .object(let object)? = entry.details else { return [] }
        let known: [(String, String)] = [
            ("reason", AppString("理由")), ("note", AppString("说明")), ("reason_label", AppString("理由")),
            ("reputation_penalty", AppString("扣除声望")), ("penalty_points", AppString("扣除能量")), ("days", AppString("天数")),
            ("from_node_id", AppString("原节点")), ("to_node_id", AppString("新节点")),
            ("until", AppString("到期")), ("ends_at", AppString("到期")), ("expires_at", AppString("到期")),
        ]
        var out: [(String, String)] = []
        var used: Set<String> = ["undo_of", "topic_id", "post_number", "node_slug", "slug", "title", "topic_title"]
        for (key, label) in known {
            guard !used.contains(key), let value = object[key], var text = Self.text(value, key: key) else { continue }
            if key == "reason" { text = Self.reasonText(text) }
            if key.hasSuffix("_node_id"), let id = value.int {
                // Node ids mean nothing to a reader; the name, when known.
                text = nodeNames[id] ?? "#\(id)"
            }
            if key == "penalty_points", text == "0" { used.insert(key); continue }
            out.append((label, text))
            used.insert(key)
        }
        for key in object.keys.sorted() where !used.contains(key) {
            if let text = Self.text(object[key]!, key: key) { out.append((key, text)) }
        }
        let span = ModerationLogPage.duration(entry)
        if !span.isEmpty, !out.contains(where: { $0.0 == AppString("天数") }) { out.insert((AppString("时长"), span), at: 0) }
        return out
    }

    private static func text(_ value: JSONValue, key: String) -> String? {
        switch value {
        case .string(let s):
            guard !s.isEmpty else { return nil }
            if key.hasSuffix("_at") || key == "until", let date = DiscourseFormat.date(s) {
                return shortTime(date)
            }
            return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? AppString("是") : AppString("否")
        default: return nil
        }
    }

    /// A move or removal reason code, in words (content/manage.go
    /// `moveReasons`); free text passes through.
    static func reasonText(_ code: String) -> String {
        TopicMoveReason(rawValue: code)?.title ?? code
    }

    /// 2026/11/28 09:12 — complete and short enough for a row in either language.
    static func shortTime(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(AppLanguage.resolved.locale))
    }

    private func stateText(_ entry: NLModerationLog.Entry) -> String {
        if entry.undoneAt != nil {
            return entry.undoneBy.map { AppString("已被 \($0) 撤销") } ?? AppString("已撤销")
        }
        if let until = entry.details?["until"]?.string ?? entry.details?["ends_at"]?.string,
           let date = DiscourseFormat.date(until), date < Date() {
            return AppString("已到期")
        }
        return AppString("仍然有效")
    }

    private func stateFooter(_ entry: NLModerationLog.Entry) -> String? {
        if entry.undoneAt != nil || entry.undoable == true { return nil }
        return AppString("这条记录不能撤销：操作本身不可逆，或你没有撤销它的权限。")
    }
}
