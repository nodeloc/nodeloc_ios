//
//  NodeDetailOverlay.swift
//  nodeloc
//
//  A single node: banner, membership, and its topic list.
//

import SwiftUI

// MARK: - Node detail

/// A single node: banner header, membership, and its topic list in one of three
/// reading modes (compact / expand / card).
struct NodeDetailOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let node: SidebarNodeSummary
    /// Decides the ‹ and whether this page brings its own navigation stack.
    var navigation: PageNavigation = .standalone
    let onClose: () -> Void

    @State private var store = NodeDetailStore()
    /// The node's tag chips and the list a picked tag shows.
    @State private var tagFilter = NodeTagFilter()
    /// Scroll-driven bar state, kept out of the page body (see
    /// `BannerScrollChrome`); flips inside one spring so the bar moves as one.
    @State private var chrome = BannerScrollChrome(revealStart: 16, revealLength: 30, animatesFlip: true)
    /// The chip row has scrolled up under the bar, so the pinned copy shows.
    @State private var filterPinned = false
    /// Shared and persisted, so the choice survives leaving the node and relaunching.
    private let readingMode = NodeReadingModeStore.shared
    @State private var descriptionExpanded = false
    @State private var showAbout = false
    @State private var showsReviewQueue = false
    @State private var showsModerationDashboard = false
    @State private var showsNodeAdmin = false
    /// Presented here, not through `app.overlay`: this page can itself be
    /// inside a full-screen cover (deep link, media viewer), and an app-level
    /// overlay would render underneath it — the button looked dead.
    @State private var showAuth = false
    /// Media opened straight from a card, without entering the post.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    @State private var viewerVideo: PostVideo?
    /// The post whose media is open, for the viewer's chrome and actions.
    @State private var viewerMediaPost: Post?

    /// Writing a topic in this node, presented from here rather than through
    /// `app.overlay`. Going through `app.overlay = .compose` put the composer
    /// behind this page's cover: it took keyboard focus, so the keyboard rose
    /// over a node page that looked untouched.
    @State private var isComposing = false
    /// Node-scoped search, presented here rather than through `app.overlay`.
    ///
    /// Same reason as `isComposing`: this page can itself be inside a
    /// full-screen cover, and `app.overlay` draws in `MainView` — underneath
    /// that cover. Setting it opened a search screen nobody could see.
    @State private var isSearching = false
    @Namespace private var readerNamespace
    @State private var sidebarSwipeSuppressionToken = UUID()

    /// About the navigation bar's height; the banner runs under it.
    private let headerRowHeight: CGFloat = 56
    /// Banner below the header row; the safe-area inset is added on top
    /// (design: 156pt in all, 54 + 56 of it status bar and buttons).
    private let bannerHeight: CGFloat = 46
    private let avatarSize: CGFloat = 60
    /// Named space of the page, for knowing when the chip row reaches the bar.
    private static let pageSpace = "node-page"
    /// Anchor for the scroll-to-top the node capsule performs.
    private let topAnchor = "node-top"

    var body: some View {
        page.inPageNavigation(navigation)
    }

    private var page: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                // Everything scrolls together: banner, node info, sort bar, list.
                ScrollView {
                    VStack(spacing: 0) {
                        banner
                            .id(topAnchor)
                        nodeSummary
                        blockedNote
                        filterRow
                            .onGeometryChange(for: Bool.self) { proxy in
                                proxy.frame(in: .named(Self.pageSpace)).minY
                                    < UIApplication.topSafeAreaInset + headerRowHeight
                            } action: { pinned in
                                if pinned != filterPinned { filterPinned = pinned }
                            }
                        if tagFilter.selected == nil {
                            pinsSection
                        }
                        topicList
                            .padding(.bottom, 40)
                    }
                    // Root of the width chain. Without this the VStack sizes to its
                    // widest descendant and the ScrollView adopts that, so a single
                    // long title or description shifts the entire page sideways.
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    if tagFilter.selected != nil {
                        await tagFilter.reload(sort: store.sort)
                    } else {
                        await store.refresh()
                    }
                }
                .tabBarFollowsScrollDirection()
                // Raw, not clamped: a negative offset is the pull that
                // stretches the banner. The title reveal clamps its own use.
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, newValue in
                    chrome.update(offset: newValue)
                }

                // The chip row, stuck under the bar once the page has
                // scrolled it there (App-iOS-Node2).
                // No strip behind it: each chip floats on its own glass, like
                // the bar's capsules above, and the rows pass underneath.
                if filterPinned {
                    filterRowContent(onGlass: true)
                        .padding(.top, UIApplication.topSafeAreaInset + headerRowHeight + 4)
                        .zIndex(1)
                }

            }
            .coordinateSpace(.named(Self.pageSpace))
            // Inside the reader's closure: the node title scrolls to the top.
            .toolbar { toolbarContent(scrollProxy: proxy) }
        }
        .bannerPageNavigationBar(bannerIsUnderBar: chrome.bannerIsUnderBar)
        .onDisappear {
            app.setSidebarSwipeSuppressed(false, for: sidebarSwipeSuppressionToken)
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .task(id: node.id) {
            // 最近访问 in the sidebar is kept on the device.
            RecentNodes.record(node.slug)
            BrowsingHistory.shared.record(HistoryEntry(
                kind: .node, topicID: nil, title: node.name, nodeSlug: node.slug,
                nodeName: node.name, author: nil, viewedAt: Date()
            ))
            // The web's node page opens on 热门, and so does the design.
            if store.slug.isEmpty { store.sort = .hot }
            async let tags: Void = tagFilter.loadTags(slug: node.slug)
            takePendingTag()
            await store.load(node: node)
            await tags
        }
        // A tag under a post's title, tapped in the reader above this page.
        .onChange(of: app.pendingNodeTag) { takePendingTag() }
        .fullScreenCover(isPresented: $showAuth) {
            AuthFlowOverlay(onDismiss: { showAuth = false })
        }
        // The composer, presented from here rather than through `app.overlay`
        // — see `isComposing`.
        // Drawn in this page rather than as a cover: a post opened from the
        // results is pushed onto the page stack, and a cover would sit on top
        // of it. In the page, the reader goes over the results and ‹ comes
        // back to them as they were.
        .overlay {
            if isSearching {
                SearchOverlay(
                    postTransitionNamespace: readerNamespace,
                    initialQuery: app.searchInitialQuery,
                    onClose: { withAnimation(.easeOut(duration: 0.2)) { isSearching = false } }
                )
                .background(Theme.bg.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .toolbar(isSearching ? .hidden : .automatic, for: .navigationBar)
        .fullScreenCover(isPresented: $isComposing) {
            ComposeOverlay(onClose: { isComposing = false })
                .appPresentationHost(app: app)
        }
        .sheet(isPresented: $showAbout) { aboutSheet }
        // A node's own queue, for its owner and moderators. The site-wide one
        // lives in settings and covers everything.
        .sheet(isPresented: $showsNodeAdmin) {
            NodeAdminPage(slug: store.slug, nodeName: store.name) { showsNodeAdmin = false }
        }
        .sheet(isPresented: $showsModerationDashboard) {
            ModerationDashboardPage(scope: .node(store.slug)) { showsModerationDashboard = false }
        }
        .sheet(isPresented: $showsReviewQueue) {
            ReviewQueuePage(scope: .node(store.slug)) { showsReviewQueue = false }
        }
        // Card media opens its viewer here, over the list, so closing returns
        // to the same scroll position rather than to a post.
        // Both viewers get the same chrome; the node is already known here.
        .postImageFullScreen(
            images: $viewerImages,
            selection: $viewerIndex,
            presentation: viewerMediaPost.map { PostVideoPresentation(post: $0, node: node) },
            onComment: { if let post = viewerMediaPost { open(post) } }
        )
        .postVideoFullScreen(
            video: $viewerVideo,
            presentation: viewerMediaPost.map { PostVideoPresentation(post: $0, node: node) },
            onComment: { if let post = viewerMediaPost { open(post) } }
        )
    }

    /// Opens a card's media directly — video full screen, images in the viewer.
    private func openMedia(for post: Post, at index: Int = 0) {
        viewerMediaPost = post
        if let videoURL = post.videoURL {
            viewerVideo = PostVideo(src: videoURL.absoluteString, posterSrc: (post.videoPosterURL ?? post.imageURL)?.absoluteString)
            return
        }
        let images = post.media.map {
            PostImage(src: ($0.originalURL ?? $0.url).absoluteString, width: $0.width, height: $0.height)
        }
        guard !images.isEmpty else {
            // No media to show; fall back to opening the topic.
            open(post)
            return
        }
        viewerImages = images
        viewerIndex = min(max(index, 0), images.count - 1)
    }

    /// 帖子排序 as the system pull-down: a picker of the orderings, each with
    /// its icon, and the system's check on the current one.
    @ViewBuilder
    private var sortMenuContent: some View {
        Picker(AppString("帖子排序"), selection: Binding(
            get: { store.sort },
            set: { option in Task { await select(sort: option) } }
        )) {
            ForEach(Self.sheetSorts.filter { store.availableSorts.contains($0) }) { option in
                Label(Self.sortLabel(option), systemImage: Self.sortIcon(option)).tag(option)
            }
        }
    }

    /// The design's five orderings. 评论最多 has no API ordering, so 新鲜
    /// (by posting time, which the API has) takes the last row.
    private static let sheetSorts: [NodeSort] = [.hot, .latest, .featured, .rising, .fresh]

    /// The design's names: 精华 rather than the enum's 推荐.
    private static func sortLabel(_ sort: NodeSort) -> String {
        switch sort {
        case .hot, .top: AppString("热门")
        case .latest: AppString("最新")
        case .featured: AppString("精华")
        case .rising: AppString("上升中")
        case .fresh: AppString("新鲜")
        case .new: AppString("新")
        }
    }

    private static func sortIcon(_ sort: NodeSort) -> String {
        switch sort {
        case .featured: "star"
        default: sort.icon
        }
    }

    /// One ordering for the whole page: the node's list, and a picked tag's.
    private func select(sort: NodeSort) async {
        async let list: Void = store.select(sort: sort)
        if tagFilter.selected != nil {
            await tagFilter.reload(sort: sort)
        }
        await list
    }

    /// Mirrors the web plugin's about panel: identity, description, the three
    /// counts, and the moderator list.
    private var aboutSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        NodeLetterAvatar(node: node, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("n/\(store.slug)")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                            Text(store.name)
                                .font(Theme.heading(18, weight: .bold))
                                .foregroundStyle(Theme.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !store.descriptionText.isEmpty {
                        Text(store.descriptionText)
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.text.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 0) {
                        aboutStat(store.memberCount, AppString("成员"))
                        aboutStat(store.topicCount, AppString("主题"))
                        aboutStat(store.postCount, AppString("帖子"))
                    }

                    if !store.rules.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppString("规则"))
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                            ForEach(Array(store.rules.enumerated()), id: \.offset) { index, rule in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(Theme.body(13, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                        .monospacedDigit()
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(rule.title)
                                            .font(Theme.body(14, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                        if let detail = rule.description, !detail.isEmpty {
                                            Text(detail)
                                                .font(Theme.body(13))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }

                    if !store.moderators.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("版主")
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)

                            ForEach(store.moderators) { moderator in
                                HStack(spacing: 10) {
                                    RemoteAvatar(
                                        url: moderator.avatarTemplate
                                            .flatMap { DiscourseClient().avatarURL(template: $0, size: 96) },
                                        letter: String(moderator.username.prefix(1)).uppercased(),
                                        variant: abs(moderator.username.hashValue),
                                        size: 34
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        if let name = moderator.name, !name.isEmpty {
                                            Text(name)
                                                .font(Theme.body(14, weight: .semibold))
                                                .foregroundStyle(Theme.text)
                                        }
                                        Text("u/\(moderator.username)")
                                            .font(Theme.body(12))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg)
            .navigationTitle(AppString("节点介绍和规则"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet()
    }

    private func aboutStat(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map(Self.groupedCount) ?? "—")
                .font(Theme.heading(17, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    nonisolated private static func groupedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    // MARK: Header chrome

    /// Over the banner (App-iOS-Node): ‹, then one capsule of 搜索 / 发帖 /
    /// 分享 / ⋯. Scrolled (App-iOS-Node2): the node's n/slug capsule fades and
    /// slides into the bar's centre, and for the node's managers 分享 becomes
    /// 管理.
    ///
    /// Every item exists in both states and only its content changes, inside
    /// the one spring `BannerScrollChrome` flips `bannerIsUnderBar` in: the
    /// centre capsule follows the scroll (`BarNodeCapsule`), and the third
    /// slot of the right capsule cross-fades in a fixed-width frame — so the system never
    /// inserts or removes an item, and the right capsule keeps its width.
    @ToolbarContentBuilder
    private func toolbarContent(scrollProxy: ScrollViewProxy) -> some ToolbarContent {
        let overBanner = chrome.bannerIsUnderBar
        if navigation.drawsBackButton {
            ToolbarItem(placement: .topBarLeading) {
                // A bare glyph, so the system draws its usual round glass
                // button. `toolIcon`'s 40×36 frame stretched it into an oval.
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(Theme.text)
                }
                .accessibilityLabel(AppString("返回"))
            }
        }
        if #available(iOS 26.0, *) {
            // Keeps the back button a glass circle of its own: without the
            // spacer the system can fold the next item into its glass.
            ToolbarSpacer(.fixed, placement: .topBarLeading)
        }
        ToolbarItem(placement: .principal) {
            centreCapsule(scrollProxy: scrollProxy)
        }
        .sharedBackgroundVisibilityHiddenIfAvailable()
        // One item holding the icons, rather than a group of items: the
        // system re-lays a group out without animating when an item comes or
        // goes, so the capsule snapped narrower. Inside one item the HStack's
        // width change rides the same spring as the centre capsule.
        ToolbarItem(placement: .topBarTrailing) {
            trailingTools(overBanner: overBanner)
        }
    }

    /// n/slug in a glass capsule of its own, in the bar's centre: hidden
    /// over the banner and revealed as the header scrolls away. Tapping it
    /// goes back to the top.
    private func centreCapsule(scrollProxy: ScrollViewProxy) -> some View {
        BarNodeCapsule(
            slug: store.slug.isEmpty ? node.slug : store.slug,
            chrome: chrome,
            accessibilityLabel: AppString("回到顶部")
        ) {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy.scrollTo(topAnchor, anchor: .top)
            }
        }
    }

    /// 搜索 / 发帖 / 分享 / ⋯ over the banner. Scrolled: 搜索 / 发帖 / 管理 for
    /// the node's managers (the ⋯ menu's items are on the 管理 page, or back
    /// at the top), 搜索 / 发帖 / ⋯ for everyone else (分享 is the menu's
    /// first item).
    private func trailingTools(overBanner: Bool) -> some View {
        let managesScrolled = !overBanner && store.canModerate
        return HStack(spacing: 2) {
            Button(action: startNodeSearch) { toolIcon("magnifyingglass", overBanner: overBanner) }
                .accessibilityLabel(AppString("在本节点内搜索"))

            // Guests get 登录 where compose would be — posting needs an
            // account anyway. Same destination as every other 登录 entry point.
            if app.isGuest {
                Button { requestLogin(app, .generic) } label: {
                    toolIcon("person.crop.circle.badge.checkmark", overBanner: overBanner)
                }
                .accessibilityLabel(AppString("登录"))
            } else {
                Button(action: startCompose) { toolIcon("plus", overBanner: overBanner) }
                    .accessibilityLabel(AppString("在本节点发帖"))
            }

            if overBanner {
                ShareLink(item: nodeShareURL) {
                    toolIcon("square.and.arrow.up", overBanner: overBanner)
                }
                .accessibilityLabel(AppString("分享"))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }

            if managesScrolled {
                Button { app.pushPage(.nodeAdmin(slug: store.slug, name: store.name)) } label: {
                    Text(AppString("管理"))
                        .font(Theme.body(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                        .frame(minWidth: 40, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                Menu {
                    nodeMenuContent
                } label: {
                    toolIcon("ellipsis", overBanner: overBanner)
                }
                .accessibilityLabel(AppString("更多"))
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    /// A glyph in the bar's tool group, in the page's text colour whether or
    /// not the banner is under the bar: the bar's glass follows the app's
    /// appearance, so ink on light glass in light mode and light on dark glass
    /// in dark mode — the same as the profile pages. (White over the banner
    /// sat on light glass in light mode and couldn't be read.)
    private func toolIcon(_ systemImage: String, overBanner: Bool) -> some View {
        BarGlyph(systemName: systemImage)
    }

    /// The node's public page, for sharing.
    private var nodeShareURL: URL {
        DiscourseConfig.baseURL.appending(path: "n/\(store.slug.isEmpty ? node.slug : store.slug)")
    }

    @ViewBuilder
    private var nodeMenuContent: some View {
        ShareLink(item: nodeShareURL) {
            Label(AppString("分享"), systemImage: "square.and.arrow.up")
        }

        Button {
            showAbout = true
        } label: {
            Label(AppString("节点介绍和规则"), systemImage: "info.circle")
        }

        // A manager's header shows 管理 where 加入 / 已加入 would be, so
        // leaving (for a moderator who isn't the owner) lives here.
        if store.canModerate && store.isJoined && !node.isCreator {
            Button(role: .destructive) {
                Task { await store.toggleJoin() }
            } label: {
                Label(AppString("退出节点"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }

        // Only the node's owner and moderators have a queue to open.
        if store.canModerate {
            Button {
                app.pushPage(.nodeAdmin(slug: store.slug, name: store.name))
            } label: {
                Label(AppString("节点管理"), systemImage: "slider.horizontal.3")
            }
            Button {
                app.pushPage(.moderationDashboard(node: store.slug))
            } label: {
                Label(AppString("管理台"), systemImage: "gauge.with.dots.needle.33percent")
            }
            Button {
                app.pushPage(.reviewQueue(node: store.slug, item: nil))
            } label: {
                Label(AppString("审核队列"), systemImage: "tray.full")
            }
        }

        // The level the server reports is only this user's when signed in;
        // anonymously it's the site default, so offering it would be a lie.
        if DiscourseAuth.shared.isAuthenticated {
            Divider()

            Menu {
                Picker("通知级别", selection: Binding(
                    get: { store.notificationLevel },
                    set: { level in Task { await store.setNotificationLevel(level) } }
                )) {
                    ForEach(NodeNotificationLevel.menuOrder) { level in
                        Label(level.label, systemImage: level.icon).tag(level)
                    }
                }
            } label: {
                Label("通知级别", systemImage: store.notificationLevel.icon)
            }
        }
    }

    /// Quotes a topic into a new post, presented from here for the same reason
    /// as `startCompose`.
    private func startRepost(of post: Post) {
        app.composePrefillTitle = post.title
        app.composeRepostTopic = AppState.RepostTopic(
            id: post.id,
            title: post.title,
            url: DiscourseConfig.baseURL.appending(path: "t/\(post.id)"),
            node: post.node,
            author: post.authorUsername,
            excerpt: post.excerpt.isEmpty ? nil : post.excerpt,
            imageURL: post.imageURL
        )
        isComposing = true
    }

    /// Opens the composer with this node already chosen.
    private func startCompose() {
        app.composePreselectedNode = node
        isComposing = true
    }

    /// Opens search scoped to this node. `#slug` is Discourse's own category
    /// filter; the trailing space leaves the caret ready for the search terms.
    private func startNodeSearch() {
        let slug = store.slug.isEmpty ? node.slug : store.slug
        app.searchInitialQuery = "#\(slug) "
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
    }

    /// Beside the name: 管理 (the dark pill) for the node's owner and
    /// moderators, otherwise 加入 (green) / 已加入 (outlined). 40pt tall.
    @ViewBuilder
    private var headerAction: some View {
        if store.canModerate {
            Button { app.pushPage(.nodeAdmin(slug: store.slug, name: store.name)) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 15, weight: .semibold))
                    Text(AppString("管理"))
                        .font(Theme.body(15, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.bg)
                .padding(.leading, 13)
                .padding(.trailing, 16)
                .frame(height: 40)
                .background(Theme.text, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(AppString("节点管理"))
        } else {
            Button {
                // Joining needs an account. Without this a guest's tap flipped
                // the button, failed, and flipped back with nothing said.
                guard DiscourseAuth.shared.isAuthenticated else {
                    requestLogin(app, .joinNode(name: "n/\(store.slug)", slug: store.slug))
                    return
                }
                Task { await store.toggleJoin() }
            } label: {
                CapsuleActionLabel(
                    title: store.isJoined ? AppString("已加入") : AppString("加入"),
                    style: store.isJoined ? .outlined : .filled,
                    height: 40,
                    isBusy: store.isTogglingJoin
                )
            }
            .buttonStyle(.pressable)
            .disabled(store.isTogglingJoin)
        }
    }

    // MARK: Banner + summary

    /// Read through `BannerPullView` so a pull re-renders the banner alone.
    private var banner: some View {
        BannerPullView(chrome: chrome) { pull in
            banner(pull: pull)
        }
    }

    // Not a @ViewBuilder: it needs a `let` before returning a single Group,
    // which the builder disallows.
    private func banner(pull: CGFloat) -> some View {
        // Runs to the very top, behind the status bar and floating buttons,
        // and grows with a pull past the top (pinned there, no gap above).
        let height = headerRowHeight + bannerHeight + UIApplication.topSafeAreaInset + pull
        let imageURL = (colorScheme == .dark ? store.bannerDarkURL : nil) ?? store.bannerURL ?? store.backgroundURL
        return Group {
            if let imageURL {
                CachedRemoteImage(url: imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    bannerFallback
                }
            } else {
                bannerFallback
            }
        }
        // `filledBanner` sizes an empty box first and hangs the image in an
        // overlay. Applying `.scaledToFill()` directly and then clipping does
        // NOT contain it: fill scales to cover the height, so a wide image
        // reports a frame far wider than the screen and the ScrollView adopts
        // that — clipping only trims the drawing, not the frame.
        .filledBanner(height: height, clip: Rectangle())
        // A light scrim at the top keeps the status bar and the glass header
        // buttons readable over a bright banner image.
        .overlay(alignment: .top) {
            if imageURL != nil {
                LinearGradient(
                    colors: [Color.black.opacity(0.28), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIApplication.topSafeAreaInset + headerRowHeight + 16)
                .allowsHitTesting(false)
            }
        }
        .offset(y: -pull)
        .padding(.bottom, -pull)
    }

    /// The design's green banner: a 120° gradient lit from the top right and
    /// shaded at the bottom left, with two faint rings.
    private var bannerFallback: some View {
        LinearGradient(
            colors: [Color(hex: 0x0A5A3E), Color(hex: 0x007A52)],
            startPoint: UnitPoint(x: 0.07, y: 0.25),
            endPoint: UnitPoint(x: 0.93, y: 0.75)
        )
        .overlay {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RadialGradient(
                        colors: [Color(hex: 0x35B98B), Color(hex: 0x35B98B).opacity(0)],
                        center: UnitPoint(x: 0.88, y: -0.1),
                        startRadius: 0,
                        endRadius: size.width * 0.68
                    )
                    RadialGradient(
                        colors: [Color(hex: 0x05382A), Color(hex: 0x05382A).opacity(0)],
                        center: UnitPoint(x: 0, y: 1.1),
                        startRadius: 0,
                        endRadius: size.width * 0.56
                    )
                    Circle()
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 22)
                        .frame(width: 210, height: 210)
                        .position(x: size.width + 40 - 105, y: 34 + 105)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 14)
                        .frame(width: 150, height: 150)
                        .position(x: size.width - 70 - 75, y: -70 + 75)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Under the banner (App-iOS-Node): the avatar, n/slug over members and
    /// online, the 管理 / 加入 pill; the description (two lines, tap for
    /// all); 节点介绍和规则; then a hairline.
    private var nodeSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                NodeLetterAvatar(node: node, size: avatarSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.slug.isEmpty ? store.name : "n/\(store.slug)")
                        .font(Theme.heading(24, weight: .heavy))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    statsLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                headerAction
            }
            .padding(.top, 14)

            if !store.descriptionText.isEmpty {
                Text(store.descriptionText)
                    .font(Theme.body(15))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .lineLimit(descriptionExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    // Measured 455pt unbounded on a 393pt screen for
                    // n/chit-chat: without a width budget it drags the whole
                    // page sideways.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Tapping the text expands it, in place of a separate link.
                    .onTapGesture {
                        withAnimation(.quick) { descriptionExpanded.toggle() }
                    }
                    .padding(.top, 10)
            }

            // 节点介绍和规则 opens from the ⋯ menu.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    /// "12.4万 成员 · ● 1,206 在线", 14pt muted; the online half only when
    /// someone is (the count is signed-in readers of the last 15 minutes).
    @ViewBuilder
    private var statsLine: some View {
        let members = store.memberCount
        let online = store.onlineCount.flatMap { $0 > 0 ? $0 : nil }
        if members != nil || online != nil {
            HStack(spacing: 6) {
                if let members {
                    Text(AppString("\(compact(members)) 成员"))
                }
                if members != nil, online != nil {
                    Text("·").accessibilityHidden(true)
                }
                if let online {
                    Circle()
                        .fill(Color(hex: 0x1FA36F))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(AppString("\(Self.groupedCount(online)) 在线"))
                }
            }
            .font(Theme.body(14))
            .foregroundStyle(Theme.textMuted)
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// Under the header while the reader has the node on 免打扰 — the v1
    /// backend's node block — saying what that hides, with 取消屏蔽
    /// (`DELETE /api/v1/nodes/{slug}/block`), as Android and the web do.
    @ViewBuilder
    private var blockedNote: some View {
        if store.isBlocked {
            VStack(alignment: .trailing, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 1)
                    Text(AppString("你已屏蔽 n/\(store.slug)。它的帖子不会出现在首页、热门和推荐里，也不会再收到通知。直接打开节点仍可浏览。"))
                        .font(Theme.body(13))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Theme.danger)

                Button {
                    Task { await store.unblock() }
                } label: {
                    Text(AppString("取消屏蔽"))
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.danger, lineWidth: 1))
                        .opacity(store.isUnblocking ? 0.5 : 1)
                }
                .buttonStyle(.pressable)
                .disabled(store.isUnblocking)
            }
            .padding(12)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    /// 124,000 → "12.4万" / "124K", in the app's language.
    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(AppLanguage.resolved.locale))
    }

    // MARK: Tag chips

    /// The sort control (the current ordering's icon and name, ⌄, opening
    /// the system pull-down), then 全部 and every tag the node has topics
    /// under, each in its own look (colour, style, icon), as 28pt chips.
    /// Scrolls sideways.
    private var filterRow: some View { filterRowContent(onGlass: false) }

    /// `onGlass`: the copy pinned under the bar, where every chip gets its own
    /// glass capsule so it reads over the rows scrolling beneath.
    private func filterRowContent(onGlass: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu { sortMenuContent } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Self.sortIcon(store.sort))
                            .font(.system(size: 12, weight: .semibold))
                        Text(Self.sortLabel(store.sort))
                            .font(Theme.body(13, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(onGlass ? Color.clear : Theme.chip, in: Capsule())
                    .background { if onGlass { Color.clear.glassSurface(tint: FloatingHeader.glassTint, in: .capsule) } }
                    .contentShape(Capsule())
                }
                .sensoryFeedback(.selection, trigger: store.sort)
                .accessibilityLabel(AppString("帖子排序"))
                .accessibilityValue(Self.sortLabel(store.sort))

                Button { pick(tag: nil) } label: {
                    TagLookChip(name: AppString("全部"), size: .filter, selected: tagFilter.selected == nil, lookOverride: .plain, onGlass: onGlass)
                }
                .buttonStyle(.pressable)
                ForEach(tagFilter.tags, id: \.self) { tag in
                    Button { pick(tag: tag) } label: {
                        TagLookChip(name: tag, size: .filter, selected: tagFilter.selected == tag, onGlass: onGlass)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    /// Picks the tag the reader asked for, if it was meant for this node.
    private func takePendingTag() {
        guard let request = app.pendingNodeTag, request.slug == node.slug else { return }
        app.pendingNodeTag = nil
        pick(tag: request.tag)
    }

    private func pick(tag: String?) {
        guard tag != tagFilter.selected else { return }
        Task { await tagFilter.select(tag, slug: store.slug.isEmpty ? node.slug : store.slug, sort: store.sort) }
    }

    // MARK: Pins

    /// 节点置顶: a heading with a fold chevron, then the pins as 164×116
    /// cards in a sideways strip. Nothing at all without pins.
    @ViewBuilder
    private var pinsSection: some View {
        let pins = store.visiblePinnedPosts
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.quick) { store.setPinsCollapsed(!store.pinsCollapsed) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pin")
                            .font(.system(size: 16, weight: .semibold))
                        Text(AppString("节点置顶"))
                            .font(Theme.body(16, weight: .bold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .rotationEffect(.degrees(store.pinsCollapsed ? -90 : 0))
                    }
                    .foregroundStyle(Theme.text)
                    .frame(height: 36)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppString("节点置顶"))
                .accessibilityValue(store.pinsCollapsed ? AppString("已收起") : AppString("已展开"))

                if !store.pinsCollapsed {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(pins.enumerated()), id: \.element.id) { index, post in
                                NodePinCard(post: post, index: index) { open(post) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    // MARK: Topics

    /// The rows on screen: the node's list, or a picked tag's.
    private var listPosts: [Post] {
        tagFilter.selected == nil ? store.visiblePosts : tagFilter.visiblePosts
    }

    private var listIsLoading: Bool {
        tagFilter.selected == nil ? store.isLoading : tagFilter.isLoading
    }

    private var listIsLoadingMore: Bool {
        tagFilter.selected == nil ? store.isLoadingMore : tagFilter.isLoadingMore
    }

    private var listErrorText: String? {
        tagFilter.selected == nil ? store.errorText : tagFilter.errorText
    }

    private func loadMoreTopics() async {
        if tagFilter.selected == nil {
            await store.loadMore()
        } else {
            await tagFilter.loadMore()
        }
    }

    private func reloadTopics() async {
        if tagFilter.selected == nil {
            await store.refresh()
        } else {
            await tagFilter.reload(sort: store.sort)
        }
    }

    @ViewBuilder
    private var topicList: some View {
        let posts = listPosts
        if listIsLoading && posts.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in FeedTopicRowSkeleton() }
            }
            .skeletonPulsing()
            .accessibilityHidden(true)
        } else if posts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                Text(listErrorText ?? AppString("还没有主题"))
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                // A failed load is not an empty node: offer the retry
                // rather than leaving only the pull to find.
                if listErrorText != nil {
                    Button {
                        Task { await reloadTopics() }
                    } label: {
                        Text(AppString("重试"))
                            .font(Theme.body(13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            LazyVStack(spacing: 0) {
                // A pin is lifted out of the list into 节点置顶, as the web
                // and Android do, rather than shown twice on one screen.
                let pinnedIDs = tagFilter.selected == nil ? Set(store.visiblePinnedPosts.map(\.id)) : []
                ForEach(posts.filter { !pinnedIDs.contains($0.id) }) { post in
                    NodeTopicRow(
                        post: post,
                        // `homeMode`: the same choice as everywhere, but with
                        // none made it is the design's row (title beside a
                        // thumbnail) rather than the old compact fallback.
                        mode: readingMode.homeMode,
                        style: .nodePage,
                        onTap: { open(post) },
                        onMediaTap: { openMedia(for: post) },
                        onMediaTapAt: { openMedia(for: post, at: $0) },
                        // Locally, not through `app.overlay`: this page can be
                        // inside a full-screen cover, where that draws behind
                        // it. Same route as the 发帖 button — see `isComposing`.
                        onRepost: { startRepost(of: post) }
                    )
                }

                if listIsLoadingMore {
                    ProgressView().tint(Theme.accent).padding(.vertical, 20)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { Task { await loadMoreTopics() } }
                }
            }
            // A LazyVStack sizes to its widest child, and the ScrollView then
            // adopts that. Bounding the stack itself gives every row a real
            // width to lay out within, instead of each row's content deciding.
            .frame(maxWidth: .infinity)
        }
    }

    private func open(_ post: Post) {
        // A pushed page on the page stack, like every reader.
        app.openReader(post)
    }

}

/// One topic, rendered per reading mode. Internal (not private): the home feed
/// renders its compact/expand modes with the same rows so the two lists match.
extension Post {
    /// The slug behind a row's "n/…" label, for opening the node. Nil for
    /// `FeedMapper`'s "n/nodeloc" placeholder, which names no real node.
    var linkedNodeSlug: String? {
        guard node.hasPrefix("n/") else { return nil }
        let slug = String(node.dropFirst(2))
        return slug.isEmpty || slug == "nodeloc" ? nil : slug
    }
}

struct NodeTopicRow: View {
    @Environment(AppState.self) private var app
    /// `.nodePage` draws the node page's rows: author line, title, excerpt,
    /// then a vote pill, a comment capsule and a round ⋯. Compact rows stay
    /// compact. The home feed and others keep `.standard`.
    enum Style { case standard, nodePage }

    let post: Post
    let mode: NodeReadingMode
    var style: Style = .standard
    let onTap: () -> Void
    /// Card mode only: media opens straight into its own viewer, skipping the
    /// post. Nil elsewhere, where a tap anywhere should open the topic.
    var onMediaTap: (() -> Void)?
    /// A page of the multi-image carousel, by index.
    var onMediaTapAt: ((Int) -> Void)?
    @State private var mediaPage = 0
    /// Opens the composer quoting this topic. Injected for the same reason as
    /// `onMediaTap`: where this row is hosted decides how a composer can be
    /// presented at all. Nil simply drops 转发 from the menu.
    var onRepost: (() -> Void)?

    /// The ⋯ menu — 举报 and 屏蔽作者 among the rest. Every list needs it, not
    /// just the home feed's card mode: reporting and blocking have to be
    /// reachable from wherever topics are read (guideline 1.2).
    @State private var showsMoreSheet = false

    /// Seeded to a full-width estimate so the first variant pick is already the
    /// right size; the geometry reader refines it. Starting at 0 would pick the
    /// smallest variant, then re-fetch a bigger one once measured.
    @State private var mediaWidth: CGFloat = 362

    @Environment(\.displayScale) private var displayScale

    /// Fixed size of the small square thumbnail in expand rows.
    private static let expandThumbSide: CGFloat = 78

    /// Card media takes the image's own shape, clamped 16:9 … 4:5.
    private var cardMediaHeight: CGFloat {
        let first = post.media.first
        return Theme.FeedMedia.height(
            forWidth: max(mediaWidth, 1),
            mediaWidth: first?.width,
            mediaHeight: first?.height
        )
    }

    var body: some View {
        Group {
            // None of these is a Button. A nested Button inside a Button doesn't
            // reliably take precedence, which is what left the row's own vote
            // arrows and comment count inert — the card mode had already been
            // fixed this way, and the other two had the same problem.
            if style == .nodePage && mode != .compact {
                nodePageRow
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else {
            switch mode {
            case .compact:
                // The 紧凑 style (design App-iOS-FeedCompact): text only.
                CompactTopicRow(post: post, onTap: onTap)
            case .expand:
                // The design's feed row (App-iOS-Feed): node line, title beside
                // a 96×72 thumbnail, a bare vote / replies / 转发 / 分享 bar.
                FeedTopicRowContent(
                    post: post,
                    linksNode: style == .standard,
                    onTap: onTap,
                    onMore: { showsMoreSheet = true },
                    onRepost: onRepost
                )
                .onTapGesture(perform: onTap)
            case .card:
                cardRow
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
            }
        }
        // Backstop for the whole row. A ScrollView adopts its widest child as
        // the content width, so one row that reports an oversized minimum drags
        // every sibling out with it.
        .clampedToWidth()
        .sheet(isPresented: $showsMoreSheet) {
            TopicMoreSheet(post: post, onRepost: onRepost)
        }
    }

    /// Discourse-mobile style: one dense line per topic with a reply count.
    private var compactRow: some View {
        HStack(spacing: 10) {
            RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(post.title)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(post.node)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textMuted)
                        .contentShape(Rectangle())
                        // Opens the node rather than the post — except on the
                        // node's own page, where it would just open itself.
                        .onTapGesture {
                            guard style == .standard, let slug = post.linkedNodeSlug else { onTap(); return }
                            app.openNode(slug: slug)
                        }
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(post.time)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textFaint)
                }
            }

            Spacer(minLength: 8)

            Text("\(post.comments)")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(post.comments > 0 ? Theme.accent : Theme.textFaint)
                .frame(minWidth: 26, alignment: .trailing)

            moreButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
        }
    }

    /// Reddit "card": title, excerpt and large edge-to-edge media.
    /// Reddit "card": title, excerpt and large edge-to-edge media.
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(post.title)
                .font(Theme.heading(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !post.tags.isEmpty {
                tagBadges
            }

            if let videoURL = post.videoURL {
                FeedVideoTile(url: videoURL, posterURL: post.videoPosterURL ?? post.imageURL, duration: post.videoDuration, knownAspect: post.videoAspect, onTap: onMediaTap)
            } else if post.media.count > 1 {
                FeedMediaCarousel(items: post.media, selection: $mediaPage) { onMediaTapAt?(mediaPage) }
            } else if let media = post.media.first {
                // Reddit-style: the card takes the image's own shape rather
                // than a fixed height, so portrait photos aren't letterboxed
                // and panoramas aren't cropped to a sliver. A full-width
                // variant keeps it crisp without pulling the original.
                CachedRemoteImage(url: media.bestURL(forWidth: max(mediaWidth, 1), scale: displayScale)) { image in
                    image.resizable()
                } placeholder: {
                    Theme.neutral300
                }
                .filledBanner(
                    height: cardMediaHeight,
                    clip: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                )
                // Opens the image viewer rather than the post.
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                .onTapGesture { onMediaTap?() }
            } else if !post.excerpt.isEmpty {
                Text(post.excerpt)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.72))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            actions
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Inside the horizontal padding, so this is the media's own width.
            proxy.size.width - Theme.pagePadding * 2
        } action: { width in
            mediaWidth = width
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: Node page style

    /// The node page's row (App-iOS-Node): the author line — 22pt avatar,
    /// u/name, time, ⋯ — then the feed row's 17pt title and tag beside a
    /// 96×72 thumbnail (展开) or above the full-width media (卡片), and the
    /// feed's bare vote / replies / 转发 / 分享 bar. The node line the home
    /// feed shows would only repeat the page's own node.
    private var nodePageRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            nodePageHeader

            HStack(alignment: .top, spacing: 12) {
                FeedRowTitle(post: post)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if mode == .expand, FeedRowThumbnail.hasThumbnail(post) {
                    FeedRowThumbnail(post: post)
                        .contentShape(Rectangle())
                        .onTapGesture { (onMediaTap ?? onTap)() }
                }
            }
            .padding(.top, 4)

            if mode == .card {
                Group {
                    if let videoURL = post.videoURL {
                        FeedVideoTile(url: videoURL, posterURL: post.videoPosterURL ?? post.imageURL, duration: post.videoDuration, knownAspect: post.videoAspect, onTap: onMediaTap)
                    } else if post.media.count > 1 {
                        FeedMediaCarousel(items: post.media, selection: $mediaPage) { onMediaTapAt?(mediaPage) }
                    } else if let media = post.media.first {
                        CachedRemoteImage(url: media.bestURL(forWidth: max(mediaWidth, 1), scale: displayScale)) { image in
                            image.resizable()
                        } placeholder: {
                            Theme.neutral300
                        }
                        .filledBanner(
                            height: cardMediaHeight,
                            clip: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
                        .onTapGesture { onMediaTap?() }
                    }
                }
                .padding(.top, 8)
            }

            FeedRowActions(post: post, onComments: onTap, onRepost: onRepost)
                .padding(.top, 2)

            if let reports = post.reportCount, reports > 0 {
                FeedModStrip(reportCount: reports, onOpen: onTap)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Inside the horizontal padding, so this is the media's own width.
            proxy.size.width - 32
        } action: { width in
            mediaWidth = width
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
    }

    /// 22pt avatar, u/name (13 semibold ink), "· time" (13 muted), the pin
    /// and state badges, ⋯ at the trailing edge. 24pt tall.
    private var nodePageHeader: some View {
        HStack(spacing: 7) {
            RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 22)
                .accessibilityHidden(true)
            Text("u/\(post.authorUsername ?? post.authorName ?? post.node)")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Text("· \(post.time)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .fixedSize()
            if post.pinned || app.isPinned(post) {
                Label(post.pinnedGlobally ? AppString("全站置顶") : AppString("置顶"), systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Theme.pinnedCard, in: Capsule())
                    .fixedSize()
            }
            TopicStateBadges(isSolved: post.isSolved, isHidden: post.isHidden)
            Spacer(minLength: 0)
            Button {
                showsMoreSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableIcon)
            .accessibilityLabel(AppString("更多"))
        }
        .frame(height: 24)
    }

    /// Deliberately a `Button` inside a row that uses `onTapGesture` rather
    /// than being a Button itself — the same arrangement that lets the vote
    /// arrows work. See the note on `body`.
    private var moreButton: some View {
        Button {
            showsMoreSheet = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableIcon)
    }

    /// Topic tags, each in its own look (colour, style, icon), as the web.
    private var tagBadges: some View {
        HStack(spacing: 4) {
            ForEach(post.tags.prefix(3), id: \.self) { tag in
                TagLookChip(name: tag, size: .row)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        .clampedToWidth()
    }

    private var header: some View {
        HStack(spacing: 7) {
            RemoteAvatar(url: post.avatarURL, letter: post.avatarLetter, variant: post.variant, size: 24)
            Text(post.authorUsername ?? post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                // `lineLimit` alone still reports the full string as the view's
                // minimum width; this is what lets a long username shrink.
                .layoutPriority(-1)
            Text("· \(post.time)")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textFaint)
                .fixedSize()
            if post.pinned {
                Label(post.pinnedGlobally ? AppString("全站置顶") : AppString("置顶"), systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }
            TopicStateBadges(isSolved: post.isSolved, isHidden: post.isHidden, reportCount: post.reportCount)
            Spacer(minLength: 0)
            moreButton
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            // Votable where discourse-vote covers the node, a plain stat where
            // it doesn't — the score already accounts for downvotes, so showing
            // it beside a bare up arrow would have been misleading.
            if let score = app.voteScore(for: post) {
                VoteControl(
                    score: score,
                    direction: app.voteDirection(for: post),
                    canVoteDown: post.canVoteDown,
                    compact: true
                ) { direction, reaction in
                    app.castVote(direction, on: post, reaction: reaction)
                }
            } else {
                Label("\(post.baseVotes)", systemImage: "arrow.up")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            // Tapping the count opens the topic — the row's own destination,
            // and where a reader would go to read or write a reply.
            Button(action: onTap) {
                Label("\(post.comments)", systemImage: "bubble.right")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pin card

/// One of 节点置顶's cards: 164×116, 16pt corners, the title in white over
/// the topic's image (or a tinted gradient), and 置顶 at the bottom.
private struct NodePinCard: View {
    let post: Post
    let index: Int
    let onOpen: () -> Void

    @Environment(\.displayScale) private var displayScale

    /// The design's three card tints, taken in turn.
    private static let tints: [(Color, Color)] = [
        (Color(hex: 0x0E6B4A), Color(hex: 0x35B98B)),
        (Color(hex: 0x0B5F73), Color(hex: 0x4FB3C8)),
        (Color(hex: 0x8A4B00), Color(hex: 0xE0A04A)),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                background
                // Darker at both ends so the title and the label read on any image.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x0B1F18).opacity(0.5), location: 0),
                        .init(color: Color(hex: 0x0B1F18).opacity(0.12), location: 0.58),
                        .init(color: Color(hex: 0x0B1F18).opacity(0.5), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(post.title)
                        .font(Theme.body(15, weight: .bold))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // No 置顶 badge: the section's own heading says so.
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .frame(width: 164, height: 116)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(AppString("置顶：\(post.title)"))
    }

    @ViewBuilder
    private var background: some View {
        let tint = Self.tints[index % Self.tints.count]
        let gradient = LinearGradient(colors: [tint.0, tint.1], startPoint: .topLeading, endPoint: .bottomTrailing)
        if let url = post.media.first?.bestURL(forWidth: 164, scale: displayScale) ?? post.imageURL {
            CachedRemoteImage(url: url, maxPointSize: 240) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                gradient
            }
            .frame(width: 164, height: 116)
            .clipped()
        } else {
            gradient
        }
    }
}

// MARK: - Tag filter

/// The node's tag chips and the list one of them shows. The chips are the
/// node's own tags with topics, most used first (`GET /api/v1/nodes/{slug}/tags`,
/// as the web's node page picks them); a picked tag lists
/// `GET /api/v1/topics?node=…&tag=…` in the page's ordering.
@MainActor
@Observable
final class NodeTagFilter {
    private struct TagRow: Decodable {
        let name: String
        let topicCount: Int?
        let own: Bool?
        let color: String?
        let style: String?
        let icon: String?
    }

    private struct TagList: Decodable {
        let tags: [TagRow]
    }

    @ObservationIgnored private let client = DiscourseClient()

    /// The chips after 全部.
    private(set) var tags: [String] = []
    /// The picked chip; nil is 全部 (the node's own list).
    private(set) var selected: String?
    private(set) var posts: [Post] = []
    var visiblePosts: [Post] { BlockedUsersStore.shared.visible(posts) }
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorText: String?

    @ObservationIgnored private var slug = ""
    @ObservationIgnored private var sort: NodeSort = .hot
    /// The next page's cursor or offset; nil once the list has ended.
    @ObservationIgnored private var next: URLQueryItem?
    /// Bumped on each new list, so an answer for an old one is dropped.
    @ObservationIgnored private var generation = 0

    func loadTags(slug: String) async {
        guard !slug.isEmpty, tags.isEmpty else { return }
        guard let list: TagList = try? await client.get("api/v1/nodes/\(slug)/tags") else { return }
        // Every tag with topics in this node, most used first, each with its
        // own look for the chips.
        let rows = list.tags
            .filter { ($0.topicCount ?? 0) > 0 }
            .sorted { ($0.topicCount ?? 0) > ($1.topicCount ?? 0) }
        TagLookStore.shared.merge(nodeTags: rows.map { ($0.name, TagLook(color: $0.color, style: $0.style, icon: $0.icon)) })
        tags = rows.map(\.name)
    }

    func select(_ tag: String?, slug: String, sort: NodeSort) async {
        selected = tag
        self.slug = slug
        posts = []
        errorText = nil
        guard tag != nil else {
            generation += 1
            return
        }
        await reload(sort: sort)
    }

    func reload(sort: NodeSort) async {
        guard selected != nil else { return }
        self.sort = sort
        generation += 1
        next = nil
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        await fetch(reset: true, generation: generation)
    }

    func loadMore() async {
        guard selected != nil, next != nil, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetch(reset: false, generation: generation)
    }

    private func fetch(reset: Bool, generation: Int) async {
        guard let tag = selected else { return }
        var query = [
            URLQueryItem(name: "node", value: slug),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "limit", value: String(DiscourseClient.pageSize)),
        ]
        switch sort {
        case .hot, .top: query.append(URLQueryItem(name: "sort", value: "hot"))
        case .rising: query.append(URLQueryItem(name: "sort", value: "rising"))
        case .fresh: query.append(URLQueryItem(name: "sort", value: "fresh"))
        case .featured: query.append(URLQueryItem(name: "featured", value: "1"))
        case .latest, .new: break
        }
        if !reset, let next { query.append(next) }
        do {
            let page: NLTopicPage = try await client.get("api/v1/topics", query: query)
            let shaped: CategoryTopicsResponse = try NodelocJSON.decode(
                object: DiscourseShape.latest(page.topics, hasMore: page.nextCursor != nil || page.nextOffset != nil)
            )
            guard generation == self.generation else { return }
            let usersByID = Dictionary(
                (shaped.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let mapped = (shaped.topicList?.topics ?? []).map {
                FeedMapper.post(topic: $0, usersByID: usersByID, client: client)
            }
            if reset { posts = mapped } else { posts.append(contentsOf: mapped) }
            if let cursor = page.nextCursor {
                next = URLQueryItem(name: "cursor", value: cursor)
            } else if let offset = page.nextOffset {
                next = URLQueryItem(name: "offset", value: String(offset))
            } else {
                next = nil
            }
        } catch {
            guard generation == self.generation else { return }
            next = nil
            if reset, posts.isEmpty {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
