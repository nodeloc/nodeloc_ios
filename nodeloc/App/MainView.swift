//
//  MainView.swift
//  nodeloc
//
//  Tab container + floating bottom nav + full-screen overlays.
//

import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Namespace private var postTransitionNamespace
    @State private var lastContentTab: Tab = .home
    /// Presentation state of the system search UI, written by the system and
    /// never by us.
    ///
    /// It used to be asserted from two places to force the scope row to appear,
    /// which meant three writers on a two-way binding — the system would
    /// present, our stale `false` would fight it, and the result was the search
    /// chrome flickering or not appearing at all. The scope bar is the app's own
    /// now, so nothing needs to force this.
    @State private var searchPresented = false
    @State private var profileTabAvatar = ProfileTabAvatarStore.shared
    /// Drives the Message tab's unread badge; shared with the inbox.
    @State private var inbox = MessageCenterStore.shared

    /// The container's size, so the pinning rule can see the aspect ratio.
    /// Nothing is pinned until this is known, which matches the phone layout —
    /// and the launch animation covers the first frames anyway.
    @State private var containerSize: CGSize = .zero

    /// Pinned only on an iPad-sized container that is currently wider than it is
    /// tall. iPad portrait deliberately keeps the phone's drawer: 834pt minus a
    /// 320pt column leaves the feed narrower than an iPhone.
    ///
    /// The size classes can't answer this alone — an iPad reports regular in
    /// *both* orientations — so the aspect ratio decides. They're still needed
    /// to exclude phones: an iPhone Max in landscape is also wider than tall,
    /// but reports a compact vertical size class.
    /// iPad draws the tab bar at the top in *both* orientations.
    ///
    /// Keyed on the idiom, not the size class: an iPhone Max in landscape also
    /// reports a regular width and must keep the phone layout — which is the
    /// same trap `isSidebarPinned` works around with its aspect-ratio check.
    static let usesTopTabBar = UIDevice.current.userInterfaceIdiom == .pad

    private var isSidebarPinned: Bool {
        horizontalSizeClass == .regular
            && verticalSizeClass == .regular
            && containerSize.width > containerSize.height
    }

    var body: some View {
        @Bindable var app = app

        GeometryReader { proxy in
            let isPinned = isSidebarPinned
            let sidebarWidth = isPinned ? pinnedSidebarWidth : min(proxy.size.width * 0.86, 330)
            // The drawer is never "open" while pinned — it's simply always there.
            let sidebarOpen = !isPinned && app.overlay == .sidebar
            let sidebarVisible = isPinned || sidebarOpen
            // Pinned, the content gives up the sidebar's width instead of being
            // pushed off the far edge the way the drawer pushes it.
            let contentWidth = isPinned ? max(proxy.size.width - sidebarWidth, 0) : proxy.size.width
            // With no drawer to drag, the swipe gestures would only fight the
            // content's own horizontal scrolling.
            let drawerGestures: GestureMask = isPinned ? .none : .all

            ZStack(alignment: .leading) {
                Theme.bg.ignoresSafeArea()

                if sidebarVisible {
                    SidebarOverlay(panelWidth: sidebarWidth, isPinned: isPinned)
                        .gesture(closeSidebarDragGesture, including: drawerGestures)
                        .zIndex(0)
                }

                TabView(selection: $app.tab) {
                    SwiftUI.Tab(value: Tab.home) {
                        tabContent(for: .home) {
                            HomeView(postTransitionNamespace: postTransitionNamespace)
                        }
                    } label: {
                        Image(systemName: "house")
                        Text("Home")
                    }

                    SwiftUI.Tab(value: Tab.nodes) {
                        tabContent(for: .nodes) {
                            BrowseNodesOverlay(showsCloseButton: false)
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                        Text("节点")
                    }

                    SwiftUI.Tab(value: Tab.chat) {
                        tabContent(for: .chat) {
                            ChatView()
                        }
                    } label: {
                        Image(systemName: "bubble.left")
                        Text("Message")
                    }
                    .badge(inbox.unreadTotal)

                    SwiftUI.Tab(value: Tab.profile) {
                        tabContent(for: .profile) {
                            ProfileView()
                        }
                    } label: {
                        if let tabImage = profileTabAvatar.tabImage {
                            // Bare Image with .original so the tab bar keeps the
                            // photo's colors instead of template-tinting it.
                            Image(uiImage: tabImage)
                                .renderingMode(.original)
                        } else {
                            Image(systemName: "person.crop.circle")
                        }
                        Text("Profile")
                    }

                    SwiftUI.Tab(value: Tab.search, role: .search) {
                        tabContent(for: .search) {
                            NavigationStack {
                                SearchView(postTransitionNamespace: postTransitionNamespace)
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                    }
                }
                .tint(Theme.accent)
                // Collapses as you scroll up into the feed and expands on the
                // pull back down, which is the same travel that hides and
                // reveals the header wordmark (`HomeView.handleScroll`).
                //
                // Verified on device, because the two constants read ambiguous:
                // "downwards scrolling" here means travelling down through the
                // content, not dragging the content downwards. `.onScrollUp`
                // was tried and left the bar expanded the whole way down the
                // feed — don't flip this again.
                //
                // What this modifier can't do: expand only on a *quick* pull,
                // the way the wordmark does via `quickRevealThreshold`. It
                // reacts to any downward scroll at any speed, and there is no
                // programmatic hook to drive it from `app.navCollapsed`
                // instead.
                .tabBarMinimizesOnScrollDown()
                // Telegram-style search: the tab bar itself morphs into the
                // search field. Selecting the search pill activates search;
                // cancelling deselects it and restores the previous tab — all
                // system-managed, so there is no custom close button to fight
                // the pill for the bottom-right corner.
                // Phone only — see `searchFieldIfNeeded`.
                .searchFieldIfNeeded(
                    enabled: !Self.usesTopTabBar,
                    text: $app.searchQuery,
                    isPresented: $searchPresented,
                    prompt: AppString("搜索")
                )
                // No `.searchScopes`: the system row only exists while search
                // is presented, so it depended on a presentation binding that
                // the system writes too and kept going missing. `SearchView`
                // draws its own scope bar in both modes now.
                .onSubmit(of: .search) {
                    SearchHistoryStore.shared.record(app.searchQuery)
                }
                .searchActivatesOnTabSelection()
                .frame(width: contentWidth, height: proxy.size.height)
                .overlay {
                    // Tap-to-dismiss only makes sense for the drawer; pinned,
                    // this would swallow every tap in the content.
                    if sidebarOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                            .gesture(closeSidebarDragGesture)
                    }
                }
                // Inside the content column, not over the whole window: the
                // pinned sidebar has to stay reachable while a post, node or
                // settings page is open. On iPhone `contentWidth` is the full
                // width and the offset is zero, so this is unchanged there.
                .overlay { overlayLayer }
                .offset(x: sidebarVisible ? sidebarWidth : 0)
                .shadow(color: sidebarOpen ? .black.opacity(0.12) : .clear, radius: 24, x: -8, y: 0)
                .simultaneousGesture(
                    openSidebarDragGesture(containerWidth: proxy.size.width),
                    including: drawerGestures
                )
                .zIndex(1)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: sidebarOpen)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { containerSize = $0 }
        }
        // Read by SidebarMenuButton on every root screen, so the button and this
        // layout always agree about whether a drawer exists to open.
        .environment(\.sidebarIsPinned, isSidebarPinned)
        .environment(\.usesTopTabBar, Self.usesTopTabBar)
        // Resizing or rotating into the pinned layout while the drawer happened
        // to be open would otherwise leave a stale `.sidebar` overlay behind the
        // pinned column, dimming the content and eating taps.
        .onChange(of: isSidebarPinned) { _, pinned in
            if pinned, app.overlay == .sidebar { app.overlay = nil }
        }
        .onAppear {
            if app.tab != .search {
                lastContentTab = app.tab
            }
        }
        .task(id: profileTabAvatarTaskID) {
            await profileTabAvatar.load(isSignedIn: app.authed && !app.isGuest)
        }
        .task(id: app.authed) {
            // Populate the Message tab's unread badge without waiting for the
            // user to open the inbox.
            await inbox.load()
        }
        .onChange(of: app.tab) { _, newValue in
            // Re-entering the inbox refreshes the counts — things may have been
            // read elsewhere. It does *not* mark notifications read: the inbox
            // opens on 聊天 now, and clearing the badge for notifications nobody
            // has looked at is exactly the bug that caused. Selecting the 通知
            // pane is what marks them (see `ChatView`).
            guard newValue == .chat else { return }
            Task { await inbox.reload() }
        }
        .onChange(of: app.tab) { oldValue, newValue in
            // The search tab is a real tab; selecting it just shows the search
            // screen. The only special case left: while the node-scoped search
            // *overlay* is up, its close button shares the bottom-right corner
            // with the tab bar's search pill, and the UIKit pill wins that hit
            // test. That tap was aimed at the X — bounce the selection and
            // close the overlay.
            //
            // Currently unreachable: node-scoped search moved to a local
            // `fullScreenCover` (it has to — `app.overlay` draws under any
            // cover, and the node page can be inside one), so nothing sets
            // `.search` here now. Kept because the conflict it describes is
            // real and would come straight back with any app-level search
            // overlay.
            if newValue == .search, app.overlay == .search {
                app.tab = oldValue == .search ? lastContentTab : oldValue
                withAnimation(.overlayPush) {
                    app.overlay = nil
                }
                return
            }
            if newValue != .search {
                lastContentTab = newValue
            }
            if app.overlay == .browseNodes {
                app.overlay = nil
            }
        }
    }

    private var profileTabAvatarTaskID: String {
        "\(app.authed)-\(app.isGuest)-\(DiscourseAuth.shared.username ?? "")"
    }

    private func openSidebar() {
        guard app.overlay == nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            app.overlay = .sidebar
        }
    }

    private func closeSidebar() {
        withAnimation(.overlayPush) {
            app.overlay = nil
        }
    }

    private func openSidebarDragGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard app.overlay == nil else { return }
                guard isHorizontalSwipe(value, direction: .right, threshold: 72) else { return }

                let edgeWidth = min(96, max(44, containerWidth * 0.18))
                if value.startLocation.x <= edgeWidth || value.translation.width > 140 {
                    openSidebar()
                }
            }
    }

    private var closeSidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard app.overlay == .sidebar else { return }
                if isHorizontalSwipe(value, direction: .left, threshold: 64) {
                    closeSidebar()
                }
            }
    }

    private enum SwipeDirection {
        case left
        case right
    }

    private func isHorizontalSwipe(_ value: DragGesture.Value, direction: SwipeDirection, threshold: CGFloat) -> Bool {
        let horizontal = value.translation.width
        let vertical = abs(value.translation.height)
        let hasDirection = direction == .right ? horizontal > threshold : horizontal < -threshold
        return hasDirection && abs(horizontal) > vertical * 1.35
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if let overlay = app.overlay {
            switch overlay {
            case .sidebar, .browseNodes:
                EmptyView()
            case .post:
                ZStack {
                    Theme.bg.ignoresSafeArea()
                    PostDetailOverlay(postTransitionNamespace: postTransitionNamespace)
                }
                .environment(\.mediaAutoplayEnabled, true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(100)
            case .search:
                SearchOverlay(
                    postTransitionNamespace: postTransitionNamespace,
                    initialQuery: app.searchInitialQuery
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(90)
                // Consumed on open, so returning to search later starts blank
                // rather than still scoped to a node the user has left.
                .onDisappear { app.searchInitialQuery = "" }
            case .auth:
                AuthFlowOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(120)
            default:
                Group {
                    switch overlay {
                    case .sidebar: EmptyView()
                    case .post: EmptyView()
                    case .compose: ComposeOverlay()
                    case .search: EmptyView()
                    case .browseNodes: EmptyView()
                    case .createNode: CreateNodeOverlay()
                    case .notifications: NotificationsOverlay()
                    case .settings: SettingsOverlay()
                    case .appsDirectory: AppsDirectoryOverlay()
                    case .appDetail: AppDetailOverlay()
                    case .auth: EmptyView()
                    }
                }
                .transition(transition(for: overlay))
                .zIndex(10)
            }
        }
    }

    private func tabContent<Content: View>(
        for tab: Tab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()

            if app.overlay == .browseNodes {
                BrowseNodesOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        // A tab's videos are only allowed to play while that tab is the one on
        // screen and nothing is layered over it. The views stay mounted either
        // way, so without this a feed clip kept playing under an opened topic
        // and behind other tabs.
        .environment(\.mediaAutoplayEnabled, app.tab == tab && app.overlay == nil)
    }

    /// Which way an overlay arrives, chosen by what it *is* rather than
    /// uniformly.
    ///
    /// Pages come in from the trailing edge and modals from the bottom, which
    /// is the platform's own distinction: a push means "deeper into the same
    /// thing", a sheet means "a task on top of it". The drawer's destinations
    /// are pages, so they push; they used to rise from the bottom and read as
    /// modal.
    ///
    /// Note this only governs the overlays `MainView` draws. Pages presented as
    /// full-screen covers from `ContentView` — a node, a custom feed, a profile
    /// — are system presentations and always come up from the bottom; iOS
    /// exposes no way to redirect them.
    private func transition(for overlay: Overlay) -> AnyTransition {
        switch overlay {
        case .sidebar:
            return .move(edge: .leading)
        case .post:
            return .redditPost
        // Pages the drawer leads to. Trailing in *and* back out the same edge,
        // which is how a navigation push and its pop move — `.push(from:)`
        // would leave towards the opposite edge, like a carousel advancing
        // rather than a screen being dismissed.
        case .browseNodes, .appsDirectory, .appDetail:
            return .move(edge: .trailing).combined(with: .opacity)
        // Modals: a task with a cancel, which belongs on the bottom edge —
        // 创建节点 included, even though the drawer opens it.
        case .compose, .search, .createNode, .auth:
            return .move(edge: .bottom).combined(with: .opacity)
        case .notifications, .settings:
            return .opacity
        }
    }
}

private struct RedditPostTransitionModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(0.18 + progress * 0.82)
            .clipShape(RoundedRectangle(cornerRadius: (1 - progress) * 28, style: .continuous))
    }
}

private extension AnyTransition {
    static var redditPost: AnyTransition {
        .modifier(
            active: RedditPostTransitionModifier(progress: 0),
            identity: RedditPostTransitionModifier(progress: 1)
        )
    }
}

/// Draws `source` aspect-filled into a centered circle that occupies
/// `contentFraction` of a transparent square canvas. The transparent margin makes
/// the tab bar's scale-to-fit land the visible circle at an optical size
/// comparable to the SF Symbol tab icons. `.alwaysOriginal` keeps the photo's
/// real colors (the tab bar template-tints otherwise).
private func paddedCircularAvatar(from source: UIImage, scale: CGFloat) -> UIImage {
    let side: CGFloat = 40
    let contentFraction: CGFloat = 0.58
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    let rendered = renderer.image { _ in
        let diameter = side * contentFraction
        let inset = (side - diameter) / 2
        let circleRect = CGRect(x: inset, y: inset, width: diameter, height: diameter)
        UIBezierPath(ovalIn: circleRect).addClip()
        let aspect = max(diameter / source.size.width, diameter / source.size.height)
        let drawSize = CGSize(width: source.size.width * aspect, height: source.size.height * aspect)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        source.draw(in: CGRect(origin: origin, size: drawSize))
    }
    return rendered.withRenderingMode(.alwaysOriginal)
}

@MainActor
@Observable
final class ProfileTabAvatarStore {
    /// Shared so other screens (the post detail's header avatar) can show the
    /// current user without fetching /session/current again.
    static let shared = ProfileTabAvatarStore()
    private init() {}

    private let client = DiscourseClient()
    private var loadedUsername: String?
    /// The URL `tabImage` was rendered from, so a new one replaces it.
    private var renderedAvatarURL: URL?

    var username = ""
    var displayName = ""
    var avatarURL: URL?
    var isSignedIn = false
    /// Pre-rendered circular avatar for the tab bar (transparent-padded, original
    /// colors). Provided as a bare `Image` so the tab bar honors its colors.
    var tabImage: UIImage?

    var initial: String {
        let source = displayName.isEmpty ? username : displayName
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    var variant: Int {
        abs(username.hashValue)
    }

    func load(isSignedIn: Bool) async {
        guard isSignedIn, DiscourseAuth.shared.isAuthenticated else {
            clear()
            return
        }

        let currentUsername = DiscourseAuth.shared.username

        // A different account than the one this store is holding. Drop the old
        // identity *before* fetching the new one: `currentUser()` failing would
        // otherwise leave the previous user's name and face in place, and the
        // avatar URL still pointing at them.
        if let loadedUsername, loadedUsername != currentUsername {
            clear()
        }

        if let restoredUsername = currentUsername, !restoredUsername.isEmpty {
            username = restoredUsername
            displayName = restoredUsername
            self.isSignedIn = true
        }

        guard loadedUsername != currentUsername || avatarURL == nil else {
            await renderTabImage()
            return
        }

        do {
            let response = try await client.currentUser()
            let user = response.currentUser
            username = user.username
            displayName = user.name?.isEmpty == false ? user.name! : user.username
            avatarURL = user.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 96) }
            self.isSignedIn = true
            loadedUsername = user.username
            // Earliest point the account preference is available; the store
            // ignores it if this device has already chosen a mode.
            NodeReadingModeStore.shared.applyAccountPreference(user.userOption?.communityViewMode)
            // Same payload already carries every other preference, so settings
            // opens with real values instead of refetching.
            UserPreferencesStore.shared.apply(user.userOption)
        } catch {
            self.isSignedIn = !username.isEmpty
        }
        await renderTabImage()
    }

    /// Fetches the avatar and renders the tab-bar image once per URL.
    ///
    /// Keyed on the URL rather than on `tabImage == nil`, which is what the
    /// comment always claimed but not what the code did: guarding on the image
    /// meant this rendered once per launch, so signing out and into a second
    /// account kept the first account's face in the tab bar. Changing your own
    /// avatar went stale the same way.
    private func renderTabImage() async {
        guard let url = avatarURL else {
            // This account has no avatar. Drop any previous one rather than
            // leaving someone else's face above the initial-letter fallback.
            tabImage = nil
            renderedAvatarURL = nil
            return
        }
        guard renderedAvatarURL != url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            guard let source = UIImage(data: data) else { return }
            let scale = UITraitCollection.current.displayScale
            tabImage = paddedCircularAvatar(from: source, scale: scale > 0 ? scale : 3)
            renderedAvatarURL = url
        } catch {
            // Keep the SF Symbol fallback when the photo can't load.
        }
    }

    private func clear() {
        username = ""
        displayName = ""
        avatarURL = nil
        isSignedIn = false
        loadedUsername = nil
        tabImage = nil
        renderedAvatarURL = nil
    }
}

/// Preview helper: a signed-in app on a given tab/overlay.
private func mainPreview(tab: Tab = .home, overlay: Overlay? = nil) -> some View {
    let app = AppState()
    app.authed = true
    app.onboardingDone = true
    app.tab = tab
    app.overlay = overlay
    return MainView()
        .environment(app)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
}

#Preview("Home") { mainPreview(tab: .home) }
#Preview("Nodes") { mainPreview(tab: .nodes) }
#Preview("Search") { mainPreview(tab: .search) }
#Preview("Chat") { mainPreview(tab: .chat) }
#Preview("Profile") { mainPreview(tab: .profile) }
#Preview("Post") { mainPreview(overlay: .post) }
#Preview("Compose") { mainPreview(overlay: .compose) }
#Preview("Browse Nodes") { mainPreview(overlay: .browseNodes) }
#Preview("Create Node") { mainPreview(overlay: .createNode) }
#Preview("Sidebar") { mainPreview(overlay: .sidebar) }
#Preview("Notifications") { mainPreview(overlay: .notifications) }
#Preview("Search Overlay") { mainPreview(overlay: .search) }

private extension View {
    /// `.searchable`, applied only where it isn't a duplicate.
    ///
    /// On iPad the tab bar sits at the top and already carries the search tab,
    /// so `.searchable` put a second search affordance in the toolbar for the
    /// same destination. The tab is the one that survives: it is where search
    /// actually lives, and the field was only ever added for the phone, whose
    /// tab bar morphs into it.
    ///
    /// A modifier rather than an `if` around the whole chain, because the
    /// branches would otherwise be two different view types and every
    /// modifier after this one would have to be written twice.
    @ViewBuilder
    func searchFieldIfNeeded(
        enabled: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: String
    ) -> some View {
        if enabled {
            searchable(text: text, isPresented: isPresented, prompt: prompt)
        } else {
            self
        }
    }
}
