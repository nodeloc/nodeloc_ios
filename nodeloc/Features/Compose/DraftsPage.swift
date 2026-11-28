//
//  DraftsPage.swift
//  nodeloc
//
//  草稿箱 (App-iOS-Drafts). Every draft here is the server's
//  (`GET /api/v1/drafts`, content/drafts.go): the app keeps no drafts of its
//  own, so the list is the same on the phone and the computer. A new-topic
//  draft continues in the composer (its key goes along, so posting removes
//  it); a reply draft opens its topic with the reply panel holding it.
//
//  Search, the type chips, select-and-delete (`POST /api/v1/drafts/delete`),
//  swipe to delete, and the held-back version from another device
//  (`POST …/conflict`) are as the design draws them, on native controls.
//

import SwiftUI

@MainActor
@Observable
final class DraftsStore {
    private let client = DiscourseClient()

    var drafts: [NLDrafts.Draft] = []
    private(set) var limit: Int?
    private(set) var isLoading = false
    private(set) var loaded = false
    private(set) var errorText: String?
    private(set) var busyKeys: Set<String> = []

    func load() async {
        isLoading = drafts.isEmpty
        defer { isLoading = false; loaded = true }
        do {
            let answer = try await client.drafts()
            drafts = answer.drafts
            limit = answer.limit
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ keys: Set<String>) async {
        guard !keys.isEmpty else { return }
        let snapshot = drafts
        withAnimation { drafts.removeAll { keys.contains($0.id) } }
        do {
            if keys.count == 1, let key = keys.first {
                try await client.deleteDraft(key: key)
            } else {
                try await client.deleteDrafts(keys: Array(keys))
            }
            ToastCenter.shared.show(keys.count == 1 ? AppString("已删除草稿") : AppString("已删除 \(keys.count) 篇草稿"))
        } catch {
            withAnimation { drafts = snapshot }
            ToastCenter.shared.showError(error)
        }
    }

    /// `held` = the other device's version, `current` = keep this one.
    func resolve(_ draft: NLDrafts.Draft, use: String) async {
        busyKeys.insert(draft.id)
        defer { busyKeys.remove(draft.id) }
        do {
            try await client.resolveDraftConflict(key: draft.id, use: use)
            await load()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }
}

enum DraftFilter: CaseIterable {
    case all, topics, replies, scheduled

    var title: String {
        switch self {
        case .all: AppString("全部")
        case .topics: AppString("新帖")
        case .replies: AppString("回复")
        case .scheduled: AppString("定时发布")
        }
    }

    func includes(_ draft: NLDrafts.Draft) -> Bool {
        switch self {
        case .all: true
        case .topics: draft.kind != "reply" && draft.scheduledAt == nil
        case .replies: draft.kind == "reply"
        case .scheduled: draft.scheduledAt != nil
        }
    }
}

struct DraftsPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var store = DraftsStore()
    @State private var filter: DraftFilter = .all
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var pendingDelete: Set<String>?

    private var visible: [NLDrafts.Draft] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.drafts.filter(filter.includes).filter { draft in
            term.isEmpty
                || (draft.title ?? "").lowercased().contains(term)
                || (draft.raw ?? "").lowercased().contains(term)
                || (draft.topicTitle ?? "").lowercased().contains(term)
                || (draft.nodeSlug ?? "").lowercased().contains(term)
        }
    }

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        List(selection: $selection) {
            Section {
                filterChips
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .selectionDisabled()
            }

            Section {
                if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                } else if let errorText = store.errorText, store.drafts.isEmpty {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                } else if visible.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                } else {
                    ForEach(visible) { draft in
                        DraftRow(
                            draft: draft,
                            isSelecting: isSelecting,
                            isBusy: store.busyKeys.contains(draft.id),
                            onOpen: { open(draft) },
                            onDelete: { pendingDelete = [draft.id] },
                            onResolve: { use in Task { await store.resolve(draft, use: use) } }
                        )
                        .tag(draft.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(AppString("删除"), role: .destructive) { pendingDelete = [draft.id] }
                        }
                    }
                }
            } footer: {
                Text(footnote)
                    .padding(.top, 8)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        // Hidden until the list is pulled down, the system's own way.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("搜索草稿"))
        .navigationTitle(AppString("草稿箱"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !store.drafts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? AppString("完成") : AppString("选择")) {
                        withAnimation {
                            editMode = isSelecting ? .inactive : .active
                            if !isSelecting { selection = [] }
                        }
                    }
                    .fontWeight(isSelecting ? .semibold : .regular)
                }
            }
            if isSelecting {
                ToolbarItem(placement: .bottomBar) {
                    Text(AppString("已选 \(selection.count) 篇"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(AppString("删除所选"), role: .destructive) { pendingDelete = selection }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
        .refreshable { await store.load() }
        .task { await store.load() }
        .alert(
            (pendingDelete?.count ?? 0) > 1 ? AppString("删除 \(pendingDelete?.count ?? 0) 篇草稿？") : AppString("删除这篇草稿？"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(AppString("删除"), role: .destructive) {
                guard let keys = pendingDelete else { return }
                pendingDelete = nil
                selection.subtract(keys)
                if store.drafts.count == keys.count { editMode = .inactive }
                Task { await store.delete(keys) }
            }
            Button(AppString("取消"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(AppString("手机和电脑上都会删除，不能恢复。"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.drafts.isEmpty ? AppString("草稿箱是空的") : AppString("没有找到相关草稿"))
                .font(.headline)
            if store.drafts.isEmpty {
                Text(AppString("写到一半的帖子和回复会自动保存在这里。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var footnote: String {
        let base = AppString("草稿保存在服务器上，手机和电脑会同步。90 天没有修改的草稿会被删除，删除前 7 天会提醒你。")
        guard let limit = store.limit else { return base }
        return base + AppString("最多保存 \(limit) 篇，当前已用 \(store.drafts.count) 篇。")
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(DraftFilter.allCases, id: \.self) { option in
                    let isOn = filter == option
                    let count = store.drafts.filter(option.includes).count
                    CountFilterChip(title: option.title, count: count, isOn: isOn) {
                        withAnimation(.snappy) { filter = option }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// A topic draft continues in the composer (title, node, body, and its
    /// key); a reply draft opens its topic with the reply panel holding it.
    private func open(_ draft: NLDrafts.Draft) {
        if draft.kind == "reply" {
            guard let topicID = draft.topicId else { return }
            app.pendingReplyDraft = (draft.raw ?? "", draft.replyTo, draft.replyToUsername)
            app.openTopicPage(id: topicID)
            return
        }
        app.composePrefillTitle = draft.title
        app.composePrefillBody = draft.raw
        app.composeDraftKey = draft.id
        app.composePrefillTags = draft.tags
        if let slug = draft.nodeSlug, slug != "_profile" {
            app.composePreselectedNode = NodeCatalog.shared.cachedNode(slug: slug)
        }
        withAnimation(.overlayPush) { app.overlay = .compose }
    }
}

// MARK: - Row

private struct DraftRow: View {
    let draft: NLDrafts.Draft
    let isSelecting: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onResolve: (String) -> Void

    private var isReply: Bool { draft.kind == "reply" }
    private var isScheduled: Bool { draft.scheduledAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    Text(titleText)
                        .font(.headline)
                        .foregroundStyle(hasTitle ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    if let raw = draft.raw, !raw.isEmpty {
                        Text(excerpt(raw))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    meta
                    if let error = draft.scheduleError, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isSelecting {
                    VStack(alignment: .trailing, spacing: 14) {
                        Button(isScheduled ? AppString("修改") : AppString("继续编辑"), action: onOpen)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.regular)
                            .fontWeight(.semibold)
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                        .accessibilityLabel(AppString("删除草稿"))
                    }
                }
            }
            if let conflict = draft.conflict {
                conflictBanner(conflict)
            }
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(kindTitle)
                .font(.caption.weight(.bold))
                .foregroundStyle(kindTint.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(kindTint.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(contextLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(savedLine, systemImage: draft.device == "phone" ? "iphone" : "desktopcomputer")
                    .labelStyle(CompactLabelStyle())
                Text(AppString("\((draft.raw ?? "").count.formatted()) 字"))
            }
            HStack(spacing: 10) {
                if let images = draft.imageCount, images > 0 {
                    Text(AppString("\(images) 张图片"))
                }
                if let expiry = expiryLine {
                    Text(expiry)
                        .fontWeight(.semibold)
                        .foregroundStyle(AdminTone.amber.text)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func conflictBanner(_ conflict: NLDrafts.Draft.Conflict) -> some View {
        let device = deviceName(conflict.device) ?? AppString("另一台设备")
        let added = (conflict.raw ?? "").count - (draft.raw ?? "").count
        let when = conflict.savedAt.map { DiscourseFormat.relative($0) }
        var detail = [when].compactMap { $0 }
        if added != 0 { detail.append(added > 0 ? AppString("多了 \(added) 字") : AppString("少了 \(-added) 字")) }
        return VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(AppString("这篇草稿在\(device)上有更新的版本") + (detail.isEmpty ? "" : "（\(detail.joined(separator: "，"))）") + "。")
            } icon: {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(AdminTone.amber.text)
            }
            .font(.subheadline)
            HStack(spacing: 10) {
                Button { onResolve("held") } label: {
                    Text(AppString("用\(device)上的版本")).foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.label))
                Button(AppString("保留这个")) { onResolve("current") }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                if isBusy { ProgressView() }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.amber.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Text

    private var kindTitle: String {
        isScheduled ? AppString("定时发布") : (isReply ? AppString("回复") : AppString("新帖"))
    }

    private var kindTint: (text: Color, fill: Color) {
        if isScheduled { return (Theme.accent700, Theme.accent.opacity(0.14)) }
        if isReply { return (Color(light: 0x1F6FA8, dark: 0x7FBEEB), Color(light: 0x1F6FA8, dark: 0x7FBEEB).opacity(0.14)) }
        return (.secondary, Color(.tertiarySystemFill))
    }

    private var contextLine: String {
        if isReply {
            let who = draft.replyToUsername.map { AppString("回复 u/\($0)") } ?? AppString("回复")
            return [who, draft.topicTitle].compactMap { $0 }.joined(separator: " · ")
        }
        // The web writes `_profile` for a post to the author's own page.
        if draft.nodeSlug == "_profile" { return AppString("我的主页") }
        if let slug = draft.nodeSlug { return "n/\(slug)" }
        return AppString("未选择节点")
    }

    private var hasTitle: Bool { isReply || draft.title?.isEmpty == false }

    private var titleText: String {
        if isReply { return AppString("回复草稿") }
        if let title = draft.title, !title.isEmpty { return title }
        return AppString("无标题")
    }

    /// The body as a line of text: images and markup left out.
    private func excerpt(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#>*_`]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    private func deviceName(_ device: String?) -> String? {
        switch device {
        case "phone": AppString("手机")
        case "pc": AppString("电脑")
        default: nil
        }
    }

    private var savedLine: String {
        let when: String
        if let scheduled = draft.scheduledAt, let date = DiscourseFormat.date(scheduled) {
            when = AppString("将于 \(date.formatted(.dateTime.month().day().hour().minute().locale(AppLanguage.resolved.locale))) 发布")
        } else {
            when = AppString("保存于 \(DiscourseFormat.relative(draft.updatedAt))")
        }
        return [when, deviceName(draft.device)].compactMap { $0 }.joined(separator: " · ")
    }

    private var expiryLine: String? {
        guard !isScheduled, let expires = DiscourseFormat.date(draft.expiresAt),
              expires.timeIntervalSinceNow < 7 * 24 * 3600 else { return nil }
        let days = max(0, Int(ceil(expires.timeIntervalSinceNow / 86_400)))
        return AppString("90 天未修改，\(days) 天后删除")
    }
}
