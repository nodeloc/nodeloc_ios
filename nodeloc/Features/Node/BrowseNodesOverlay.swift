//
//  BrowseNodesOverlay.swift
//  nodeloc
//
//  节点广场: the node directory — a title, search, section chips, and the
//  headed groups of node cards (为你推荐 / 最受欢迎 / 新节点), a section's
//  nodes, or search results.
//

import SwiftUI

// MARK: - Browse nodes

struct BrowseNodesOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    @State private var store = NodeBrowseStore()
    @State private var query = ""
    /// The chip that's on: nil is 全部, otherwise a section's id.
    @State private var sectionID: Int?
    /// How many cards each list shows so far, keyed by list (显示更多 adds more).
    @State private var shownCounts: [String: Int] = [:]
    /// Only so the toolbar's mark can send the directory back to the top.
    @State private var browseScroll = ScrollPosition()
    /// The joined node whose 退出 is waiting on the confirmation.
    @State private var leaveCandidate: SidebarNodeSummary?
    @State private var collapsedOnce = false
    let showsCloseButton: Bool

    init(showsCloseButton: Bool = true) {
        self.showsCloseButton = showsCloseButton
    }

    /// Cards a group shows before 显示更多, and how many each tap adds; a
    /// section or search list pages by 12 (the design's numbers).
    private let groupStep = 3
    private let listStep = 12

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionChips
                content
            }
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // The system search field, hidden until the directory is pulled down.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: AppString("搜索节点名称或简介"))
        .refreshable {
            await store.load(force: true)
            collapseSearchDrawer()
        }
        .tabBarFollowsScrollDirection()
        .scrollPosition($browseScroll)
        .onChange(of: app.scrollToTopRequests) { _, _ in
            withAnimation(.easeOut(duration: 0.3)) {
                browseScroll.scrollTo(edge: .top)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .toolbar {
            // 节点广场 in the bar's centre, like the other tabs' centre content.
            if !usesTopTabBar {
                ToolbarItem(placement: .principal) {
                    Text(AppString("节点广场"))
                        .font(Theme.body(17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button { closeOverlay(app) } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityLabel(AppString("返回"))
                }
            } else {
                // Root of the nodes tab: no back destination, so the slot
                // holds the sidebar toggle like the home feed does.
                SidebarToolbarItem(sidebarIsPinned: sidebarIsPinned)
            }
            // 新建 (or 登录); search is the pull-down field.
            ToolbarItem(placement: .topBarTrailing) {
                browseTrailingAction
            }
        }
        .tabRootNavigationBar()
        // A tab's root view gets the search drawer open at rest, where a
        // pushed page (草稿箱, 我的收藏) gets it collapsed; no modifier here
        // is the cause. Scrolling the directory by a point collapses it, the
        // same thing UIKit apps do to start with a hidden search bar.
        .onAppear {
            guard !collapsedOnce else { return }
            collapsedOnce = true
            collapseSearchDrawer()
        }
        .onChange(of: query) { old, new in
            if !old.isEmpty, new.isEmpty { collapseSearchDrawer() }
        }
        .task { await store.load() }
        // Before the whole directory is in, a search asks the server.
        .task(id: searchTerm) {
            let term = searchTerm
            guard !term.isEmpty, !store.isComplete else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await store.searchRemote(term)
        }
        // A join or leave on the node page (or another directory) shows here
        // too; this store's own announcements land as no-ops.
        .onReceive(NotificationCenter.default.publisher(for: NodeMembership.didChange)) { note in
            guard let id = note.userInfo?["id"] as? Int, let joined = note.userInfo?["joined"] as? Bool else { return }
            store.apply(id: id, joined: joined)
        }
    }

    /// Guests get 登录 where 新建 would be — creating a node needs an account.
    @ViewBuilder
    private var browseTrailingAction: some View {
        if app.isGuest {
            GuestLoginButton()
        } else {
            Button { createNode() } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel(AppString("创建节点"))
        }
    }

    private func collapseSearchDrawer() {
        Task { @MainActor in
            // After the layout pass that put the drawer there.
            try? await Task.sleep(for: .milliseconds(50))
            browseScroll.scrollTo(y: 1)
        }
    }

    // MARK: Chips

    private var sectionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(AppString("全部"), isOn: sectionID == nil && !isSearching) { pick(nil) }
                ForEach(store.sections) { section in
                    chip(section.name, isOn: sectionID == section.id && !isSearching) { pick(section.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    /// Selected: ink fill, background-coloured text; otherwise an outline.
    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(13, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(isOn ? Theme.bg : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(isOn ? Theme.text : Theme.bg, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(isOn ? Theme.text : Theme.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// A chip clears the search, as on the web square.
    private func pick(_ id: Int?) {
        guard id != sectionID || isSearching else { return }
        withAnimation(.quick) {
            sectionID = id
            query = ""
            shownCounts = [:]
        }
    }

    // MARK: Content

    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !searchTerm.isEmpty }

    @ViewBuilder
    private var content: some View {
        if !store.hasContent && store.isLoading {
            skeleton
        } else if !store.hasContent, let errorText = store.errorText {
            errorState(errorText)
        } else if isSearching {
            searchContent
        } else if let sectionID, let section = store.sections.first(where: { $0.id == sectionID }) {
            let list = store.entries(in: section)
            cardList(
                key: "section-\(section.id)", title: section.name,
                note: AppString("\(list.count) 个节点"), entries: list, step: listStep, isFirst: true
            )
        } else {
            ForEach(Array(store.groups(signedIn: !app.isGuest).enumerated()), id: \.element.id) { index, group in
                cardList(
                    key: group.id, title: group.title, note: group.note,
                    entries: group.entries, step: groupStep, isFirst: index == 0
                )
            }
        }

        if store.hasContent, let errorText = store.errorText, !store.isComplete {
            errorRow(errorText)
                .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let term = searchTerm
        let usesServer = !store.isComplete
        let results = usesServer ? (store.remoteTerm == term ? store.remoteResults : []) : store.localResults(for: term)
        let pending = usesServer && (store.remoteTerm != term || store.isSearchingRemote)
        if pending && results.isEmpty {
            skeleton
        } else if results.isEmpty {
            noMatch(term)
        } else {
            cardList(
                key: "search", title: AppString("搜索结果"),
                note: AppString("\(results.count) 个节点"), entries: results, step: listStep, isFirst: true
            )
        }
    }

    /// A heading, its cards, and 显示更多 while some are still hidden.
    private func cardList(key: String, title: String, note: String, entries: [NodeBrowseStore.Entry], step: Int, isFirst: Bool) -> some View {
        let shown = shownCounts[key] ?? step
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Theme.body(18, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !note.isEmpty {
                    Text(note)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(entries.prefix(shown)) { entry in
                nodeCard(entry)
            }

            if entries.count > shown {
                Button {
                    withAnimation(.quick) { shownCounts[key] = shown + step }
                } label: {
                    Text("显示更多")
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.pressable)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isFirst ? 20 : 28)
    }

    // MARK: Card

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
    }

    private func nodeCard(_ entry: NodeBrowseStore.Entry) -> some View {
        let node = entry.node
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                NodeLetterAvatar(node: node, size: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName(for: node))
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(AppString("n/\(node.slug) · \(memberCount(entry.members)) 成员"))
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                joinButton(for: node)
            }

            // Two lines' room either way, so the cards keep one height.
            Text(description(for: node))
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .lineSpacing(2)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: cardShape)
        .overlay { cardShape.strokeBorder(Theme.hairline, lineWidth: 1) }
        .contentShape(cardShape)
        .onTapGesture { openNode(node) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: AppString("打开节点")) { openNode(node) }
    }

    /// 加入 is the grey fill; 已加入 the outlined chip. 加入 joins on the
    /// spot (guests get the sign-in sheet); 已加入 asks before leaving. A
    /// node's owner can't leave it, so their chip just opens the node.
    private func joinButton(for node: SidebarNodeSummary) -> some View {
        let joined = !app.isGuest && store.isJoined(node)
        let busy = store.togglingJoin.contains(node.id)
        return Button {
            guard DiscourseAuth.shared.isAuthenticated, !app.isGuest else {
                requestLogin(app, .joinNode(name: "n/\(node.slug)", slug: node.slug))
                return
            }
            if joined {
                if node.isCreator { openNode(node) } else { leaveCandidate = node }
            } else {
                Task { await store.toggleJoin(node) }
            }
        } label: {
            ZStack {
                Text(joined ? AppString("已加入") : AppString("加入"))
                    .opacity(busy ? 0 : 1)
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.text)
                }
            }
            .font(Theme.body(13, weight: .bold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 32)
            .background(joined ? Theme.bg : Theme.chip, in: Capsule())
            .overlay {
                Capsule().strokeBorder(joined ? Theme.textFaint : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .disabled(busy)
        .accessibilityLabel(joined ? AppString("退出 \(displayName(for: node))") : AppString("加入 \(displayName(for: node))"))
        // On the button, not the page: iOS 26 anchors the dialog to its
        // source, and hung off the whole scroll view it never appeared but
        // still swallowed the next taps.
        .alert(
            AppString("退出节点？"),
            isPresented: Binding(
                get: { leaveCandidate?.id == node.id },
                set: { if !$0 { leaveCandidate = nil } }
            )
        ) {
            Button(AppString("退出"), role: .destructive) {
                leaveCandidate = nil
                Task { await store.toggleJoin(node) }
            }
            Button(AppString("取消"), role: .cancel) { leaveCandidate = nil }
        } message: {
            Text(AppString("将退出 \(displayName(for: node))，之后可以随时重新加入。"))
        }
    }

    /// 33,400 → "3.3万" / "33K", in the app's language.
    private func memberCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(AppLanguage.resolved.locale))
    }

    private func displayName(for node: SidebarNodeSummary) -> String {
        node.name.isEmpty ? node.slug : node.name
    }

    /// The summary falls back to "n/slug" for a node with no description,
    /// which the meta line already shows.
    private func description(for node: SidebarNodeSummary) -> String {
        node.description == "n/\(node.slug)" ? "" : node.description
    }

    // MARK: States

    /// Placeholder cards shown only on a cold first load (no cache yet).
    private var skeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                cardShape
                    .fill(Theme.surface)
                    .frame(height: 116)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .skeletonPulsing()
        .accessibilityHidden(true)
    }

    private func noMatch(_ term: String) -> some View {
        VStack(spacing: 4) {
            Text(AppString("没有找到“\(term)”"))
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            HStack(spacing: 0) {
                Text("换个关键词，或者")
                Button { createNode() } label: {
                    Text("自己创建一个节点")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Text("。")
            }
            .font(Theme.body(13))
            .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
    }

    /// Nothing to show and the load failed: the reason and 重试.
    private func errorState(_ text: String) -> some View {
        VStack(spacing: 12) {
            Text("节点加载失败")
                .font(Theme.body(16, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button { Task { await store.load(force: true) } } label: {
                Text(AppString("重试"))
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
    }

    /// The full list failed after the first page drew the screen.
    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(Theme.danger)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button { Task { await store.load(force: true) } } label: {
                Text(AppString("重试"))
                    .font(Theme.body(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Theme.chip, in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Actions

    /// Creating a node needs an account; a guest gets the sign-in sheet.
    private func createNode() {
        guard !app.isGuest else {
            requestLogin(app)
            return
        }
        withAnimation(.overlayPush) {
            app.overlay = .createNode
        }
    }

    /// Through the app's one node route (`AppState.openNode`), the same as
    /// the sidebar, feed labels and post chips, so a node looks and behaves
    /// the same wherever it was opened from.
    private func openNode(_ node: SidebarNodeSummary) {
        app.openNode(slug: node.slug)
    }
}

// MARK: - Node avatar (design letter circle)

/// The design's node mark: the node's logo in a circle, else its first letter
/// in white on a solid circle of the node's colour (节点广场 cards, the node
/// page's header and its compact bar pill).
struct NodeLetterAvatar: View {
    let node: SidebarNodeSummary
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let logoURL = node.logoURL {
                CachedRemoteImage(url: logoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    letter
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var letter: some View {
        Text(Self.initial(for: node))
            .font(Theme.body(size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(nodeAccentColor(node.colorHex), in: Circle())
    }

    /// The name's first character ("独立开发" → 独, "AI" → A), else the slug's.
    static func initial(for node: SidebarNodeSummary) -> String {
        let source = node.name.trimmingCharacters(in: .whitespaces).isEmpty ? node.slug : node.name
        return source.first.map { String($0).uppercased() } ?? "#"
    }
}
