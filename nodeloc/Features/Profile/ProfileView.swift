//
//  ProfileView.swift
//  nodeloc
//

import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    /// Shared so switching tabs doesn't discard the loaded profile.
    private var store = ProfileStore.shared
    @State private var showBadges = false
    @State private var showNodes = false
    @State private var selectedTab: ProfileStore.ProfileTab = .topics
    @State private var scrollOffset: CGFloat = 0

    /// Anchor for the scroll-to-top the identity capsule performs.
    private let topAnchor = "profile-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Nothing pins: the tab bar scrolls with the content. Sticking
                // it required a top safe-area inset, and that inset is what
                // stopped the banner reaching the top of the screen.
                LazyVStack(spacing: 18) {
                    profileHero
                        .id(topAnchor)
                    redditStatsRow

                    tabBar
                    tabContent
                        .padding(.top, 6)
                        .padding(.bottom, 112)
                }
            }
            .scrollIndicators(.hidden)
            // The scroll view extends under the status bar so the banner fills
            // it. `.ignoresSafeArea` has to be here, not on the banner: a child
            // cannot escape the scroll view's own safe-area inset.
            .ignoresSafeArea(edges: .top)
            .background(Theme.bg)
            // Raw offset, not clamped: pulling down gives a negative value,
            // which is what stretches the banner.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                scrollOffset = newValue
            }
            // Pinned above the scroll view so they stay reachable as the banner
            // scrolls away, matching the home feed's floating controls. The
            // overlay sits on the ignored area, so it re-applies the inset
            // itself — otherwise the buttons land under the notch.
            .overlay(alignment: .top) {
                floatingHeaderButtons(scrollProxy: proxy)
                    .padding(.top, topSafeArea)
            }
        }
        .task(id: app.authed) { await store.load(isAppAuthed: app.authed) }
        .task(id: tabTaskKey) { await store.loadTab(selectedTab) }
        .refreshable { await store.load(isAppAuthed: app.authed, force: true) }
        .sheet(isPresented: $showBadges) { badgeSheet }
        .sheet(isPresented: $showNodes) { nodesSheet }
    }

    /// Re-run tab loading when either the selected tab or the loaded user changes.
    private var tabTaskKey: String { "\(store.username)-\(selectedTab.rawValue)" }

    private let bannerHeight: CGFloat = 176

    private var profileHero: some View {
        VStack(spacing: 0) {
            // Extends to the physical top: the scroll view ignores the top
            // safe area, so the banner's own frame already covers the status
            // bar. Its height grows to match, keeping the avatar's overlap.
            profileBanner
                .frame(height: bannerHeight + topSafeArea + pullStretch)
                // Pinned to the top of the scroll content while it grows, so
                // pulling down never opens a gap above the image.
                .offset(y: -pullStretch)
                .padding(.bottom, -pullStretch)

            profileCard
                .padding(.horizontal, 16)
                .offset(y: -54)
                .padding(.bottom, -54)
        }
    }

    /// Stays put while the page scrolls. The identity capsule fades in between
    /// the buttons once the profile card has scrolled past.
    private func floatingHeaderButtons(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            SidebarMenuButton()

            Spacer(minLength: 8)

            identityCapsule(scrollProxy: scrollProxy)
                .opacity(identityRevealProgress)
                // Rises into place rather than just appearing.
                .offset(y: (1 - identityRevealProgress) * 6)
                // Not tappable while invisible, or it would swallow taps meant
                // for whatever is beneath it.
                .allowsHitTesting(identityRevealProgress > 0.9)

            Spacer(minLength: 8)

            HeaderIconButton(systemName: "gearshape", accessibilityLabel: "设置") {
                app.overlay = .settings
            }
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.top, 8)
        .frame(height: headerBarHeight, alignment: .top)
    }

    /// Avatar + username, shown once the big card is out of view. Uses the same
    /// glass capsule as the post reader's node pill. Tapping returns to the top,
    /// which is the usual gesture for a collapsed title.
    private func identityCapsule(scrollProxy: ScrollViewProxy) -> some View {
        FloatingHeaderButton(borderShape: .capsule) {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy.scrollTo(topAnchor, anchor: .top)
            }
        } label: {
            HStack(spacing: 8) {
                RemoteAvatar(
                    url: store.avatarURL,
                    letter: store.initial,
                    variant: abs(store.username.hashValue),
                    size: 26
                )
                Text(store.displayName)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 14)
            .frame(height: FloatingHeader.controlHeight)
        }
        .accessibilityLabel("回到顶部")
    }

    /// Fades the capsule in as the card's display name slides behind the header
    /// bar. Measured, not guessed: the name sits at content y ≈ 190, which
    /// passes under the floating buttons at a scroll of ≈ 81 — so the window is
    /// 90…140 rather than something that would leave both names visible at once.
    private var identityRevealProgress: CGFloat {
        min(max((scrollOffset - 90) / 50, 0), 1)
    }

    /// Extra banner height while the user overscrolls downward. Zero at rest
    /// and when scrolling up, so it only ever grows the image.
    private var pullStretch: CGFloat {
        max(0, -scrollOffset)
    }

    /// Height reserved for the floating button row.
    private var headerBarHeight: CGFloat { FloatingHeader.controlHeight + 16 }

    /// Status-bar height, added back wherever the ignored safe area needs it.
    private var topSafeArea: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .max() ?? 0
    }

    /// Banner artwork. Scales to *cover* whatever height the hero gives it —
    /// enlarging a small image or shrinking a large one — then crops the
    /// overflow. It must not carry its own fixed height: the container is
    /// `bannerHeight + topSafeArea`, so a hard-coded `bannerHeight` left the
    /// image short by the status bar, with gaps above and below.
    @ViewBuilder
    private var profileBanner: some View {
        if let backgroundURL = store.backgroundURL {
            CachedRemoteImage(url: backgroundURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                profileBannerFallback
            }
            // Fills the frame the hero sets, then trims the excess. Without the
            // clip a filled image reports its scaled size and widens the page.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            profileBannerFallback
        }
    }

    private var profileBannerFallback: some View {
        ZStack {
            Theme.surface
            HStack {
                Spacer()
                Image(systemName: "at")
                    .font(.system(size: 118, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.08))
                    .rotationEffect(.degrees(-8))
                    .padding(.trailing, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
    }

    private var profileCard: some View {
        VStack(spacing: 14) {
            RemoteAvatar(
                url: store.avatarURL,
                letter: store.initial,
                variant: abs(store.username.hashValue),
                size: 96
            )
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
            .offset(y: -42)
            .padding(.bottom, -34)

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
                }
            }

            HStack(spacing: 8) {
                profilePill(store.lastSeen, icon: "circle.fill", iconColor: store.isGuest ? Theme.muted(0.38) : Theme.accent)
                profilePill(store.joined, icon: "calendar")
            }

            if !store.roles.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    ForEach(store.roles, id: \.self) { role in
                        profileChip(role, color: roleColor(role))
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.badges.isEmpty || !store.recentNodes.isEmpty {
                FlowLayout(spacing: 8, alignment: .center) {
                    if !store.badges.isEmpty {
                        achievementsLink
                    }
                    if !store.recentNodes.isEmpty {
                        recentNodesLink
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !store.bio.isEmpty {
                Text(store.bio)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.text.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            profileMeta

            if store.isGuest {
                guestLoginAction
                    .padding(.top, 2)
            }

            if store.isLoading {
                ProgressView()
                    .tint(Theme.accent)
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

    /// Guests still need a way into the login flow.
    private var guestLoginAction: some View {
        Button {
            withAnimation(.quick) {
                app.isGuest = false
                app.authed = false
            }
        } label: {
            Label("登录", systemImage: "person.crop.circle.badge.checkmark")
                .font(Theme.body(13, weight: .semibold))
                .frame(height: 34)
                .padding(.horizontal, 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var profileMeta: some View {
        let items = profileMetaItems
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text(item.text)
                            .font(Theme.body(12, weight: .medium))
                            .foregroundStyle(Theme.muted(0.62))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    private var profileMetaItems: [(icon: String, text: String)] {
        var items: [(icon: String, text: String)] = []
        if let location = store.location, !location.isEmpty {
            items.append(("mappin.and.ellipse", location))
        }
        if let website = store.website, !website.isEmpty {
            items.append(("link", website))
        }
        return items
    }

    // MARK: Achievements link + badge sheet

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

    /// 头衔 next to the display name. Uses the admin-designed style from
    /// discourse-custom-badge when one is configured for the user's group/badge.
    /// Plain text — the color/effect carries the emphasis, no background chrome.
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

    /// Recently visited nodes, styled like the achievements pill.
    private var recentNodesLink: some View {
        Button { showNodes = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.recentNodes.prefix(3)) { node in
                        Circle()
                            .fill(profileNodeColor(node.colorHex))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Text(String(node.name.prefix(1)))
                                    .font(Theme.heading(10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    }
                }
                Text("\(store.recentNodes.count) 个节点")
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

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.recentNodes) { node in
                        Button {
                            showNodes = false
                            app.tab = .nodes
                        } label: {
                            ProfileNodeRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("最近访问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNodes = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(badgeSheetItems) { item in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(badgeColor(item.index).opacity(0.14))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "rosette")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(badgeColor(item.index))
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showBadges = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private struct BadgeSheetItem: Identifiable {
        let id: Int
        let index: Int
        let name: String
        let description: String
    }

    private var badgeSheetItems: [BadgeSheetItem] {
        if !store.badgeDetails.isEmpty {
            return store.badgeDetails.enumerated().map {
                BadgeSheetItem(id: $1.id, index: $0, name: $1.name, description: $1.description)
            }
        }
        return store.badges.enumerated().map {
            BadgeSheetItem(id: $0, index: $0, name: $1, description: "")
        }
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

    // MARK: Reddit-style stats

    private var redditStatsRow: some View {
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

    // MARK: Sticky activity tabs

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
            energyContent
        } else if store.loadingTab == selectedTab && (store.actionItems[selectedTab]?.isEmpty ?? true) {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
        } else if let items = store.actionItems[selectedTab], !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { activityRow($0) }
            }
        } else {
            emptyTab
        }
    }

    /// 能量 history from the discourse-points-service plugin.
    @ViewBuilder
    private var energyContent: some View {
        if store.loadingTab == .energy && store.pointsHistory.isEmpty {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
        } else if store.pointsHistory.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.35))
                Text(store.isGuest ? "登录后查看你的能量历史" : "暂无能量历史记录")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.pointsHistory) { pointsRow($0) }
            }
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
                Text(pointsDate(entry))
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

    /// Prefers the event's own date; falls back to the created timestamp.
    private func pointsDate(_ entry: PointsHistoryEntry) -> String {
        if let date = entry.date, !date.isEmpty {
            return String(date.prefix(10))
        }
        return DiscourseFormat.relative(entry.createdAt)
    }

    private func activityRow(_ item: UserActionItem) -> some View {
        Button { openAction(item) } label: {
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

                HStack(spacing: 6) {
                    Image(systemName: activityIcon(item))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(DiscourseFormat.relative(item.createdAt))
                        .font(Theme.body(11, weight: .medium))
                        .foregroundStyle(Theme.muted(0.45))
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private var emptyTab: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(store.isGuest ? "登录后查看你的\(selectedTab.rawValue)" : "还没有\(selectedTab.rawValue)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    private func activityIcon(_ item: UserActionItem) -> String {
        switch item.actionType {
        case 1: return "heart.fill"
        case 3: return "bookmark.fill"
        case 4: return "doc.text.fill"
        case 5: return "arrowshape.turn.up.left.fill"
        default: return "circle.fill"
        }
    }

    private func openAction(_ item: UserActionItem) {
        guard let topicId = item.topicId else { return }
        let author = item.name?.isEmpty == false ? item.name! : (item.username ?? "?")
        app.selectedPost = Post(
            id: topicId,
            node: "",
            avatarLetter: String(author.prefix(1)).uppercased(),
            variant: abs(author.hashValue) % 2,
            time: DiscourseFormat.relative(item.createdAt),
            title: item.title ?? "",
            excerpt: DiscourseFormat.plainText(item.excerpt ?? ""),
            baseVotes: 0,
            comments: 0,
            hasImage: false,
            authorUsername: item.username,
            authorName: item.name
        )
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
    }

    private func profilePill(_ text: String, icon: String, iconColor: Color = Theme.muted(0.46)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: icon == "circle.fill" ? 8 : 11, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(text)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.bg, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
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
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "ADMIN", "MOD":
            return Theme.danger
        case "REGULAR", "LEADER":
            return Color(light: 0x8A36D6, dark: 0xC99BFF)
        case "GUEST":
            return Theme.muted(0.58)
        default:
            return Color(light: 0x2F6DF6, dark: 0x7EA7FF)
        }
    }
}

/// Node accent color from a Discourse category hex string.
private func profileNodeColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let value = UInt32(cleaned, radix: 16) else { return Theme.accent }
    return Color(hex: value)
}

/// Row in the "最近访问" sheet.
private struct ProfileNodeRow: View {
    let node: SidebarNodeSummary

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(node.description)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Text(node.memberCount)
                .font(Theme.body(11, weight: .semibold))
                .foregroundStyle(Theme.muted(0.48))
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if let logoURL = node.logoURL {
            RemoteAvatar(url: logoURL, letter: letter, size: 44, cornerRadius: 12)
        } else {
            let tint = profileNodeColor(node.colorHex)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(letter)
                        .font(Theme.heading(17, weight: .bold))
                        .foregroundStyle(tint)
                }
        }
    }

    private var letter: String { String(node.name.prefix(1)) }
}

#Preview {
    let app = AppState()
    app.authed = true
    app.onboardingDone = true
    return ProfileView()
        .environment(app)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
}
