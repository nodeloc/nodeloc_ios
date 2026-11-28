//
//  HomeView.swift
//  nodeloc
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// Decided once by MainView; drives whether the bar's leading slot holds
    /// the menu button or the wordmark.
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    @Environment(\.openURL) private var openURL
    let postTransitionNamespace: Namespace.ID
    @State private var feed = FeedStore()
    @State private var announcements = HomeAnnouncementStore()
    /// Whether the sort tabs have moved up into the bar. Its own small
    /// observable, written from the scroll handler only when the answer
    /// flips, so scrolling never re-renders this view frame by frame.
    @State private var chrome = HomeChromeState()
    /// The guest 登录 label's width, for the bar centre's room.
    @State private var trailingLabelWidth: CGFloat = 52
    @State private var selectedProfile: UserProfileTarget?
    /// The sort tab on show. Starts from the default-homepage preference.
    @State private var selectedTab: HomeFeed = HomeFeedTabs.tab(for: UserPreferencesStore.shared.homeFeed)
    /// Same store as the node pages, so one choice drives every list.
    private var readingMode = NodeReadingModeStore.shared
    /// Watched for the default-homepage choice.
    private var preferences = UserPreferencesStore.shared

    init(postTransitionNamespace: Namespace.ID) {
        self.postTransitionNamespace = postTransitionNamespace
    }

    var body: some View {
        feedBody
            .toolbar {
                SidebarToolbarItem(sidebarIsPinned: sidebarIsPinned)
                // Not on iPad: the top tab bar owns the centre of that row.
                if !usesTopTabBar {
                    // The logo and the compact tabs, both always in the bar,
                    // switched by UIKit alpha straight from `chrome` (see
                    // `HomeBarCenterView`): SwiftUI toolbar content, hosted by
                    // the UIKit bar, was seen on the phone keeping the logo
                    // after the strip had folded — no tabs anywhere.
                    ToolbarItem(placement: .principal) {
                        HomeBarCenterView(
                            chrome: chrome,
                            selection: selectedTab,
                            onSelect: { tab in selectTabScrollingUp(tab) }
                        )
                        .frame(width: barCenterWidth, height: 44)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    headerTrailingAction
                }
            }
            .tabRootNavigationBar()
            // Someone's profile is pushed onto this tab's stack, so the back
            // button and the swipe back are the system's.
            .navigationDestination(item: $selectedProfile) { target in
                PublicProfileOverlay(target: target, navigation: .pushed) {
                    selectedProfile = nil
                }
            }
    }

    private var feedBody: some View {
        // `visiblePosts` filters the whole list against the block list on
        // every access, so take it once per render.
        let visiblePosts = feed.visiblePosts
        return ZStack(alignment: .top) {
            // Feed
            ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The strip is laid out by the page itself, above the
                // list — not as a system safe-area bar, which on the phone
                // sometimes kept the strip's space but didn't draw it
                // (logo in the bar, no tabs anywhere). Folding it moves the
                // list up without touching its scroll offset or insets.
                // The navigation bar always stays. Collapsed (with the bottom
                // bar minimised), the strip folds to zero height under it and
                // the tabs show in the bar's centre in place of the logo.
                HomeTabStripSlot(chrome: chrome, alwaysShown: usesTopTabBar) {
                    HomeFeedTabs(selection: selectedTab) { tab in
                        selectTab(tab)
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.topAnchor, anchor: .top)
                        }
                    }
                }
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topAnchor)

                    // Above the first row, the way the web's front page has it:
                    // the site announcements, as one line.
                    if !showsLoader {
                        HomeAnnouncementStrip(
                            announcements: announcements.visible,
                            onOpen: { openAnnouncement($0) },
                            onDismiss: { announcement in
                                Task { await announcements.dismiss(announcement) }
                            }
                        )
                    }

                    if showsFollowingSignIn {
                        followingSignIn
                    } else if showsLoader {
                        feedSkeleton
                    } else if visiblePosts.isEmpty {
                        // Load failed or nothing came back: say so instead of
                        // an unexplained blank screen.
                        feedUnavailable
                    } else {
                        ForEach(visiblePosts) { post in
                            switch readingMode.homeMode {
                            case .card:
                                PostCard(
                                    post: post,
                                    postTransitionNamespace: postTransitionNamespace,
                                    onOpenAuthor: { target in
                                        withAnimation(.panelSlide) {
                                            selectedProfile = target
                                        }
                                    }
                                )
                            case .compact, .expand:
                                // The node pages' rows, so the two lists match.
                                NodeTopicRow(
                                    post: post,
                                    mode: readingMode.homeMode,
                                    onTap: { openPost(post) },
                                    // This list is inside `MainView`, so the
                                    // composer overlay presents normally here.
                                    onRepost: {
                                        app.startRepost(
                                            of: post,
                                            url: DiscourseConfig.baseURL.appending(path: "t/\(post.id)")
                                        )
                                    }
                                )
                            }
                        }

                        if feed.hasMore {
                            // Auto-loads the next page when scrolled into view.
                            HStack {
                                ProgressView().tint(Theme.accent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                guard visible else { return }
                                Task { await feed.loadMore() }
                            }
                        }
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            // The sort tabs stay put under the bar while the list scrolls.
            // A bar, not a plain inset: on iOS 26 the navigation bar's soft
            // scroll-edge effect is drawn over the scroll view's top inset, and
            // it blurred the tab labels. `safeAreaBar` makes the strip part of
            // the bar area, so the effect sits under it instead.
            .refreshable {
                await feed.load()
                await announcements.load()
                chrome.settleAtTop()
            }
            .task {
                if feed.selectedFeed == nil {
                    selectTab(selectedTab)
                } else {
                    await feed.loadIfNeeded()
                }
            }
            .task { await announcements.load() }
            // A new reading language: titles, node names and notices come back
            // in it, so the feed on screen isn't left in the old one.
            .onReceive(NotificationCenter.default.publisher(for: .nodelocLanguageDidChange)) { _ in
                Task {
                    await feed.load()
                    await announcements.load()
                }
            }
            // Settings is an overlay over this view, so `task` won't run again
            // when it closes. Reload the moment the choice changes instead.
            .onChange(of: preferences.homeFeed) { _, newValue in
                selectTab(HomeFeedTabs.tab(for: newValue))
            }
            .tabBarFollowsScrollDirection()
            // Measured from the resting position under the navigation bar,
            // so 0 is the top whatever the bar's height.
            .onScrollGeometryChange(for: HomeScrollPosition.self) { geo in
                HomeScrollPosition(raw: geo.contentOffset.y, fromTop: geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, newValue in
                chrome.track(newValue)
            }
            // Back from the background at the top: the strip is down.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { chrome.settleAtTop() }
            }
            // A fling released, or the top reached: the bottom bar's rules
            // flipped, and the strip moves with it in the same frame.
            .onChange(of: TabBarScrollState.shared.chromeCollapsed) { _, _ in
                chrome.sync()
            }
            // The system can open or close the bottom bar without a scroll
            // frame here; a light check keeps the strip in step with it.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    chrome.sync()
                }
            }
            // The toolbar's mark asks for this; only it knows whether the
            // layout has a drawer to open instead.
            .onChange(of: app.scrollToTopRequests) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
            .onChange(of: chrome.scrollToTopRequests) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
            }
            }
        }
        // The page colour, safe area included: the strip under the status bar
        // and the navigation bar is painted by no row, and showed the window's
        // black in dark mode.
        .background(Theme.bg.ignoresSafeArea())
    }

    /// Target for the toolbar's "back to top" control, which lives outside
    /// this view's `ScrollViewReader`.
    private static let topAnchor = "feed-top"

    private let logoHeight: CGFloat = 30

    /// First load with nothing to show yet — the skeleton stands in for it.
    private var showsLoader: Bool {
        feed.visiblePosts.isEmpty && feed.isLoading
    }

    /// A tab tapped up in the bar: switch, and go back to the top of the new
    /// list (which also brings the wordmark back).
    private func selectTabScrollingUp(_ tab: HomeFeed) {
        selectTab(tab)
        chrome.scrollToTopRequests += 1
        // Back at the top: the bottom bar opens with the strip. A scroll by
        // code doesn't count as arriving there for the bar's own rules.
        TabBarScrollState.shared.expand()
    }

    // MARK: Header

    /// Always the plain wordmark: the skeleton (first load) and the system
    /// refresh spinner are the loading signals, so the header stays still.
    /// The bar's centre is laid out centred, so it is as wide as the screen
    /// less twice the larger side: the 16pt margin, the button (☰ is 44; the
    /// trailing one is measured — its glass adds ~14pt each side to the
    /// label) and an 8pt gap.
    private var barCenterWidth: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 393
        let trailing = app.isGuest ? max(44, trailingLabelWidth + 28) : 44
        let side = 16 + max(44, trailing) + 8
        return max(160, min(screen, 600) - 2 * side)
    }

    private var headerWordmark: some View {
        Image("NodelocWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: logoHeight)
            .accessibilityLabel("NodeLoc")
    }

    /// 发帖 for members, 登录 for guests — posting needs an account either way.
    @ViewBuilder
    private var headerTrailingAction: some View {
        if app.isGuest {
            GuestLoginButton()
                // Its real width (登录 / Log in differ), so the bar's centre
                // can take everything up to it.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingLabelWidth = $0 }
        } else {
            Button {
                withAnimation(.overlayPush) { app.overlay = .compose }
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel(AppString("发帖"))
        }
    }

    /// 关注 needs an account: a guest gets the sign-in prompt, not a request
    /// the server would answer with everything.
    private var showsFollowingSignIn: Bool {
        selectedTab == .following && app.isGuest
    }

    private func selectTab(_ tab: HomeFeed) {
        selectedTab = tab
        guard !(tab == .following && app.isGuest) else { return }
        Task { await feed.select(tab) }
    }

    private var followingSignIn: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            Text(AppString("登录后查看你加入的节点里的新帖"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button(AppString("登录")) { requestLogin(app, .content) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 130)
        .padding(.horizontal, 32)
    }

    private func openPost(_ post: Post) {
        app.openReader(post)
    }

    /// An announcement points at a topic; the id is all the overlay needs.
    /// Anything else goes through the app's link routing (in-app browser).
    private func openAnnouncement(_ announcement: NLHomeAnnouncements.Announcement) {
        if let topicID = announcement.topicId, topicID > 0 {
            app.openTopic(id: topicID)
        } else if let link = announcement.url, let url = URL(string: link) {
            openURL(url)
        }
    }

    /// Friendly failure/empty state with a retry, shown when the first load
    /// produced nothing (usually no network).
    private var feedUnavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: feed.errorText == nil ? "tray" : "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
            Text(feed.errorText ?? AppString("暂时没有内容"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await feed.load() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 130)
        .padding(.horizontal, 32)
    }

    // MARK: Skeleton

    /// First-load placeholders, shaped like the rows the current mode renders.
    /// One pulse on the container keeps every row in phase.
    private var feedSkeleton: some View {
        VStack(spacing: 0) {
            switch readingMode.homeMode {
            case .card:
                ForEach(0..<3, id: \.self) { _ in cardSkeleton }
            case .compact:
                ForEach(0..<10, id: \.self) { _ in compactSkeleton }
            case .expand:
                ForEach(0..<6, id: \.self) { _ in FeedTopicRowSkeleton() }
            }
        }
        .skeletonPulsing()
    }

    /// Mirrors PostCard: author line, title, media block, action pills.
    private var cardSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Theme.neutral300).frame(width: 22, height: 22)
                SkeletonLine(widthFraction: 0.35)
            }
            SkeletonLine(widthFraction: 0.9, height: 16)
            SkeletonLine(widthFraction: 0.55, height: 16)
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                .fill(Theme.neutral300)
                .frame(height: 200)
            HStack(spacing: 8) {
                Capsule().fill(Theme.neutral300).frame(width: 90, height: 30)
                Capsule().fill(Theme.neutral300).frame(width: 64, height: 30)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Mirrors NodeTopicRow's compact row: avatar plus two short lines.
    private var compactSkeleton: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.neutral300).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonLine(widthFraction: 0.85)
                SkeletonLine(widthFraction: 0.4, height: 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
        }
    }

}

// MARK: - Sort tabs

/// The home feed's sort tabs (design App-iOS-Feed): 热门 / 最新 / 精华 /
/// 上升中 / 关注 as underlined text, 16pt, 26pt apart, on a 44pt strip with a
/// hairline under it. Scrolls sideways when a translation runs long.
struct HomeFeedTabs: View {
    let selection: HomeFeed
    /// The copy that sits in the navigation bar while scrolling down the
    /// feed: smaller, tighter, and without the strip's own background and
    /// hairline, which would cut a box out of the bar's glass.
    var inBar = false
    let onSelect: (HomeFeed) -> Void

    @Namespace private var underline

    /// The web's order (web/pages.go `homeSorts`): 新鲜 sits right after 最新,
    /// its posting-time twin.
    static let tabs: [HomeFeed] = [.hot, .latest, .fresh, .top, .rising, .following]

    /// The tab a default-homepage choice lands on. 精选 (the personal mix) has
    /// no tab of its own and starts on 热门.
    static func tab(for feed: HomeFeed) -> HomeFeed {
        switch feed {
        case .best: .hot
        default: feed
        }
    }

    static func label(_ feed: HomeFeed) -> String {
        switch feed {
        case .hot: AppString("热门")
        case .latest: AppString("最新")
        case .top: AppString("精华")
        case .rising: AppString("上升中")
        case .fresh: AppString("新鲜")
        case .following: AppString("关注")
        default: feed.label
        }
    }

    var body: some View {
        // No 列表样式 button here: the style is chosen in 设置 → 偏好 → 默认列表
        // 视图 and from the node page's sort bar, and the strip needs the
        // room for its six tabs.
        tabs
        .frame(height: inBar ? 38 : 44)
        .background(inBar ? Color.clear : Theme.bg)
        .overlay(alignment: .bottom) {
            if !inBar {
                Rectangle().fill(Theme.chip).frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tabs: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: inBar ? 18 : 22) {
                ForEach(Self.tabs) { tab in
                    let isOn = tab == selection
                    Button { onSelect(tab) } label: {
                        Text(Self.label(tab))
                            .font(Theme.body(inBar ? 15 : 16, weight: isOn ? .bold : .medium))
                            .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
                            .fixedSize()
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .bottom) {
                                // In the bar the selected tab is told apart
                                // by weight and colour alone.
                                if isOn, !inBar {
                                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                        .fill(Theme.text)
                                        .frame(height: 3)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    .id(tab)
                }
            }
            .padding(.horizontal, inBar ? 6 : 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // The bar's copy is narrower than the row: keep the current tab in view.
        .onAppear { if inBar { proxy.scrollTo(selection, anchor: .center) } }
        .onChange(of: selection) { _, tab in
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
        }
        }
    }
}

// MARK: - Bar ⇄ strip

/// Whether the sort tabs sit in the navigation bar (reading down the feed) or
/// in their strip under it (at the top, or heading back up).
///
/// Kept apart from `HomeView` so the scroll handler — called every frame —
/// touches only `@ObservationIgnored` bookkeeping. `tabsInBar` is written
/// only when it flips, and only the two small views below read it.
@MainActor
@Observable
final class HomeChromeState {
    private(set) var tabsInBar = false
    /// Bumped when a tab tapped in the bar should take the list to its top.
    var scrollToTopRequests = 0

    @ObservationIgnored private var lastOffset: CGFloat = 0
    @ObservationIgnored private var lastRaw: CGFloat = 0
    /// Distance travelled in the current direction; flips reset it.
    @ObservationIgnored private var run: CGFloat = 0

    /// How far the reader must keep going one way before the bar changes —
    /// enough that a finger's wobble or a bounce doesn't flicker it.
    private let threshold: CGFloat = 28
    /// Never move the tabs up before the strip itself has scrolled away.
    private let minimumOffset: CGFloat = 56

    /// Follows the bottom tab bar (`TabBarScrollState.chromeCollapsed`, set
    /// by the same scroll rules that minimise and expand it): the strip
    /// collapses after a downward run and comes back only on a fast pull
    /// back (1000 pt/s while dragging), a fast fling on release, or the top —
    /// never on a slow reverse drag. `fromTop` keeps the strip down until it
    /// has scrolled away, and at the top it is always down.
    ///
    /// The strip's own height change moves `fromTop` but not the shared
    /// state, so it can't drive itself (the earlier flip-flop).
    func track(_ position: HomeScrollPosition) {
        let top = position.fromTop
        lastRaw = position.raw
        lastOffset = top
        if top <= 8 {
            set(false)
            run = 0
            return
        }
        sync()
    }

    /// Re-reads the shared state — also when it flips without a scroll frame.
    func sync() {
        let state = TabBarScrollState.shared
        let minimized = TabBarScrollState.isActuallyMinimized()
        // The system opened the bottom bar by itself (a tap on the minimised
        // bar): open everything with it. Only the open edge is taken from
        // UIKit — the bar's minimise animation and its reading lag the
        // finger, and following it made the tabs fold only after the scroll
        // had stopped.
        if wasMinimized, !minimized, state.chromeCollapsed {
            state.expand()
        }
        wasMinimized = minimized
        // Collapse straight from the scroll rules, during the drag: set after
        // a 30 pt downward run (`noteScrolledDown`), in the same frames the
        // system starts minimising the bottom bar.
        if !state.chromeCollapsed {
            set(false)
        } else if lastOffset > minimumOffset {
            set(true)
        }
    }

    @ObservationIgnored private var wasMinimized = false

    /// Back to the strip under the bar, at once: for a return to the app or
    /// the end of a refresh, when the list sits at its top.
    func settleAtTop() {
        guard lastOffset <= 8, tabsInBar else { return }
        tabsInBar = false
        run = 0
    }

    private func set(_ value: Bool) {
        guard tabsInBar != value else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { tabsInBar = value }
    }
}

struct HomeScrollPosition: Equatable {
    let raw: CGFloat
    let fromTop: CGFloat
}

/// The bar's centre as a UIKit view holding both the logo and the compact
/// tabs. Which one shows is set as UIKit alpha by an observation of
/// `chrome.tabsInBar` that re-arms itself on every change — not by SwiftUI
/// re-evaluating toolbar content, which the bar didn't reliably do.
struct HomeBarCenterView: UIViewRepresentable {
    let chrome: HomeChromeState
    let selection: HomeFeed
    let onSelect: (HomeFeed) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(chrome: chrome) }

    func makeUIView(context: Context) -> UIView {
        let c = context.coordinator
        let container = UIView()
        container.backgroundColor = .clear
        let logo = UIHostingController(rootView: AnyView(
            Image("NodelocWordmark").resizable().scaledToFit().frame(height: 30).accessibilityLabel("NodeLoc")
        ))
        let tabs = UIHostingController(rootView: AnyView(tabsView))
        for host in [logo, tabs] {
            host.view.backgroundColor = .clear
            host.view.frame = container.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(host.view)
        }
        c.logo = logo
        c.tabs = tabs
        c.apply(animated: false)
        c.observe()
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        let c = context.coordinator
        // The bar keeps this view across a rebuild of the page (a language
        // change re-keys the root; a new `HomeView` brings a new `chrome`).
        // Held on to, the old object stayed "expanded" while the strip
        // followed the new one into "collapsed": the logo in the bar, the
        // strip folded — no tabs anywhere. Always follow the current one.
        if c.chrome !== chrome {
            c.chrome = chrome
            c.observe()
        }
        c.tabs?.rootView = AnyView(tabsView)
        c.apply(animated: true)
    }

    private var tabsView: some View {
        HomeFeedTabs(selection: selection, inBar: true, onSelect: onSelect)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    final class Coordinator {
        var chrome: HomeChromeState
        var logo: UIHostingController<AnyView>?
        var tabs: UIHostingController<AnyView>?
        private var shown: Bool?

        init(chrome: HomeChromeState) { self.chrome = chrome }

        /// Bumped on each `observe()`, so a callback armed on an object
        /// that's since been replaced doesn't re-arm itself.
        private var generation = 0

        func observe() {
            generation += 1
            let mine = generation
            let watched = chrome
            withObservationTracking {
                _ = watched.tabsInBar
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == mine else { return }
                    self.apply(animated: true)
                    self.observe()
                }
            }
        }

        func apply(animated: Bool) {
            let inBar = chrome.tabsInBar
            guard inBar != shown, let logo = logo?.view, let tabs = tabs?.view else { return }
            shown = inBar
            let change = {
                logo.alpha = inBar ? 0 : 1
                tabs.alpha = inBar ? 1 : 0
            }
            logo.isUserInteractionEnabled = !inBar
            tabs.isUserInteractionEnabled = inBar
            logo.accessibilityElementsHidden = inBar
            tabs.accessibilityElementsHidden = !inBar
            if animated { UIView.animate(withDuration: 0.22, animations: change) } else { change() }
        }
    }
}

/// The bar's centre: the wordmark, or the sort tabs once they've moved up.
struct HomeBarCenter<Wordmark: View>: View {
    let chrome: HomeChromeState
    let tabsInBar: Bool
    let selection: HomeFeed
    let onSelect: (HomeFeed) -> Void
    @ViewBuilder var wordmark: Wordmark

    var body: some View {
        ZStack {
            wordmark
                .opacity(tabsInBar ? 0 : 1)
                .offset(y: tabsInBar ? -8 : 0)
                .accessibilityHidden(tabsInBar)
                .allowsHitTesting(!tabsInBar)
            HomeFeedTabs(selection: selection, inBar: true, onSelect: onSelect)
                .padding(.horizontal, 6)
                .frame(height: 44)
                // The bar's own glass, like the buttons beside it: over the
                // feed the labels need it to stay readable.
                .glassSurface(tint: Theme.bg.opacity(0.35))
                .clipShape(Capsule())
                .opacity(tabsInBar ? 1 : 0)
                .offset(y: tabsInBar ? 0 : 8)
                .accessibilityHidden(!tabsInBar)
                .allowsHitTesting(tabsInBar)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tabsInBar)
        // Between the bar's buttons; the tabs scroll sideways inside it.
        .frame(width: HomeBarCenter.width)
        .clipped()
    }

    /// The bar's width less the leading and trailing buttons and their gaps.
    static var width: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 393
        // Room for the trailing button's widest form (登录 / Log in) too.
        return max(160, min(screen, 600) - 2 * (16 + 64 + 8))
    }
}

/// The strip under the bar. Collapses (sliding up under the bar) while the
/// tabs ride in the bar, and comes back when they return.
struct HomeTabStripSlot<Strip: View>: View {
    let chrome: HomeChromeState
    /// iPad's top tab bar owns the bar's centre, so the strip never leaves.
    var alwaysShown = false
    @ViewBuilder var strip: Strip

    /// The strip sits this much closer to the bar than its own frame would
    /// put it — the design has the tabs right under the bar's controls.
    private let tuck: CGFloat = 6

    var body: some View {
        let hidden = chrome.tabsInBar && !alwaysShown
        // Always the same view, never inserted or removed, and never faded:
        // collapsing only animates the height to zero (clipped), so while the
        // strip takes any space its labels are drawn in it. The earlier
        // insert/remove transition could be cut off by the next scroll and
        // leave the slot holding its height with the labels at zero opacity —
        // the empty band, with the bar's blur over it.
        strip
            .frame(height: stripHeight, alignment: .bottom)
            .frame(height: hidden ? 0 : stripHeight, alignment: .bottom)
            .clipped()
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }

    private var stripHeight: CGFloat { 44 - tuck }
}

// MARK: - Post card

struct PostCard: View {
    @Environment(AppState.self) private var app
    let post: Post
    let postTransitionNamespace: Namespace.ID
    /// Opens the author's public profile; nil disables the avatar tap.
    var onOpenAuthor: ((UserProfileTarget) -> Void)? = nil
    @State private var selectedMediaIndex = 0
    @State private var showsMoreSheet = false
    /// Media opened straight from the card, without entering the post.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    @State private var viewerVideo: PostVideo?
    /// Resolved node, so the player's header shows the same logo as elsewhere.
    @State private var nodeSummary: SidebarNodeSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            postHeader
            postBody
            mediaPreview
            actionRow
            if let reports = post.reportCount, reports > 0 {
                FeedModStrip(reportCount: reports, onOpen: openPost)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.chip).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openPost)
        // Media opens over the feed, so closing returns to the same scroll
        // position instead of dropping the reader into the post.
        .postImageFullScreen(
            images: $viewerImages,
            selection: $viewerIndex,
            presentation: PostVideoPresentation(post: post, node: nodeSummary),
            onComment: { openPost() }
        )
        .postVideoFullScreen(
            video: $viewerVideo,
            presentation: PostVideoPresentation(post: post, node: nodeSummary),
            // Commenting needs the post, so it opens it.
            onComment: { openPost() }
        )
        .task(id: post.node) { nodeSummary = await NodeCatalog.shared.node(slug: post.node) }
    }

    private func openPost() {
        app.openReader(post)
    }

    /// New/unread for the signed-in user, unless opened this session.
    private var showsUnreadDot: Bool {
        post.isUnread && !app.locallyReadTopicIDs.contains(post.id)
    }

    /// Opens the tapped media directly rather than the post.
    private func openMedia(at index: Int) {
        if let videoURL = post.videoURL {
            viewerVideo = PostVideo(src: videoURL.absoluteString, posterSrc: (post.videoPosterURL ?? post.imageURL)?.absoluteString)
            return
        }
        // The viewer shows the original; the card drew the card-size thumbnail.
        let images = mediaItems.map {
            PostImage(src: ($0.originalURL ?? $0.url).absoluteString, width: $0.width, height: $0.height)
        }
        guard !images.isEmpty else { return }
        viewerImages = images
        viewerIndex = min(max(index, 0), images.count - 1)
    }

    /// The feed row's node line (design App-iOS-Feed), shared with the
    /// thumbnail rows so both reading modes start the same way.
    private var postHeader: some View {
        FeedRowHeader(post: post, showsUnreadDot: showsUnreadDot) {
            showsMoreSheet = true
        }
        .sheet(isPresented: $showsMoreSheet) {
            TopicMoreSheet(post: post) { startRepost() }
        }
    }

    private var postBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(post.highlightedTitle.map { SearchHighlight.attributed($0, tint: Theme.accent) } ?? AttributedString(post.title))
                .font(Theme.heading(17, weight: .semibold))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if !post.excerpt.isEmpty {
                Text(post.highlightedExcerpt.map { SearchHighlight.attributed($0, tint: Theme.accent) } ?? AttributedString(post.excerpt))
                    .font(Theme.body(13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text.opacity(0.72))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        // A topic with a video autoplays it in place of the image carousel;
        // the thumbnail is just its poster frame anyway.
        if let videoURL = post.videoURL {
            FeedVideoTile(url: videoURL, posterURL: post.videoPosterURL ?? post.imageURL, duration: post.videoDuration, knownAspect: post.videoAspect) {
                openMedia(at: 0)
            }
            .padding(.top, 2)
        } else if !mediaItems.isEmpty {
            FeedMediaCarousel(items: mediaItems, selection: $selectedMediaIndex) {
                // Opens whichever page is showing, not always the first.
                openMedia(at: selectedMediaIndex)
            }
            .padding(.top, 2)
        } else if post.hasImage {
            ImagePlaceholder()
                .frame(height: FeedMediaCarousel.defaultHeight)
                .padding(.top, 2)
        }
    }

    /// Opens the composer quoting this topic, the same shape the reader's 转发
    /// hands over.
    private func startRepost() {
        app.composePrefillTitle = post.title
        app.composeRepostTopic = AppState.RepostTopic(
            id: post.id,
            title: post.title,
            url: topicURL,
            node: post.node,
            author: post.authorUsername,
            excerpt: post.excerpt.isEmpty ? nil : post.excerpt,
            imageURL: post.imageURL
        )
        withAnimation(.overlayPush) { app.overlay = .compose }
    }

    private var topicURL: URL {
        DiscourseConfig.baseURL.appending(path: "t/\(post.id)")
    }

    private var actionRow: some View {
        FeedRowActions(post: post, onComments: openPost, onRepost: startRepost)
    }

    private var mediaItems: [PostMedia] {
        if !post.media.isEmpty { return post.media }
        if let imageURL = post.imageURL {
            return [PostMedia(url: imageURL, width: nil, height: nil)]
        }
        return []
    }
}

struct FeedMediaCarousel: View {
    let items: [PostMedia]
    @Binding var selection: Int
    /// Opens the current page full screen. Nil falls through to the card.
    var onTap: (() -> Void)?
    @State private var availableWidth: CGFloat = 362

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    FeedMediaPage(item: item, width: availableWidth)
                        .tag(index)
                        // On the page, not the TabView: a gesture on the
                        // container would fight the paging swipe.
                        .contentShape(Rectangle())
                        .onTapGesture { onTap?() }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: previewHeight)
            .background(Theme.surface)

            if items.count > 1 {
                carouselControls
            }
        }
        .frame(height: previewHeight)
        // 16pt, as App-iOS-FeedCard's media block.
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        availableWidth = newValue
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
    }

    /// App-iOS-FeedCard's media badge: a photo glyph and the count, bottom
    /// right on a dark pill. While paging it reads "2/12", so the badge
    /// doubles as the page indicator; the design has no arrows on iOS — the
    /// swipe is the control.
    private var carouselControls: some View {
        FeedMediaBadge(
            systemImage: "photo",
            text: selection == 0 ? "\(items.count)" : "\(selection + 1)/\(items.count)"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(10)
        .allowsHitTesting(false)
        .accessibilityLabel(AppString("第 \(selection + 1) 张，共 \(items.count) 张"))
    }

    /// Sized from the first item's real dimensions, Reddit-style: the card
    /// takes the media's own shape, clamped to 16:9 wide … 4:5 tall.
    private var previewHeight: CGFloat {
        Theme.FeedMedia.height(
            forWidth: max(availableWidth, 1),
            mediaWidth: items.first?.width,
            mediaHeight: items.first?.height
        )
    }

    /// Placeholder height before any media is known — a square, matching the
    /// default aspect, so the card doesn't resize once dimensions arrive.
    static let defaultHeight: CGFloat = 230
}

private struct FeedMediaPage: View {
    let item: PostMedia
    let width: CGFloat

    /// Far outside the card's 16:9 … 4:5 range (by more than a third).
    private var fitsWhole: Bool {
        guard let w = item.width, let h = item.height, w > 0, h > 0 else { return false }
        let ratio = CGFloat(h) / CGFloat(w)
        return ratio < Theme.FeedMedia.minAspect / 1.33 || ratio > Theme.FeedMedia.maxAspect * 1.33
    }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // CachedRemoteImage (not AsyncImage): it caches and decodes to the
        // card's pixel size. The URL is the variant sized to the card, so the
        // source is neither the blurry mid-size default nor the heavy original.
        CachedRemoteImage(url: item.bestURL(forWidth: width, scale: displayScale)) { image in
            if fitsWhole {
                // A panorama or a very tall screenshot: cropping it to the
                // card's clamped shape left a meaningless slice, so it's shown
                // whole over a blurred copy of itself (the design's carousel).
                image.resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        image.resizable().scaledToFill()
                            .blur(radius: 32)
                            .saturation(1.25)
                            .overlay(Color(red: 15 / 255, green: 26 / 255, blue: 28 / 255).opacity(0.16))
                            .clipped()
                    }
            } else {
                image
                    .resizable()
                    .scaledToFill()
            }
        } placeholder: {
            // The image's own main colour while it loads (`card_media`), the
            // hatch when the server doesn't know it.
            if let hex = item.placeholderHex {
                nodeAccentColor(hex)
            } else {
                StripePattern()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// The dark pill App-iOS-FeedCard puts on a card's media (photo count, and
/// the same pill for a video's length).
struct FeedMediaBadge: View {
    let systemImage: String?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            }
            Text(text).font(.system(size: 13, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.leading, systemImage == nil ? 10 : 8)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(Color(red: 11 / 255, green: 31 / 255, blue: 24 / 255).opacity(0.78), in: Capsule())
    }
}

/// A compact icon+text label used in post meta rows.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 13))
            configuration.title
        }
    }
}

/// Diagonal-hatch image placeholder matching the design.
struct ImagePlaceholder: View {
    var body: some View {
        ZStack {
            StripePattern()
            Image(systemName: "photo")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }
}

private struct StripePattern: View {
    var body: some View {
        GeometryReader { geo in
            let count = Int((geo.size.width + geo.size.height) / 16) + 2
            Theme.surface
                .overlay {
                    ForEach(0..<count, id: \.self) { i in
                        Rectangle()
                            .fill(Theme.neutral400)
                            .frame(width: 8)
                            .rotationEffect(.degrees(-45))
                            .offset(x: CGFloat(i) * 16 - geo.size.height)
                    }
                }
                .clipped()
        }
    }
}

extension Color {
    /// Approximate CSS color-mix by blending in sRGB.
    func blended(with other: Color, fraction: Double) -> Color {
        Color(UIColor { traits in
            let a = UIColor(self).resolvedColor(with: traits)
            let b = UIColor(other).resolvedColor(with: traits)
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let f = CGFloat(fraction)
            return UIColor(
                red: ar + (br - ar) * f,
                green: ag + (bg - ag) * f,
                blue: ab + (bb - ab) * f,
                alpha: aa + (ba - aa) * f
            )
        })
    }
}
