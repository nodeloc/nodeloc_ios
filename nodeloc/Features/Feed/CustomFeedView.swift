//
//  CustomFeedView.swift
//  nodeloc
//
//  A custom feed, read natively instead of in the web view.
//
//  discourse-community lets a reader gather several nodes into one named list
//  at `/f/<username>/<slug>`. Everything the web client offers is here: the
//  topics, the nodes behind them, creating and editing a feed, adding and
//  removing its nodes, copying someone else's, and deleting your own.
//
//  Rows are `NodeTopicRow` at the reader's chosen density, so a custom feed, a
//  node and a tag all look alike — each is just a different way of gathering
//  topics.
//

import SwiftUI

/// Addresses a feed. Owner plus slug is its whole identity, and the pair is
/// what both the API and the web route are keyed on.
struct CustomFeedTarget: Identifiable, Hashable {
    let username: String
    let slug: String
    /// Known up front when opened from the drawer, so the header can show a
    /// title before the request lands.
    var name: String?

    var id: String { "\(username)/\(slug)" }

    /// The web address, used for 复制链接 and as the fallback if the server
    /// didn't send one.
    var path: String { "/f/\(username)/\(slug)" }
}

struct CustomFeedView: View {
    let target: CustomFeedTarget
    let onOpenPost: (Post) -> Void
    var onOpenNode: ((SidebarNodeSummary) -> Void)?
    /// The feed no longer exists; whoever presented this should close it.
    var onDeleted: (() -> Void)?

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store = CustomFeedStore()
    /// Retargeted after a copy, which the plugin's own client does too: the
    /// copy is a new feed and the reader is taken to it.
    @State private var current: CustomFeedTarget
    @State private var tab = Tab.feed
    @State private var editing: CustomFeedFormSheet.Mode?
    @State private var showsNodePicker = false
    @State private var confirmsDelete = false
    private var readingMode = NodeReadingModeStore.shared

    private enum Tab: Hashable { case feed, about }

    init(
        target: CustomFeedTarget,
        onOpenPost: @escaping (Post) -> Void,
        onOpenNode: ((SidebarNodeSummary) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.target = target
        self.onOpenPost = onOpenPost
        self.onOpenNode = onOpenNode
        self.onDeleted = onDeleted
        _current = State(initialValue: target)
    }

    var body: some View {
        NavigationStack {
            content
                .background(Theme.bg)
                .navigationTitle(store.feed?.name ?? current.name ?? AppString("Custom Feed"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                    ToolbarItem(placement: .topBarTrailing) { manageMenu }
                }
        }
        .task(id: current.id) {
            await store.loadIfNeeded(username: current.username, slug: current.slug)
        }
        .sheet(item: $editing) { mode in
            CustomFeedFormSheet(mode: mode) { saved in
                switch mode {
                case .edit:
                    // Same feed, new name — adopt it without refetching topics.
                    await store.adopt(saved, reloadTopics: false)
                    // A renamed feed lives at a new slug, so keep addressing it.
                    current = CustomFeedTarget(
                        username: saved.username ?? current.username,
                        slug: saved.slug,
                        name: saved.name
                    )
                case .copy, .create:
                    // A copy is a different feed; follow it, as the web does.
                    current = CustomFeedTarget(
                        username: saved.username ?? current.username,
                        slug: saved.slug,
                        name: saved.name
                    )
                    await store.load(username: current.username, slug: current.slug)
                }
            }
            .standardSheet()
        }
        .sheet(isPresented: $showsNodePicker) {
            CustomFeedNodePickerSheet(store: store)
                .standardSheet()
        }
        .confirmationDialog(
            AppString("删除「\(store.feed?.name ?? "")」？"),
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button(AppString("删除"), role: .destructive) { deleteFeed() }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text("删除后无法恢复，但其中的节点不会受影响。")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.visiblePosts.isEmpty, store.feed == nil {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.feed == nil {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                message: store.errorText ?? AppString("找不到这个 Custom Feed")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    header

                    SegmentedControl(
                        selection: $tab,
                        options: [
                            (.feed, AppString("帖子")),
                            (.about, AppString("关于")),
                        ]
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    switch tab {
                    case .feed: feedTab
                    case .about: aboutTab
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await store.load(username: current.username, slug: current.slug)
            }
        }
    }

    private var header: some View {
        let feed = store.feed
        let description = DiscourseFormat.plainText(feed?.description)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(nodeAccentColor(feed?.color ?? "009966"))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(feed?.name ?? current.name ?? "")
                        .font(Theme.heading(19, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(AppString("\(feed?.nodeCount ?? store.nodes.count) 个节点"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.6))
                }

                Spacer(minLength: 8)

                if feed?.isPrivate == true {
                    TagChip(text: AppString("私密"), style: .neutral)
                }
            }

            if !description.isEmpty {
                Text(description)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.muted(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let creator = feed?.creator, let username = creator.username {
                Button {
                    app.openProfile(username: username)
                } label: {
                    HStack(spacing: 7) {
                        RemoteAvatar(
                            url: avatarURL(creator),
                            letter: String(username.prefix(1)).uppercased(),
                            size: 22
                        )
                        Text(AppString("由 \(creator.name?.isEmpty == false ? creator.name! : username) 创建"))
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.6))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var feedTab: some View {
        if store.visiblePosts.isEmpty {
            EmptyStateView(
                icon: "tray",
                message: store.nodes.isEmpty
                    ? AppString("这个 Custom Feed 还没有节点")
                    : AppString("这些节点下还没有主题")
            )
            .padding(.top, 30)
        } else {
            ForEach(store.visiblePosts) { post in
                NodeTopicRow(
                    post: post,
                    mode: readingMode.mode,
                    onTap: { onOpenPost(post) }
                )
            }

            if store.hasMore {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        guard visible else { return }
                        Task { await store.loadMore() }
                    }
            }
        }
    }

    @ViewBuilder
    private var aboutTab: some View {
        VStack(spacing: 10) {
            if store.nodes.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    message: AppString("还没有添加节点")
                )
                .padding(.vertical, 20)
            } else {
                ForEach(store.nodes) { node in
                    Button {
                        onOpenNode?(node)
                    } label: {
                        HStack(spacing: 11) {
                            NodeAvatar(node: node, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("n/\(node.slug)")
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(node.name)
                                    .font(Theme.body(12))
                                    .foregroundStyle(Theme.muted(0.6))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.4))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenNode == nil)
                }
            }

            if store.canEdit {
                Button {
                    showsNodePicker = true
                } label: {
                    Label(AppString("管理节点"), systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private var manageMenu: some View {
        Menu {
            if store.canEdit, let feed = store.feed {
                Button {
                    editing = .edit(feed)
                } label: {
                    Label(AppString("编辑"), systemImage: "pencil")
                }
                Button {
                    showsNodePicker = true
                } label: {
                    Label(AppString("管理节点"), systemImage: "slider.horizontal.3")
                }
            }
            // Copying someone else's feed is the point of a public one, so this
            // is offered whether or not the feed is yours.
            if let feed = store.feed, app.authed {
                Button {
                    editing = .copy(feed)
                } label: {
                    Label(AppString("复制此 Feed"), systemImage: "plus.square.on.square")
                }
            }
            Button {
                copyLink()
            } label: {
                Label(AppString("复制链接"), systemImage: "link")
            }
            if store.canEdit {
                Divider()
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label(AppString("删除"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: Actions

    private func avatarURL(_ creator: CustomFeedCreator) -> URL? {
        creator.avatarTemplate.flatMap { DiscourseClient().avatarURL(template: $0, size: 80) }
    }

    private func copyLink() {
        let path = store.feed?.url ?? current.path
        let url = URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        UIPasteboard.general.string = url?.absoluteString ?? path
        ToastCenter.shared.show(AppString("链接已复制"))
    }

    private func deleteFeed() {
        guard let id = store.feed?.id else { return }
        Task {
            do {
                try await DiscourseClient().deleteCustomFeed(id: id)
                ToastCenter.shared.show(AppString("已删除"))
                onDeleted?()
                dismiss()
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }
}

// MARK: - Create / edit / copy

/// The plugin's create, edit and copy modals, which are one form with three
/// verbs and the same four fields.
struct CustomFeedFormSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(CustomFeed)
        case copy(CustomFeed)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let feed): return "edit-\(feed.id)"
            case .copy(let feed): return "copy-\(feed.id)"
            }
        }

        var title: String {
            switch self {
            case .create: return AppString("创建 Custom Feed")
            case .edit: return AppString("编辑 Custom Feed")
            case .copy: return AppString("复制 Custom Feed")
            }
        }

        var submitTitle: String {
            switch self {
            case .create, .copy: return AppString("创建")
            case .edit: return AppString("保存")
            }
        }
    }

    let mode: Mode
    /// Handed the feed the server returned, so the caller can adopt or follow it.
    let onSaved: (CustomFeed) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = false
    @State private var showOnProfile = true
    @State private var isSaving = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppString("名称"), text: $name)
                        .focused($nameFocused)
                        .submitLabel(.next)
                    TextField(AppString("描述（可选）"), text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Toggle(AppString("私密"), isOn: $isPrivate)
                    Toggle(AppString("在个人资料上展示"), isOn: $showOnProfile)
                        // A private feed can't also be advertised, which is the
                        // rule the plugin's own form enforces.
                        .disabled(isPrivate)
                } footer: {
                    Text(isPrivate
                         ? AppString("私密的 Custom Feed 只有你自己能看到。")
                         : AppString("公开的 Custom Feed 别人可以查看和复制。"))
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(Theme.body(13))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppString("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mode.submitTitle) { save() }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: prefill)
        }
        .onChange(of: isPrivate) { _, nowPrivate in
            if nowPrivate { showOnProfile = false }
        }
    }

    private func prefill() {
        switch mode {
        case .create:
            nameFocused = true
        case .edit(let feed):
            name = feed.name
            description = DiscourseFormat.plainText(feed.description)
            isPrivate = feed.isPrivate ?? false
            showOnProfile = feed.showOnProfile ?? false
        case .copy(let feed):
            // The plugin seeds the copy's name from the original and caps it at
            // 50 characters, which is the column's limit.
            name = String(AppString("\(feed.name) 的副本").prefix(50))
            description = DiscourseFormat.plainText(feed.description)
        }
    }

    private func save() {
        isSaving = true
        errorText = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { isSaving = false }
            let client = DiscourseClient()
            do {
                let response: CustomFeedResponse
                switch mode {
                case .create:
                    response = try await client.createCustomFeed(
                        name: trimmedName,
                        description: description,
                        isPrivate: isPrivate,
                        showOnProfile: showOnProfile
                    )
                case .edit(let feed):
                    response = try await client.updateCustomFeed(
                        id: feed.id,
                        name: trimmedName,
                        description: description,
                        isPrivate: isPrivate,
                        showOnProfile: showOnProfile
                    )
                case .copy(let feed):
                    response = try await client.copyCustomFeed(
                        username: feed.username ?? "",
                        slug: feed.slug,
                        name: trimmedName,
                        description: description,
                        isPrivate: isPrivate,
                        showOnProfile: showOnProfile
                    )
                }
                await onSaved(response.customFeed)
                dismiss()
            } catch {
                errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Node picker

/// Adds and removes the feed's nodes, against `/custom-feeds/node-search`.
struct CustomFeedNodePickerSheet: View {
    let store: CustomFeedStore

    @Environment(\.dismiss) private var dismiss
    @State private var search = CustomFeedNodeSearchStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    searchField

                    if search.isSearching {
                        ProgressView().tint(Theme.accent).padding(.vertical, 12)
                    }

                    if !search.results.isEmpty {
                        sectionTitle(AppString("搜索结果"))
                        // Nodes already in the feed are shown as included
                        // rather than hidden, so a repeated search doesn't look
                        // like it lost them.
                        ForEach(search.results) { node in
                            nodeRow(node, isIncluded: includedIDs.contains(node.id))
                        }
                    }

                    if !store.nodes.isEmpty {
                        sectionTitle(AppString("已包含 (\(store.nodes.count))"))
                        ForEach(store.nodes) { node in
                            nodeRow(node, isIncluded: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle(AppString("管理节点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppString("完成")) { dismiss() }
                }
            }
        }
    }

    private var includedIDs: Set<Int> { Set(store.nodes.map(\.id)) }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.muted(0.5))
            TextField(AppString("搜索节点"), text: $search.term)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: search.term) { _, _ in search.search() }
            if !search.term.isEmpty {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.body(14))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(12, weight: .semibold))
            .foregroundStyle(Theme.muted(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    private func nodeRow(_ node: SidebarNodeSummary, isIncluded: Bool) -> some View {
        HStack(spacing: 11) {
            NodeAvatar(node: node, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("n/\(node.slug)")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(node.name)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if store.busyNodeID == node.id {
                ProgressView().tint(Theme.accent)
            } else {
                Button {
                    Task {
                        if isIncluded {
                            await store.removeNode(categoryID: node.id)
                        } else {
                            await store.addNode(categoryID: node.id)
                        }
                    }
                } label: {
                    Image(systemName: isIncluded ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isIncluded ? Color.red.opacity(0.8) : Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
