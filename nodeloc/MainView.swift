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
                        Image(systemName: "person")
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
        .onChange(of: app.tab) { oldValue, newValue in
            if newValue == .search {
                openSearchOverlay(restoring: oldValue == .search ? lastContentTab : oldValue)
                return
            }
            lastContentTab = newValue
            if app.overlay == .browseNodes {
                app.overlay = nil
            }
        }
    }

    private func openSearchOverlay(restoring tab: Tab) {
        let restoredTab = tab == .search ? lastContentTab : tab
        app.tab = restoredTab
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
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
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
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
                SearchOverlay(postTransitionNamespace: postTransitionNamespace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(90)
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
        case .compose, .search, .browseNodes, .createNode:
            return .move(edge: .bottom).combined(with: .opacity)
        case .notifications, .settings, .pro:
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
