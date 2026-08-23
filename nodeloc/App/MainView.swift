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
    /// Focus handle for the system search field in the tab bar.
    @FocusState private var searchFieldFocused: Bool
    /// Presentation state of the system search UI (field expanded, scope row
    /// and cancel visible). Distinct from focus: search can stay presented
    /// with the keyboard down.
    @State private var searchPresented = false
    @State private var profileTabAvatar = ProfileTabAvatarStore.shared
    /// Drives the Message tab's unread badge; shared with the inbox.
    @State private var inbox = MessageCenterStore.shared

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
                        Image(systemName: "bubble.left")
                        Text("Message")
                    }
                    .badge(inbox.unreadTotal)

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
                // Telegram-style search: the tab bar itself morphs into the
                // search field. Selecting the search pill activates search;
                // cancelling deselects it and restores the previous tab — all
                // system-managed, so there is no custom close button to fight
                // the pill for the bottom-right corner.
                .searchable(text: $app.searchQuery, isPresented: $searchPresented, prompt: "搜索")
                // The system scope row, shown at the top whenever search is
                // presented (the default only reveals it once text is typed).
                .searchScopes($app.searchScope, activation: .onSearchPresentation) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .onSubmit(of: .search) {
                    SearchHistoryStore.shared.record(app.searchQuery)
                }
                .tabViewSearchActivation(.searchTabSelection)
                .searchFocused($searchFieldFocused)
                // A tapped suggestion fills the query without presenting
                // search; present it so the scope row and cancel appear —
                // then retract the keyboard once the presentation settles,
                // since the results are already on screen.
                .onChange(of: app.searchActivationRequested) { _, requested in
                    guard requested else { return }
                    app.searchActivationRequested = false
                    searchPresented = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        searchFieldFocused = false
                    }
                }
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
        .task(id: app.authed) {
            // Populate the Message tab's unread badge without waiting for the
            // user to open the inbox.
            await inbox.load()
        }
        .onChange(of: app.tab) { _, newValue in
            // Re-entering the inbox refreshes counts (things may have been read
            // elsewhere) and clears the notifications badge.
            guard newValue == .chat else { return }
            Task {
                await inbox.reload()
                await inbox.markNotificationsRead()
            }
        }
        .onChange(of: app.tab) { oldValue, newValue in
            // The search tab is a real tab; selecting it just shows the search
            // screen. The only special case left: while the node-scoped search
            // *overlay* is up, its close button shares the bottom-right corner
            // with the tab bar's search pill, and the UIKit pill wins that hit
            // test. That tap was aimed at the X — bounce the selection and
            // close the overlay.
            if newValue == .search, app.overlay == .search {
                app.tab = oldValue == .search ? lastContentTab : oldValue
                withAnimation(.overlayPush) {
                    app.overlay = nil
                }
                return
            }
            if newValue == .search {
                // Selecting the pill focuses the field, but that doesn't
                // reliably flow back into the isPresented binding — and the
                // scope row keys off presentation. Assert it ourselves.
                searchPresented = true
            } else {
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
                    case .pro: ProOverlay()
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
        case .compose, .search, .browseNodes, .createNode, .appsDirectory, .auth:
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
final class ProfileTabAvatarStore {
    /// Shared so other screens (the post detail's header avatar) can show the
    /// current user without fetching /session/current again.
    static let shared = ProfileTabAvatarStore()
    private init() {}

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
            // Same payload already carries every other preference, so settings
            // opens with real values instead of refetching.
            UserPreferencesStore.shared.apply(user.userOption)
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
