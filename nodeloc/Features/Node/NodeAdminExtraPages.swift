//
//  NodeAdminExtraPages.swift
//  nodeloc
//
//  The hub's 节点 section: 基本信息, 置顶帖, 版主团队, 节点规则, and the
//  node's current penalties (处罚中的用户). Same grouped look as the rest of
//  节点管理 (AdminKit). Backed by node/manage_handlers.go and handlers.go.
//

import SwiftUI

// MARK: - 基本信息

/// Name and description (`PUT /nodes/{slug}/details`). Appearance, rules and
/// the rest stay on the web's node settings, which have far more fields than
/// fit a phone.
struct NodeInfoPage: View {
    let slug: String
    let manage: NLNodeManage?
    let onClose: () -> Void

    @State private var name = ""
    @State private var summary = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private let client = DiscourseClient()

    private var canEdit: Bool { manage?.canEdit ?? false }
    private var isDirty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != (manage?.node.name ?? "")
            || summary.trimmingCharacters(in: .whitespacesAndNewlines) != (manage?.node.description ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("基本信息"), onBack: onClose)
                .toolbar {
                    if canEdit {
                        PrimaryToolbarAction(
                            title: AppString("保存"),
                            isEnabled: isDirty && !name.trimmingCharacters(in: .whitespaces).isEmpty,
                            isWorking: isSaving
                        ) { Task { await save() } }
                    }
                }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AdminSection(title: AppString("名称")) {
                        TextField(AppString("节点名称"), text: $name)
                            .font(Theme.body(17))
                            .focused($focused)
                            .disabled(!canEdit)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                    }
                    AdminSection(
                        title: AppString("简介"),
                        footer: AppString("显示在节点页的名称下面和节点广场的卡片上。")
                    ) {
                        TextField(AppString("一句话说明这个节点聊什么"), text: $summary, axis: .vertical)
                            .font(Theme.body(17))
                            .lineLimit(3...8)
                            .disabled(!canEdit)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                    }
                    if let node = manage?.node {
                        AdminSection(title: AppString("节点")) {
                            AdminRow(title: AppString("地址"), value: "n/\(node.slug)")
                            AdminRow(title: AppString("成员"), value: node.memberCount.map { NodeAdminPage.count($0) })
                            AdminRow(title: AppString("主题"), value: node.topicCount.map { NodeAdminPage.count($0) })
                            AdminRow(title: AppString("帖子"), value: node.postCount.map { NodeAdminPage.count($0) },
                                     isLast: node.createdAt == nil)
                            if let created = node.createdAt {
                                AdminRow(title: AppString("创建于"), value: adminRelative(created), isLast: true)
                            }
                        }
                    }
                    if !canEdit {
                        AdminNote(text: AppString("只有节点主理人和站务能改名称和简介。"))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AdminTheme.pageBg)
        .onAppear {
            name = manage?.node.name ?? ""
            summary = manage?.node.description ?? ""
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.updateNodeDetails(
                slug: slug,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            ToastCenter.shared.show(AppString("已保存"))
            onClose()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

// MARK: - 置顶帖

struct NodePinsManagePage: View {
    let slug: String
    let onClose: () -> Void

    @State private var pins: [NLNodePins.Pin] = []
    @State private var isLoading = true
    @State private var errorText: String?

    private let client = DiscourseClient()

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("置顶帖"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading || errorText != nil {
                        AdminStatePlaceholder(isLoading: isLoading, errorText: errorText) { Task { await load() } }
                    } else if pins.isEmpty {
                        AdminStatePlaceholder(isLoading: false, emptyText: AppString("这个节点还没有置顶帖。"))
                    } else {
                        AdminSection(title: AppString("\(pins.count) 个置顶，按置顶时间排列")) {
                            ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                                AdminRow(
                                    icon: "pin.fill", tint: AdminTheme.IconTint.green,
                                    title: pin.title,
                                    subtitle: subtitle(pin),
                                    isLast: index == pins.count - 1
                                )
                            }
                        }
                    }
                    AdminNote(text: AppString("置顶和取消置顶在帖子右上角的 ⋯ 菜单里。到期的置顶会自动取消。"))
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .background(AdminTheme.pageBg)
        .task { await load() }
    }

    private func subtitle(_ pin: NLNodePins.Pin) -> String {
        var parts: [String] = []
        if let author = pin.author { parts.append(author) }
        if let at = pin.pinnedAt { parts.append(AppString("\(adminRelative(at)) 置顶")) }
        if let until = DiscourseFormat.date(pin.pinnedUntil), until > Date(), until.timeIntervalSinceNow < 86_400 * 365 * 2 {
            parts.append(AppString("\(adminRelative(pin.pinnedUntil)) 到期"))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = pins.isEmpty
        defer { isLoading = false }
        do {
            pins = try await client.nodePinList(slug: slug)
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 版主团队

struct NodeModeratorsPage: View {
    let slug: String
    let manage: NLNodeManage?
    let onClose: () -> Void

    @State private var members: [NLNodeMembers.Member] = []
    @State private var isLoading = true

    private let client = DiscourseClient()

    /// The manage summary's list, enriched with avatars once the members
    /// call answers.
    private var rows: [(id: Int, username: String, name: String?, avatar: String?, owner: Bool)] {
        let mods = manage?.moderators ?? []
        if mods.isEmpty {
            return members.map { ($0.id, $0.username, $0.name, $0.avatar, $0.role == "owner") }
        }
        return mods
            .sorted { ($0.owner == true ? 0 : 1) < ($1.owner == true ? 0 : 1) }
            .map { mod in
                let member = members.first { $0.id == mod.id }
                return (mod.id, mod.username, member?.name, member?.avatar, mod.owner == true)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("版主团队"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty {
                        AdminStatePlaceholder(isLoading: isLoading, emptyText: AppString("还没有版主。"))
                    } else {
                        AdminSection(title: AppString("\(rows.count) 人")) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 12) {
                                    RemoteAvatar(
                                        url: NodeSummaryFactory.resolvedURL(row.avatar),
                                        letter: String(row.username.prefix(1)).uppercased(),
                                        variant: row.id % 8, size: 36
                                    )
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.name?.isEmpty == false ? row.name! : row.username)
                                                .font(Theme.body(17))
                                                .foregroundStyle(Theme.text)
                                                .lineLimit(1)
                                            Text(verbatim: "@\(row.username)")
                                                .font(Theme.body(13))
                                                .foregroundStyle(Theme.textMuted)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        AdminBadge(
                                            text: row.owner ? AppString("主理人") : AppString("版主"),
                                            tone: row.owner ? .green : .neutral,
                                            icon: row.owner ? "checkmark.shield" : nil
                                        )
                                    }
                                    .padding(.trailing, 16)
                                    .padding(.vertical, 9)
                                    .overlay(alignment: .bottom) {
                                        if index < rows.count - 1 {
                                            Rectangle().fill(AdminTheme.separator).frame(height: 1)
                                        }
                                    }
                                }
                                .padding(.leading, 16)
                            }
                        }
                    }
                    AdminNote(text: AppString("添加和移除版主、转让节点请在网页版的节点管理里操作。"))
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(AdminTheme.pageBg)
        .task {
            defer { isLoading = false }
            async let mods = try? client.nodeMembers(slug: slug, role: "moderator")
            async let owners = try? client.nodeMembers(slug: slug, role: "owner")
            let (m, o) = await (mods, owners)
            members = (o?.members ?? []) + (m?.members ?? [])
        }
    }
}

// MARK: - 节点规则

struct NodeRulesPage: View {
    let rules: [NLNodeManage.Rule]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("节点规则"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AdminNote(text: AppString("规则显示在节点介绍里，举报和删帖时可以选作理由。"))
                    if rules.isEmpty {
                        AdminStatePlaceholder(isLoading: false, emptyText: AppString("还没有规则。"))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(verbatim: "\(index + 1)")
                                        .font(Theme.body(15, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(AdminTheme.IconTint.purple, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(rule.title)
                                            .font(Theme.body(17, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                        if let detail = rule.description, !detail.isEmpty {
                                            Text(detail)
                                                .font(Theme.body(14))
                                                .foregroundStyle(Theme.textMuted)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.trailing, 16)
                                    .padding(.bottom, 12)
                                    .overlay(alignment: .bottom) {
                                        if index < rules.count - 1 {
                                            Rectangle().fill(AdminTheme.separator).frame(height: 1)
                                        }
                                    }
                                }
                                .padding(.leading, 16)
                                .padding(.top, 12)
                            }
                        }
                        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.listRadius, style: .continuous))
                        .padding(.horizontal, AdminTheme.inset)
                    }
                    AdminNote(text: AppString("规则较长，编辑请在电脑上的节点管理里进行。"))
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(AdminTheme.pageBg)
    }
}

// MARK: - 处罚中的用户

/// Who is silenced or banned in this node right now, styled after the
/// 用户管理 artboard's penalty strip, with 解除 for each.
struct NodeRestrictionsPage: View {
    let slug: String
    let onClose: () -> Void

    @State private var rows: [NLNodeRestrictions.Restriction] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var liftTarget: NLNodeRestrictions.Restriction?

    private let client = DiscourseClient()

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("处罚中的用户"), onBack: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading || errorText != nil {
                        AdminStatePlaceholder(isLoading: isLoading, errorText: errorText) { Task { await load() } }
                    } else if rows.isEmpty {
                        AdminStatePlaceholder(isLoading: false, emptyText: AppString("现在没有人在这个节点被禁言或封禁。"))
                    } else {
                        ForEach(rows) { row in
                            card(row).padding(.horizontal, AdminTheme.inset)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .background(AdminTheme.pageBg)
        .task { await load() }
        .alert(
            AppString("解除对 \(liftTarget?.username ?? "") 的处罚？"),
            isPresented: Binding(get: { liftTarget != nil }, set: { if !$0 { liftTarget = nil } })
        ) {
            Button(AppString("解除")) {
                guard let row = liftTarget else { return }
                liftTarget = nil
                Task { await lift(row) }
            }
            Button("取消", role: .cancel) { liftTarget = nil }
        }
    }

    private func card(_ row: NLNodeRestrictions.Restriction) -> some View {
        let isBan = row.kind == "ban"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RemoteAvatar(url: nil, letter: String(row.username.prefix(1)).uppercased(), variant: row.userId % 8, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.username)
                            .font(Theme.body(17, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        AdminBadge(
                            text: isBan ? AppString("封禁中") : AppString("禁言中"),
                            tone: isBan ? .orange : .amber,
                            icon: isBan ? "nosign" : "text.bubble"
                        )
                    }
                    if let created = row.createdAt {
                        Text(AppString("\(adminRelative(created)) · 由 \(row.createdBy ?? AppString("管理员")) 处理"))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remaining(row))
                        .font(Theme.body(13, weight: .semibold))
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason).font(Theme.body(13))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    liftTarget = row
                } label: {
                    Text(AppString("解除"))
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.pressable)
            }
            .foregroundStyle(AdminTone.amber.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .adminCard()
    }

    private func remaining(_ row: NLNodeRestrictions.Restriction) -> String {
        let label = row.kind == "ban" ? AppString("在本节点被封禁") : AppString("在本节点被禁言")
        guard let expires = row.expiresAt, let date = DiscourseFormat.date(expires) else {
            return AppString("\(label) · 永久")
        }
        let seconds = max(0, date.timeIntervalSinceNow)
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        let left = days > 0 ? AppString("\(days) 天 \(hours) 小时") : AppString("\(max(1, hours)) 小时")
        return AppString("\(label) · 还剩 \(left)")
    }

    private func load() async {
        isLoading = rows.isEmpty
        defer { isLoading = false }
        do {
            rows = try await client.nodeRestrictions(slug: slug)
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func lift(_ row: NLNodeRestrictions.Restriction) async {
        do {
            try await client.liftNodeRestriction(slug: slug, userID: row.userId)
            rows.removeAll { $0.userId == row.userId }
            ToastCenter.shared.show(AppString("已解除"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}
