//
//  RoutedPageStack.swift
//  nodeloc
//
//  Profiles, nodes, posts, custom feeds, apps and group inboxes opened from
//  anywhere, as one navigation stack in
//  one full-screen cover. Each page pushes on top of the last; ‹ (or ✕ on a
//  post) goes back exactly one step, and closing the bottom page closes the
//  cover. See `AppState.pageStack` for why this replaced separate covers.
//
//  Profiles and nodes use the system navigation bar: the native back button
//  once pushed, their own ‹ on the bottom page (which closes the cover). The
//  post reader keeps its own floating chrome, so the bar is hidden there.
//

import SwiftUI

struct RoutedPageStack: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: Binding(
            get: { Array(app.pageStack.dropFirst()) },
            set: { tail in
                // Back swipe / pop: keep the root, take the new tail.
                if let root = app.pageStack.first {
                    app.pageStack = [root] + tail
                }
            }
        )) {
            Group {
                if let root = app.pageStack.first {
                    page(root)
                }
            }
            .navigationDestination(for: RoutedPage.self) { page($0) }
        }
        // Nothing in here should bring up a keyboard by itself, and one that
        // does (a reply field) goes away by dragging the content.
        .scrollDismissesKeyboard(.interactively)
        // Back down to the clear base (‹, or the edge swipe): once the pop has
        // played out over the page underneath, take the cover away.
        .onChange(of: app.pageStack.count) { _, count in
            guard count == 1, case .base = app.pageStack.first?.kind else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard app.pageStack.count == 1, case .base = app.pageStack.first?.kind else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { app.pageStack.removeAll() }
            }
        }
    }

    /// Every page carries a title for the back button's long-press menu,
    /// which lists the pages underneath. Pages that draw their own centre
    /// (a capsule, a hidden title) keep it — the centre view hides the plain
    /// title — and a page's own `.navigationTitle` still wins.
    private func page(_ page: RoutedPage) -> some View {
        pageContent(page).navigationTitle(backTitle(page.kind))
    }

    private func backTitle(_ kind: RoutedPage.Kind) -> String {
        switch kind {
        case .base:
            switch app.tab {
            case .home: return AppString("首页")
            case .nodes: return AppString("节点")
            case .chat: return AppString("消息")
            case .profile: return AppString("我的")
            case .search: return AppString("搜索")
            }
        case .profile(let target): return target.displayName?.isEmpty == false ? target.displayName! : "u/\(target.username)"
        case .node(let node): return node.name.isEmpty ? "n/\(node.slug)" : node.name
        case .post(let post): return post.title.isEmpty ? AppString("帖子") : String(post.title.prefix(24))
        case .customFeed(let target): return target.name ?? AppString("信息流")
        case .appsDirectory: return AppString("小游戏和应用")
        case .app(let slug, let preloaded): return preloaded?.name ?? slug
        case .groupInbox(let group): return group
        case .feed(let feed): return feed.label
        case .reputation: return AppString("声望")
        case .upgrade: return AppString("升级进度")
        case .leaderboard: return AppString("财富榜")
        case .energy: return AppString("能量")
        case .invite: return AppString("邀请好友")
        case .reviewQueue: return AppString("审核队列")
        case .accountStatus: return AppString("账号状态")
        case .moderationDashboard: return AppString("管理台")
        case .drafts: return AppString("草稿箱")
        case .tags: return AppString("所有标签")
        case .tag(let name): return "#\(name)"
        case .saved: return AppString("我的收藏")
        case .myNodes: return AppString("我的节点")
        case .trades: return AppString("我的交易")
        case .onboardingGuide: return AppString("新人指引")
        case .nodeAdmin(_, let name): return AppString("\(name) 管理")
        case .history: return AppString("浏览记录")
        case .settings: return AppString("设置")
        case .settingsPreference(let group): return group.title
        case .settingsAccount(let account):
            switch account {
            case .profile: return AppString("个人资料")
            case .associatedAccounts: return AppString("关联账户")
            case .security: return AppString("安全性")
            case .pushNotifications: return AppString("推送通知")
            case .postSource: return AppString("发帖来源")
            case .blockedUsers: return AppString("屏蔽的用户")
            case .deleteAccount: return AppString("注销账号")
            }
        }
    }

    @ViewBuilder
    private func pageContent(_ page: RoutedPage) -> some View {
        // With the clear base at the bottom every real page is pushed; a stack
        // without one (none today) would make its first page the root.
        let navigation: PageNavigation = page == app.pageStack.first ? .stackRoot : .pushed
        switch page.kind {
        case .base:
            // Transparent: the screen underneath shows through it while a
            // page is pushed on top or popped away.
            Color.clear
                .toolbar(.hidden, for: .navigationBar)
                .allowsHitTesting(false)
        case .profile(let target):
            PublicProfileOverlay(target: target, navigation: navigation) { pop(page) }
        case .node(let node):
            NodeDetailOverlay(node: node, navigation: navigation) { pop(page) }
        case .post(let post):
            PostDetailOverlay(
                onClose: { pop(page) },
                post: post
            )
            .environment(\.mediaAutoplayEnabled, true)
        case .customFeed(let target):
            CustomFeedView(
                target: target,
                onOpenPost: { app.openPostPage($0) },
                onOpenNode: { app.pushPage(.node($0)) },
                onDeleted: { pop(page) },
                onClose: { pop(page) },
                navigation: navigation
            )
        case .appsDirectory:
            AppsDirectoryOverlay(navigation: navigation) { pop(page) }
        case .app(let slug, let preloaded):
            AppDetailOverlay(slug: slug, preloaded: preloaded, navigation: navigation) { pop(page) }
        case .groupInbox(let group):
            GroupInboxPage(group: group, navigation: navigation) { pop(page) }
        case .feed(let feed):
            HomeFeedPage(feed: feed, navigation: navigation) { pop(page) }
        case .reputation:
            ReputationPage(navigation: navigation) { pop(page) }
        case .upgrade:
            UpgradePage(navigation: navigation) { pop(page) }
        case .leaderboard:
            LeaderboardPage(navigation: navigation) { pop(page) }
        case .energy:
            EnergyPage(navigation: navigation) { pop(page) }
        case .invite:
            InvitePage(navigation: navigation) { pop(page) }
        case .reviewQueue(let node, let item):
            ReviewQueuePage(scope: node.map { .node($0) } ?? .site, focusItem: item) { pop(page) }
        case .accountStatus:
            AccountStatusPage { pop(page) }
        case .moderationDashboard(let node):
            ModerationDashboardPage(scope: node.map { .node($0) } ?? .site) { pop(page) }
        case .drafts:
            DraftsPage { pop(page) }
        case .tags:
            AllTagsPage { pop(page) }
        case .tag(let name):
            TagPage(name: name) { pop(page) }
        case .saved:
            SavedPage { pop(page) }
        case .myNodes:
            MyNodesPage { pop(page) }
        case .trades:
            TradesPage { pop(page) }
        case .onboardingGuide:
            OnboardingGuidePage { pop(page) }
        case .nodeAdmin(let slug, let name):
            NodeAdminPage(slug: slug, nodeName: name) { pop(page) }
        case .history:
            BrowsingHistoryPage { pop(page) }
        case .settings:
            SettingsOverlay { pop(page) }
        case .settingsPreference(let group):
            PreferencePage(group: group) { pop(page) }
        case .settingsAccount(let account):
            SettingsOverlay.accountPage(account) { pop(page) }
        }
    }

    /// Removes this page and everything above it.
    private func pop(_ page: RoutedPage) {
        guard let index = app.pageStack.firstIndex(of: page) else { return }
        app.pageStack.removeSubrange(index...)
    }
}
