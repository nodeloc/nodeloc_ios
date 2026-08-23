//
//  SearchView.swift
//  nodeloc
//

import SwiftUI

/// Internal (not file-private): the system search field lives in MainView's
/// tab bar, so its `.searchScopes` needs this type too.
enum SearchScope: String, CaseIterable {
    case all = "全部"
    case nodes = "节点"
    case posts = "帖子"
    case users = "用户"
    case apps = "应用"
    case media = "媒体"
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

    var body: some View {
        SearchExperience(
            postTransitionNamespace: postTransitionNamespace,
            mode: .overlay,
            initialQuery: initialQuery
        )
    }
}

private enum SearchExperienceMode {
    case screen
    case overlay
}

private struct SearchExperience: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    let mode: SearchExperienceMode
    var initialQuery: String = ""

    @State private var store = SearchStore()
    private let history = SearchHistoryStore.shared
    @State private var query = ""
    @State private var showHistory = false
    @State private var selectedScope: SearchScope = .all
    @State private var selectedProfile: UserProfileTarget?
    @FocusState private var searchFocused: Bool
    @Namespace private var scopeSelectionNamespace

    private var isOverlay: Bool { mode == .overlay }
    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop

            searchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.bottom, isOverlay ? 0 : 12)

            if isOverlay {
                telegramSearchControls
            }

            if let selectedProfile {
                PublicProfileOverlay(target: selectedProfile) {
                    withAnimation(.overlayPush) {
                        self.selectedProfile = nil
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(30)
            }
        }
        .task { await store.loadCategories() }
        .onAppear {
            // Seeding the query here rather than in an init: assigning to the
            // @State is a real change from "", so the onChange below runs the
            // first search. A value baked into the State's initial value would
            // not fire it.
            if !initialQuery.isEmpty, query.isEmpty {
                query = initialQuery
            }
            guard isOverlay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                searchFocused = true
            }
        }
        .onChange(of: query) { _, newValue in
            Task { await store.search(newValue) }
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
                sectionHeader(title: "最近", trailing: "历史记录") {
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 24)
            }

            sectionHeader(title: "热门", trailing: nil)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Self.hotSearches, id: \.self) { title in
                    Button {
                        apply(title)
                    } label: {
                        RedditSearchRow(
                            icon: "arrow.up.right",
                            title: title,
                            subtitle: "根据你的兴趣",
                            badge: nil,
                            trailingIcon: nil
                        )
                    }
                    .buttonStyle(.plain)
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

    /// Topics that carry media, for the 媒体 scope.
    private var mediaResults: [Post] {
        store.results.filter { !$0.media.isEmpty || $0.videoURL != nil }
    }

    private var scopedResultsAreEmpty: Bool {
        switch activeScope {
        case .all:
            return store.results.isEmpty && store.userResults.isEmpty && store.nodeResults.isEmpty
        case .nodes: return store.nodeResults.isEmpty
        case .posts: return store.results.isEmpty
        case .users: return store.userResults.isEmpty
        case .apps: return store.appResults.isEmpty
        case .media: return mediaResults.isEmpty
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
                    sectionHeader(title: "节点", trailing: nil)
                    ForEach(store.nodeResults.prefix(3)) { nodeRow($0) }
                }
                if !store.userResults.isEmpty {
                    sectionHeader(title: "用户", trailing: nil)
                    ForEach(store.userResults.prefix(3)) { userRow($0) }
                }
                if !store.results.isEmpty, !store.nodeResults.isEmpty || !store.userResults.isEmpty {
                    sectionHeader(title: "帖子", trailing: nil)
                }
                postCards(store.results)
            case .nodes:
                ForEach(store.nodeResults) { nodeRow($0) }
            case .posts:
                postCards(store.results)
            case .users:
                ForEach(store.userResults) { userRow($0) }
            case .apps:
                ForEach(store.appResults) { appRow($0) }
            case .media:
                postCards(mediaResults)
            }

            if !store.isSearching && scopedResultsAreEmpty {
                EmptyStateView(icon: "magnifyingglass", message: "没有找到相关内容")
                .frame(maxWidth: .infinity)
                .padding(.top, 54)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func postCards(_ posts: [Post]) -> some View {
        ForEach(posts) { post in
            PostCard(
                post: post,
                postTransitionNamespace: postTransitionNamespace,
                onOpenAuthor: { target in
                    withAnimation(.panelSlide) {
                        selectedProfile = target
                    }
                }
            )
        }
    }

    private func userRow(_ user: SearchUserResult) -> some View {
        Button {
            withAnimation(.panelSlide) {
                selectedProfile = UserProfileTarget(
                    username: user.username,
                    displayName: user.displayName,
                    avatarURL: user.avatarURL
                )
            }
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
                        .foregroundStyle(Theme.muted(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nodeRow(_ node: SearchNodeResult) -> some View {
        Button {
            app.openNode(slug: node.slug)
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    url: node.logoURL,
                    letter: String(node.name.prefix(1)).uppercased(),
                    variant: node.id % 2,
                    size: 34,
                    cornerRadius: 10
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("n/\(node.slug)")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if !node.desc.isEmpty {
                        Text(node.desc)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appRow(_ item: DirectoryApp) -> some View {
        Button {
            app.selectedApp = item
            withAnimation(.overlayPush) {
                app.overlay = .appDetail
            }
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    url: item.logoUrl.flatMap(URL.init(string:)),
                    letter: String(item.name.prefix(1)).uppercased(),
                    variant: item.id % 2,
                    size: 34,
                    cornerRadius: 10
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var scopeBar: some View {
        GlassEffectContainer(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    selectedScope = scope
                                    proxy.scrollTo(scope, anchor: .center)
                                }
                            } label: {
                                Text(scope.rawValue)
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(selectedScope == scope ? Theme.text : Theme.text.opacity(0.84))
                                    .padding(.horizontal, 15)
                                    .frame(height: 38)
                                    .background {
                                        if selectedScope == scope {
                                            Capsule()
                                                .fill(Theme.neutral400.opacity(0.62))
                                                .matchedGeometryEffect(id: "scope-selection", in: scopeSelectionNamespace)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(scope)
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selectedScope, anchor: .center)
                }
                .onChange(of: selectedScope) { _, newValue in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .glassEffect(.regular, in: Capsule())
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.muted(0.45))

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
                        .foregroundStyle(Theme.muted(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 50)
        .glassEffect(.regular.interactive(), in: Capsule())
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
                .foregroundStyle(Theme.muted(0.58))

            Spacer()

            if let trailing {
                Button { action?() } label: {
                    HStack(spacing: 5) {
                        Text(trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.58))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Runs a saved or suggested term: fills the field, records it, and closes
    /// the keyboard so the results are visible immediately.
    private func apply(_ term: String) {
        query = term
        // Screen mode's visible field is the system one: sync the text and ask
        // MainView to present search, or the scope row stays hidden.
        if !isOverlay {
            app.searchQuery = term
            app.searchActivationRequested = true
        }
        history.record(term)
        searchFocused = false
    }

    private func dismissOverlay() {
        guard isOverlay else { return }
        searchFocused = false
        withAnimation(.overlayPush) {
            app.overlay = nil
        }
    }

    private static let hotSearches = [
        "GitHub Outage",
        "WNBA Highlights",
        "Fairphone Gen 6+ US Launch",
        "August 2026 Visa Bulletin"
    ]
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
            .confirmationDialog(
                "清空全部历史记录？",
                isPresented: $confirmingClear,
                titleVisibility: .visible
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
                                .foregroundStyle(Theme.muted(0.5))
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
                                    .foregroundStyle(Theme.muted(0.5))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除 \(term)")
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 58)
                }
            }
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        EmptyStateView(icon: "clock", message: "还没有搜索记录")
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
                            .foregroundStyle(Color(hex: 0x9A4E05))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(hex: 0xFFF2D8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(hex: 0xA85C0D), lineWidth: 1)
                            }
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(13, weight: .regular))
                        .foregroundStyle(Theme.muted(0.58))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailingIcon {
                let glyph = Image(systemName: trailingIcon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.muted(0.58))
                    .frame(width: 28, height: 28)

                if let onTrailingTap {
                    // Its own button so deleting an entry doesn't also trigger
                    // the row's search action underneath.
                    Button(action: onTrailingTap) {
                        glyph.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
