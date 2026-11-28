//
//  NodeAdminPages.swift
//  nodeloc
//
//  节点管理 for a node's owner and moderators: a hub with what waits in the
//  node's queue and the ways into its tools, plus the two tools that live
//  only here — 访问名单 (who may read and post) and 频道 (outside feeds the
//  node imports as topics).
//
//  Both follow the backend's node/access.go and channel/handlers.go.
//

import SwiftUI

// MARK: - Hub

/// What the hub reads on open: the manage summary, the pending queue counts,
/// and the two extension pages' state for their subtitles.
@MainActor
@Observable
final class NodeAdminHubStore {
    private let client = DiscourseClient()
    let slug: String

    private(set) var manage: NLNodeManage?
    private(set) var pendingPosts: Int?
    private(set) var reports: Int?
    private(set) var appeals: Int?
    private(set) var accessCount: Int?
    private(set) var channelKinds: [String] = []
    private(set) var channelErrors = 0

    init(slug: String) { self.slug = slug }

    func load() async {
        async let manageCall = try? client.nodeManage(slug: slug)
        async let queueCall = try? client.reviewQueue(.node(slug), status: "pending", limit: 1)
        async let accessCall = try? client.nodeAccess(slug: slug)
        async let channelsCall = try? client.nodeChannels(slug: slug)
        let (manage, queue, access, channels) = await (manageCall, queueCall, accessCall, channelsCall)
        if let manage { self.manage = manage }
        if let queue {
            let kinds = queue.kindCounts ?? [:]
            let total = queue.counts?["pending"] ?? kinds.values.reduce(0, +)
            let pending = kinds["pending_post"] ?? 0
            let appeal = kinds.filter { $0.key.hasSuffix("_appeal") }.values.reduce(0, +)
            pendingPosts = pending
            appeals = appeal
            reports = max(0, total - pending - appeal)
        }
        accessCount = access?.entries?.count
        if let channels {
            var seen: [String] = []
            for kind in channels.compactMap({ NodeChannelsPage.sourceName($0.kind) }) where !seen.contains(kind) {
                seen.append(kind)
            }
            channelKinds = seen
            channelErrors = channels.filter { $0.status == "error" }.count
        }
    }
}

struct NodeAdminPage: View {
    let slug: String
    let nodeName: String
    let onClose: () -> Void

    private enum Route: String, Identifiable, Hashable {
        case dashboard, queue, log, access, channels, info, pins, team, rules, members
        var id: String { rawValue }
    }

    @State private var route: Route?
    @State private var store: NodeAdminHubStore

    init(slug: String, nodeName: String, onClose: @escaping () -> Void) {
        self.slug = slug
        self.nodeName = nodeName
        self.onClose = onClose
        _store = State(initialValue: NodeAdminHubStore(slug: slug))
    }

    private var handle: String { "n/\(store.manage?.node.slug ?? slug)" }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("\(handle) 管理"), onBack: onClose) {
                Menu {
                    Button { route = .dashboard } label: { Label(AppString("管理台"), systemImage: "rectangle.grid.2x2") }
                    Button { route = .members } label: { Label(AppString("处罚中的用户"), systemImage: "person.crop.circle.badge.exclamationmark") }
                } label: {
                    BarIcon(systemName: "ellipsis")
                }
                .accessibilityLabel(AppString("更多"))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identityCard
                    HStack(spacing: 10) {
                        AdminStatTile(
                            icon: "clock", tone: .amber,
                            value: store.pendingPosts.map(String.init) ?? "–", label: AppString("待审核")
                        ) { route = .queue }
                        AdminStatTile(
                            icon: "flag", tone: .orange,
                            value: store.reports.map(String.init) ?? "–", label: AppString("举报")
                        ) { route = .queue }
                    }
                    .padding(.horizontal, AdminTheme.inset)

                    AdminSection(title: AppString("节点")) {
                        AdminRow(icon: "pencil", tint: AdminTheme.IconTint.slate, title: AppString("基本信息"),
                                 value: AppString("名称、简介")) { route = .info }
                        AdminRow(icon: "pin", tint: AdminTheme.IconTint.green, title: AppString("置顶帖"),
                                 value: store.manage?.node.pinnedCount.map { AppString("\($0) 个") }) { route = .pins }
                        AdminRow(icon: "person.2", tint: AdminTheme.IconTint.blue, title: AppString("版主团队"),
                                 value: store.manage?.moderators.map { AppString("\($0.count) 人") }) { route = .team }
                        AdminRow(icon: "line.3.horizontal.decrease", tint: AdminTheme.IconTint.purple, title: AppString("节点规则"),
                                 value: store.manage?.rules.map { AppString("\($0.count) 条") }, isLast: true) { route = .rules }
                    }

                    AdminSection(title: AppString("权限与扩展")) {
                        AdminRow(icon: "key", tint: AdminTheme.IconTint.rust, title: AppString("访问名单"),
                                 subtitle: accessSubtitle) { route = .access }
                        AdminRow(icon: "dot.radiowaves.up.forward", tint: AdminTheme.IconTint.amber, title: AppString("频道"),
                                 subtitle: channelsSubtitle, isLast: true) { route = .channels }
                    }

                    AdminSection {
                        AdminRow(icon: "clock.arrow.circlepath", tint: AdminTheme.IconTint.slate, title: AppString("操作日志"),
                                 isLast: true) { route = .log }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.load() }
        }
        .background(AdminTheme.pageBg)
        .task { await store.load() }
        // Each page pushed on the same stack, with the system back button.
        .navigationDestination(item: $route) { route in
            switch route {
            case .dashboard: ModerationDashboardPage(scope: .node(slug)) { self.route = nil }
            case .queue: ReviewQueuePage(scope: .node(slug)) { self.route = nil }
            case .log: ModerationLogPage(scope: .node(slug)) { self.route = nil }
            case .access: NodeAccessPage(slug: slug) { self.route = nil }
            case .channels: NodeChannelsPage(slug: slug, nodeName: handle) { self.route = nil }
            case .info: NodeInfoPage(slug: slug, manage: store.manage) { self.route = nil }
            case .pins: NodePinsManagePage(slug: slug) { self.route = nil }
            case .team: NodeModeratorsPage(slug: slug, manage: store.manage) { self.route = nil }
            case .rules: NodeRulesPage(rules: store.manage?.rules ?? []) { self.route = nil }
            case .members: NodeRestrictionsPage(slug: slug) { self.route = nil }
            }
        }
    }

    /// n/indie, and who you are here: 你是主理人 · 3 位版主 · 2.4 万成员.
    private var identityCard: some View {
        let node = store.manage?.node
        let color = node?.color.flatMap(Color.init(cssHex:)) ?? Theme.accent
        let icon = node?.iconText ?? ""
        let letter = icon.isEmpty ? String((node?.name ?? slug).prefix(1)).uppercased() : String(icon.prefix(1))
        var parts: [String] = []
        switch store.manage?.role {
        case "owner": parts.append(AppString("你是主理人"))
        case "moderator": parts.append(AppString("你是版主"))
        case .some: parts.append(AppString("你是站务"))
        case nil: break
        }
        if let mods = store.manage?.moderators {
            parts.append(AppString("\(mods.filter { $0.owner != true }.count) 位版主"))
        }
        if let members = node?.memberCount {
            parts.append(AppString("\(Self.count(members)) 成员"))
        }
        return HStack(spacing: 12) {
            if let url = NodeSummaryFactory.resolvedURL(node?.logoUrl) {
                CachedRemoteImage(url: url) { $0.resizable().scaledToFill() } placeholder: { color }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                AdminLetterAvatar(letter: letter, color: color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: handle)
                    .font(Theme.body(17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AdminTheme.card, in: RoundedRectangle(cornerRadius: AdminTheme.cardRadius, style: .continuous))
        .padding(.horizontal, AdminTheme.inset)
    }

    private var accessSubtitle: String {
        guard let count = store.accessCount else { return AppString("限制谁能看和发帖") }
        return count == 0
            ? AppString("名单是空的，只有节点成员能回帖和发主题")
            : AppString("名单里的 \(count) 个用户组不用加入也能参与")
    }

    private var channelsSubtitle: String {
        var text = store.channelKinds.isEmpty
            ? AppString("自动拉取外部内容发成帖子")
            : AppString("自动拉取 \(store.channelKinds.joined(separator: "、"))")
        if store.channelErrors > 0 { text += AppString(" · \(store.channelErrors) 个出错") }
        return text
    }

    /// 2.4 万 from ten thousand up, the plain number below.
    static func count(_ value: Int) -> String {
        guard value >= 10_000 else { return "\(value)" }
        // 2.4万 in Chinese, 24K in English: the locale's own compact form.
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(AppLanguage.resolved.locale))
    }
}

// MARK: - 访问名单

/// The node's access list (node/access.go): each row lets one group go as far
/// as a step in this node without joining it. It only lets more people in;
/// shutting people out is the node's visibility and posting settings.
struct NodeAccessPage: View {
    let slug: String
    let onClose: () -> Void

    @State private var entries: [NLNodeAccess.Entry] = []
    @State private var choices: [NLNodeAccess.Group] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var isSaving = false
    @State private var showsGroupPicker = false

    private let client = DiscourseClient()

    private struct Step: Hashable {
        let level: Int
        let label: String
    }

    /// The steps, each including the ones before it (node/service.go).
    private static let steps: [Step] = [
        Step(level: 1, label: AppString("能看")),
        Step(level: 2, label: AppString("能看、能回帖")),
        Step(level: 3, label: AppString("能看、能回帖、能发主题")),
        Step(level: 4, label: AppString("能帮着管（等同节点版主）")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("访问名单"), onBack: onClose) {
                if !isLoading && errorText == nil {
                    AdminCircleButton(systemName: "plus", accessibilityLabel: AppString("添加用户组")) {
                        showsGroupPicker = true
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading || errorText != nil {
                        AdminStatePlaceholder(isLoading: isLoading, errorText: errorText) {
                            Task { await load() }
                        }
                    } else {
                        AdminNote(text: AppString("让某些用户组不用加入节点，也能直接做到某一步。名单只会多放人，不会把人挡在外面。"))

                        AdminSection(
                            title: AppString("名单 · \(entries.count) 个用户组"),
                            footer: entries.isEmpty ? AppString("名单是空的：现在只有节点成员能回帖和发主题。") : nil
                        ) {
                            ForEach(Array(entries.enumerated()), id: \.element.subject) { _, entry in
                                row(entry)
                            }
                            AdminRow(
                                icon: "plus", tint: AdminTheme.IconTint.green,
                                title: AppString("添加用户组"), titleColor: Theme.accent,
                                showsChevron: false, isLast: true
                            ) { showsGroupPicker = true }
                        }

                        AdminSection(title: AppString("每一步能做什么")) {
                            ForEach(Array(Self.steps.enumerated()), id: \.element.level) { index, step in
                                AdminRow(
                                    icon: Self.stepIcon(step.level), tint: Self.stepTint(step.level),
                                    title: step.label, isLast: index == Self.steps.count - 1
                                )
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .disabled(isSaving)
        }
        .background(AdminTheme.pageBg)
        .task { await load() }
        .sheet(isPresented: $showsGroupPicker) {
            GroupPickerSheet(
                choices: choices.filter { group in !entries.contains { $0.subject == group.subject } },
                label: Self.label
            ) { picked in
                Task { await save(entries + [NLNodeAccess.Entry(subject: picked.subject, level: 1)]) }
            }
        }
    }

    private static func stepIcon(_ level: Int) -> String {
        switch level {
        case 1: "eye"
        case 2: "bubble.left"
        case 3: "square.and.pencil"
        default: "shield"
        }
    }

    private static func stepTint(_ level: Int) -> Color {
        switch level {
        case 1: AdminTheme.IconTint.slate
        case 2: AdminTheme.IconTint.blue
        case 3: AdminTheme.IconTint.green
        default: AdminTheme.IconTint.purple
        }
    }

    private func row(_ entry: NLNodeAccess.Entry) -> some View {
        let group = choices.first { $0.subject == entry.subject }
        // 没登录的人只能看; only moderators and custom groups may help manage.
        let maxLevel = group?.kind == "everyone" ? 1 : (group?.kind == "group" || group?.kind == "moderators" ? 4 : 3)
        let name = group.map(Self.label) ?? entry.subject
        return AdminRow(
            icon: "person.2", tint: AdminTheme.IconTint.rust, title: name, showsChevron: false
        ) {
            Menu {
                ForEach(Self.steps.filter { $0.level <= maxLevel }, id: \.level) { step in
                    Button(step.label) {
                        var next = entries
                        if let i = next.firstIndex(where: { $0.subject == entry.subject }) { next[i].level = step.level }
                        Task { await save(next) }
                    }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await save(entries.filter { $0.subject != entry.subject }) }
                } label: {
                    Label(AppString("从名单移除"), systemImage: "minus.circle")
                }
            } label: {
                HStack(spacing: 3) {
                    Text(Self.shortStep(entry.level))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(Theme.body(15))
                .foregroundStyle(Theme.textMuted)
            }
            .accessibilityLabel(AppString("\(name) 的权限"))
        }
    }

    private static func shortStep(_ level: Int) -> String {
        switch level {
        case 1: AppString("能看")
        case 2: AppString("能回帖")
        case 3: AppString("能发主题")
        default: AppString("帮着管")
        }
    }

    /// The web's names for the built-in kinds; `level` reads "<level> 起".
    static func label(_ group: NLNodeAccess.Group) -> String {
        switch group.kind {
        case "everyone": AppString("所有人（包括没登录的）")
        case "members": AppString("登录用户")
        case "moderators": AppString("全站版主")
        case "level": AppString("\(group.name ?? group.subject)起")
        default: group.name ?? group.subject
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let access = try await client.nodeAccess(slug: slug)
            entries = access.entries ?? []
            choices = access.groups ?? []
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(_ next: [NLNodeAccess.Entry]) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.updateNodeAccess(slug: slug, entries: next)
            entries = next
            ToastCenter.shared.show(AppString("已保存"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

/// Pick one of the groups the server offers for the list; filtered locally,
/// since the access endpoint already returns every choice.
private struct GroupPickerSheet: View {
    let choices: [NLNodeAccess.Group]
    let label: (NLNodeAccess.Group) -> String
    let onPick: (NLNodeAccess.Group) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [NLNodeAccess.Group] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return choices }
        return choices.filter { label($0).localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { group in
                    Button {
                        onPick(group)
                        dismiss()
                    } label: {
                        Text(label(group)).foregroundStyle(Theme.text)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("用户组名称"))
            .navigationTitle("添加用户组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .standardSheet([.large])
    }
}

// MARK: - 频道

@MainActor
@Observable
final class NodeChannelsStore {
    private let client = DiscourseClient()
    let slug: String

    private(set) var channels: [NLNodeChannels.Channel] = []
    private(set) var isLoading = false
    private(set) var errorText: String?
    private(set) var busyIDs: Set<Int> = []

    init(slug: String) { self.slug = slug }

    func load() async {
        isLoading = channels.isEmpty
        defer { isLoading = false }
        do {
            channels = try await client.nodeChannels(slug: slug)
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func perform(_ id: Int, _ action: () async throws -> Void) async {
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            try await action()
            await load()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    func setPaused(_ channel: NLNodeChannels.Channel, _ paused: Bool) async {
        await perform(channel.id) { try await client.setNodeChannelPaused(slug: slug, channel: channel, paused: paused) }
    }

    func retry(_ channel: NLNodeChannels.Channel) async {
        await perform(channel.id) { try await client.retryNodeChannel(slug: slug, id: channel.id) }
    }

    func remove(_ channel: NLNodeChannels.Channel) async {
        await perform(channel.id) { try await client.removeNodeChannel(slug: slug, id: channel.id) }
    }

    func add(url: String) async -> Bool {
        let (kind, source) = Self.kindAndSource(of: url)
        do {
            try await client.addNodeChannel(slug: slug, kind: kind, source: source)
            ToastCenter.shared.show(AppString("已添加频道"))
            await load()
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// The server wants the platform up front; the field takes a link, so
    /// read it off the host. Anything else is a feed, which must be a full
    /// http(s) address.
    nonisolated static func kindAndSource(of input: String) -> (kind: String, source: String) {
        let lower = input.lowercased()
        let host = URL(string: lower.contains("://") ? lower : "https://" + lower)?.host() ?? ""
        func on(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if on(["youtube.com", "youtu.be"]) || (lower.hasPrefix("@") && !lower.contains("/")) { return ("youtube", input) }
        if on(["bilibili.com", "b23.tv"]) { return ("bilibili", input) }
        if on(["t.me", "telegram.me"]) { return ("telegram", input) }
        return ("rss", input.contains("://") ? input : "https://" + input)
    }
}

struct NodeChannelsPage: View {
    let nodeName: String
    let onClose: () -> Void

    @State private var store: NodeChannelsStore
    @State private var showsAdd = false
    @State private var newURL = ""
    @State private var removeTarget: NLNodeChannels.Channel?

    init(slug: String, nodeName: String, onClose: @escaping () -> Void) {
        self.nodeName = nodeName
        self.onClose = onClose
        _store = State(initialValue: NodeChannelsStore(slug: slug))
    }

    var body: some View {
        VStack(spacing: 0) {
            AdminHeader(title: AppString("频道"), onBack: onClose) {
                AdminCircleButton(systemName: "plus", accessibilityLabel: AppString("添加频道")) {
                    newURL = ""
                    showsAdd = true
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AdminNote(text: AppString("频道里的新内容会自动发成 \(nodeName) 的帖子，作者显示为频道名。"))

                    if store.isLoading || (store.errorText != nil && store.channels.isEmpty) {
                        AdminStatePlaceholder(isLoading: store.isLoading, errorText: store.errorText) {
                            Task { await store.load() }
                        }
                    } else if store.channels.isEmpty {
                        VStack(spacing: 14) {
                            AdminStatePlaceholder(isLoading: false, emptyText: AppString("还没有频道。添加 YouTube、Bilibili、Telegram 公开频道或 RSS 地址，新内容会自动发到节点里。"))
                            AdminActionButton(title: AppString("添加频道"), icon: "plus", tone: .green, height: 44) {
                                newURL = ""
                                showsAdd = true
                            }
                            .padding(.horizontal, AdminTheme.inset)
                        }
                    } else {
                        ForEach(store.channels) { channel in
                            card(channel)
                                .padding(.horizontal, AdminTheme.inset)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await store.load() }
        }
        .background(AdminTheme.pageBg)
        .task { await store.load() }
        .alert(AppString("添加频道"), isPresented: $showsAdd) {
            TextField("youtube.com/@…", text: $newURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button(AppString("添加")) {
                let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                Task { _ = await store.add(url: url) }
            }
        } message: {
            Text("支持 YouTube、Bilibili、Telegram 公开频道和 RSS 地址。")
        }
        .alert(
            AppString("移除这个频道？"),
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            )
        ) {
            Button(AppString("移除"), role: .destructive) {
                guard let channel = removeTarget else { return }
                removeTarget = nil
                Task { await store.remove(channel) }
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: {
            Text("已经发出的帖子会保留。")
        }
    }

    private func card(_ channel: NLNodeChannels.Channel) -> some View {
        let status = channel.status ?? "ok"
        let style = Self.style(channel.kind)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: style.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(style.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text([Self.sourceName(channel.kind), channel.name].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.body(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let url = channel.displayURL {
                        Text(Self.trimScheme(url))
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch status {
                case "paused": AdminBadge(text: AppString("已暂停"))
                case "error": AdminBadge(text: AppString("出错"), tone: .orange)
                default: AdminBadge(text: AppString("正常"), tone: .green)
                }
            }

            if status == "error" {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(channel.lastError ?? AppString("读取失败"))
                        .font(Theme.body(13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await store.retry(channel) }
                    } label: {
                        Text(AppString("重试")).font(Theme.body(13, weight: .bold))
                    }
                    .buttonStyle(.pressable)
                }
                .foregroundStyle(AdminTone.orange.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AdminTone.orange.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            let recent = Array((channel.recent ?? []).prefix(2))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(adminRelative(item.createdAt))
                                .foregroundStyle(Theme.textFaint)
                            Text(item.title)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                        .font(Theme.body(13))
                    }
                }
            }

            HStack {
                Text(footer(channel))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if store.busyIDs.contains(channel.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { status != "paused" },
                        set: { on in Task { await store.setPaused(channel, !on) } }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .accessibilityLabel(AppString("自动拉取"))
                }
            }
        }
        .adminCard()
        .contextMenu {
            Button(role: .destructive) {
                removeTarget = channel
            } label: {
                Label(AppString("移除频道"), systemImage: "trash")
            }
        }
    }

    private func footer(_ channel: NLNodeChannels.Channel) -> String {
        if channel.status == "paused" {
            return channel.pausedAt.map { AppString("已暂停 · \(adminRelative($0))") } ?? AppString("已暂停")
        }
        var parts: [String] = []
        if channel.kind != "webhook", let minutes = channel.pollMinutes { parts.append(AppString("每 \(minutes) 分钟检查")) }
        if let checked = channel.lastPolledAt { parts.append(AppString("上次 \(adminRelative(checked))")) }
        return parts.joined(separator: " · ")
    }

    private static func trimScheme(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
    }

    /// The artboard's per-platform squircle: red play for YouTube, teal play
    /// for Bilibili, blue bubble for Telegram.
    private static func style(_ kind: String?) -> (icon: String, tint: Color) {
        switch kind?.lowercased() {
        case "youtube": ("play.fill", AdminTheme.IconTint.red)
        case "bilibili": ("play.fill", AdminTheme.IconTint.teal)
        case "telegram": ("bubble.left", AdminTheme.IconTint.blue)
        case "webhook": ("arrow.down.to.line", AdminTheme.IconTint.purple)
        default: ("dot.radiowaves.up.forward", AdminTheme.IconTint.amber)
        }
    }

    static func sourceName(_ source: String?) -> String? {
        switch source?.lowercased() {
        case "youtube": "YouTube"
        case "bilibili": "Bilibili"
        case "telegram": "Telegram"
        case "rss": "RSS"
        case "webhook": AppString("外部推送")
        case let other?: other
        case nil: nil
        }
    }
}
