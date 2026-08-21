//
//  MainView.swift
//  nodeloc
//
//  Tab container + floating bottom nav + full-screen overlays.
//

import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @Namespace private var postTransitionNamespace
    @State private var lastContentTab: Tab = .home
    @State private var profileTabAvatar = ProfileTabAvatarStore()

    var body: some View {
        @Bindable var app = app

        GeometryReader { proxy in
            let sidebarWidth = min(proxy.size.width * 0.86, 330)
            let sidebarOpen = app.overlay == .sidebar

            ZStack(alignment: .leading) {
                Theme.bg.ignoresSafeArea()

                if sidebarOpen {
                    SidebarOverlay(panelWidth: sidebarWidth)
                        .gesture(closeSidebarDragGesture)
                        .zIndex(0)
                }

                TabView(selection: $app.tab) {
                    SwiftUI.Tab(value: Tab.home) {
                        tabContent {
                            HomeView(postTransitionNamespace: postTransitionNamespace)
                        }
                    } label: {
                        Image(systemName: "house")
                        Text("Home")
                    }

                    SwiftUI.Tab(value: Tab.nodes) {
                        tabContent {
                            BrowseNodesOverlay(showsCloseButton: false)
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                        Text("节点")
                    }

                    SwiftUI.Tab(value: Tab.chat) {
                        tabContent {
                            ChatView()
                        }
                    } label: {
                        Image(systemName: "bell")
                        Text("Message")
                    }

                    SwiftUI.Tab(value: Tab.profile) {
                        tabContent {
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
                        tabContent {
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
                .tabBarMinimizeBehavior(.onScrollDown)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay {
                    if sidebarOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                            .gesture(closeSidebarDragGesture)
                    }
                }
                .offset(x: sidebarOpen ? sidebarWidth : 0)
                .shadow(color: sidebarOpen ? .black.opacity(0.12) : .clear, radius: 24, x: -8, y: 0)
                .simultaneousGesture(openSidebarDragGesture(containerWidth: proxy.size.width))
                .zIndex(1)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: sidebarOpen)
        }
        .overlay {
            overlayLayer
        }
        .onAppear {
            if app.tab != .search {
                lastContentTab = app.tab
            }
        }
        .task(id: profileTabAvatarTaskID) {
            await profileTabAvatar.load(isSignedIn: app.authed && !app.isGuest)
        }
        .onChange(of: app.tab) { oldValue, newValue in
            if newValue == .search {
                // Selecting Search while its overlay is already up means the
                // tap landed on the tab bar rather than the close button — the
                // two share the bottom-right corner. Bounce the selection back
                // without reopening, or the overlay the user is dismissing
                // immediately returns.
                guard app.overlay != .search else {
                    app.tab = oldValue == .search ? lastContentTab : oldValue
                    return
                }
                openSearchOverlay(restoring: oldValue)
                return
            }
            lastContentTab = newValue
            if app.overlay == .browseNodes {
                app.overlay = nil
            }
        }
    }

    private var profileTabAvatarTaskID: String {
        "\(app.authed)-\(app.isGuest)-\(DiscourseAuth.shared.username ?? "")"
    }

    /// Opens the search overlay and moves the tab selection off `.search`.
    ///
    /// The selection must not stay on `.search`: that tab's own content is a
    /// full `SearchView` in screen mode, so leaving it selected means closing
    /// the overlay simply reveals a near-identical search screen underneath and
    /// the close button looks like it did nothing.
    private func openSearchOverlay(restoring tab: Tab) {
        let restoredTab = tab == .search ? lastContentTab : tab
        app.tab = restoredTab
        withAnimation(.panelSlide) {
            app.overlay = .search
        }
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
                    case .pro: ProOverlay()
                    case .appsDirectory: AppsDirectoryOverlay()
                    case .appDetail: AppDetailOverlay()
                    }
                }
                .transition(transition(for: overlay))
                .zIndex(10)
            }
        }
    }

    private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()

            if app.overlay == .browseNodes {
                BrowseNodesOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
    }

    private func transition(for overlay: Overlay) -> AnyTransition {
        switch overlay {
        case .sidebar:
            return .move(edge: .leading)
        case .post:
            return .redditPost
        case .compose, .search, .browseNodes, .createNode, .appsDirectory:
            return .move(edge: .bottom).combined(with: .opacity)
        case .notifications, .settings, .pro, .appDetail:
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
private final class ProfileTabAvatarStore {
    private let client = DiscourseClient()
    private var loadedUsername: String?

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

        if let restoredUsername = DiscourseAuth.shared.username, !restoredUsername.isEmpty {
            username = restoredUsername
            displayName = restoredUsername
            self.isSignedIn = true
        }

        guard loadedUsername != DiscourseAuth.shared.username || avatarURL == nil else {
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
        } catch {
            self.isSignedIn = !username.isEmpty
        }
        await renderTabImage()
    }

    /// Fetches the avatar and renders the tab-bar image once per URL.
    private func renderTabImage() async {
        guard tabImage == nil, let url = avatarURL else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            guard let source = UIImage(data: data) else { return }
            let scale = UITraitCollection.current.displayScale
            tabImage = paddedCircularAvatar(from: source, scale: scale > 0 ? scale : 3)
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
#Preview("Pro") { mainPreview(overlay: .pro) }
#Preview("Notifications") { mainPreview(overlay: .notifications) }
#Preview("Search Overlay") { mainPreview(overlay: .search) }
