//
//  PersonalPages.swift
//  nodeloc
//
//  我的收藏 (App-iOS-Saved), 我的节点 (App-iOS-MyNodes), 我的交易
//  (App-iOS-Trades) and 新人指引 (App-iOS-Onboarding), on the app-wide page
//  stack with the system navigation bar.
//
//  Endpoints: GET /api/v1/saved and /bookmark-folders; GET /api/v1/me/nodes;
//  GET /api/v1/trade-orders; GET /api/v1/me/onboarding. Everything that moves
//  money on an order (pay, ship, confirm, dispute) happens on the order's web
//  page, which a card opens in the in-app browser.
//

import SwiftUI

// MARK: - Shared pieces

private struct PageTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.body(28, weight: .bold))
                .foregroundStyle(Theme.text)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// A chip with a count, ink when picked: the node page's style.
private struct CountChip: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CapsuleChipLabel(title: count.map { "\(title) \($0)" } ?? title, isSelected: selected, unselectedWeight: .medium)
        }
        .buttonStyle(.pressable)
    }
}

private struct SearchBox: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
            TextField(prompt, text: $text).submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.textFaint.opacity(0.6), lineWidth: 1))
    }
}

private struct CardSkeleton: View {
    var height: CGFloat = 120
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(Theme.chip).frame(height: height).skeletonPulsing()
    }
}

// MARK: - 我的收藏

@MainActor
@Observable
final class SavedStore {
    private let client = DiscourseClient()
    private(set) var folders: [NLBookmarkFolders.Folder] = []
    private(set) var total: Int?
    var items: [NLSaved.Bookmark] = []
    private(set) var loaded = false
    private(set) var nextOffset: Int?

    var folder: String?
    var kind: String?
    var sort: String?
    var query = ""

    func loadFolders() async {
        if let found = try? await client.bookmarkFolders() {
            folders = found.folders
            total = found.total
        }
    }

    /// `POST /api/v1/bookmark-folders {"name"}` (1–16 characters, at most
    /// 50 folders, no two alike). The new folder's id, or the server's words.
    func createFolder(_ name: String) async -> Result<Int, FolderError> {
        struct Created: Decodable { let id: Int }
        do {
            let data = try await client.http.send("POST", "api/v1/bookmark-folders", body: .json(["name": name]))
            let created = try NodelocJSON.decode(Created.self, from: data)
            await loadFolders()
            return .success(created.id)
        } catch {
            return .failure(FolderError(error))
        }
    }

    /// `PATCH /api/v1/bookmark-folders/{id} {"name"}`.
    func renameFolder(_ id: Int, to name: String) async -> FolderError? {
        do {
            try await client.http.send("PATCH", "api/v1/bookmark-folders/\(id)", body: .json(["name": name]))
            await loadFolders()
            return nil
        } catch {
            return FolderError(error)
        }
    }

    /// `DELETE /api/v1/bookmark-folders/{id}`: its bookmarks go back to 未分类.
    func deleteFolder(_ id: Int) async -> FolderError? {
        do {
            try await client.http.send("DELETE", "api/v1/bookmark-folders/\(id)")
            if folder == String(id) { folder = nil }
            await loadFolders()
            await reload()
            return nil
        } catch {
            return FolderError(error)
        }
    }

    /// Moves one bookmark: the card changes at once (and leaves a filtered
    /// folder it no longer belongs to); a refusal puts it back.
    func move(_ item: NLSaved.Bookmark, to folderID: Int?) async -> String? {
        let before = items
        let moved = item.with(folderId: folderID)
        withAnimation(.snappy) {
            if let folder, folder != "none", folder != String(folderID ?? -1) {
                items.removeAll { $0.id == item.id }
            } else if folder == "none", folderID != nil {
                items.removeAll { $0.id == item.id }
            } else if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = moved
            }
        }
        do {
            try await BookmarkAPI.move([item.id], to: folderID)
            await loadFolders()
            return nil
        } catch {
            withAnimation(.snappy) { items = before }
            return BookmarkAPI.message(error)
        }
    }

    func setNote(_ item: NLSaved.Bookmark, _ note: String) async -> String? {
        let before = items
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item.with(note: note) }
        do {
            try await BookmarkAPI.setNote(item.id, note)
            return nil
        } catch {
            items = before
            return BookmarkAPI.message(error)
        }
    }

    func remove(_ item: NLSaved.Bookmark) async -> String? {
        let before = items
        withAnimation(.snappy) { items.removeAll { $0.id == item.id } }
        do {
            try await BookmarkAPI.remove([item.id])
            await loadFolders()
            return nil
        } catch {
            withAnimation(.snappy) { items = before }
            return BookmarkAPI.message(error)
        }
    }

    struct FolderError: Error {
        let message: String
        init(_ error: Error) {
            message = ServerFieldErrors.last()["name"]
                ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reload() async {
        let page = try? await fetch(offset: 0)
        items = page?.bookmarks ?? []
        nextOffset = page?.nextOffset
        loaded = true
    }

    func loadMore() async {
        guard let offset = nextOffset, let page = try? await fetch(offset: offset) else { return }
        items += page.bookmarks
        nextOffset = page.nextOffset
    }

    private func fetch(offset: Int) async throws -> NLSaved {
        var query = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "offset", value: String(offset))]
        if let folder { query.append(URLQueryItem(name: "folder", value: folder)) }
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        if let sort { query.append(URLQueryItem(name: "sort", value: sort)) }
        let term = self.query.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty { query.append(URLQueryItem(name: "q", value: term)) }
        return try await client.get("api/v1/saved", query: query)
    }
}

struct SavedPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var store = SavedStore()
    @State private var searchTask: Task<Void, Never>?
    /// The name being typed for a new or renamed folder; kept when the
    /// server refuses it, so the alert comes back with it.
    @State private var folderName = ""
    @State private var folderPrompt: FolderPrompt?
    @State private var folderMessage: String?
    @State private var deleteCandidate: NLBookmarkFolders.Folder?
    @State private var isWorkingOnFolder = false
    /// The card whose 收藏夹, note or removal is under way.
    @State private var movingItem: SavedItemRef?
    @State private var noteItem: SavedItemRef?
    @State private var noteText = ""
    @State private var removeItem: SavedItemRef?

    private struct SavedItemRef: Identifiable {
        let item: NLSaved.Bookmark
        var id: Int { item.id }
    }

    private enum FolderPrompt: Identifiable {
        case create
        case rename(NLBookmarkFolders.Folder)
        var isCreate: Bool { if case .create = self { true } else { false } }
        var id: String {
            switch self {
            case .create: "create"
            case .rename(let folder): "rename-\(folder.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                folderChips
                    .padding(.top, 8)
                filters
                if !store.loaded {
                    ForEach(["a", "b", "c"], id: \.self) { _ in CardSkeleton() }
                } else if store.items.isEmpty {
                    EmptyStateView(icon: "bookmark", message: AppString("这里还没有收藏"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    ForEach(store.items, id: \.id) { item in
                        savedCard(item)
                            .contextMenu {
                                Button { movingItem = SavedItemRef(item: item) } label: {
                                    Label(AppString("移动到收藏夹"), systemImage: "folder")
                                }
                                Button {
                                    noteText = item.note ?? ""
                                    noteItem = SavedItemRef(item: item)
                                } label: {
                                    Label(item.note?.isEmpty == false ? AppString("编辑备注") : AppString("添加备注"), systemImage: "pencil")
                                }
                                Button(role: .destructive) { removeItem = SavedItemRef(item: item) } label: {
                                    Label(AppString("取消收藏"), systemImage: "bookmark.slash")
                                }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if store.nextOffset != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onScrollVisibilityChange { if $0 { Task { await store.loadMore() } } }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.surface.opacity(0.5))
        // Hidden until the page is pulled down; the server search, debounced.
        .searchable(text: Bindable(store).query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("在收藏里搜索"))
        .onChange(of: store.query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await store.reload()
            }
        }
        .navigationTitle(AppString("我的收藏"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    folderName = ""
                    folderMessage = nil
                    folderPrompt = .create
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isWorkingOnFolder)
                .accessibilityLabel(AppString("新建收藏夹"))
            }
        }
        .alert(
            folderPromptTitle,
            isPresented: Binding(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } }),
            presenting: folderPrompt
        ) { prompt in
            TextField(AppString("收藏夹名字"), text: $folderName)
            Button(AppString("取消"), role: .cancel) { folderMessage = nil }
            Button(prompt.isCreate ? AppString("创建") : AppString("保存")) { submitFolder(prompt) }
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: { _ in
            Text(folderMessage ?? AppString("最多 16 个字。"))
        }
        .sheet(item: $movingItem) { ref in
            BookmarkFolderChooser(current: ref.item.folderId) { folderID in
                await store.move(ref.item, to: folderID)
            }
        }
        .alert(AppString("备注"), isPresented: Binding(get: { noteItem != nil }, set: { if !$0 { noteItem = nil } }), presenting: noteItem) { ref in
            TextField(AppString("写点什么，只有你自己能看到"), text: $noteText)
            Button(AppString("取消"), role: .cancel) {}
            Button(AppString("保存")) {
                let text = String(noteText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                Task { if let error = await store.setNote(ref.item, text) { ToastCenter.shared.show(error) } }
            }
        } message: { _ in
            Text(AppString("最多 100 个字。"))
        }
        .alert(
            AppString("取消收藏这条内容？"),
            isPresented: Binding(get: { removeItem != nil }, set: { if !$0 { removeItem = nil } }),
            presenting: removeItem
        ) { ref in
            Button(AppString("取消收藏"), role: .destructive) {
                Task { if let error = await store.remove(ref.item) { ToastCenter.shared.show(error) } }
            }
            Button(AppString("保留"), role: .cancel) {}
        }
        .alert(
            AppString("删除收藏夹「\(deleteCandidate?.name ?? "")」？"),
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
            presenting: deleteCandidate
        ) { folder in
            Button(AppString("删除收藏夹"), role: .destructive) {
                Task {
                    if let error = await store.deleteFolder(folder.id) { ToastCenter.shared.show(error.message) }
                }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: { folder in
            Text(AppString("里面的 \(folder.count ?? 0) 条收藏会回到未分类，不会被删除。"))
        }
        .task {
            async let folders: Void = store.loadFolders()
            await store.reload()
            await folders
        }
        .refreshable {
            await store.loadFolders()
            await store.reload()
        }
    }

    private var folderChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                CountChip(title: AppString("全部收藏"), count: store.total, selected: store.folder == nil) {
                    select(folder: nil)
                }
                ForEach(store.folders, id: \.id) { folder in
                    CountChip(title: folder.name, count: folder.count, selected: store.folder == String(folder.id)) {
                        select(folder: String(folder.id))
                    }
                    .contextMenu {
                        Button {
                            folderName = folder.name
                            folderMessage = nil
                            folderPrompt = .rename(folder)
                        } label: {
                            Label(AppString("重命名"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteCandidate = folder
                        } label: {
                            Label(AppString("删除收藏夹"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker(AppString("类型"), selection: Binding(get: { store.kind ?? "" }, set: { value in
                store.kind = value.isEmpty ? nil : value
                Task { await store.reload() }
            })) {
                Text(AppString("全部")).tag("")
                Text(AppString("帖子")).tag("post")
                Text(AppString("评论")).tag("comment")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
            Spacer(minLength: 0)
            Menu {
                Picker(AppString("排序"), selection: Binding(get: { store.sort ?? "" }, set: { value in
                    store.sort = value.isEmpty ? nil : value
                    Task { await store.reload() }
                })) {
                    Text(AppString("最近收藏")).tag("")
                    Text(AppString("最早收藏")).tag("old")
                    Text(AppString("赞同最多")).tag("top")
                }
            } label: {
                Label(sortTitle, systemImage: "arrow.up.arrow.down")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
    }

    private var sortTitle: String {
        switch store.sort {
        case "old": AppString("最早收藏")
        case "top": AppString("赞同最多")
        default: AppString("最近收藏")
        }
    }

    private var folderPromptTitle: String {
        if case .rename = folderPrompt { return AppString("重命名收藏夹") }
        return AppString("新建收藏夹")
    }

    /// Creates or renames; a refusal brings the alert back with the typed
    /// name and the server's reason.
    private func submitFolder(_ prompt: FolderPrompt) {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        isWorkingOnFolder = true
        Task {
            defer { isWorkingOnFolder = false }
            switch prompt {
            case .create:
                switch await store.createFolder(name) {
                case .success(let id):
                    folderMessage = nil
                    select(folder: String(id))
                case .failure(let error):
                    folderMessage = error.message
                    folderPrompt = .create
                }
            case .rename(let folder):
                if let error = await store.renameFolder(folder.id, to: name) {
                    folderMessage = error.message
                    folderPrompt = .rename(folder)
                } else {
                    folderMessage = nil
                }
            }
        }
    }

    private func select(folder: String?) {
        store.folder = folder
        Task { await store.reload() }
    }

    private func savedCard(_ item: NLSaved.Bookmark) -> some View {
        Button {
            app.openTopicPage(id: item.topicId, postNumber: item.postNumber > 1 ? item.postNumber : nil, nodeSlug: item.nodeSlug)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let slug = item.nodeSlug {
                        Circle().fill(nodeAccentColor(NodeCatalog.shared.cachedNode(slug: slug)?.colorHex ?? "007A52")).frame(width: 8, height: 8)
                        Text(NodeCatalog.shared.cachedNode(slug: slug)?.name ?? "n/\(slug)")
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    if let author = item.author {
                        Text("· \(author)")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(item.postNumber > 1 ? AppString("评论") : AppString("帖子"))
                        .font(Theme.body(11, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Theme.chip, in: Capsule())
                }
                .lineLimit(1)
                Text(item.topicTitle ?? "")
                    .font(Theme.body(17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let excerpt = item.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let note = item.note, !note.isEmpty {
                    Label(note, systemImage: "pencil")
                        .font(Theme.body(13))
                        .foregroundStyle(AdminTone.amber.text)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AdminTone.amber.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack {
                    if let at = item.createdAt {
                        Text(AppString("收藏于 \(DiscourseFormat.relative(at))"))
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    if let folderID = item.folderId, let folder = store.folders.first(where: { $0.id == folderID }) {
                        Label(folder.name, systemImage: "folder")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Theme.chip, in: Capsule())
                    }
                    Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - 我的节点

struct MyNodesPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @State private var mine: NLMyNodes?
    @State private var filter: Filter = .all
    @State private var query = ""

    private enum Filter { case all, owned, managed, joined }

    private var joined: [NLMyNodes.Joined] { mine?.joined ?? [] }
    private var owned: [NLMyNodes.Joined] { joined.filter { $0.owner == true } }
    private var managed: [NLMyNodes.Joined] { joined.filter { $0.owner != true && ($0.role == "moderator" || $0.pending != nil) } }
    private var plain: [NLMyNodes.Joined] { joined.filter { $0.owner != true && $0.role != "moderator" && $0.pending == nil } }

    private func matches(_ node: NLMyNodes.Joined) -> Bool {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return term.isEmpty || node.slug.lowercased().contains(term) || (node.name ?? "").lowercased().contains(term)
    }

    private var waiting: [(NLMyNodes.Joined, String)] {
        joined.compactMap { node in
            guard let pending = node.pending else { return nil }
            var parts: [String] = []
            if let n = pending.reports, n > 0 { parts.append(AppString("\(n) 条举报待处理")) }
            if let n = pending.queued, n > 0 { parts.append(AppString("\(n) 个帖子待审核")) }
            if let n = pending.joinRequests, n > 0 { parts.append(AppString("\(n) 个加入申请")) }
            return parts.isEmpty ? nil : (node, parts.joined(separator: " · "))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        CountChip(title: AppString("全部"), count: joined.count, selected: filter == .all) { filter = .all }
                        CountChip(title: AppString("我创建的"), count: owned.count, selected: filter == .owned) { filter = .owned }
                        CountChip(title: AppString("我管理的"), count: managed.count, selected: filter == .managed) { filter = .managed }
                        CountChip(title: AppString("我加入的"), count: plain.count, selected: filter == .joined) { filter = .joined }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .padding(.top, 8)

                if mine == nil {
                    ForEach(["a", "b", "c"], id: \.self) { _ in CardSkeleton(height: 70) }
                } else {
                    if !waiting.isEmpty, filter == .all || filter == .managed || filter == .owned {
                        waitingCard
                    }
                    if filter == .all || filter == .owned { section(AppString("我创建的"), owned.filter(matches)) }
                    if filter == .all || filter == .managed { section(AppString("我管理的"), managed.filter(matches)) }
                    if filter == .all || filter == .joined { section(AppString("我加入的"), plain.filter(matches)) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("在我的节点里搜索"))
        .navigationTitle(AppString("我的节点"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.overlay = .createNode
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppString("创建节点"))
            }
        }
        .task { mine = try? await DiscourseClient().myNodes() }
        .refreshable { mine = try? await DiscourseClient().myNodes() }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(AppString("待你处理"))
                    .font(Theme.body(16, weight: .bold))
                Text(AppString("\(waiting.count) 项"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(waiting, id: \.0.slug) { node, line in
                HStack(spacing: 12) {
                    icon(node)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("n/\(node.slug)").font(Theme.body(15, weight: .semibold))
                        Text(line).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button(AppString("去处理")) {
                        app.pushPage(.reviewQueue(node: node.slug, item: nil))
                    }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
    }

    @ViewBuilder
    private func section(_ title: String, _ nodes: [NLMyNodes.Joined]) -> some View {
        if !nodes.isEmpty {
            HStack(spacing: 6) {
                Text(title).font(Theme.body(18, weight: .bold))
                Text("\(nodes.count)").font(Theme.body(14)).foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.element.slug) { index, node in
                    if index > 0 { Divider().overlay(Theme.divider).padding(.leading, 56) }
                    Button { app.openNode(slug: node.slug) } label: {
                        HStack(spacing: 12) {
                            icon(node)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("n/\(node.slug)")
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text([node.name, node.memberCount.map { AppString("\($0) 成员") }].compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if node.owner == true {
                                roleBadge(AppString("节点主"))
                            } else if node.role == "moderator" {
                                roleBadge(AppString("版主"))
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
        }
    }

    private func roleBadge(_ title: String) -> some View {
        Text(title)
            .font(Theme.body(12, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.accent.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func icon(_ node: NLMyNodes.Joined) -> some View {
        if let cached = NodeCatalog.shared.cachedNode(slug: node.slug) {
            NodeAvatar(node: cached, size: 36, cornerRadius: 10)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(nodeAccentColor(node.color ?? "007A52"))
                .frame(width: 36, height: 36)
                .overlay(Text(String((node.name ?? node.slug).prefix(1))).font(Theme.body(15, weight: .bold)).foregroundStyle(.white))
        }
    }
}

// MARK: - 我的交易

nonisolated struct NLTradeOrders: Decodable, Sendable {
    nonisolated struct Order: Decodable, Sendable, Identifiable {
        let id: Int
        let topicId: Int?
        let title: String
        let tradeKind: String?
        let role: String?
        let buyer: String?
        let seller: String?
        let quantity: Int?
        let unitPriceCents: Int?
        let amountCents: Int?
        let feePercent: Int?
        let status: String
        let todo: Bool?
        let createdAt: String?
    }
    nonisolated struct Summary: Decodable, Sendable {
        let todoTotal: Int?
        let pendingPayoutCents: Int?
    }
    let orders: [Order]
    let nextBefore: Int?
    let summary: Summary?
    let counts: [String: Int]?
}

struct TradesPage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @Environment(BrowserState.self) private var browser
    @State private var tab = "bought"
    @State private var status = ""
    @State private var page: NLTradeOrders?
    @State private var loading = true
    @State private var showsEscrowInfo = false

    private let statuses: [(String, String)] = [
        ("", AppString("全部")), ("todo", AppString("待我处理")), ("pending_payment", AppString("待付款")),
        ("paid", AppString("待发货")), ("shipped", AppString("待收货")), ("dispute", AppString("纠纷")),
        ("completed", AppString("已完成")), ("cancelled", AppString("已取消")),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let payout = page?.summary?.pendingPayoutCents, payout > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppString("待结算")).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
                        Text(TradeCard.yuan(payout)).font(Theme.body(24, weight: .bold))
                    }
                    .padding(14)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
                }
                if let todo = page?.summary?.todoTotal, todo > 0 {
                    Label(AppString("有 \(todo) 笔订单等你处理"), systemImage: "bell")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(AdminTone.orange.text)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AdminTone.orange.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if tab != "disputes" {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(statuses, id: \.0) { key, title in
                                CountChip(title: title, count: nil, selected: status == key) {
                                    status = key
                                    Task { await load() }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
                if loading && page == nil {
                    ForEach(["a", "b"], id: \.self) { _ in CardSkeleton(height: 160) }
                } else if (page?.orders ?? []).isEmpty {
                    EmptyStateView(icon: "arrow.left.arrow.right", message: AppString("这里还没有订单"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    ForEach(page?.orders ?? []) { order in orderCard(order) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .navigationTitle(AppString("我的交易"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            // The escrow explanation, behind a small button rather than at the top.
            // 我买的 / 我卖的 / 纠纷 as a filter; the escrow note is the
            // menu's last item, so the bar keeps one control and the title
            // stays centred.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(AppString("订单"), selection: Binding(
                        get: { tab },
                        set: { key in
                            tab = key
                            status = ""
                            Task { await load() }
                        }
                    )) {
                        ForEach(Self.tabs, id: \.0) { key, title in
                            if let count = page?.counts?[key], count > 0 {
                                Text(AppString("\(title)（\(count) 待处理）")).tag(key)
                            } else {
                                Text(title).tag(key)
                            }
                        }
                    }
                    Divider()
                    Button { showsEscrowInfo = true } label: {
                        Label(AppString("担保交易说明"), systemImage: "info.circle")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.tabs.first { $0.0 == tab }?.1 ?? "")
                            .font(Theme.body(15, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.text)
                    // Another list has orders waiting: the badge isn't lost.
                    .overlay(alignment: .topTrailing) {
                        if otherTabHasTodo {
                            Circle().fill(AdminTone.orange.text).frame(width: 7, height: 7).offset(x: 6, y: -3)
                        }
                    }
                }
                .accessibilityLabel(AppString("订单：\(Self.tabs.first { $0.0 == tab }?.1 ?? "")"))
            }
        }
        .alert(AppString("担保交易"), isPresented: $showsEscrowInfo) {
            Button(AppString("知道了"), role: .cancel) {}
        } message: {
            Text(AppString("买家付款后钱由平台代收，确认收货后扣除手续费记入卖家余额。卖家超时未发货自动退款，买家超时未确认自动结算，有争议可以申请平台介入。"))
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private static let tabs: [(String, String)] = [
        ("bought", AppString("我买的")), ("sold", AppString("我卖的")), ("disputes", AppString("纠纷")),
    ]

    private var otherTabHasTodo: Bool {
        Self.tabs.contains { key, _ in key != tab && (page?.counts?[key] ?? 0) > 0 }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var query = [URLQueryItem(name: "tab", value: tab)]
        if !status.isEmpty { query.append(URLQueryItem(name: "status", value: status)) }
        page = try? await DiscourseClient().get("api/v1/trade-orders", query: query)
    }

    private func orderCard(_ order: NLTradeOrders.Order) -> some View {
        Button {
            if let url = nodelocSiteURL("/trades?order=\(order.id)") {
                LinkRouter.open(url, app: app, browser: browser)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(statusTitle(order.status))
                        .font(Theme.body(12, weight: .bold))
                        .foregroundStyle(AdminTone.amber.text)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(AdminTone.amber.fill, in: Capsule())
                    Text(order.title)
                        .font(Theme.body(16, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if order.todo == true {
                        Text(AppString("待你处理"))
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    Text(AppString("订单 #\(order.id)") + (order.createdAt.map { " · " + DiscourseFormat.relative($0) } ?? ""))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    let other = order.role == "seller" ? order.buyer : order.seller
                    if let other {
                        Text(order.role == "seller" ? AppString("买家 u/\(other)") : AppString("卖家 u/\(other)"))
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppString("数量 × 单价")).font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                            Text("\(order.quantity ?? 1) × \(TradeCard.yuan(order.unitPriceCents ?? 0))").font(Theme.body(15, weight: .bold))
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppString("订单金额")).font(Theme.body(12)).foregroundStyle(Theme.textMuted)
                            Text(TradeCard.yuan(order.amountCents ?? 0)).font(Theme.body(15, weight: .bold))
                        }
                    }
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Spacer()
                    Text(AppString("查看订单"))
                        .font(Theme.body(14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(order.todo == true ? Theme.accent : Theme.divider, lineWidth: order.todo == true ? 1.5 : 1))
        }
        .buttonStyle(.pressable)
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "pending_payment": AppString("待付款")
        case "paid": AppString("待发货")
        case "shipped": AppString("待收货")
        case "completed": AppString("已完成")
        case "cancelled", "closed": AppString("已取消")
        case "disputed": AppString("纠纷中")
        case "resolved": AppString("纠纷已处理")
        default: status
        }
    }
}

// MARK: - 新人指引

nonisolated struct NLOnboarding: Decodable, Sendable {
    nonisolated struct Step: Decodable, Sendable, Identifiable {
        let key: String
        let group: String?
        let title: String?
        let need: Int?
        let count: Int?
        let done: Bool?
        let energy: Int?
        let href: String?
        var id: String { key }
    }
    let state: String?
    let tier: Int?
    let steps: [Step]
    let done: Int?
    let total: Int?
    let energy: Int?
    let daysLeft: Int?
    let waitDays: Int?
}

struct OnboardingGuidePage: View {
    let onClose: () -> Void

    @Environment(AppState.self) private var app
    @Environment(BrowserState.self) private var browser
    @State private var guide: NLOnboarding?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                PageTitle(title: AppString("新人指引"), subtitle: AppString("七步认识 nodeloc，做完就从青铜升到白银。"))
                if let guide {
                    progressCard(guide)
                    let groups = guide.steps.reduce(into: [String]()) { list, step in
                        let group = step.group ?? ""
                        if !list.contains(group) { list.append(group) }
                    }
                    ForEach(groups, id: \.self) { group in
                        if !group.isEmpty {
                            Text(groupTitle(group))
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.top, 4)
                        }
                        ForEach(guide.steps.filter { ($0.group ?? "") == group }) { step in stepCard(step) }
                    }
                } else if failed {
                    EmptyStateView(icon: "sparkles", message: AppString("新人指引暂时打不开"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                } else {
                    ForEach(["a", "b", "c"], id: \.self) { _ in CardSkeleton(height: 90) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            guide = try await DiscourseClient().get("api/v1/me/onboarding")
        } catch {
            failed = guide == nil
        }
    }

    private func groupTitle(_ key: String) -> String {
        switch key {
        case "account": AppString("账号")
        case "community": AppString("认识社区")
        case "participate": AppString("参与")
        default: key
        }
    }

    private func progressCard(_ guide: NLOnboarding) -> some View {
        let done = guide.done ?? guide.steps.filter { $0.done == true }.count
        let total = max(guide.total ?? guide.steps.count, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                TierBadgeIcon(tier: 1)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(AppString("已完成 \(done) / \(total)")).font(Theme.body(15, weight: .bold))
                        Spacer()
                        if total > done {
                            Text(AppString("还差 \(total - done) 步")).font(Theme.body(13)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    ProgressView(value: Double(done), total: Double(total)).tint(Theme.accent)
                }
                TierBadgeIcon(tier: 2)
            }
            Text(AppString("全部完成后，注册满 \(guide.waitDays ?? 3) 天自动升到白银，并获得 \(guide.energy ?? 80) 能量。不限时，可以分几天做。"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepCard(_ step: NLOnboarding.Step) -> some View {
        let isDone = step.done == true
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isDone ? "checkmark" : "circle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isDone ? .white : Theme.textMuted)
                .frame(width: 30, height: 30)
                .background(isDone ? Theme.accentFill : Theme.chip, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title ?? step.key)
                    .font(Theme.body(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let need = step.need, need > 1 {
                    Text(AppString("\(min(step.count ?? 0, need)) / \(need)"))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                if let energy = step.energy, energy > 0 {
                    Label(AppString("+\(energy) 能量"), systemImage: "bolt")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                }
            }
            Spacer(minLength: 6)
            if isDone {
                Text(AppString("已完成")).font(Theme.body(14, weight: .semibold)).foregroundStyle(Theme.accent)
            } else if let href = step.href, let url = nodelocSiteURL(href) {
                Button(AppString("去完成")) { LinkRouter.open(url, app: app, browser: browser) }
                    .font(Theme.body(14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.accentFill, in: Capsule())
                    .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isDone ? Theme.divider : Theme.accent.opacity(0.5), lineWidth: 1))
    }
}

/// The tier mark used on the guide's progress card.
private struct TierBadgeIcon: View {
    let tier: Int
    var body: some View {
        TierIcon(name: nil, number: tier, size: 44)
    }
}

private extension NLSaved.Bookmark {
    func with(folderId: Int?) -> Self {
        .init(id: id, postId: postId, postNumber: postNumber, topicId: topicId, topicTitle: topicTitle, folderId: folderId,
              note: note, excerpt: excerpt, author: author, nodeSlug: nodeSlug, createdAt: createdAt)
    }

    func with(note: String) -> Self {
        .init(id: id, postId: postId, postNumber: postNumber, topicId: topicId, topicTitle: topicTitle, folderId: folderId,
              note: note, excerpt: excerpt, author: author, nodeSlug: nodeSlug, createdAt: createdAt)
    }
}
