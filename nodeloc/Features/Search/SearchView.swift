//
//  SearchView.swift
//  nodeloc
//

import SwiftUI

/// Internal (not file-private): the app-wide selection lives on `AppState`,
/// because the search field in MainView's tab bar writes the query that
/// screen-mode search reads.
enum SearchScope: String, CaseIterable {
    // The design's order (App-iOS-Search): 全部 帖子 节点 用户 标签, then
    // the app's own two.
    case all = "全部"
    case posts = "帖子"
    case nodes = "节点"
    case users = "用户"
    case tags = "标签"
    case apps = "应用"
    case media = "媒体"

    /// The raw values double as identifiers, and an enum's raw value has to be
    /// a compile-time constant — so the words shown to the user come from here
    /// instead.
    var label: String {
        switch self {
        case .all: return AppString("全部")
        case .nodes: return AppString("节点")
        case .posts: return AppString("帖子")
        case .users: return AppString("用户")
        case .tags: return AppString("标签")
        case .apps: return AppString("应用")
        case .media: return AppString("媒体")
        }
    }
}

struct SearchView: View {
    let postTransitionNamespace: Namespace.ID

    var body: some View {
        SearchExperience(
            postTransitionNamespace: postTransitionNamespace,
            mode: .screen
        )
    }
}

struct SearchOverlay: View {
    let postTransitionNamespace: Namespace.ID
    /// Text to open with, e.g. "#slug " when scoped to a node. Defaults to
    /// empty so the existing call sites are unaffected.
    var initialQuery: String = ""
    /// How to close. Nil means "clear `app.overlay`", which is how `MainView`
    /// presents this.
    ///
    /// A page that presents this itself must pass its own dismissal, because
    /// `app.overlay` draws in `MainView` — beneath any full-screen cover. The
    /// node page needs that: it can be inside one.
    var onClose: (() -> Void)?

    var body: some View {
        SearchExperience(
            postTransitionNamespace: postTransitionNamespace,
            mode: .overlay,
            initialQuery: initialQuery,
            onClose: onClose
        )
    }
}

private enum SearchExperienceMode {
    case screen
    case overlay
}

private struct SearchExperience: View {
    @Environment(AppState.self) private var app
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    let postTransitionNamespace: Namespace.ID
    let mode: SearchExperienceMode
    var initialQuery: String = ""
    var onClose: (() -> Void)?

    @State private var store = SearchStore()
    private let history = SearchHistoryStore.shared
    @State private var query = ""
    @State private var showHistory = false
    @State private var selectedScope: SearchScope = .all
    /// The pending debounced search, replaced on every keystroke.
    @State private var searchTask: Task<Void, Never>?
    /// True from a keystroke until its debounced search has answered, so the
    /// "nothing found" state doesn't flash while the request hasn't started.
    @State private var searchPending = false
    @State private var hotSearches = Self.fallbackHotSearches
    @FocusState private var searchFocused: Bool
    @State private var didFocusOnce = false
    @Namespace private var scopeSelectionNamespace

    private var isOverlay: Bool { mode == .overlay }

    /// Whether this screen has to draw its own search field.
    ///
    /// On the phone the field comes from `.searchable` on the tab view, whose
    /// tab bar morphs into it. iPad doesn't get `.searchable` — it would be a
    /// second search affordance beside the search tab already in the top tab
    /// bar — so the tab has to supply the field itself, or it is a results
    /// screen with nothing to type into.
    private var drawsOwnField: Bool { !isOverlay && usesTopTabBar }
    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop

            VStack(spacing: 0) {
                // Screen mode used to get its scope row from the system's
                // `.searchScopes`, which only shows while the search field is
                // *presented* — so it hung off a presentation binding that the
                // system writes too, and went missing whenever the two
                // disagreed. This is the same bar the overlay draws, owned by
                // the app, so it is simply always there.
                if drawsOwnField {
                    searchField
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                if !isOverlay {
                    scopeBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }

                searchContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.bottom, isOverlay ? 0 : 12)

            if isOverlay {
                telegramSearchControls
            }

        }
        .task { await store.loadCategories() }
        .task { await loadHotSearches() }
        .onAppear {
            // Seeding the query here rather than in an init: assigning to the
            // @State is a real change from "", so the onChange below runs the
            // first search. A value baked into the State's initial value would
            // not fire it.
            if !initialQuery.isEmpty, query.isEmpty {
                query = initialQuery
            }
            // Once: coming back from a post opened from the results must not
            // bring the keyboard back up.
            guard isOverlay, !didFocusOnce else { return }
            didFocusOnce = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                searchFocused = true
            }
        }
        // Debounced: the server allows 30 searches a minute per reader, and a
        // request per keystroke spent that in a couple of queries — after
        // which every search came back empty (a 429 reads as no results).
        .onChange(of: query) { _, newValue in
            runSearch(newValue, scope: activeScope, delay: .milliseconds(350))
        }
        // Scopes aren't a filter over one payload — each is answered by a
        // different endpoint — so changing scope refetches.
        .onChange(of: activeScope) { _, newScope in
            runSearch(query, scope: newScope, delay: .zero)
        }
        // Screen mode types into the system field in the tab bar (.searchable
        // in MainView); mirror it into the local query that drives results.
        .onChange(of: app.searchQuery) { _, newValue in
            guard !isOverlay else { return }
            query = newValue
        }
        .sheet(isPresented: $showHistory) {
            SearchHistorySheet { term in
                showHistory = false
                apply(term)
            }
        }
        // The search tab's bar (`MainView` wraps it in a stack) is the same
        // inline, see-through one every other tab has.
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runSearch(_ text: String, scope: SearchScope, delay: Duration) {
        searchTask?.cancel()
        searchPending = true
        searchTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await store.search(text, scope: scope)
            guard !Task.isCancelled else { return }
            searchPending = false
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if isOverlay {
            Theme.bg
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissOverlay() }
        } else {
            Theme.bg
                .ignoresSafeArea()
        }
    }

    private var searchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: isOverlay ? 26 : 12)

                if isSearching {
                    resultsSection
                } else {
                    redditSuggestions
                }
            }
            .padding(.bottom, isOverlay ? 130 : 14)
        }
        .scrollIndicators(.hidden)
        // Telegram-style: dragging the list tracks the keyboard down with the
        // finger instead of leaving it stuck open.
        .scrollDismissesKeyboard(.interactively)
    }

    private var redditSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hidden entirely when there is nothing to show, rather than an
            // empty heading over blank space.
            if !history.entries.isEmpty {
                sectionHeader(title: AppString("最近"), trailing: AppString("历史记录")) {
                    showHistory = true
                }
                .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(history.recent(), id: \.self) { term in
                        Button {
                            apply(term)
                        } label: {
                            RedditSearchRow(
                                icon: "clock",
                                title: term,
                                subtitle: nil,
                                badge: nil,
                                trailingIcon: "xmark",
                                onTrailingTap: { history.remove(term) }
                            )
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.bottom, 24)
            }

            sectionHeader(title: AppString("热门"), trailing: nil)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(hotSearches, id: \.self) { title in
                    Button {
                        apply(title)
                    } label: {
                        RedditSearchRow(
                            icon: "arrow.up.right",
                            title: title,
                            // Not "根据你的兴趣": the list is the same for
                            // everyone.
                            subtitle: nil,
                            badge: nil,
                            trailingIcon: nil
                        )
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Which scope filters the results: the system scope row in screen mode,
    /// the glass capsules in overlay mode.
    private var activeScope: SearchScope {
        isOverlay ? selectedScope : app.searchScope
    }

    private var scopedResultsAreEmpty: Bool {
        switch activeScope {
        case .all:
            return store.results.isEmpty && store.userResults.isEmpty && store.nodeResults.isEmpty
        case .nodes: return store.nodeResults.isEmpty
        case .posts: return store.results.isEmpty
        case .users: return store.userResults.isEmpty
        case .tags: return store.tagResults.isEmpty
        case .apps: return store.appResults.isEmpty
        case .media: return store.mediaResults.isEmpty
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isSearching {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }

            switch activeScope {
            case .all:
                // Discourse's default mixed result: nodes and users first
                // (capped, like the web's grouped search), then the topics.
                if !store.nodeResults.isEmpty {
                    sectionHeader(title: AppString("节点"), trailing: nil)
                    ForEach(store.nodeResults.prefix(3)) { nodeRow($0) }
                }
                if !store.userResults.isEmpty {
                    sectionHeader(title: AppString("用户"), trailing: nil)
                    ForEach(store.userResults.prefix(3)) { userRow($0) }
                }
                if !store.results.isEmpty {
                    postsHeader
                }
                postCards(store.results)
            case .nodes:
                ForEach(store.nodeResults) { nodeRow($0) }
            case .posts:
                if !store.results.isEmpty { postsHeader }
                postCards(store.results)
            case .users:
                ForEach(store.userResults) { userRow($0) }
            case .tags:
                HStack {
                    Spacer()
                    Button(AppString("所有标签")) { app.pushPage(.tags) }
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                ForEach(store.tagResults) { tagRow($0) }
            case .apps:
                ForEach(store.appResults) { appRow($0) }
            case .media:
                postCards(store.mediaResults)
            }

            if !store.isSearching && !searchPending && scopedResultsAreEmpty {
                EmptyStateView(icon: "magnifyingglass", message: AppString("没有找到相关内容"))
                .frame(maxWidth: .infinity)
                .padding(.top, 54)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 帖子, and how they're ordered: 按相关度 or 按时间 (`sort=new`).
    private var postsHeader: some View {
        HStack {
            Text(AppString("帖子"))
                .font(Theme.body(15, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Menu {
                Picker(AppString("排序"), selection: Binding(
                    get: { store.sort ?? "" },
                    set: { value in
                        store.sort = value.isEmpty ? nil : value
                        runSearch(query, scope: activeScope, delay: .zero)
                    }
                )) {
                    Text(AppString("按相关度")).tag("")
                    Text(AppString("按时间")).tag("new")
                }
            } label: {
                Label(store.sort == "new" ? AppString("按时间") : AppString("按相关度"), systemImage: "arrow.up.arrow.down")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func postCards(_ posts: [Post]) -> some View {
        ForEach(posts) { post in
            PostCard(
                post: post,
                postTransitionNamespace: postTransitionNamespace,
                onOpenAuthor: { target in openProfile(target) }
            )
        }
    }

    private func tagRow(_ tag: SearchTagResult) -> some View {
        Button {
            app.pushPage(.tag(tag.name))
        } label: {
            HStack(spacing: 10) {
                TagLookChip(name: tag.name, size: .filter)
                Spacer(minLength: 6)
                Text(AppString("\(tag.topicCount) 个主题"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func userRow(_ user: SearchUserResult) -> some View {
        Button {
            openProfile(UserProfileTarget(
                username: user.username,
                displayName: user.displayName,
                avatarURL: user.avatarURL
            ))
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    url: user.avatarURL,
                    letter: String(user.username.prefix(1)).uppercased(),
                    variant: user.id % 2,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName ?? user.username)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("u/\(user.username)")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func nodeRow(_ node: SearchNodeResult) -> some View {
        Button {
            searchFocused = false
            app.openNode(slug: node.slug)
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    url: node.logoURL,
                    letter: String(node.name.prefix(1)).uppercased(),
                    variant: node.id % 2,
                    size: 34,
                    cornerRadius: Theme.cornerMedium
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("n/\(node.slug)")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if !node.desc.isEmpty {
                        Text(node.desc)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func appRow(_ item: DirectoryApp) -> some View {
        Button {
            app.openApp(item)
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    url: item.logoUrl.flatMap(URL.init(string:)),
                    letter: String(item.name.prefix(1)).uppercased(),
                    variant: item.id % 2,
                    size: 34,
                    cornerRadius: Theme.cornerMedium
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private var telegramSearchControls: some View {
        VStack(spacing: 10) {
            scopeBar

            HStack(spacing: 9) {
                searchField

                Button {
                    dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 50, height: 50)
                        .glassSurface(interactive: true, in: .circle)
                }
                .buttonStyle(.pressable)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Which scope the bar drives, which differs by mode: the overlay keeps its
    /// own choice, while the screen writes the app-wide one that external
    /// scoping (`#slug` from a node page) also sets. `activeScope` reads the
    /// same pair, so the two can't drift.
    private var scopeSelection: Binding<SearchScope> {
        isOverlay
            ? Binding(get: { selectedScope }, set: { selectedScope = $0 })
            : Binding(get: { app.searchScope }, set: { app.searchScope = $0 })
    }

    private var scopeBar: some View {
        let selection = scopeSelection

        return GlassContainer(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    selection.wrappedValue = scope
                                    proxy.scrollTo(scope, anchor: .center)
                                }
                            } label: {
                                // The design's chips: ink when picked.
                                CapsuleChipLabel(title: scope.label, isSelected: selection.wrappedValue == scope, unselectedWeight: .medium)
                            }
                            .buttonStyle(.pressable)
                            .id(scope)
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selection.wrappedValue, anchor: .center)
                }
                .onChange(of: activeScope) { _, newValue in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .glassSurface()
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textFaint)

            TextField("搜索", text: $query)
                .font(Theme.heading(19, weight: .regular))
                .foregroundStyle(Theme.text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                // Recorded on submit rather than in the live-search onChange,
                // which fires per keystroke and would save "v", "vp", "vps".
                .onSubmit { history.record(query) }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 50)
        .glassSurface(interactive: true)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
    }

    private func sectionHeader(
        title: String,
        trailing: String?,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Text(title)
                .font(Theme.body(14, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            Spacer()

            if let trailing {
                Button { action?() } label: {
                    HStack(spacing: 5) {
                        Text(trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    /// Runs a saved or suggested term: fills the field, records it, and closes
    /// the keyboard so the results are visible immediately.
    private func apply(_ term: String) {
        query = term
        // Screen mode's visible field is the system one, so the text has to be
        // mirrored into it. It no longer asks for search to be *presented*:
        // that was only ever to coax the system scope row out, and the scope
        // bar is drawn here now.
        if !isOverlay {
            app.searchQuery = term
        }
        history.record(term)
        searchFocused = false
    }

    /// Through the app's profile route, like every other tab. Profiles used
    /// to open as a layer *inside* this screen, so the tab bar's search field
    /// and its ✕ stayed on top of them — and ✕, which closes the search tab,
    /// took the opened profile away with it. The routed page is a full-screen
    /// page of its own; closing it comes back to the results as they were.
    private func openProfile(_ target: UserProfileTarget) {
        searchFocused = false
        app.openProfile(target)
    }

    private func dismissOverlay() {
        guard isOverlay else { return }
        searchFocused = false
        if let onClose {
            onClose()
            return
        }
        withAnimation(.overlayPush) {
            app.overlay = nil
        }
    }

    /// Shown until (or unless) the hot list's tags answer. The previous list
    /// here was placeholder copy ("WNBA Highlights"…) with nothing to do with
    /// this forum.
    private static let fallbackHotSearches = ["VPS", "优惠", "教程", "白嫖", "折腾", "IPv6", "免费", "面板"]

    /// Suggestions from the tags on the hot list, the way the Android client
    /// does it: tags are short, real and searchable, where titles are whole
    /// sentences. Search logs aren't exposed to readers.
    private func loadHotSearches() async {
        guard let list = try? await DiscourseClient().topicList(feed: .hot) else { return }
        var counts: [String: Int] = [:]
        for topic in list.topicList.topics {
            for name in (topic.tags ?? []).compactMap(\.name) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { counts[trimmed, default: 0] += 1 }
            }
        }
        let ranked = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
            .map(\.key)
        // A near-empty row reads as breakage; the fixed list is better.
        if ranked.count >= 4 { hotSearches = Array(ranked) }
    }
}

/// The full list of saved search terms, with per-row delete and a clear-all.
private struct SearchHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    private let history = SearchHistoryStore.shared
    @State private var confirmingClear = false

    /// Called with the term to search for; the caller closes the sheet.
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.bg)
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .font(Theme.body(15, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { confirmingClear = true }
                        .font(Theme.body(15, weight: .semibold))
                        .disabled(history.entries.isEmpty)
                }
            }
            // Clearing everything can't be undone, so it asks first.
            .alert(
                AppString("清空全部历史记录？"),
                isPresented: $confirmingClear
            ) {
                Button("清空", role: .destructive) { history.clear() }
                Button("取消", role: .cancel) {}
            }
        }
        .standardSheet()
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(history.entries, id: \.self) { term in
                    Button {
                        onSelect(term)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 26)

                            Text(term)
                                .font(Theme.body(15))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Button {
                                history.remove(term)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textMuted)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("删除 \(term)")
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)

                    Divider().padding(.leading, 58)
                }
            }
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        EmptyStateView(icon: "clock", message: AppString("还没有搜索记录"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RedditSearchRow: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let badge: String?
    let trailingIcon: String?
    var avatarText: String?
    var avatarTint: Color = Theme.accent
    /// Set to make the trailing icon its own control, e.g. deleting a history
    /// entry without also running that search.
    var onTrailingTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 15) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(Theme.heading(18, weight: .regular))
                        .foregroundStyle(Theme.text.opacity(0.92))
                        .lineLimit(1)

                    if let badge {
                        Text(badge)
                            .font(Theme.body(12, weight: .bold))
                            .foregroundStyle(Color(light: 0x9A4E05, dark: 0xFFC078))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(light: 0xFFF2D8, dark: 0x3A2A12), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                                    .strokeBorder(Color(light: 0xA85C0D, dark: 0x8A5A1E), lineWidth: 1)
                            }
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingIcon {
                let glyph = Image(systemName: trailingIcon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)

                if let onTrailingTap {
                    // Its own button so deleting an entry doesn't also trigger
                    // the row's search action underneath.
                    Button(action: onTrailingTap) {
                        glyph.contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("删除")
                } else {
                    glyph
                }
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let avatarText {
            Text(avatarText)
                .font(Theme.body(11, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(avatarTint, in: Circle())
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Theme.text.opacity(0.82))
                .frame(width: 32, height: 32)
        } else {
            Color.clear
                .frame(width: 32, height: 32)
        }
    }
}
