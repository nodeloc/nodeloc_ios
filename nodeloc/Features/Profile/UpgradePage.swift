//
//  UpgradePage.swift
//  nodeloc
//
//  升级进度 — the tier card and this week's tasks (shared with 声望与成就),
//  then 用户组与权限: what each tier can do, one column at a time, with what
//  a tier newly opens up over the one below marked 新. A page on the routed
//  page stack, opened from 声望与成就's 各段位能做什么.
//
//  The table comes from `GET /api/v1/tiers` (public): each tier lists only
//  the rows that changed from the tier below — bronze against signed out —
//  as `from` / `to`, so a column is rebuilt by walking those changes. The
//  tier card and tasks need a session (`/me/reputation`, `/me/tasks`) and
//  are left out signed out.
//

import SwiftUI

struct UpgradePage: View {
    let navigation: PageNavigation
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var store = ReputationStore(includesAchievements: false)
    @State private var selectedTierIndex: Int?
    /// 0 is 游客, then one per tier; nil follows the reader's own.
    @State private var pickedColumn: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.isLoading {
                    ReputationSkeleton()
                } else {
                    if store.reputation != nil {
                        ReputationHero(store: store, selectedTierIndex: $selectedTierIndex)
                        ReputationTasksSection(store: store) { app.openReputationTaskLink($0) }
                    }
                    if store.tiers.isEmpty {
                        ReputationErrorView { Task { await store.load() } }
                    } else {
                        permissionsSection
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.load() }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(AppString("升级进度"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if navigation.drawsBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    PageBackButton(action: onClose)
                }
            }
        }
        .inPageNavigation(navigation)
        .task { if !store.hasLoaded { await store.load() } }
    }

    // MARK: 用户组与权限

    private var table: TierPermissionTable { TierPermissionTable(tiers: store.tiers) }

    /// The reader's column: their tier, or 游客 signed out.
    private var mineColumn: Int {
        if let index = store.currentTierIndex { return index + 1 }
        return app.authed ? -1 : 0
    }

    private var column: Int {
        let picked = pickedColumn ?? max(mineColumn, 0)
        return min(max(picked, 0), store.tiers.count)
    }

    private var permissionsSection: some View {
        let table = self.table
        let column = self.column
        let rows = table.rows(column: column)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppString("用户组与权限"))
                    .font(Theme.heading(24, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(AppString("段位决定你能怎样参与社区，管理权限另外授予。"))
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(0...store.tiers.count, id: \.self) { index in
                            columnChip(index, selected: index == column)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -16)
                .onAppear { proxy.scrollTo(column, anchor: .center) }
            }

            pickedCard(column: column, newCount: rows.filter(\.isNew).count)

            Text(AppString("段位越高，能参与的方式越多。标「新」的是比上一级新放开或变宽的。"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)

            VStack(spacing: 0) {
                ForEach(table.groups(rows)) { group in
                    Text(group.title)
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                    ForEach(group.rows) { row in
                        permissionRow(row)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }

            VStack(spacing: 12) {
                if store.reputation != nil {
                    linkCard(AppString("声望与成就"), subtitle: mineNote) {
                        app.pushPage(.reputation)
                    }
                }
                linkCard(AppString("社区规范"), subtitle: AppString("违反规范时，任何段位都可能被限制或封禁")) {
                    openURL(DiscourseConfig.baseURL.appendingPathComponent("guidelines"))
                }
            }
        }
    }

    private func columnName(_ index: Int) -> String {
        index == 0 ? AppString("游客") : store.tiers[index - 1].name
    }

    @ViewBuilder
    private func columnIcon(_ index: Int, size: CGFloat) -> some View {
        if index == 0 {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.8, weight: .semibold))
        } else {
            let tier = store.tiers[index - 1]
            TierIcon(name: tier.name, number: tier.level + 1, size: size)
        }
    }

    private func columnChip(_ index: Int, selected: Bool) -> some View {
        Button {
            withAnimation(.quick) { pickedColumn = index }
        } label: {
            HStack(spacing: 6) {
                columnIcon(index, size: 15)
                    .frame(width: 28, height: 28)
                    .background(selected ? Theme.bg.opacity(0.16) : Theme.bg, in: Circle())
                Text(columnName(index))
                    .font(Theme.body(14, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.bg : Theme.text)
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 40)
            .background(selected ? Theme.text : Theme.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pickedCard(column: Int, newCount: Int) -> some View {
        HStack(spacing: 12) {
            columnIcon(column, size: 26)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(columnName(column))
                        .font(Theme.heading(18, weight: .heavy))
                    if column == mineColumn {
                        Text(AppString("你的段位"))
                            .font(Theme.body(11, weight: .bold))
                            .foregroundStyle(Color(hex: 0x0F1A1C))
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Color.white, in: Capsule())
                    }
                }
                Text(pickedSubtitle(column: column, newCount: newCount))
                    .font(Theme.body(12))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(light: 0x0F1A1C, dark: 0x1D2421), in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .animation(.quick, value: column)
    }

    /// 800 声望 · 比铂金多 4 项
    private func pickedSubtitle(column: Int, newCount: Int) -> String {
        if column == 0 {
            return AppString("未登录 · 没有登录时能做的事")
        }
        let tier = store.tiers[column - 1]
        let previous = columnName(column - 1)
        let delta = newCount > 0
            ? AppString("比\(previous)多 \(newCount) 项")
            : AppString("和\(previous)一样")
        if let threshold = store.threshold(of: tier) {
            let gate = threshold <= 0
                ? AppString("注册即有")
                : AppString("\(ReputationFormat.grouped(threshold)) 声望")
            return "\(gate) · \(delta)"
        }
        return delta
    }

    private func permissionRow(_ row: TierPermissionTable.Row) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(row.label)
                    .font(Theme.body(14))
                    .foregroundStyle(row.value == .no ? Theme.textMuted : Theme.text)
                if row.isNew {
                    Text(AppString("新"))
                        .font(Theme.body(11, weight: .bold))
                        .foregroundStyle(Theme.roleChipText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Theme.roleChipFill, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                switch row.value {
                case .yes:
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.accent500)
                        .accessibilityLabel(AppString("可以"))
                case .no:
                    Capsule().fill(Theme.textFaint)
                        .frame(width: 9, height: 2.4)
                        .accessibilityLabel(AppString("不可以"))
                case .text(let text):
                    Text(text)
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: 160, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.neutral300).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    /// 你现在是钻石，再积累 1,260 声望到王者。
    private var mineNote: String {
        let name = store.reputation?.tierName ?? store.currentTierIndex.map { store.tiers[$0].name } ?? ""
        if let needed = store.reputation?.needed, needed > 0, let next = store.nextTierName {
            return AppString("你现在是\(name)，再积累 \(ReputationFormat.grouped(needed)) 声望到\(next)。")
        }
        return AppString("你现在是\(name)。")
    }

    private func linkCard(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Table

/// The tier table rebuilt from `/api/v1/tiers`. Each tier only lists what
/// changed from the one below (bronze from signed out), so a column's value
/// for a row is the last change at or below it, or — when the row first
/// changes higher up — that change's `from`.
struct TierPermissionTable {
    enum Value: Equatable {
        case yes, no
        case text(String)
    }

    struct Row: Identifiable {
        let key: String
        let label: String
        let value: Value
        /// Opened up or widened at this column.
        let isNew: Bool
        var id: String { key }
    }

    struct Group: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    let tiers: [NLTiers.Tier]

    /// The web table's sections, by row key. A key the app doesn't know yet
    /// goes at the end of the last one rather than being dropped.
    private static let sections: [(title: String, keys: [String])] = [
        (AppString("阅读"), ["browse", "scope", "follow"]),
        (AppString("发帖与互动"), ["post", "gap", "topics", "links", "uploads", "likes", "messages", "groupchat", "gate", "lottery-join", "lottery-create"]),
        (AppString("社区建设"), ["report", "invite", "nodes", "priority"]),
    ]

    /// Every row key in first-seen order, with its label.
    private var keys: [(key: String, label: String)] {
        var seen: [(String, String)] = []
        for tier in tiers {
            for unlock in tier.unlocks ?? [] where !seen.contains(where: { $0.0 == unlock.key }) {
                seen.append((unlock.key, unlock.label ?? unlock.key))
            }
        }
        return seen
    }

    /// Column 0 is signed out; column n is `tiers[n - 1]`.
    func rows(column: Int) -> [Row] {
        let tierIndex = column - 1
        return keys.compactMap { entry in
            var value: String?
            // The last change at or below this column…
            for index in tiers.indices where index <= tierIndex {
                if let unlock = tiers[index].unlocks?.first(where: { $0.key == entry.key }) {
                    value = unlock.to
                }
            }
            // …or, before any change, what the first change started from.
            if value == nil {
                for index in tiers.indices where index > tierIndex {
                    if let unlock = tiers[index].unlocks?.first(where: { $0.key == entry.key }) {
                        value = unlock.from
                        break
                    }
                }
            }
            guard let value else { return nil }
            let parsed = Self.parse(value)
            let isNew = tierIndex >= 0
                && parsed != .no
                && tiers[tierIndex].unlocks?.contains(where: { $0.key == entry.key }) == true
            return Row(key: entry.key, label: entry.label, value: parsed, isNew: isNew)
        }
    }

    func groups(_ rows: [Row]) -> [Group] {
        var remaining = rows
        var out: [Group] = []
        for (index, section) in Self.sections.enumerated() {
            var picked = section.keys.compactMap { key in rows.first { $0.key == key } }
            remaining.removeAll { row in section.keys.contains(row.key) }
            if index == Self.sections.count - 1 {
                picked.append(contentsOf: remaining)
            }
            if !picked.isEmpty { out.append(Group(title: section.title, rows: picked)) }
        }
        return out
    }

    /// The server writes a yes/no cell as its screen-reader word, in the
    /// request's language.
    private static func parse(_ value: String) -> Value {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if ["可以", "Yes", "yes", AppString("可以")].contains(trimmed) { return .yes }
        if ["不可以", "No", "no", AppString("不可以")].contains(trimmed) { return .no }
        return .text(trimmed)
    }
}

// MARK: - Task links

extension AppState {
    /// A task's call to action from 声望与成就 / 升级进度: the composer, the
    /// reader's own profile, or the home feed. The page stack goes away first
    /// so the target shows.
    func openReputationTaskLink(_ task: NLTaskList.Task) {
        let href = task.href ?? ""
        pageStack.removeAll()
        if task.compose == true || href.hasPrefix("/new") {
            overlay = .compose
        } else if href.hasPrefix("/u/") {
            tab = .profile
        } else {
            tab = .home
        }
    }
}
