//
//  EnergyPage.swift
//  nodeloc
//
//  能量明细 — the reader's own ledger, after the design's iOS artboard and the
//  web's /points: the night-green balance card (check-in, 转赠, this month's
//  income and spending, the 财富榜 place), the 全部 / 收入 / 支出 switch and a
//  month menu, type chips, then the entries grouped by day (Beijing time),
//  each opening to its serial number, time, type, link and message.
//
//  Reads `GET /api/v1/points`, `/points/history`, `/points/summary`,
//  `/checkin` and the reader's place on the all-time board. Writes only on the
//  reader's own tap: `POST /api/v1/checkin` and `POST /api/v1/points/transfers`.
//

import SwiftUI

// MARK: - Entry presentation

/// How one ledger entry reads: the web's titles, types, icons and colours
/// (static/energy.js), so the two clients describe the same entry the same way.
enum LedgerEntryStyle {
    private static let games: Set = ["red_envelope_fund", "red_envelope_claim", "red_envelope_refund", "lottery_ticket", "lottery_payout", "lottery_refund"]
    private static let rewards: Set = ["featured_reward", "featured_reward_revoke", "node_owner_reward", "node_owner_reward_revoke", "moderator_stipend", "system_reward", "app_award", "app_award_revert", "task_reward", "onboarding_reward"]
    private static let invites: Set = ["invite_reward", "invite_welcome", "invite_level_reward", "invite_second_reward", "invite_milestone"]
    private static let spends: Set = ["content_unlock", "pay", "pay_refund", "pay_transfer", "app_spend"]
    /// Kinds whose memo is a person's own words (a tip's or transfer's note,
    /// an adjustment's reason) rather than a system description.
    static let noteKinds: Set = ["tip", "transfer", "admin_adjust"]

    enum Kind {
        case checkin, tipIn, tipOut, games, reward, invite, sendIn, sendOut, spend, other
    }

    static func kind(of entry: NLLedgerPage.Entry) -> Kind {
        switch entry.kind {
        case "checkin": return .checkin
        case "tip", "tip_revoke": return entry.amount > 0 ? .tipIn : .tipOut
        case "transfer": return entry.amount > 0 ? .sendIn : .sendOut
        default:
            if games.contains(entry.kind) { return .games }
            if invites.contains(entry.kind) { return .invite }
            if rewards.contains(entry.kind) { return .reward }
            if spends.contains(entry.kind) { return .spend }
            return .other
        }
    }

    static func typeName(_ kind: Kind) -> String {
        switch kind {
        case .checkin: AppString("签到")
        case .tipIn: AppString("收到打赏")
        case .tipOut: AppString("打赏他人")
        case .games: AppString("红包与抽奖")
        case .reward: AppString("奖励")
        case .invite: AppString("邀请奖励")
        case .sendIn: AppString("收到转赠")
        case .sendOut: AppString("转赠")
        case .spend: AppString("消费")
        case .other: AppString("其他")
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .checkin: "calendar"
        case .tipIn, .tipOut: "heart"
        case .games: "gift"
        case .reward, .invite: "star"
        case .sendIn: "arrow.left"
        case .sendOut: "arrow.right"
        case .spend: "bag"
        case .other: "exclamationmark.circle"
        }
    }

    static func colors(_ kind: Kind) -> (fill: Color, glyph: Color) {
        switch kind {
        case .checkin: EnergyPalette.checkin
        case .tipIn: EnergyPalette.tip
        case .games: EnergyPalette.games
        case .reward, .invite: EnergyPalette.reward
        case .sendIn: EnergyPalette.receive
        default: EnergyPalette.plain
        }
    }

    static func title(_ entry: NLLedgerPage.Entry) -> String {
        let who = entry.counterpart.map { "u/\($0)" }
        let gain = entry.amount > 0
        switch entry.kind {
        case "checkin": return AppString("每日签到")
        case "tip":
            if gain { return who.map { AppString("收到 \($0) 的打赏") } ?? AppString("收到打赏") }
            return who.map { AppString("打赏 \($0)") } ?? AppString("打赏")
        case "tip_revoke":
            if gain { return AppString("撤回打赏") }
            return who.map { AppString("\($0) 撤回了打赏") } ?? AppString("打赏被撤回")
        case "transfer":
            if gain { return who.map { AppString("收到 \($0) 的转赠") } ?? AppString("收到转赠") }
            return who.map { AppString("转赠给 \($0)") } ?? AppString("转赠")
        case "red_envelope_fund": return AppString("发红包")
        case "red_envelope_claim": return AppString("领到红包")
        case "red_envelope_refund": return AppString("红包剩余退回")
        case "lottery_ticket": return AppString("购买抽奖券")
        case "lottery_payout": return AppString("抽奖票款到账")
        case "lottery_refund": return AppString("抽奖券退款")
        case "featured_reward": return AppString("主题被设为精华")
        case "featured_reward_revoke": return AppString("取消精华，收回奖励")
        case "node_owner_reward": return AppString("节点主奖励")
        case "node_owner_reward_revoke": return AppString("收回节点主奖励")
        case "moderator_stipend": return AppString("版主津贴")
        case "system_reward": return AppString("系统奖励")
        case "system_deduct": return AppString("系统扣除")
        case "app_award": return AppString("应用发放")
        case "app_spend": return AppString("应用收取")
        case "app_award_revert": return AppString("应用发放的能量被收回")
        case "task_reward": return AppString("完成日常任务")
        case "onboarding_reward": return AppString("完成新人指引，升到白银")
        case "invite_reward": return AppString("邀请的好友验证了邮箱")
        case "invite_welcome": return AppString("受邀注册奖励")
        case "invite_level_reward": return AppString("邀请的好友升级了")
        case "invite_second_reward": return AppString("二级邀请奖励")
        case "invite_milestone": return AppString("邀请里程碑奖励")
        case "content_unlock":
            if gain { return who.map { AppString("\($0) 购买了你的付费内容") } ?? AppString("付费内容被购买") }
            return who.map { AppString("购买 \($0) 的付费内容") } ?? AppString("购买付费内容")
        case "pay": return AppString("向应用付款")
        case "pay_refund": return AppString("应用退款")
        case "pay_transfer": return AppString("应用转账")
        case "topup": return AppString("充值")
        case "admin_adjust": return AppString("管理员调整")
        case "risk_clawback": return AppString("风控追回")
        case "risk_clawback_revert": return AppString("风控追回已撤销")
        case "move_penalty": return AppString("主题被迁移，扣除能量")
        case "account_deleted": return AppString("账号注销，余额转出")
        default: return entry.memo ?? entry.kind
        }
    }

    /// A person's own message on the entry, if it has one.
    static func note(_ entry: NLLedgerPage.Entry) -> String? {
        guard noteKinds.contains(entry.kind), let memo = entry.memo, !memo.isEmpty else { return nil }
        return memo
    }

    /// The grey line after the time: streak day, the related post, the note.
    static func subtitle(_ entry: NLLedgerPage.Entry) -> String? {
        if entry.kind == "checkin" {
            return (entry.streak ?? 0) > 0 ? AppString("连续第 \(entry.streak ?? 0) 天") : nil
        }
        if let ref = entry.ref, ref.type != "user", let label = ref.label { return label }
        if let note = note(entry) { return note }
        if let label = entry.ref?.label { return label }
        if noteKinds.contains(entry.kind) { return nil }
        return entry.memo
    }
}

// MARK: - Store

@MainActor
@Observable
final class EnergyStore {
    private let client = DiscourseClient()
    private static let pageSize = 20

    private(set) var account: NLPointsAccount?
    private(set) var month: NLPointsMonth?
    private(set) var rank: Int?
    private(set) var checkin: NLCheckinState?
    private(set) var isCheckingIn = false

    private(set) var filter = LedgerFilter()
    private(set) var entries: [NLLedgerPage.Entry] = []
    private(set) var total = 0
    private var nextBefore: Int?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadedOnce = false
    private(set) var errorText: String?

    var hasMore: Bool { nextBefore != nil }

    func loadAll() async {
        async let card: Void = loadCard()
        async let list: Void = loadList()
        _ = await (card, list)
    }

    func loadCard() async {
        async let account = try? client.pointsAccount()
        async let month = try? client.pointsMonth()
        async let board = try? client.leaderboard(period: .all, page: 1, limit: 1)
        async let checkin = try? client.checkinState()
        self.account = await account ?? self.account
        self.month = await month ?? self.month
        if let me = await board?.me { rank = me.rank ?? 0 }
        self.checkin = await checkin ?? self.checkin
    }

    func setFilter(_ filter: LedgerFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        await loadList()
    }

    func loadList() async {
        let asked = filter
        isLoading = true
        errorText = nil
        defer { if asked == filter { isLoading = false } }
        do {
            let page = try await client.ledger(filter: asked, limit: Self.pageSize)
            guard asked == filter else { return }
            entries = page.entries
            total = page.total ?? page.entries.count
            nextBefore = page.nextBefore
            loadedOnce = true
        } catch {
            guard asked == filter, !(error is CancellationError) else { return }
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadMore() async {
        guard let before = nextBefore, !isLoadingMore, !isLoading else { return }
        let asked = filter
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.ledger(filter: asked, before: before, limit: Self.pageSize)
            guard asked == filter else { return }
            entries += page.entries
            nextBefore = page.nextBefore
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    func checkIn() async {
        guard !isCheckingIn else { return }
        isCheckingIn = true
        defer { isCheckingIn = false }
        do {
            let response = try await client.checkIn()
            if response.success == true, let points = response.points {
                ToastCenter.shared.show(AppString("签到成功，获得 \(points) 能量"))
            } else if let message = response.message, !message.isEmpty {
                ToastCenter.shared.show(message)
            }
        } catch {
            ToastCenter.shared.showError(error)
        }
        await loadAll()
    }

    /// The last twelve months, Beijing time, newest first — what the month
    /// menu offers besides 全部时间.
    static var recentMonths: [(key: String, label: String)] {
        let calendar = EnergyFormat.calendar
        let now = Date()
        return (0..<12).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return nil }
            return (EnergyFormat.monthKey.string(from: date), AppString("\(String(year)) 年 \(month) 月"))
        }
    }
}

// MARK: - Page

struct EnergyPage: View {
    @Environment(AppState.self) private var app
    let navigation: PageNavigation
    let onClose: () -> Void

    @State private var store = EnergyStore()
    @State private var scrolled = false
    @State private var expanded: Int?
    @State private var isTransferring = false

    var body: some View {
        Group {
            if app.authed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        EnergyPageTitle(text: AppString("能量明细"))
                            .padding(.bottom, 12)
                        balanceCard
                        filters
                            .padding(.top, 16)
                        typeChips
                            .padding(.top, 10)
                        ledger
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .tracksTitleScroll($scrolled)
                .refreshable { await store.loadAll() }
                .task { await store.loadAll() }
            } else {
                EnergySignedOutView(message: AppString("登录后查看你的能量明细"), onClose: onClose)
            }
        }
        .energyPageChrome(
            title: AppString("能量明细"),
            navigation: navigation,
            titleVisible: scrolled,
            onClose: onClose
        )
        .sheet(isPresented: $isTransferring) {
            EnergyTransferSheet(
                rule: store.account?.transfer,
                balance: store.account?.balance ?? 0
            ) {
                Task { await store.loadAll() }
            }
        }
    }

    // MARK: Balance card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(EnergyPalette.gold)
                        Text(AppString("当前能量"))
                    }
                    .font(Theme.body(13))
                    .foregroundStyle(EnergyPalette.nightMuted)
                    Text(store.account.map { EnergyFormat.grouped($0.balance) } ?? "—")
                        .font(Theme.heading(32, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                HStack(spacing: 8) {
                    checkinControl
                    Button {
                        isTransferring = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .bold))
                            Text(AppString("转赠"))
                        }
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable)
                    // The rule comes with the balance; without it there is
                    // nothing to check an amount against.
                    .disabled(store.account?.transfer == nil)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                cardStat(AppString("本月收入"), value: store.month.map { "+" + EnergyFormat.grouped($0.income) } ?? "—", tint: EnergyPalette.mint)
                cardStat(AppString("本月支出"), value: store.month.map { "−" + EnergyFormat.grouped($0.expense) } ?? "—", tint: .white)
                Button {
                    app.pushPage(.leaderboard)
                } label: {
                    cardStat(AppString("财富榜"), value: rankText, tint: .white)
                }
                .buttonStyle(.pressable)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            }
            .padding(.top, 16)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.profileBanner, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var rankText: String {
        guard let rank = store.rank else { return "—" }
        return rank > 0 ? AppString("第 \(rank) 名") : AppString("未上榜")
    }

    private func cardStat(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(EnergyPalette.nightMuted)
            Text(value)
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 今日已签到 · 连续 N 天 as a quiet pill, or the 签到 +N button while the
    /// day is still open. Nothing for a group that can't check in.
    @ViewBuilder
    private var checkinControl: some View {
        if let state = store.checkin {
            if state.checkedInToday {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text((state.streak ?? 0) > 0 ? AppString("今日已签到 · 连续 \(state.streak ?? 0) 天") : AppString("今日已签到"))
                        .lineLimit(1)
                }
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(EnergyPalette.nightMuted)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white.opacity(0.12), in: Capsule())
            } else if let points = state.todayPoints, points > 0 {
                Button {
                    Task { await store.checkIn() }
                } label: {
                    HStack(spacing: 6) {
                        if store.isCheckingIn {
                            ProgressView().controlSize(.mini).tint(EnergyPalette.goldInk)
                        } else {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(AppString("签到 +\(points)"))
                    }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(EnergyPalette.goldInk)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(EnergyPalette.mint, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .disabled(store.isCheckingIn)
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: 12) {
            EnergySegmented(
                options: [
                    (LedgerFilter.Direction.all, AppString("全部")),
                    (.income, AppString("收入")),
                    (.expense, AppString("支出")),
                ],
                selection: store.filter.direction,
                shadow: true
            ) { direction in
                var next = store.filter
                next.direction = direction
                apply(next)
            }
            Spacer(minLength: 0)
            Menu {
                Picker(AppString("选择月份"), selection: Binding(
                    get: { store.filter.month },
                    set: { month in
                        var next = store.filter
                        next.month = month
                        apply(next)
                    }
                )) {
                    Text(AppString("全部时间")).tag("")
                    ForEach(EnergyStore.recentMonths, id: \.key) { month in
                        Text(month.label).tag(month.key)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(monthLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(Theme.body(14, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .accessibilityLabel(AppString("选择月份"))
        }
    }

    private var monthLabel: String {
        EnergyStore.recentMonths.first { $0.key == store.filter.month }?.label ?? AppString("全部时间")
    }

    /// The server's type groups, in the web's order, 其他 last.
    private var groups: [(key: String, label: String)] {
        [
            ("", AppString("全部")),
            ("checkin", AppString("签到")),
            ("tip", AppString("打赏")),
            ("games", AppString("红包与抽奖")),
            ("reward", AppString("奖励")),
            ("spend", AppString("消费与转赠")),
            ("other", AppString("其他")),
        ]
    }

    private var typeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(groups, id: \.key) { group in
                    Button {
                        var next = store.filter
                        next.group = group.key
                        apply(next)
                    } label: {
                        EnergyFilterChip(title: group.label, isSelected: store.filter.group == group.key)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func apply(_ filter: LedgerFilter) {
        expanded = nil
        Task { await store.setFilter(filter) }
    }

    // MARK: Ledger

    @ViewBuilder
    private var ledger: some View {
        if !store.loadedOnce, store.isLoading {
            EnergyLedgerSkeleton()
        } else if store.entries.isEmpty, let errorText = store.errorText {
            EnergyRetryView(message: errorText) { Task { await store.loadList() } }
        } else if store.entries.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.key) { day in
                    dayHeader(day)
                    ForEach(day.entries) { entry in
                        EnergyLedgerRow(
                            entry: entry,
                            isExpanded: expanded == entry.id,
                            onToggle: {
                                withAnimation(.quick) { expanded = expanded == entry.id ? nil : entry.id }
                            },
                            onOpenRef: openRef
                        )
                    }
                }
                footer
            }
            .opacity(store.isLoading ? 0.5 : 1)
        }
    }

    private struct Day {
        let key: String
        let entries: [NLLedgerPage.Entry]
        var income: Int { entries.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
        var expense: Int { entries.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount } }
    }

    /// Entries by Beijing day, in the order they came. The day's sums count
    /// only what has loaded, as on the web.
    private var days: [Day] {
        var out: [Day] = []
        var current: (key: String, entries: [NLLedgerPage.Entry])?
        for entry in store.entries {
            let key = DiscourseFormat.date(entry.createdAt).map(EnergyFormat.dayKey.string(from:)) ?? ""
            if current?.key == key {
                current?.entries.append(entry)
            } else {
                if let current { out.append(Day(key: current.key, entries: current.entries)) }
                current = (key, [entry])
            }
        }
        if let current { out.append(Day(key: current.key, entries: current.entries)) }
        return out
    }

    private func dayHeader(_ day: Day) -> some View {
        let label = dayLabel(day.key)
        let sums = [
            day.income > 0 ? AppString("收入 +\(EnergyFormat.grouped(day.income))") : nil,
            day.expense > 0 ? AppString("支出 −\(EnergyFormat.grouped(day.expense))") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(label.day).font(Theme.body(14, weight: .bold)).foregroundColor(Theme.text)
                + Text("  " + label.note).font(Theme.body(14)).foregroundColor(Theme.textMuted))
            Spacer(minLength: 0)
            Text(sums)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    /// 11月15日 with 今天 / 昨天 / the weekday.
    private func dayLabel(_ key: String) -> (day: String, note: String) {
        guard let date = EnergyFormat.dayKey.date(from: key) else { return (key, "") }
        let calendar = EnergyFormat.calendar
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let day = AppString("\(parts.month ?? 0)月\(parts.day ?? 0)日")
        let note: String
        if calendar.isDateInToday(date) {
            note = AppString("今天")
        } else if calendar.isDateInYesterday(date) {
            note = AppString("昨天")
        } else {
            let names = [AppString("周日"), AppString("周一"), AppString("周二"), AppString("周三"), AppString("周四"), AppString("周五"), AppString("周六")]
            note = names[((parts.weekday ?? 1) - 1) % 7]
        }
        return (day, note)
    }

    @ViewBuilder
    private var footer: some View {
        if store.hasMore {
            VStack(spacing: 6) {
                Button {
                    Task { await store.loadMore() }
                } label: {
                    CapsuleActionLabel(title: AppString("加载更多"), height: 44, isBusy: store.isLoadingMore)
                }
                .buttonStyle(.pressable)
                .disabled(store.isLoadingMore)
                Text(AppString("已显示 \(store.entries.count) / \(store.total) 条"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 8)
        } else {
            Text(AppString("没有更早的记录了"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        let filter = store.filter
        let monthName = filter.month.isEmpty ? "" : monthLabel + " "
        let title: String
        if !filter.isFiltered {
            title = AppString("还没有能量记录")
        } else {
            switch filter.direction {
            case .expense: title = monthName + AppString("没有支出记录")
            case .income: title = monthName + AppString("没有收入记录")
            case .all: title = monthName + AppString("没有符合条件的记录")
            }
        }
        return VStack(spacing: 0) {
            Image(systemName: "bolt")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 48, height: 48)
                .background(Theme.surface, in: Circle())
            Text(title)
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 8)
            Text(filter.isFiltered ? AppString("换个类型或月份看看。") : AppString("签到、收到打赏、领红包，都会记在这里。"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            if filter.isFiltered {
                Button {
                    apply(LedgerFilter())
                } label: {
                    CapsuleActionLabel(title: AppString("查看全部记录"), height: 44)
                }
                .buttonStyle(.pressable)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
    }

    /// The related object: a post or topic opens natively, a person opens
    /// their profile; anything else goes through the app's link router.
    private func openRef(_ entry: NLLedgerPage.Entry) {
        if let path = entry.ref?.url, let url = nodelocSiteURL(path) {
            LinkRouter.open(url, app: app, browser: .shared)
        } else if let name = entry.counterpart {
            app.pushPage(.profile(UserProfileTarget(username: name)))
        }
    }
}

// MARK: - Row

/// One ledger entry: icon disc, title, time and the related thing, the signed
/// amount over the balance after it, and a chevron that opens the details.
private struct EnergyLedgerRow: View {
    let entry: NLLedgerPage.Entry
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpenRef: (NLLedgerPage.Entry) -> Void

    var body: some View {
        let kind = LedgerEntryStyle.kind(of: entry)
        let colors = LedgerEntryStyle.colors(kind)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: LedgerEntryStyle.symbol(kind))
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(colors.glyph)
                        .frame(width: 40, height: 40)
                        .background(colors.fill, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LedgerEntryStyle.title(entry))
                            .font(Theme.body(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(subline)
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(EnergyFormat.signed(entry.amount))
                            .font(Theme.body(16, weight: .bold))
                            .foregroundStyle(entry.amount > 0 ? EnergyPalette.plus : Theme.text)
                        if let balance = entry.balanceAfter {
                            Text(AppString("余额 \(EnergyFormat.grouped(balance))"))
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 10)
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityValue(isExpanded ? AppString("已展开") : AppString("已收起"))

            if isExpanded {
                details(typeName: LedgerEntryStyle.typeName(kind))
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    private var subline: String {
        let time = DiscourseFormat.date(entry.createdAt).map(EnergyFormat.time.string(from:)) ?? ""
        guard let sub = LedgerEntryStyle.subtitle(entry), !sub.isEmpty else { return time }
        return time + " · " + sub
    }

    private func details(typeName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let no = entry.no { line(AppString("流水号"), Text(no).monospacedDigit()) }
            if let date = DiscourseFormat.date(entry.createdAt) {
                line(AppString("时间"), Text(EnergyFormat.full.string(from: date)).monospacedDigit())
            }
            line(AppString("类型"), Text(typeName))
            if let ref = entry.ref, let label = ref.label {
                line(AppString("关联"), linkText(label, enabled: ref.url != nil))
            } else if let name = entry.counterpart {
                line(AppString("关联"), linkText("u/\(name)", enabled: true))
            } else if let memo = entry.memo, !memo.isEmpty, !LedgerEntryStyle.noteKinds.contains(entry.kind) {
                line(AppString("说明"), Text(memo))
            }
            if let note = LedgerEntryStyle.note(entry) {
                line(entry.kind == "admin_adjust" ? AppString("原因") : AppString("留言"), Text("“\(note)”"))
            }
        }
        .font(Theme.body(13))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func linkText(_ label: String, enabled: Bool) -> some View {
        if enabled {
            Button { onOpenRef(entry) } label: {
                Text(label)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        } else {
            Text(label)
        }
    }

    private func line<Value: View>(_ label: String, _ value: Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 72, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Skeleton, signed out

private struct EnergyLedgerSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonLine(widthFraction: 0.3, height: 14)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(Theme.neutral300).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonLine(widthFraction: 0.6, height: 13)
                        SkeletonLine(widthFraction: 0.4, height: 11)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 48, height: 14)
                }
                .frame(height: 64)
            }
        }
        .skeletonPulsing()
        .accessibilityLabel(AppString("加载中"))
    }
}

/// What a guest who followed a /points or /invites link sees.
struct EnergySignedOutView: View {
    @Environment(AppState.self) private var app
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            EmptyStateView(icon: "person.crop.circle.badge.questionmark", message: message, iconSize: 28)
            Button {
                onClose()
                requestLogin(app, .generic)
            } label: {
                Text(AppString("登录"))
            }
            .buttonStyle(FilledButtonStyle())
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Profile tab header

/// The top of 我的's 能量 tab, after the artboard: 当前能量 with the reader's
/// 财富榜 place and 全部明细 beside it.
struct EnergyTabHeader: View {
    @Environment(AppState.self) private var app
    let balance: Int?

    @State private var rank: Int?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(AppString("当前能量"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                Text(balance.map(EnergyFormat.grouped) ?? "—")
                    .font(Theme.heading(24, weight: .heavy))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                app.pushPage(.leaderboard)
            } label: {
                CapsuleActionLabel(
                    title: (rank ?? 0) > 0 ? AppString("财富榜第 \(rank ?? 0) 名") : AppString("财富榜"),
                    height: 44
                )
            }
            .buttonStyle(.pressable)
            Button {
                app.pushPage(.energy)
            } label: {
                Text(AppString("全部明细"))
            }
            .buttonStyle(FilledButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .task {
            rank = (try? await DiscourseClient().leaderboard(period: .all, page: 1, limit: 1))?.me?.rank
        }
    }
}
