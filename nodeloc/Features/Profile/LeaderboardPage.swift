//
//  LeaderboardPage.swift
//  nodeloc
//
//  财富排行榜 — the same table as the web's /rank, read from
//  `GET /api/v1/points/leaderboard?period=&page=&limit=20`. The server
//  recomputes it hourly and the endpoint only reads, so this page never
//  recalculates anything itself and the numbers always agree with the web's.
//
//  Laid out after the design's iOS artboard: title and period switch, the top
//  three on a podium (page one only), the reader's own standing, twenty rows a
//  page with 上一页 / 下一页, and the 我的能量 / 如何获得能量 card under it.
//
//  Income over a week or a month deliberately excludes transfers between
//  members — otherwise two accounts passing energy back and forth would climb
//  the board. Tips, red envelopes and lottery winnings all count.
//

import SwiftUI

// MARK: - Palette

/// The colours the energy, leaderboard and invite artboards use beyond the
/// shared Theme tokens, each with a dark counterpart (the web's own dark
/// values where it has them).
enum EnergyPalette {
    /// Secondary text on the night-green cards.
    static let nightMuted = Color(hex: 0xC9D6D0)
    /// The bright mint used on the night cards and the 你的名次 ring.
    static let mint = Color(hex: 0x5CC79A)
    static let gold = Color(hex: 0xFF9C38)
    static let goldInk = Color(hex: 0x0B1F18)
    static let bronzeRing = Color(hex: 0xC98B5E)
    static let bronzeFill = Color(light: 0xF1E3D6, dark: 0x3A2A1A)
    static let bronzeText = Color(light: 0x92400E, dark: 0xF2C9A8)
    /// Gains: #00573B on light, the mint on dark.
    static let plus = Color(light: 0x00573B, dark: 0x5CC79A)
    /// Warnings in small text (待验证).
    static let warn = Color(light: 0x8A4B00, dark: 0xFFCF94)
    static let mineFill = Color(light: 0xEEF7F2, dark: 0x173326)

    // Ledger icon discs: (fill, glyph).
    static let checkin = (Color(light: 0xEEF7F2, dark: 0x173326), Color(light: 0x007A52, dark: 0x5CC79A))
    static let tip = (Color(light: 0xFCE7F0, dark: 0x3A1A28), Color(light: 0x9D174D, dark: 0xF49AC1))
    static let games = (Color(light: 0xFFF1E0, dark: 0x3A2A12), Color(light: 0x8A4B00, dark: 0xFFCF94))
    static let reward = (Color(light: 0xEFE7FB, dark: 0x2A2142), Color(light: 0x6D28D9, dark: 0xC4B5FD))
    static let receive = (Color(light: 0xE0F2F6, dark: 0x13323A), Color(light: 0x0E7490, dark: 0x67E8F9))
    static let plain = (Color(light: 0xE5EBEE, dark: 0x272B2F), Color(light: 0x2A3C42, dark: 0xC4CACD))
}

// MARK: - Shared pieces

/// The 24pt heavy page title the energy, leaderboard and invite artboards open
/// with, under the bar.
struct EnergyPageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.heading(24, weight: .heavy))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The design's segmented control: a #E5EBEE capsule, 38pt pills, the
/// selected one white and bold.
struct EnergySegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    /// The energy page's pill casts a faint shadow; the leaderboard's doesn't.
    var shadow = false
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(Theme.body(14, weight: isSelected || shadow ? .bold : .medium))
                        .foregroundStyle(isSelected ? Theme.text : Theme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.segmentPill)
                                    .shadow(color: .black.opacity(shadow ? 0.16 : 0), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.chip, in: Capsule())
    }
}

/// A 36pt filter chip: ink when selected, outlined otherwise, with an
/// optional count after the label.
struct EnergyFilterChip: View {
    let title: String
    var count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.body(13, weight: .bold))
            if let count {
                Text("\(count)")
                    .font(Theme.body(13))
                    .opacity(0.75)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isSelected ? Theme.bg : Theme.text)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(isSelected ? Theme.text : Theme.bg, in: Capsule())
        .overlay {
            Capsule().strokeBorder(isSelected ? Theme.text : Theme.hairline, lineWidth: 1)
        }
        .contentShape(Capsule())
    }
}

/// The bar for the energy, leaderboard and invite pages: no title while the
/// page's own big title is on screen, the name in the middle once it has
/// scrolled away, and a ‹ for the bottom page of the routed stack.
private struct EnergyPageChrome: ViewModifier {
    let title: String
    let navigation: PageNavigation
    let titleVisible: Bool
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if navigation.drawsBackButton {
                    ToolbarItem(placement: .topBarLeading) {
                        PageBackButton(action: onClose)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .opacity(titleVisible ? 1 : 0)
                        .animation(.quick, value: titleVisible)
                }
            }
            .softTopScrollEdge()
            .inPageNavigation(navigation)
    }
}

extension View {
    func energyPageChrome(
        title: String,
        navigation: PageNavigation,
        titleVisible: Bool,
        onClose: @escaping () -> Void
    ) -> some View {
        modifier(EnergyPageChrome(title: title, navigation: navigation, titleVisible: titleVisible, onClose: onClose))
    }

    /// Reports whether the page has scrolled past its big title.
    func tracksTitleScroll(_ scrolled: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 40
        } action: { _, newValue in
            scrolled.wrappedValue = newValue
        }
    }
}

/// Error text and a 重试 capsule, centred.
struct EnergyRetryView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            Text(message)
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                CapsuleActionLabel(title: AppString("重试"), height: 44)
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
    }
}

// MARK: - Store

@MainActor
@Observable
final class LeaderboardStore {
    /// The web's page size, so 第 N 页 means the same page on both.
    static let pageSize = 20
    /// The endpoint answers at most page 1000.
    private static let maxPage = 1000

    private let client = DiscourseClient()

    private(set) var period: DiscourseClient.LeaderboardPeriod = .all
    private(set) var page = 1
    private(set) var board: NLLeaderboard?
    private(set) var isLoading = false
    private(set) var errorText: String?

    /// The side card, signed in only.
    private(set) var balance: Int?
    private(set) var weekGain: Int?
    private(set) var monthGain: Int?
    private(set) var checkin: NLCheckinState?
    private(set) var isCheckingIn = false
    /// 如何获得能量 rows that depend on site settings the reader can see.
    private(set) var taskRange: (lo: Int, hi: Int)?
    private(set) var inviteRewards: NLInviteOverview.Rewards?

    var pageCount: Int {
        guard let total = board?.total, total > 0 else { return 1 }
        return min((total + Self.pageSize - 1) / Self.pageSize, Self.maxPage)
    }

    /// Page one's first three stand on the podium; the table starts at four.
    var podium: [NLLeaderboard.Entry] {
        guard page == 1, let users = board?.users, users.count >= 3 else { return [] }
        return [users[1], users[0], users[2]]
    }

    var rows: [NLLeaderboard.Entry] {
        guard let users = board?.users else { return [] }
        return podium.isEmpty ? users : Array(users.dropFirst(3))
    }

    func load(period: DiscourseClient.LeaderboardPeriod? = nil, page: Int? = nil) async {
        if let period, period != self.period {
            // The old list stays until the new one arrives: no page loader.
            self.period = period
            self.page = 1
        }
        if let page { self.page = min(max(page, 1), Self.maxPage) }
        let asked = (self.period, self.page)
        isLoading = true
        errorText = nil
        defer { if asked == (self.period, self.page) { isLoading = false } }
        do {
            let result = try await client.leaderboard(period: asked.0, page: asked.1, limit: Self.pageSize)
            // Another period or page was picked while this one was on its way.
            guard asked == (self.period, self.page) else { return }
            board = result
        } catch {
            guard asked == (self.period, self.page), !(error is CancellationError) else { return }
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 我的能量: balance, this week's and month's income (the reader's own
    /// value on those two boards, as the web reads it), check-in state, and
    /// the setting-driven rows of 如何获得能量.
    func loadMine() async {
        async let account = try? client.pointsAccount()
        async let week = try? client.leaderboard(period: .week, page: 1, limit: 1)
        async let month = try? client.leaderboard(period: .month, page: 1, limit: 1)
        async let state = try? client.checkinState()
        async let tasks = try? client.weeklyTasks()
        async let invites = try? client.inviteOverview()
        balance = await account?.balance
        weekGain = await week?.me?.value
        monthGain = await month?.me?.value
        checkin = await state
        let energies = (await tasks)?.tasks.compactMap(\.energy).filter { $0 > 0 } ?? []
        if let lo = energies.min(), let hi = energies.max() { taskRange = (lo, hi) }
        inviteRewards = await invites?.overview.rewards
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
        checkin = try? await client.checkinState()
        balance = (try? await client.pointsAccount())?.balance ?? balance
    }
}

// MARK: - Page

struct LeaderboardPage: View {
    @Environment(AppState.self) private var app
    let navigation: PageNavigation
    let onClose: () -> Void

    @State private var store = LeaderboardStore()
    @State private var scrolled = false
    private var profile: ProfileStore { .shared }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0)
                        .id("rank-top")
                    boardContent(proxy: proxy)
                    LeaderboardSideCard(store: store, isSignedIn: app.authed) {
                        app.pushPage(.energy)
                    }
                    // What the removed subtitle said, quietly at the end.
                    Text(subtitle)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .tracksTitleScroll($scrolled)
            .refreshable {
                await store.load()
                if app.authed { await store.loadMine() }
            }
        }
        .energyPageChrome(
            title: AppString("财富榜"),
            navigation: navigation,
            titleVisible: true,
            onClose: onClose
        )
        .toolbar {
            // 总榜 / 本周 / 本月, the node page's sort control in the bar.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(AppString("榜单"), selection: Binding(
                        get: { store.period },
                        set: { period in Task { await store.load(period: period) } }
                    )) {
                        ForEach(DiscourseClient.LeaderboardPeriod.allCases, id: \.self) { period in
                            Text(period.title).tag(period)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.period.title)
                            .font(Theme.body(15, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.text)
                }
                .accessibilityLabel(AppString("榜单：\(store.period.title)"))
            }
        }
        .task { await store.load() }
        .task(id: app.authed) {
            if app.authed { await store.loadMine() }
        }
    }

    // MARK: Header

    /// 按能量排名 · 每小时更新 · 14:00 更新 — the web's line, its time in
    /// Beijing time like everything else on the board.
    private var subtitle: String {
        var parts = [AppString("按能量排名")]
        let minutes = store.board?.refreshMinutes ?? 60
        parts.append(minutes == 60 ? AppString("每小时更新") : AppString("每 \(minutes) 分钟更新"))
        if let updated = DiscourseFormat.date(store.board?.updatedAt) {
            parts.append(AppString("\(EnergyFormat.time.string(from: updated)) 更新"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Board

    @ViewBuilder
    private func boardContent(proxy: ScrollViewProxy) -> some View {
        if store.board == nil, store.isLoading {
            LeaderboardSkeleton()
                .padding(.top, 20)
        } else if store.board == nil, let errorText = store.errorText {
            EnergyRetryView(message: errorText) { Task { await store.load() } }
        } else if let board = store.board, board.users.isEmpty {
            EmptyStateView(icon: "trophy", message: AppString("榜上还没有人。"), iconSize: 26)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 52)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !store.podium.isEmpty {
                    podium
                        .padding(.top, 20)
                }
                if app.authed, let board = store.board {
                    mineCard(board.me)
                        .task { if profile.username.isEmpty { await profile.load(isAppAuthed: true) } }
                        .padding(.top, 16)
                }
                VStack(spacing: 0) {
                    ForEach(store.rows) { row($0) }
                    pager(proxy: proxy)
                }
                .padding(.top, 8)
            }
            .opacity(store.isLoading ? 0.5 : 1)
            .animation(.quick, value: store.isLoading)
        }
    }

    private var podium: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(store.podium) { entry in
                LeaderboardPodiumSeat(entry: entry, isIncome: store.period != .all) {
                    open(entry)
                }
            }
        }
    }

    /// 你当前第 N 名, or 你还没有上榜 — the web's two cases.
    private func mineCard(_ me: NLLeaderboard.Me?) -> some View {
        let rank = me?.rank ?? 0
        let title = rank > 0 ? AppString("你当前第 \(rank) 名") : AppString("你还没有上榜")
        var detail: String
        if rank > 0 {
            detail = AppString("\(value(me?.value ?? 0)) 能量")
            if let gap = me?.gap, gap > 0 {
                detail += " · " + AppString("距离上一名还差 \(EnergyFormat.grouped(gap))")
            }
        } else {
            detail = store.period == .all ? AppString("有了能量就会出现在榜上。") : AppString("这段时间还没有收入。")
        }
        // Your own row on the board, when you're on this page of it: its
        // avatar stands in until the profile has loaded (opened straight
        // from a link, 我的 may not have been visited yet — that was the "?").
        let onBoard = store.board?.users.first { $0.me == true }
        let username = profile.username.isEmpty ? (onBoard?.username ?? "") : profile.username
        let avatar = profile.avatarURL ?? onBoard?.avatarUrl.flatMap { URL(string: $0, relativeTo: DiscourseConfig.baseURL)?.absoluteURL }
        return HStack(spacing: 12) {
            RemoteAvatar(
                url: avatar,
                letter: profile.initial != "?" ? profile.initial : (username.first.map { String($0).uppercased() } ?? "?"),
                variant: abs(username.hashValue) % 2,
                size: 40
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                app.pushPage(.profile(UserProfileTarget(
                    username: profile.username,
                    displayName: profile.displayName,
                    avatarURL: profile.avatarURL
                )))
            } label: {
                Text(AppString("我的主页"))
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(profile.username.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(EnergyPalette.mineFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(EnergyPalette.mint, lineWidth: 1)
        }
    }

    private func row(_ entry: NLLeaderboard.Entry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 12) {
                Text("\(entry.rank)")
                    .font(Theme.heading(16, weight: .heavy))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 32)
                RemoteAvatar(
                    url: entry.avatarUrl.flatMap(URL.init(string:)),
                    letter: initial(entry),
                    variant: entry.userId % 2,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.me == true ? AppString("\(name(entry))（我）") : name(entry))
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    // Null when that reader hides their tier.
                    if let tierName = entry.tierName {
                        Text(tierName)
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(value(entry.value))
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    private func pager(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            pagerButton(AppString("上一页"), enabled: store.page > 1) {
                go(to: store.page - 1, proxy: proxy)
            }
            Spacer(minLength: 0)
            (Text(AppString("第 ")) + Text("\(store.page)").foregroundColor(Theme.text).bold()
                + Text(AppString(" / \(store.pageCount) 页")))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 0)
            pagerButton(AppString("下一页"), enabled: store.page < store.pageCount) {
                go(to: store.page + 1, proxy: proxy)
            }
        }
        .padding(.vertical, 16)
    }

    private func pagerButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Theme.chip, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled || store.isLoading)
        .opacity(enabled ? 1 : 0.45)
    }

    private func go(to page: Int, proxy: ScrollViewProxy) {
        Task {
            await store.load(page: page)
            withAnimation(.quick) { proxy.scrollTo("rank-top", anchor: .top) }
        }
    }

    // MARK: Helpers

    private func name(_ entry: NLLeaderboard.Entry) -> String {
        (entry.name?.isEmpty == false ? entry.name : nil) ?? entry.username
    }

    private func initial(_ entry: NLLeaderboard.Entry) -> String {
        name(entry).first.map { String($0).uppercased() } ?? "?"
    }

    /// The board's number: energy on 总榜, `+income` on the period boards.
    private func value(_ number: Int) -> String {
        store.period == .all ? EnergyFormat.grouped(number) : "+" + EnergyFormat.grouped(number)
    }

    private func open(_ entry: NLLeaderboard.Entry) {
        app.pushPage(.profile(UserProfileTarget(
            username: entry.username,
            displayName: entry.name,
            avatarURL: entry.avatarUrl.flatMap(URL.init(string:))
        )))
    }
}

// MARK: - Podium

/// One of the three podium seats: first in the middle on the night card,
/// taller and with a gold ring; second and third on grey.
private struct LeaderboardPodiumSeat: View {
    let entry: NLLeaderboard.Entry
    let isIncome: Bool
    let onTap: () -> Void

    private var isFirst: Bool { entry.rank == 1 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                medal
                RemoteAvatar(
                    url: entry.avatarUrl.flatMap(URL.init(string:)),
                    letter: initial,
                    variant: entry.userId % 2,
                    size: avatarSize
                )
                .overlay(Circle().strokeBorder(ring, lineWidth: 3))
                .padding(.top, 8)
                Text(name)
                    .font(Theme.body(15, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, 8)
                Text(entry.tierName ?? " ")
                    .font(Theme.body(12))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                Text((isIncome ? "+" : "") + EnergyFormat.grouped(entry.value))
                    .font(Theme.heading(17, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 6)
                Text(AppString("能量"))
                    .font(Theme.body(12))
                    .foregroundStyle(muted)
            }
            .foregroundStyle(isFirst ? Color.white : Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, isFirst ? 24 : 16)
            .padding(.bottom, 16)
            .background(
                isFirst ? Theme.profileBanner : Theme.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(AppString("第 \(entry.rank) 名：\(name)"))
    }

    private var medal: some View {
        Text("\(entry.rank)")
            .font(Theme.heading(15, weight: .heavy))
            .foregroundStyle(medalText)
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 28)
            .background(medalFill, in: Capsule())
    }

    private var avatarSize: CGFloat { isFirst ? 60 : 48 }
    private var muted: Color { isFirst ? EnergyPalette.nightMuted : Theme.textMuted }

    private var ring: Color {
        switch entry.rank {
        case 1: EnergyPalette.gold
        case 2: Theme.textFaint
        default: EnergyPalette.bronzeRing
        }
    }

    private var medalFill: Color {
        switch entry.rank {
        case 1: EnergyPalette.gold
        case 2: Theme.hairline
        default: EnergyPalette.bronzeFill
        }
    }

    private var medalText: Color {
        switch entry.rank {
        case 1: EnergyPalette.goldInk
        case 2: Theme.textSecondary
        default: EnergyPalette.bronzeText
        }
    }

    private var name: String {
        (entry.name?.isEmpty == false ? entry.name : nil) ?? entry.username
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Side card

/// 我的能量 (signed in) and 如何获得能量, under the table — where the web puts
/// its side column on a phone.
private struct LeaderboardSideCard: View {
    let store: LeaderboardStore
    let isSignedIn: Bool
    let onOpenLedger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSignedIn {
                mine
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
            Text(AppString("如何获得能量"))
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            ForEach(ways.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    Text(ways[index].label)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ways[index].gain)
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(EnergyPalette.plus)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minHeight: 40)
            }
            Text(AppString("能量可以用来打赏、发红包和参加抽奖。刷分的账号会被清零，也就不在榜上了。"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(AppString("我的能量"))
            } icon: {
                Image(systemName: "bolt.circle")
            }
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(Theme.textMuted)
            .labelStyle(CompactLabelStyle())

            Text(store.balance.map(EnergyFormat.grouped) ?? "—")
                .font(Theme.heading(32, weight: .heavy))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .padding(.top, 4)
            Text(AppString("本周 +\(EnergyFormat.grouped(store.weekGain ?? 0)) · 本月 +\(EnergyFormat.grouped(store.monthGain ?? 0))"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)

            Button(action: onOpenLedger) {
                HStack(spacing: 4) {
                    Text(AppString("查看能量明细"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            checkinButton
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var checkinButton: some View {
        if let state = store.checkin {
            if state.checkedInToday {
                // The web's `btn block off`: a disabled grey bar.
                Text(state.streak.map { $0 > 0 ? AppString("今日已签到 · 连续 \($0) 天") : AppString("今日已签到") } ?? AppString("今日已签到"))
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.chip, in: Capsule())
            } else if let points = state.todayPoints, points > 0 {
                Button {
                    Task { await store.checkIn() }
                } label: {
                    HStack(spacing: 6) {
                        if store.isCheckingIn {
                            ProgressView().controlSize(.mini).tint(Theme.onAccent)
                        }
                        Text(AppString("签到领 \(points) 能量"))
                    }
                }
                .buttonStyle(FilledButtonStyle(block: true))
                .disabled(store.isCheckingIn)
            }
        }
    }

    /// The web's 如何获得能量, from what this reader can read: the check-in
    /// award for their tier, the task range and the invite rewards come from
    /// the API; the featured and node-owner rewards are fixed amounts in the
    /// backend (`play.FeaturedReward`, `play.OwnerRewardFor…`).
    private var ways: [(label: String, gain: String)] {
        var ways: [(String, String)] = []
        if let points = store.checkin?.todayPoints, points > 0 {
            ways.append((AppString("每日签到"), "+\(points)"))
        } else {
            ways.append((AppString("每日签到"), AppString("+1 至 +30，看段位")))
        }
        ways.append((AppString("主题被设为精华"), "+200"))
        ways.append((AppString("你的节点里有新主题 / 新回帖"), "+5 / +1"))
        if let rewards = store.inviteRewards {
            if rewards.inviter > 0 { ways.append((AppString("邀请的好友验证了邮箱"), "+\(rewards.inviter)")) }
            if rewards.welcome > 0 { ways.append((AppString("受邀注册并验证邮箱"), "+\(rewards.welcome)")) }
        }
        if let range = store.taskRange {
            ways.append((
                AppString("完成每日、每周任务"),
                range.lo == range.hi ? "+\(range.hi)" : AppString("+\(range.lo) 至 +\(range.hi)")
            ))
        }
        ways.append((AppString("收到打赏"), AppString("按金额")))
        ways.append((AppString("抢红包、抽奖中奖"), AppString("看运气")))
        return ways
    }
}

// MARK: - Skeleton

/// The board's first load: three podium blocks and a few rows, where the real
/// ones will land.
private struct LeaderboardSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.neutral300)
                        .frame(height: index == 1 ? 196 : 170)
                }
            }
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 20, height: 14)
                            .frame(width: 32)
                        Circle().fill(Theme.neutral300).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonLine(widthFraction: 0.5, height: 12)
                            SkeletonLine(widthFraction: 0.25, height: 10)
                        }
                        RoundedRectangle(cornerRadius: 4).fill(Theme.neutral300).frame(width: 64, height: 14)
                    }
                    .frame(height: 60)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.chip).frame(height: 1) }
                }
            }
            .padding(.top, 8)
        }
        .skeletonPulsing()
        .accessibilityLabel(AppString("加载中"))
    }
}
