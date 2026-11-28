//
//  ReputationPage.swift
//  nodeloc
//
//  声望与成就 — the reader's tier and reputation, this week's tasks, their
//  achievements and 主页展示, the latest reputation changes and where the
//  total came from. A page on the routed page stack, opened from the 成就
//  card and the 声望 cell on 我的.
//
//  Reads `GET /api/v1/me/reputation`, `GET /api/v1/tiers`,
//  `GET /api/v1/me/tasks`, `GET /api/v1/achievements` and
//  `GET /api/v1/me/reputation/ledger`; 展示在主页 writes
//  `PUT|DELETE /api/v1/achievements/{key}/pin`.
//
//  The tier card and the task strip are shared with 升级进度 (UpgradePage).
//

import SwiftUI

// MARK: - Store

@MainActor
@Observable
final class ReputationStore {
    private let client = DiscourseClient()

    /// 升级进度 needs neither achievements nor the ledger.
    let includesAchievements: Bool

    private(set) var reputation: NLReputation?
    private(set) var tiers: [NLTiers.Tier] = []
    private(set) var tasks: NLTaskList?
    private(set) var achievements: NLAchievementList?
    private(set) var ledger: [NLReputationLedger.Item] = []
    /// 主页展示, in order. Kept apart from `achievements` so a pin shows at
    /// once without reloading the whole catalogue.
    private(set) var showcaseKeys: [String] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    init(includesAchievements: Bool = true) {
        self.includesAchievements = includesAchievements
    }

    func load() async {
        isLoading = !hasLoaded
        defer {
            isLoading = false
            hasLoaded = true
        }

        let withAchievements = includesAchievements
        async let reputationCall = try? client.reputation()
        async let tiersCall = try? client.tierCatalog()
        async let tasksCall = try? client.weeklyTasks()
        async let achievementsCall: NLAchievementList? = withAchievements ? (try? await client.achievementList()) : nil
        async let ledgerCall: NLReputationLedger? = withAchievements ? (try? await client.reputationLedger(limit: 5)) : nil

        let (loadedReputation, loadedTiers, loadedTasks, loadedAchievements, loadedLedger) =
            await (reputationCall, tiersCall, tasksCall, achievementsCall, ledgerCall)

        if let loadedReputation { reputation = loadedReputation }
        if let loadedTiers { tiers = loadedTiers.sorted { $0.level < $1.level } }
        if let loadedTasks { tasks = loadedTasks }
        if let loadedAchievements {
            achievements = loadedAchievements
            showcaseKeys = loadedAchievements.showcase
                ?? loadedAchievements.achievements.filter { $0.pinned == true }.map(\.key)
        }
        if let loadedLedger { ledger = loadedLedger.items }
    }

    /// Nothing personal came back: signed out, or every read failed.
    var reputationFailed: Bool { hasLoaded && reputation == nil && achievements == nil }

    // MARK: Showcase

    var maxShowcase: Int { achievements?.maxShowcase ?? 3 }

    func isPinned(_ item: AchievementItem) -> Bool { showcaseKeys.contains(item.key) }

    var showcaseItems: [AchievementItem] {
        let all = achievements?.achievements ?? []
        return showcaseKeys.compactMap { key in all.first { $0.key == key } }
    }

    /// 展示在主页 / 取消展示. Refuses a fourth pin locally with the server's
    /// own wording rather than sending a request that can only fail.
    func setPinned(_ item: AchievementItem, _ pinned: Bool) async throws {
        if pinned, !isPinned(item), showcaseKeys.count >= maxShowcase {
            throw ReputationNotice(AppString("最多展示三枚，先取消一枚"))
        }
        try await client.setAchievementPinned(key: item.key, pinned: pinned)
        if pinned {
            if !showcaseKeys.contains(item.key) { showcaseKeys.append(item.key) }
        } else {
            showcaseKeys.removeAll { $0 == item.key }
        }
    }

    // MARK: Tiers

    /// Index of the reader's tier in `tiers`.
    var currentTierIndex: Int? {
        guard let reputation else { return nil }
        if let level = reputation.tier, let index = tiers.firstIndex(where: { $0.level == level }) {
            return index
        }
        if let name = reputation.tierName {
            return tiers.firstIndex { $0.name == name }
        }
        return nil
    }

    /// The reputation a tier starts at, from the summary (signed in only).
    func threshold(of tier: NLTiers.Tier) -> Int? {
        reputation?.tiers?.first { $0.level == tier.level }?.threshold
    }

    var nextTierName: String? {
        if let name = reputation?.next?.name { return name }
        guard let index = currentTierIndex, tiers.indices.contains(index + 1) else { return nil }
        return tiers[index + 1].name
    }

    // MARK: Ledger wording

    /// A task's title by its key, for 完成每日任务：….
    func task(forKey key: String?) -> NLTaskList.Task? {
        guard let key else { return nil }
        return tasks?.tasks.first { $0.key == key }
    }

    func achievement(forKey key: String?) -> AchievementItem? {
        guard let key else { return nil }
        return achievements?.achievements.first { $0.key == key }
    }
}

/// A refusal worded for the reader.
struct ReputationNotice: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Page

struct ReputationPage: View {
    let navigation: PageNavigation
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var store = ReputationStore()
    @State private var selectedTierIndex: Int?
    @State private var achievementCategory: String?
    @State private var openAchievement: AchievementItem?
    @State private var showsLedger = false
    @State private var showsRules = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.isLoading {
                    ReputationSkeleton()
                } else if store.reputationFailed {
                    ReputationErrorView { Task { await store.load() } }
                } else {
                    if store.reputation != nil {
                        ReputationHero(store: store, selectedTierIndex: $selectedTierIndex)
                    }
                    ReputationTasksSection(store: store, onOpen: openTaskLink)
                    achievementsSection
                    showcaseCard
                    recentCard
                    sourcesCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.load() }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigation.drawsBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    PageBackButton(action: onClose)
                }
            }
            if let url = shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityLabel(AppString("分享"))
                }
            }
        }
        .inPageNavigation(navigation)
        .task { if !store.hasLoaded { await store.load() } }
        .sheet(item: $openAchievement) { item in
            AchievementDetailSheet(item: item, store: store)
        }
        .sheet(isPresented: $showsLedger) {
            ReputationLedgerSheet(store: store)
        }
    }

    /// The reader's public profile, where 主页展示 shows.
    private var shareURL: URL? {
        guard let username = DiscourseAuth.shared.username, !username.isEmpty else { return nil }
        return DiscourseConfig.baseURL.appendingPathComponent("u").appendingPathComponent(username)
    }

    private func openTaskLink(_ task: NLTaskList.Task) {
        app.openReputationTaskLink(task)
    }
}

// MARK: - Achievements

extension ReputationPage {
    private var allAchievements: [AchievementItem] { store.achievements?.achievements ?? [] }

    /// Categories in the order the server lists them.
    private var categories: [String] {
        var seen: [String] = []
        for item in allAchievements {
            if let category = item.category, !seen.contains(category) { seen.append(category) }
        }
        return seen
    }

    private var hasRepeatable: Bool { allAchievements.contains { $0.repeatable == true } }

    private var filtered: [AchievementItem] {
        switch achievementCategory {
        case nil: return allAchievements
        case "__repeatable": return allAchievements.filter { $0.repeatable == true }
        case let category?: return allAchievements.filter { $0.category == category }
        }
    }

    private var unlockedItems: [AchievementItem] {
        filtered.filter(\.isUnlocked)
    }

    /// Closest first; retired and admin-only ones last (the web's order).
    private var lockedItems: [AchievementItem] {
        filtered.filter { !$0.isUnlocked }
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element, right = rhs.element
                if left.isOff != right.isOff { return !left.isOff }
                if left.fraction != right.fraction { return left.fraction > right.fraction }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    @ViewBuilder
    var achievementsSection: some View {
        if let list = store.achievements, !allAchievements.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(AppString("成就"))
                        .font(Theme.heading(20, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(AppString("已解锁 \(list.unlockedCount ?? allAchievements.filter(\.isUnlocked).count) / \(list.total ?? allAchievements.count)"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }

                if categories.count > 1 || hasRepeatable {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            categoryChip(AppString("全部"), value: nil)
                            ForEach(categories, id: \.self) { category in
                                categoryChip(category, value: category)
                            }
                            if hasRepeatable {
                                categoryChip(AppString("可重复"), value: "__repeatable")
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -16)
                    .padding(.top, 10)
                }

                if !unlockedItems.isEmpty {
                    sectionCaption(AppString("已解锁 · \(unlockedItems.count)"))
                        .padding(.top, 16)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        spacing: 8
                    ) {
                        ForEach(unlockedItems) { item in
                            Button { openAchievement = item } label: { unlockedTile(item) }
                                .buttonStyle(.pressable)
                                .accessibilityLabel(AppString("\(item.title)，已解锁"))
                        }
                    }
                    .padding(.top, 10)
                }

                if !lockedItems.isEmpty {
                    sectionCaption(AppString("还没解锁 · \(lockedItems.count) · 离得最近的排前面"))
                        .padding(.top, 20)
                    VStack(spacing: 0) {
                        ForEach(Array(lockedItems.enumerated()), id: \.element.id) { index, item in
                            Button { openAchievement = item } label: { lockedRow(item) }
                                .buttonStyle(.pressable)
                                .accessibilityLabel(AppString("\(item.title)，未解锁"))
                            if index < lockedItems.count - 1 {
                                Rectangle().fill(Theme.chip).frame(height: 1)
                            }
                        }
                    }
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .padding(.top, 10)
                }

                if unlockedItems.isEmpty, lockedItems.isEmpty {
                    Text(AppString("这一类里没有成就。"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(Theme.textMuted)
    }

    private func categoryChip(_ title: String, value: String?) -> some View {
        let selected = achievementCategory == value
        return Button {
            withAnimation(.quick) { achievementCategory = value }
        } label: {
            Text(title)
                .font(Theme.body(13, weight: .bold))
                .foregroundStyle(selected ? Theme.bg : Theme.textMuted)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selected ? Theme.text : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func unlockedTile(_ item: AchievementItem) -> some View {
        VStack(spacing: 2) {
            AchievementMedal(item: item, size: 52)
                .overlay(alignment: .bottomTrailing) {
                    if item.repeatable == true, let times = item.times, times > 0 {
                        Text("×\(times)")
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Theme.text, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.bg, lineWidth: 2))
                            .offset(x: 6, y: 4)
                    }
                }
            Text(item.title)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.top, 8)
            if let date = item.tileDate {
                Text(date)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        // On 主页展示.
        .overlay(alignment: .topTrailing) {
            if store.isPinned(item) {
                Circle().fill(Theme.accent500)
                    .frame(width: 8, height: 8)
                    .padding(8)
                    .accessibilityLabel(AppString("展示在主页"))
            }
        }
    }

    private func lockedRow(_ item: AchievementItem) -> some View {
        HStack(spacing: 12) {
            AchievementMedal(item: item, size: 40, locked: true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let grade = item.tierName {
                        Text(grade)
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize()
                    }
                    if item.repeatable == true, !item.isOff {
                        Text(AppString("可重复"))
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Theme.chip, in: Capsule())
                            .fixedSize()
                    }
                }
                if let line = item.description ?? item.how, !line.isEmpty {
                    Text(line)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                if let offText = item.offText {
                    Text(offText)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                } else if let target = item.target, target > 0 {
                    HStack(spacing: 8) {
                        AchievementProgressBar(fraction: item.fraction)
                            .frame(maxWidth: 240)
                        Text("\(ReputationFormat.grouped(item.current ?? 0)) / \(ReputationFormat.grouped(target))")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let reward = item.rewardShort {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(reward)
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text(AppString("声望"))
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textMuted)
                }
                .fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(item.isOff ? 0.62 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Side cards

extension ReputationPage {
    private func card<Content: View>(
        _ title: String,
        trailing: String? = nil,
        bottomPadding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.body(12, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    /// 主页展示: the (at most three) unlocked achievements on the profile.
    @ViewBuilder
    var showcaseCard: some View {
        if store.achievements != nil {
            let items = store.showcaseItems
            card(AppString("主页展示"), trailing: "\(items.count) / \(store.maxShowcase)") {
                if items.isEmpty {
                    Text(AppString("还没有选择。"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 8)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        spacing: 8
                    ) {
                        ForEach(items) { item in
                            Button { openAchievement = item } label: {
                                VStack(spacing: 6) {
                                    AchievementMedal(item: item, size: 52)
                                    Text(item.title)
                                        .font(Theme.body(13, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(.top, 12)
                }
                Text(AppString("点开任意已解锁的成就，可以放到主页和名片上。"))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 10)
            }
        }
    }

    /// 最近的声望变化: the latest five ledger entries.
    @ViewBuilder
    var recentCard: some View {
        if store.reputation != nil {
            card(AppString("最近的声望变化"), bottomPadding: 8) {
                if store.ledger.isEmpty {
                    Text(AppString("还没有声望变化。被赞、被采纳、精华、成就和任务带来的声望会记在这里。"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.ledger) { item in
                            ReputationLedgerRow(row: ReputationLedgerText(item, store: store))
                        }
                    }
                    .padding(.top, 4)
                    Button { showsLedger = true } label: {
                        HStack(spacing: 4) {
                            Text(AppString("全部明细"))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    /// 声望来源: the all-time total split five ways, then 计分规则 and the
    /// way to 各段位能做什么.
    @ViewBuilder
    var sourcesCard: some View {
        if let reputation = store.reputation {
            let total = reputation.reputation ?? 0
            let sources = reputation.sources ?? []
            card(AppString("声望来源"), trailing: AppString("合计 \(ReputationFormat.grouped(total))")) {
                if total > 0, !sources.isEmpty {
                    GeometryReader { proxy in
                        let positive = sources.filter { $0.total > 0 }
                        let gaps = CGFloat(max(positive.count - 1, 0)) * 2
                        let width = max(proxy.size.width - gaps, 0)
                        HStack(spacing: 2) {
                            ForEach(positive, id: \.source) { source in
                                Rectangle()
                                    .fill(ReputationSourceStyle.color(source.source))
                                    .frame(width: max(width * CGFloat(source.total) / CGFloat(total), 4))
                            }
                        }
                        .frame(width: proxy.size.width, alignment: .leading)
                    }
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                }

                VStack(spacing: 0) {
                    ForEach(sources, id: \.source) { source in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ReputationSourceStyle.color(source.source))
                                .frame(width: 8, height: 8)
                            Text(ReputationSourceStyle.name(source.source))
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 8)
                            Text(ReputationFormat.grouped(source.total))
                                .font(Theme.body(13, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .monospacedDigit()
                            Text(share(source.total, of: total))
                                .font(Theme.body(12))
                                .foregroundStyle(Theme.textMuted)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                        .frame(minHeight: 30)
                    }
                }
                .padding(.top, 8)

                Button {
                    withAnimation(.quick) { showsRules.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(AppString("计分规则"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .rotationEffect(.degrees(showsRules ? 180 : 0))
                    }
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
                .padding(.top, 4)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(showsRules ? AppString("已展开") : AppString("已收起"))

                if showsRules {
                    ReputationRules(taskCap: store.tasks?.weekCap ?? reputation.tasks?.cap)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                Button {
                    app.pushPage(.upgrade)
                } label: {
                    HStack(spacing: 6) {
                        Text(AppString("各段位能做什么"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Theme.chip).frame(height: 1) }
            }
        }
    }

    private func share(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        let percent = Double(value) / Double(total) * 100
        return "\(Int(percent.rounded()))%"
    }
}

/// 计分规则. The per-like numbers are site settings the API doesn't expose,
/// so this says what counts without quoting them; the weekly task cap does
/// come from `/me/tasks`.
private struct ReputationRules: View {
    let taskCap: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rule(AppString("被赞"), AppString("每个有效赞都计声望。同一个人每天给你计的分、你每天从赞里得的分都有上限；赞带来的声望在第二天结算。"))
            rule(AppString("被采纳"), AppString("回答被提问者采纳时，回答者和采纳的楼主都得声望。同一对提问者和回答者每周只计一次；撤销采纳或回答被删时扣回。"))
            rule(AppString("精华"), AppString("帖子被版主评为精华时得声望，不设上限；取消精华时扣回。"))
            rule(AppString("成就"), AppString("解锁成就时一次性获得，可重复的成就每次都给。"))
            if let taskCap {
                rule(AppString("任务"), AppString("每日和每周任务，白银起每周最多给 \(taskCap) 声望，其余奖励发能量。"))
            }
            Text(AppString("被反对不扣声望。"))
            Text(AppString("这些赞不计入声望"))
                .font(Theme.body(12, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                bullet(AppString("点赞的人还是青铜、注册不久，或者还没发过言。"))
                bullet(AppString("没有读过帖子就点的赞。"))
                bullet(AppString("抽奖、福利、签到这类节点里的赞，带抽奖或红包的主题里的赞。"))
                bullet(AppString("自己赞自己，或者关联账号之间的赞。"))
                bullet(AppString("被复核判定为互刷的赞，已计入的会扣回。"))
            }
        }
        .font(Theme.body(12))
        .foregroundStyle(Theme.textMuted)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rule(_ name: String, _ text: String) -> some View {
        (Text(name).bold().foregroundColor(Theme.text) + Text(AppString("：")) + Text(text))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}

// MARK: - Tier card (shared with 升级进度)

/// The tier card: the shown tier, the reader's reputation and a track of all
/// nine tiers. Tapping a tier previews it; 回到我的段位 goes back.
struct ReputationHero: View {
    let store: ReputationStore
    @Binding var selectedTierIndex: Int?

    private var reputation: NLReputation? { store.reputation }
    private var current: Int? { store.currentTierIndex }
    private var shownIndex: Int? { selectedTierIndex ?? current }
    private var shown: NLTiers.Tier? {
        shownIndex.flatMap { store.tiers.indices.contains($0) ? store.tiers[$0] : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack(alignment: .topTrailing) {
                if let shown {
                    TierIcon(name: shown.name, number: shown.level + 1, size: 92)
                        .foregroundStyle(tierFill(shown))
                        .shadow(color: .black.opacity(0.42), radius: 9, y: 12)
                        .frame(width: 132, height: 122)
                        .offset(x: 14, y: -16)
                        .id(shown.level)
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 16) {
                    tierBlock
                        .padding(.trailing, 112)
                    reputationBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            tierTrack
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .background {
            ZStack {
                (shown.flatMap { $0.darkBg.flatMap { Color(cssHex: $0) } } ?? Color(hex: 0x0D1E3B))
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x06080E).opacity(0.62), location: 0),
                        .init(color: Color(hex: 0x06080E).opacity(0.12), location: 0.7),
                        .init(color: Color(hex: 0x06080E).opacity(0.5), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x06080E).opacity(0.7), location: 0),
                        .init(color: .clear, location: 0.42),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
        }
        .shadow(color: Color(hex: 0x0B1F18).opacity(0.3), radius: 20, y: 14)
        .animation(.easeInOut(duration: 0.35), value: shownIndex)
    }

    // MARK: Lines

    private enum Phase { case current, reached, ahead }

    private var state: Phase {
        guard let shownIndex, let current else { return .current }
        if shownIndex == current { return .current }
        return shownIndex < current ? .reached : .ahead
    }

    private var tierBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppString("声望与成就"))
                .font(Theme.body(12, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 10) {
                Text(shown?.name ?? reputation?.tierName ?? "—")
                    .font(Theme.heading(30, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                stateChip
            }

            if let line = firstLine {
                Text(line)
                    .font(Theme.body(13))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack(spacing: 12) {
                if let percent = shownPercent {
                    (Text(state == .current ? AppString("这一段已走完 ") : AppString("已完成 "))
                        + Text("\(percent)%").bold().foregroundColor(.white))
                        .font(Theme.body(13))
                        .foregroundStyle(.white.opacity(0.78))
                        .monospacedDigit()
                        .fixedSize()
                }
                if state != .current {
                    Button {
                        selectedTierIndex = nil
                    } label: {
                        Text(AppString("回到我的段位"))
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .fixedSize()
                }
            }
            .frame(minHeight: 30)

            if state == .current, let until = reputation?.upgradeLockedUntil, !until.isEmpty {
                Text(AppString("处罚期间暂停晋级，至 \(String(until.prefix(10)))"))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFFB15C))
            }
        }
    }

    private var stateChip: some View {
        let isCurrent = state == .current
        return Text(isCurrent ? AppString("当前段位") : (state == .reached ? AppString("已达成") : AppString("还没达成")))
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(isCurrent ? Color(hex: 0x111517) : .white)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(isCurrent ? Color.white.opacity(0.92) : Color.white.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var firstLine: String? {
        let rep = reputation?.reputation ?? 0
        switch state {
        case .current:
            if let needed = reputation?.needed, needed > 0, let next = store.nextTierName {
                return AppString("距离\(next)还差 \(ReputationFormat.grouped(needed)) 声望")
            }
            return nil
        case .reached:
            guard let shown else { return nil }
            let threshold = store.threshold(of: shown) ?? 0
            return threshold <= 0
                ? AppString("注册即有")
                : AppString("门槛 \(ReputationFormat.grouped(threshold)) 声望")
        case .ahead:
            guard let shown, let threshold = store.threshold(of: shown) else { return nil }
            return AppString("需要 \(ReputationFormat.grouped(threshold)) 声望，还差 \(ReputationFormat.grouped(max(threshold - rep, 0)))")
        }
    }

    private var shownPercent: Int? {
        switch state {
        case .current:
            guard let progress = reputation?.progress else { return nil }
            return Int((min(max(progress, 0), 1) * 100).rounded())
        case .reached:
            return 100
        case .ahead:
            guard let shown, let threshold = store.threshold(of: shown), threshold > 0 else { return nil }
            let rep = Double(reputation?.reputation ?? 0)
            return Int((min(max(rep / Double(threshold), 0), 1) * 100).rounded())
        }
    }

    private var reputationBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppString("我的声望"))
                .font(Theme.body(12, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.6))
            Text(reputation?.reputation.map(ReputationFormat.grouped) ?? "—")
                .font(Theme.heading(36, weight: .heavy))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let week = reputation?.week {
                HStack(spacing: 3) {
                    Image(systemName: week >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .heavy))
                    Text(AppString("本周 \(week >= 0 ? "+" : "")\(week)"))
                }
                .font(Theme.body(12, weight: .bold))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.white.opacity(0.16), in: Capsule())
                .padding(.top, 6)
            }
        }
    }

    // MARK: Track

    private func tierFill(_ tier: NLTiers.Tier) -> Color {
        tier.bg.flatMap { Color(cssHex: $0) } ?? .white
    }

    private func tierInk(_ tier: NLTiers.Tier) -> Color {
        tier.fg.flatMap { Color(cssHex: $0) } ?? Color(hex: 0x111517)
    }

    /// 2pt line showing overall progress, then one button per tier.
    private var tierTrack: some View {
        let count = store.tiers.count
        let current = self.current ?? 0
        let within = min(max(reputation?.progress ?? 0, 0), 1)
        let overall = count > 1 ? (Double(current) + within) / Double(count - 1) : 0

        return ZStack(alignment: .top) {
            GeometryReader { proxy in
                // Runs between the first and last circle centres.
                let inset = proxy.size.width / CGFloat(max(count, 1)) / 2
                let width = max(proxy.size.width - inset * 2, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                        .frame(width: width, height: 2)
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.7), .white, .white.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * min(max(overall, 0), 1), height: 2)
                }
                .offset(x: inset, y: 21)
            }
            .frame(height: 44)

            HStack(spacing: 0) {
                ForEach(Array(store.tiers.enumerated()), id: \.element.level) { index, tier in
                    Button {
                        selectedTierIndex = index == current ? nil : index
                    } label: {
                        tierStop(tier, index: index, current: current)
                    }
                    .buttonStyle(.pressable)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func tierStop(_ tier: NLTiers.Tier, index: Int, current: Int) -> some View {
        let isCurrent = index == current
        let isShown = index == shownIndex
        let reached = index < current
        let size: CGFloat = isCurrent ? 36 : 28
        return VStack(spacing: 4) {
            ZStack {
                if isCurrent {
                    Circle().fill(tierFill(tier))
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.6), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().strokeBorder(Color.white, lineWidth: 2)
                } else {
                    Circle().fill(reached ? Color(hex: 0x3A3D47) : Color(hex: 0x1C1E26))
                    Circle().strokeBorder(
                        isShown ? Color.white : (reached ? Color(hex: 0x7A7F8C) : Color(hex: 0x3E424D)),
                        lineWidth: isShown ? 2 : 1
                    )
                }
                TierIcon(name: tier.name, number: tier.level + 1, size: isCurrent ? 18 : 14)
                    .foregroundStyle(isCurrent ? tierInk(tier) : (reached || isShown ? Color.white : Color(hex: 0x8A8F9C)))
            }
            .frame(width: size, height: size)
            .background {
                if isCurrent {
                    Circle().fill(Color.white.opacity(0.16)).padding(-5)
                }
            }
            .overlay {
                if isCurrent { TierPulse() }
            }
            .shadow(color: .black.opacity(isCurrent ? 0.35 : 0), radius: 8, y: 6)
            .frame(height: 36)

            Text(tier.name)
                .font(Theme.body(12, weight: isCurrent || isShown ? .bold : .medium))
                .foregroundStyle(isCurrent || isShown ? Color.white : Color.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .accessibilityLabel(tier.name)
        .accessibilityValue(isCurrent ? AppString("当前段位") : (reached ? AppString("已达成") : AppString("还没达成")))
    }
}

/// The ring that keeps widening out of the current tier's dot.
private struct TierPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.55), lineWidth: 2)
            .padding(-7)
            .scaleEffect(expanded ? 1.5 : 0.82)
            .opacity(reduceMotion ? 0 : (expanded ? 0 : 0.75))
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(1.2)) {
                    expanded = true
                }
            }
    }
}

// MARK: - Tasks (shared with 升级进度)

struct ReputationTasksSection: View {
    let store: ReputationStore
    let onOpen: (NLTaskList.Task) -> Void

    var body: some View {
        if let list = store.tasks, !list.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        title
                        subtitle(list).fixedSize()
                        Spacer(minLength: 0)
                        counter(list)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 16) {
                            title
                            subtitle(list)
                        }
                        counter(list)
                    }
                }

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(sortedTasks(list.tasks)) { task in
                            taskCard(task)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
                // Bleeds to the screen edges like the design.
                .padding(.horizontal, -16)
            }
        }
    }

    private var title: some View {
        Text(AppString("任务"))
            .font(Theme.heading(20, weight: .bold))
            .foregroundStyle(Theme.text)
            .fixedSize()
    }

    private func subtitle(_ list: NLTaskList) -> some View {
        Text(list.reputationEligible == false
             ? AppString("青铜段位的任务只发能量。")
             : AppString("任务主要发能量，声望每周最多 \(list.weekCap ?? 10)。"))
            .font(Theme.body(13))
            .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder
    private func counter(_ list: NLTaskList) -> some View {
        if let cap = list.weekCap, cap > 0, list.reputationEligible != false {
            let done = list.weekReputation ?? 0
            HStack(spacing: 8) {
                Text(AppString("本周声望 \(done) / \(cap)"))
                    .font(Theme.body(12, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                AchievementProgressBar(fraction: Double(done) / Double(cap), height: 6, track: Theme.hairline)
                    .frame(width: 72)
            }
            .fixedSize()
        }
    }

    /// Unfinished first, keeping the server's order otherwise.
    private func sortedTasks(_ tasks: [NLTaskList.Task]) -> [NLTaskList.Task] {
        tasks.enumerated()
            .sorted { ($0.element.done == true ? 1 : 0, $0.offset) < ($1.element.done == true ? 1 : 0, $1.offset) }
            .map(\.element)
    }

    private func taskCard(_ task: NLTaskList.Task) -> some View {
        let done = task.done == true
        let target = max(task.target ?? 1, 1)
        let progress = min(task.progress ?? 0, target)
        let weekly = task.period == "weekly"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.hairline, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: done ? 1 : Double(progress) / Double(target))
                        .stroke(Theme.accent500, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.accent500)
                    } else {
                        Text("\(progress)/\(target)")
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 40, height: 40)

                if task.period != nil {
                    Text(weekly ? AppString("每周") : AppString("每日"))
                        .font(Theme.body(11, weight: .bold))
                        .foregroundStyle(weekly ? Theme.titleChipText : Theme.roleChipText)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(weekly ? Theme.titleChipFill : Theme.roleChipFill, in: Capsule())
                        .fixedSize()
                }

                Spacer(minLength: 4)

                if let energy = task.energy, energy > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("+\(energy)")
                    }
                    .font(Theme.body(12, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize()
                }
                if let reputation = task.reputation, reputation > 0 {
                    Text(AppString("+\(reputation) 声望"))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(Theme.roleChipText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Text(task.title ?? task.key)
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(done ? Theme.textMuted : Theme.text)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if done {
                    Text(AppString("已完成"))
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                } else if let cta = task.cta, !cta.isEmpty, task.href != nil || task.compose == true {
                    Button {
                        onOpen(task)
                    } label: {
                        HStack(spacing: 4) {
                            Text(cta)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.accent500)
                    }
                    .buttonStyle(.pressable)
                } else {
                    Text(AppString("浏览时自动计数"))
                        .font(Theme.body(13, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(minHeight: 24)
        }
        .padding(14)
        .frame(width: 232, alignment: .leading)
        .background(done ? Theme.surface : Theme.bg, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Loading and error

struct ReputationSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.surface)
                .frame(height: 300)
            VStack(alignment: .leading, spacing: 12) {
                bar(width: 120, height: 22)
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                            .fill(Theme.surface)
                            .frame(width: 232, height: 134)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 12) {
                bar(width: 140, height: 22)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                            .fill(Theme.surface)
                            .frame(height: 128)
                    }
                }
            }
        }
        .accessibilityLabel(AppString("加载中"))
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.surface)
            .frame(width: width, height: height)
    }
}

struct ReputationErrorView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: "wifi.exclamationmark", message: AppString("加载失败"))
            Button(AppString("重试"), action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Small pieces

struct AchievementProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var track: Color = Theme.chip

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(Theme.accent500)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

enum ReputationFormat {
    nonisolated static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// 2022 年 9 月 — when an achievement was earned.
    static func month(_ value: String?) -> String? {
        guard let date = DiscourseFormat.date(value) else { return nil }
        return DiscourseFormat.cachedFormatter(locale: AppLanguage.resolved.locale, template: "yMMM")
            .string(from: date)
    }

    /// 今天 14:20, 昨天, 3 天前, then a date — the ledger's times.
    static func day(_ value: String?) -> String {
        guard let date = DiscourseFormat.date(value) else { return "" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        let locale = AppLanguage.resolved.locale
        switch days {
        case ...0:
            let formatter = DiscourseFormat.cachedFormatter(locale: locale, template: "HHmm")
            return AppString("今天 \(formatter.string(from: date))")
        case 1:
            return AppString("昨天")
        case 2..<7:
            return AppString("\(days) 天前")
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            return DiscourseFormat.cachedFormatter(locale: locale, template: sameYear ? "MMMd" : "yMMMd")
                .string(from: date)
        }
    }
}

extension AchievementItem {
    /// Retired (已停止发放) or admin-only (管理员发放): not something to work toward.
    var isOff: Bool { off == true || closed == true || manual == true }

    var offText: String? {
        if closed == true { return AppString("已停止发放") }
        if manual == true || off == true { return AppString("管理员发放") }
        return nil
    }

    /// The tile's date: the month it was earned, or the latest time for a
    /// repeatable one.
    var tileDate: String? {
        if repeatable == true, let month = ReputationFormat.month(lastAt ?? unlockedAt) {
            return AppString("最近 \(month)")
        }
        return ReputationFormat.month(unlockedAt)
    }

    /// 「+100」 or 「每次 +10」, right of a locked row.
    var rewardShort: String? {
        guard let reputation else { return nil }
        return repeatable == true ? AppString("每次 +\(reputation)") : "+\(reputation)"
    }

    var rewardText: String? {
        guard let reputation else { return nil }
        return repeatable == true ? AppString("每次 +\(reputation) 声望") : AppString("+\(reputation) 声望")
    }
}

// MARK: - Ledger

enum ReputationSourceStyle {
    static func color(_ source: String) -> Color {
        switch source {
        case "like": return Theme.accent500
        case "accept": return Theme.repAccept
        case "featured": return Theme.repFeatured
        case "achievement": return Theme.repAchievement
        case "revoke": return Theme.danger
        default: return Theme.repTask
        }
    }

    static func name(_ source: String) -> String {
        switch source {
        case "like": return AppString("被赞")
        case "accept": return AppString("被采纳")
        case "featured": return AppString("精华")
        case "achievement": return AppString("成就")
        case "task": return AppString("任务")
        default: return source
        }
    }
}

/// One ledger entry in words, the way the web's 声望明细 writes it.
struct ReputationLedgerText: Identifiable {
    let id: Int
    let dot: Color
    let kind: String
    let text: String
    let when: String
    let value: String
    let isGain: Bool
    let isLoss: Bool
    let isPending: Bool

    @MainActor
    init(_ item: NLReputationLedger.Item, store: ReputationStore) {
        id = item.id
        isPending = item.status == "pending"
        when = ReputationFormat.day(item.createdAt)
        let quoted = (item.title?.isEmpty == false && item.source != "achievement") ? "《\(item.title!)》" : ""
        let orTopic = quoted.isEmpty ? AppString("一个主题") : quoted
        let orPost = quoted.isEmpty ? AppString("你的一个帖子") : quoted
        let memo = item.memo ?? ""
        var source = item.source
        var kind = ReputationSourceStyle.name(item.source)
        var text: String

        if item.source == "moderation", item.amount < 0 {
            source = "revoke"
            kind = AppString("违规处罚")
            text = AppString("\(orPost)被管理人员处理")
            if !memo.isEmpty { text += AppString("：") + memo }
        } else if item.source == "moderation" {
            source = "like"
            kind = AppString("返还")
            text = AppString("返还被扣除的声望")
            if !memo.isEmpty { text += AppString("：") + memo }
        } else if item.revoke == true {
            source = "revoke"
            kind = AppString("撤回")
            text = memo.isEmpty ? AppString("声望被扣回") : memo
            if !quoted.isEmpty { text = quoted + " · " + text }
        } else {
            switch item.source {
            case "like":
                text = quoted.isEmpty ? AppString("收到的赞") : AppString("\(quoted)收到的赞")
            case "accept" where memo == "采纳了回答":
                text = AppString("你在\(orTopic)里采纳了回答")
            case "accept":
                text = AppString("你在\(orTopic)里的回答被采纳")
            case "featured":
                text = AppString("\(orTopic)被评为精华")
            case "achievement":
                let name = store.achievement(forKey: memo)?.name ?? item.title ?? memo
                text = AppString("解锁成就「\(name)」")
            case "task":
                if let task = store.task(forKey: memo), let title = task.title {
                    text = task.period == "weekly"
                        ? AppString("完成每周任务：\(title)")
                        : AppString("完成每日任务：\(title)")
                } else {
                    text = AppString("完成任务")
                }
            default:
                text = memo
            }
        }

        dot = ReputationSourceStyle.color(source)
        self.kind = kind
        self.text = text
        isGain = item.amount > 0
        isLoss = item.amount < 0
        if item.amount > 0 {
            value = "+" + ReputationFormat.grouped(item.amount)
        } else if item.amount < 0 {
            value = "−" + ReputationFormat.grouped(-item.amount)
        } else {
            value = "0"
        }
    }
}

struct ReputationLedgerRow: View {
    let row: ReputationLedgerText

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(row.dot)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.text)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .lineSpacing(2)
                Text(row.isPending
                     ? "\(row.kind) · \(row.when) · \(AppString("待结算"))"
                     : "\(row.kind) · \(row.when)")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.value)
                .font(Theme.body(14, weight: .bold))
                .foregroundStyle(row.isGain ? Theme.accent500 : (row.isLoss ? Theme.danger : Theme.textMuted))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, 9)
        .opacity(row.isPending ? 0.55 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.chip).frame(height: 1) }
    }
}

/// 声望明细: the whole ledger, twenty at a time.
struct ReputationLedgerSheet: View {
    let store: ReputationStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NLReputationLedger.Item] = []
    @State private var next: String?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(AppString("声望明细"))
                        .font(Theme.heading(18, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.trailing, -10)
                    .accessibilityLabel(AppString("关闭"))
                }
                Text(AppString("赞带来的声望在第二天结算，结算前标灰、可能被复核剔除；被删的内容带来的声望会扣回。"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.bottom, 6)

                ForEach(items) { item in
                    ReputationLedgerRow(row: ReputationLedgerText(item, store: store))
                }

                if isLoading {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if failed {
                    VStack(spacing: 8) {
                        Text(AppString("加载失败"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                        Button(AppString("重试")) { Task { await loadMore() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if next != nil {
                    Button(AppString("加载更多")) { Task { await loadMore() } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                } else if items.isEmpty {
                    Text(AppString("还没有声望变化。"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { if items.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }
        do {
            let page = try await DiscourseClient().reputationLedger(before: items.isEmpty ? nil : next, limit: 20)
            items.append(contentsOf: page.items.filter { new in !items.contains { $0.id == new.id } })
            next = page.next
        } catch {
            failed = true
        }
    }
}

// MARK: - Detail

/// One achievement: what it is, how to get it, where the reader stands, and
/// 展示在主页 for one that's unlocked.
struct AchievementDetailSheet: View {
    let item: AchievementItem
    /// Absent for someone else's showcase: nothing to pin there.
    var store: ReputationStore?

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AchievementMedal(item: item, size: 96, locked: !item.isUnlocked)

                Text(item.title)
                    .font(Theme.heading(22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                if !meta.isEmpty {
                    Text(meta)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 2)
                }
                if let how = item.how ?? item.description, !how.isEmpty {
                    Text(how)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(stateText)
                            .font(Theme.body(13, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        if let progressText {
                            Text(progressText)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                                .monospacedDigit()
                        }
                    }
                    AchievementProgressBar(fraction: fraction)
                    if let reward = item.rewardText {
                        Text(reward)
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Theme.roleChipText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 16)

                if let errorText {
                    Text(errorText)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }

                HStack(spacing: 8) {
                    Button { dismiss() } label: {
                        Text(AppString("关闭"))
                            .font(Theme.body(14, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)

                    if let store, item.isUnlocked {
                        let pinned = store.isPinned(item)
                        Button {
                            Task { await togglePin(store, pinned: pinned) }
                        } label: {
                            ZStack {
                                if isSaving {
                                    ProgressView().tint(pinned ? Theme.text : .white)
                                } else {
                                    Text(pinned ? AppString("取消展示") : AppString("展示在主页"))
                                }
                            }
                            .font(Theme.body(14, weight: .bold))
                            .foregroundStyle(pinned ? Theme.text : Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(pinned ? Theme.bg : Theme.accentFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(pinned ? Theme.text : Theme.accentFill, lineWidth: 1))
                        }
                        .buttonStyle(.pressable)
                        .disabled(isSaving)
                    }
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 铜级 · 互动 · 可重复
    private var meta: String {
        var parts: [String] = []
        if let grade = item.tierName { parts.append(grade) }
        if let category = item.category { parts.append(category) }
        if item.repeatable == true { parts.append(AppString("可重复")) }
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        if item.repeatable == true, item.unlocked != nil {
            return AppString("已获得 \(item.times ?? 0) 次")
        }
        if item.isUnlocked {
            if let month = ReputationFormat.month(item.unlockedAt) { return AppString("\(month) 解锁") }
            return AppString("已解锁")
        }
        if let offText = item.offText { return offText }
        return AppString("进行中")
    }

    private var progressText: String? {
        guard item.unlocked != nil, item.repeatable != true, !item.isOff, let target = item.target, target > 0 else { return nil }
        return "\(ReputationFormat.grouped(item.current ?? 0)) / \(ReputationFormat.grouped(target))"
    }

    private var fraction: Double {
        if item.repeatable == true { return (item.times ?? 0) > 0 ? 1 : 0 }
        if item.isUnlocked { return 1 }
        return item.fraction
    }

    private func togglePin(_ store: ReputationStore, pinned: Bool) async {
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            try await store.setPinned(item, !pinned)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? AppString("操作失败，请稍后重试")
        }
    }
}

// MARK: - Someone else's showcase

/// Another member's 成就: how many they've unlocked and the ones they chose to
/// show. The full list is private to its owner, so this is all there is.
struct AchievementShowcaseSheet: View {
    let name: String
    let count: Int?
    let items: [AchievementItem]

    @State private var open: AchievementItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let count {
                        Text(AppString("\(name) 已解锁 \(count) 个成就"))
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if items.isEmpty {
                        Text(AppString("还没有挑选要展示的成就。"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        Text(AppString("展示的成就"))
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                        ForEach(items) { item in
                            Button { open = item } label: {
                                HStack(spacing: 12) {
                                    AchievementMedal(item: item, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(Theme.body(15, weight: .bold))
                                                .foregroundStyle(Theme.text)
                                            if let grade = item.tierName {
                                                Text(grade)
                                                    .font(Theme.body(11, weight: .bold))
                                                    .foregroundStyle(Theme.textMuted)
                                            }
                                        }
                                        if let description = item.description, !description.isEmpty {
                                            Text(description)
                                                .font(Theme.body(13))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                                        .strokeBorder(Theme.hairline, lineWidth: 1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(AppString("成就"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
        .sheet(item: $open) { AchievementDetailSheet(item: $0) }
    }
}
