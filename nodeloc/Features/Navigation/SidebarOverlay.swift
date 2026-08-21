//
//  SidebarOverlay.swift
//  nodeloc
//
//  The drawer: shortcuts, apps, custom feeds, recent nodes, and resources.
//

import SwiftUI

// MARK: - Sidebar

struct SidebarOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    let panelWidth: CGFloat?
    @State private var store = SidebarStore()

    init(panelWidth: CGFloat? = nil) {
        self.panelWidth = panelWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = panelWidth ?? min(proxy.size.width * 0.86, 330)

            sidebarPanel(
                width: panelWidth,
                topInset: proxy.safeAreaInsets.top,
                bottomInset: proxy.safeAreaInsets.bottom
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .task { await store.load(isSignedIn: isSignedIn) }
    }

    private func sidebarPanel(width: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topShortcuts

                    sidebarSection("推荐应用") {
                        appsSection
                    }

                    if isSignedIn {
                        sidebarSection("Custom Feed") {
                            customFeedsSection
                        }
                    }

                    sidebarSection("最近访问") {
                        recentNodesSection
                    }

                    sidebarSection("Resources") {
                        resourcesSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, topInset + 16)
                .padding(.bottom, bottomInset + 28)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 28, x: 10, y: 0)
        .ignoresSafeArea(edges: .vertical)
    }

    private var topShortcuts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(shortcutItems) { item in
                Button {
                    perform(item.action)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 24)
                        Text(item.title)
                            .font(Theme.body(14, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(item.isPrimary ? Theme.accent : Theme.text)
                    .padding(.horizontal, 11)
                    .frame(height: 46)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(item.isPrimary ? Theme.accent.opacity(0.34) : Theme.divider, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var appsSection: some View {
        VStack(spacing: 3) {
            ForEach(store.apps.prefix(5)) { item in
                sidebarImageRow(
                    title: item.name,
                    subtitle: "应用",
                    imageURL: item.logoURL,
                    fallbackIcon: "cube.fill",
                    tint: Theme.accent,
                    badge: nil
                ) {
                    perform(.openApp(item.slug))
                }
            }
            sidebarMenuRow(
                SidebarMenuItem(title: "浏览全部应用", subtitle: "Apps On NodeLoc", icon: "gamecontroller.fill", action: .browseApps)
            )
        }
    }

    private var customFeedsSection: some View {
        VStack(spacing: 3) {
            if store.customFeeds.isEmpty {
                emptySidebarRow("还没有 Custom Feed", icon: "rectangle.stack.badge.plus")
            } else {
                ForEach(store.customFeeds.prefix(6)) { feed in
                    sidebarColorRow(
                        title: feed.name,
                        subtitle: feed.description,
                        color: sidebarColor(feed.colorHex),
                        icon: "line.3.horizontal.decrease.circle.fill",
                        badge: feed.nodeCount.map { "\($0)" }
                    ) {
                        perform(.open(feed.url ?? "/custom-feeds"))
                    }
                }
            }

            sidebarMenuRow(
                SidebarMenuItem(title: "创建 Custom Feed", subtitle: "把多个节点组合成一个流", icon: "plus.circle.fill", action: .open("/custom-feeds"))
            )
        }
    }

    private var recentNodesSection: some View {
        VStack(spacing: 3) {
            ForEach(store.recentNodes.prefix(8)) { node in
                sidebarImageRow(
                    title: "n/\(node.slug)",
                    subtitle: node.name,
                    imageURL: node.logoURL,
                    fallbackIcon: "circle.grid.2x2.fill",
                    tint: sidebarColor(node.colorHex),
                    badge: node.isCreator ? "主理" : (node.memberCount.isEmpty ? nil : node.memberCount)
                ) {
                    perform(.open(node.url ?? "/n/\(node.slug)"))
                }
            }

            sidebarMenuRow(
                SidebarMenuItem(title: "浏览全部节点", subtitle: "Nodes", icon: "list.bullet", action: .browseNodes)
            )
        }
    }

    private var resourcesSection: some View {
        VStack(spacing: 3) {
            ForEach(store.resources) { resource in
                if resource.dividerAbove {
                    FadingRule()
                        .padding(.vertical, 0)
                }
                sidebarMenuRow(
                    SidebarMenuItem(title: resource.title, subtitle: resource.url, icon: mappedResourceIcon(resource.icon), action: .open(resource.url))
                )
            }
        }
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.48))
                .textCase(.uppercase)
                .padding(.horizontal, 8)

            content()
        }
    }

    private func sidebarMenuRow(_ item: SidebarMenuItem) -> some View {
        Button {
            perform(item.action)
        } label: {
            HStack(spacing: 12) {
                iconShell(systemName: item.icon, tint: Theme.text.opacity(0.88))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.body(15, weight: item.isPrimary ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badge = item.badge {
                    Text(badge)
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.selected, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                item.isPrimary ? Theme.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarImageRow(
        title: String,
        subtitle: String?,
        imageURL: URL?,
        fallbackIcon: String,
        tint: Color,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                sidebarIcon(imageURL: imageURL, fallbackIcon: fallbackIcon, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body(15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.body(11))
                            .foregroundStyle(Theme.muted(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(Theme.body(10, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.55))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarColorRow(
        title: String,
        subtitle: String?,
        color: Color,
        icon: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        sidebarImageRow(
            title: title,
            subtitle: subtitle,
            imageURL: nil,
            fallbackIcon: icon,
            tint: color,
            badge: badge,
            action: action
        )
    }

    private func emptySidebarRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            iconShell(systemName: icon, tint: Theme.muted(0.45))
            Text(title)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.54))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func sidebarIcon(imageURL: URL?, fallbackIcon: String, tint: Color) -> some View {
        Group {
            if let imageURL {
                CachedRemoteImage(url: imageURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: fallbackIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func iconShell(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            }
    }

    private func perform(_ action: SidebarAction) {
        withAnimation(.quick) {
            switch action {
            case .home:
                app.tab = .home
                app.overlay = nil
            case .hot:
                openSitePath("/top")
            case .browseNodes:
                app.overlay = .browseNodes
            case .createNode:
                app.overlay = .createNode
            case .open(let path):
                openSitePath(path)
            case .search:
                app.tab = .search
                app.overlay = nil
            case .browseApps:
                app.overlay = .appsDirectory
            case .openApp(let slug):
                openApp(slug: slug)
            }
        }
    }

    /// The sidebar row only carries a slug, so the app is fetched before the
    /// detail page opens.
    private func openApp(slug: String) {
        app.overlay = .appsDirectory
        Task {
            guard let fetched = try? await DiscourseClient().app(slug: slug).directoryApp else { return }
            app.selectedApp = fetched
            withAnimation(.quick) {
                app.overlay = .appDetail
            }
        }
    }

    private var isSignedIn: Bool {
        app.authed || DiscourseAuth.shared.isAuthenticated
    }

    private var shortcutItems: [SidebarMenuItem] {
        [
            SidebarMenuItem(title: "首页", subtitle: nil, icon: "house.fill", isPrimary: app.tab == .home, action: .home),
            SidebarMenuItem(title: "热门", subtitle: nil, icon: "flame.fill", action: .hot),
            SidebarMenuItem(title: "浏览节点", subtitle: nil, icon: "square.grid.2x2.fill", action: .browseNodes),
            SidebarMenuItem(title: "创建节点", subtitle: nil, icon: "plus.circle.fill", isPrimary: store.canCreateNode, action: .createNode)
        ]
    }

    private func openSitePath(_ path: String) {
        guard let url = nodelocSiteURL(path) else { return }
        openURL(url)
        app.overlay = nil
    }

    private func sidebarColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
        return Color(hex: value)
    }

    private func mappedResourceIcon(_ icon: String) -> String {
        switch icon {
        case "circle-info": return "info.circle"
        case "circle-question": return "questionmark.circle"
        case "file-lines": return "doc.text"
        case "shield-halved": return "shield"
        case "right-to-bracket": return "key"
        case "wallet": return "wallet.pass"
        case "rectangle-ad": return "megaphone"
        case "circle-check": return "checkmark.seal"
        case "heart": return "heart"
        case "handshake": return "hands.sparkles"
        default: return icon
        }
    }
}

private struct SidebarMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    var isPrimary: Bool = false
    var badge: String? = nil
    let action: SidebarAction
}

private enum SidebarAction {
    case home
    case hot
    case browseNodes
    case createNode
    case open(String)
    case search
    /// Opens the native app directory instead of the web category.
    case browseApps
    /// Opens one app's detail page by slug.
    case openApp(String)
}
