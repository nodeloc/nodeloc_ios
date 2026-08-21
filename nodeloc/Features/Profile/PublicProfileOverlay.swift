//
//  PublicProfileOverlay.swift
//  nodeloc
//
//  Another user's profile.
//

import SwiftUI

// MARK: - Public profile

struct PublicProfileOverlay: View {
    let target: UserProfileTarget
    let onClose: () -> Void
    @State private var store = PublicProfileStore()

    @State private var showBadges = false
    @State private var showNodes = false
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                    profileHero
                    statsRow

                    Section {
                        tabContent
                            .padding(.top, 6)
                            .padding(.bottom, 34)
                    } header: {
                        tabBar
                    }
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y)
            } action: { _, newValue in
                scrollOffset = newValue
            }

            floatingHeader
                .frame(maxWidth: .infinity, alignment: .top)
                .zIndex(10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: target.id) { await store.load(target: target) }
        .task(id: "\(store.username)-\(selectedTab.rawValue)") { await store.loadTab(selectedTab) }
        .sheet(isPresented: $showBadges) { badgeSheet }
        .sheet(isPresented: $showNodes) { nodesSheet }
    }

    // MARK: Floating header (matches the post reader's chrome)

    private let headerControlHeight: CGFloat = 34
    private let headerHorizontalInset: CGFloat = 16
    private let headerGlassTint = Theme.bg.opacity(0.34)
    private let headerShadow = Color.black.opacity(0.08)

    /// 0 → 1 as the banner scrolls away, revealing the inline user pill.
    private var userRevealProgress: CGFloat {
        min(max((scrollOffset - 60) / 80, 0), 1)
    }

    private var floatingHeader: some View {
        HStack(spacing: 8) {
            headerGlassButton(borderShape: .circle, action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: headerControlHeight, height: headerControlHeight)
            }

            userPill
                .opacity(userRevealProgress)
                .offset(y: (1 - userRevealProgress) * -4)

            Spacer(minLength: 0)

            headerTools
        }
        .padding(.horizontal, headerHorizontalInset)
        .padding(.top, 8)
    }

    /// Avatar + username, revealed between the back button and the tool pill.
    private var userPill: some View {
        headerGlassButton(borderShape: .capsule, action: {}) {
            HStack(spacing: 6) {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: 22
                )
                Text(store.displayName)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: headerControlHeight)
        }
        .allowsHitTesting(false)
    }

    /// Search / share / more in one glass capsule. Same construction as the post
    /// reader's tool cluster: a native glass button provides the capsule, with
    /// the tappable icons layered on top.
    private var headerTools: some View {
        ZStack {
            headerGlassButton(borderShape: .capsule, action: {}) {
                headerToolsChrome
                    .opacity(0)
            }
            .allowsHitTesting(false)

            headerToolsContent
        }
    }

    private var headerToolsChrome: some View {
        HStack(spacing: 4) {
            headerToolIcon("magnifyingglass")
            headerToolIcon("square.and.arrow.up")
            headerToolIcon("ellipsis")
        }
        .padding(.horizontal, 7)
        .frame(height: headerControlHeight)
    }

    private var headerToolsContent: some View {
        HStack(spacing: 4) {
            Button {} label: { headerToolIcon("magnifyingglass") }
                .buttonStyle(.plain)
            Button {} label: { headerToolIcon("square.and.arrow.up") }
                .buttonStyle(.plain)
            Button {} label: { headerToolIcon("ellipsis") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .frame(height: headerControlHeight)
    }

    private func headerToolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
    }

    /// Native glass button, matching the post reader and home header chrome.
    private func headerGlassButton<Label: View>(
        borderShape: ButtonBorderShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(height: headerControlHeight)
        }
        .buttonStyle(.glass(.regular.tint(headerGlassTint)))
        .buttonBorderShape(borderShape)
        .shadow(color: headerShadow, radius: 9, y: 6)
    }

    /// Banner height, including the area behind the status bar.
    private var bannerHeight: CGFloat { 188 + UIApplication.topSafeAreaInset }

    private var profileHero: some View {
        VStack(spacing: 0) {
            // Runs to the very top, behind the status bar and floating header.
            profileBanner

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -58)
                .padding(.bottom, -58)
        }
    }


    /// Fixed-height banner: a tall image is aspect-filled then cropped to
    /// `bannerHeight` rather than pushing the content below it down.
    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: bannerHeight)
                    .clipped()
            } placeholder: {
                profileBannerFallback
            }
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        ZStack {
            Theme.surface
            Image(systemName: "at")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(Theme.muted(0.08))
        }
        .frame(maxWidth: .infinity)
        .frame(height: bannerHeight)
    }

    /// 关注 / 取关 toggle backed by the discourse-follow endpoints.
    private var followButton: some View {
        Button {
            Task { await store.toggleFollow() }
        } label: {
            HStack(spacing: 4) {
                if store.isTogglingFollow {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(store.isFollowing ? Theme.text : .white)
                } else {
                    Image(systemName: store.isFollowing ? "checkmark" : "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(store.isFollowing ? "已关注" : "关注")
                    .font(Theme.body(12, weight: .semibold))
            }
            .foregroundStyle(store.isFollowing ? Theme.text : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(store.isFollowing ? Theme.surface : Theme.accent, in: Capsule())
            .overlay {
                if store.isFollowing {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isTogglingFollow)
    }

    private var profileCard: some View {
        VStack(spacing: 12) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 96
            )
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
            .offset(y: -44)
            .padding(.bottom, -36)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.displayName)
                        .font(Theme.heading(24, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let title = store.title, !title.isEmpty {
                        titleBadge(title)
                    }
                }

                HStack(spacing: 6) {
                    Text("@\(store.username)")
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.62))

                    if let flair = store.flair {
                        FlairBadge(flair: flair)
                    }

                    if let followers = store.followerCount {
                        Text("·")
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.38))
                        Text("\(followers) 粉丝")
                            .font(Theme.body(14, weight: .semibold))
                            .foregroundStyle(Theme.muted(0.62))
                    }

                    if store.canFollow {
                        followButton
                    }
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, dot: true)
                profilePill(store.joined)
            }

            if !store.roles.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    ForEach(store.roles, id: \.self) { role in
                        profileChip(role, color: roleColor(role))
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.badges.isEmpty || !store.topCategories.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    if !store.badges.isEmpty { achievementsLink }
                    if !store.topCategories.isEmpty { nodesLink }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }

            profileMeta

            if store.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 2)
            } else if let errorText = store.errorText {
                Text(errorText)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    /// 头衔 with its admin-designed style, beside the display name. Plain text —
    /// the style itself (color + effect) carries the emphasis, no chrome.
    @ViewBuilder
    private func titleBadge(_ title: String) -> some View {
        if let style = store.titleStyle {
            StyledTitleText(text: title, style: style)
                .lineLimit(1)
        } else {
            Text(title)
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
    }

    private var achievementsLink: some View {
        Button { showBadges = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(0..<min(3, store.badges.count), id: \.self) { index in
                        Circle()
                            .fill(badgeColor(index))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Image(systemName: "rosette")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.badges.count) 项徽章")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var nodesLink: some View {
        Button { showNodes = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.topCategories.prefix(3)) { node in
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Text(node.letter)
                                    .font(Theme.heading(10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.topCategories.count) 个节点")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func badgeColor(_ index: Int) -> Color {
        let colors: [Color] = [
            Color(light: 0xD99A00, dark: 0xF8D34B),
            Color(light: 0x2F6DF6, dark: 0x7EA7FF),
            Color(light: 0x8A36D6, dark: 0xC99BFF),
            Color(light: 0x1FA36B, dark: 0x5FD6A0)
        ]
        return colors[index % colors.count]
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(store.badgeDetails.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(badgeColor(index).opacity(0.14))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "rosette")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(badgeColor(index))
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("徽章")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.topCategories) { node in
                        HStack(spacing: 12) {
                            Avatar(letter: node.letter, variant: node.variant, size: 44, cornerRadius: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.name)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                if !node.desc.isEmpty {
                                    Text(node.desc)
                                        .font(Theme.body(12))
                                        .foregroundStyle(Theme.muted(0.6))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(node.members)
                                .font(Theme.body(11, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.48))
                        }
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("常去节点")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var profileMeta: some View {
        let items = [store.location, store.website].compactMap { value in
            value?.isEmpty == false ? value : nil
        }
        if !items.isEmpty {
            HStack(spacing: 14) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item == store.website ? "link" : "mappin.and.ellipse")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                        Text(item)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Reddit-style stat row, matching the 我的 page.
    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.stats.enumerated()), id: \.offset) { index, stat in
                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(Theme.heading(17, weight: .bold))
                        .foregroundStyle(stat.label == "能量" || stat.label == "声望" ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(Theme.body(10, weight: .medium))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)

                if index < store.stats.count - 1 {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1, height: 26)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(ProfileStore.ProfileTab.allCases) { tab in
                    Button {
                        withAnimation(.quick) { selectedTab = tab }
                    } label: {
                        VStack(spacing: 7) {
                            Text(tab.rawValue)
                                .font(Theme.body(14, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? Theme.text : Theme.muted(0.5))
                            Rectangle()
                                .fill(selectedTab == tab ? Theme.accent : Color.clear)
                                .frame(height: 2)
                                .clipShape(Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == .energy {
            if store.loadingTab == .energy && store.pointsHistory.isEmpty {
                loadingRow
            } else if store.pointsHistory.isEmpty {
                emptyTab(icon: "bolt.slash", text: "暂无能量历史记录")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.pointsHistory) { pointsRow($0) }
                }
            }
        } else if store.loadingTab == selectedTab && (store.actionItems[selectedTab]?.isEmpty ?? true) {
            loadingRow
        } else if let items = store.actionItems[selectedTab], !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { activityRow($0) }
            }
        } else {
            emptyTab(icon: "tray", text: "还没有\(selectedTab.rawValue)")
        }
    }

    private var loadingRow: some View {
        ProgressView()
            .tint(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
    }

    private func emptyTab(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(text)
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title ?? "无标题")
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            let excerpt = DiscourseFormat.plainText(item.excerpt ?? "")
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Text(DiscourseFormat.relative(item.createdAt))
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.muted(0.45))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func pointsRow(_ entry: PointsHistoryEntry) -> some View {
        let points = entry.points ?? 0
        let positive = entry.isPositive ?? (points > 0)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.description ?? "能量变动")
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.date.map { String($0.prefix(10)) } ?? DiscourseFormat.relative(entry.createdAt))
                    .font(Theme.body(11, weight: .medium))
                    .foregroundStyle(Theme.muted(0.45))
            }
            Spacer(minLength: 8)
            Text(positive ? "+\(points)" : "\(points)")
                .font(Theme.heading(16, weight: .bold))
                .foregroundStyle(positive ? Theme.accent : Theme.danger)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private func profilePill(_ text: String, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(Theme.muted(0.32))
                    .frame(width: 8, height: 8)
            }
            Text(text)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.hover, in: Capsule())
    }

    private func profileChip(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "ADMIN", "MOD": return Theme.danger
        case "REGULAR", "LEADER": return Color(light: 0x8A36D6, dark: 0xC99BFF)
        default: return Color(light: 0x2F6DF6, dark: 0x7EA7FF)
        }
    }
}
