//
//  ProfileView.swift
//  nodeloc
//

import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    /// Shared so switching tabs doesn't discard the loaded profile.
    private var store = ProfileStore.shared
    /// Which sheet is up. A single `.sheet(item:)` rather than one modifier
    /// per sheet: several `.sheet` on the same view silently collapse to
    /// whichever was applied last, which is why the badge and upgrade sheets
    /// never opened.
    @State private var activeSheet: ProfileSheet?

    private enum ProfileSheet: String, Identifiable {
        case badges, nodes, upgrade
        var id: String { rawValue }
    }
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
                    if store.isShowingSkeleton {
                        profileSkeleton
                            .id(topAnchor)
                    } else {
                        profileHero
                            .id(topAnchor)
                        redditStatsRow

                        tabBar
                        tabContent
                            .padding(.top, 6)
                            .padding(.bottom, 112)
                    }
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
                // Hidden once its controls have moved into the iPad tab bar's
                // row, or they would appear twice.
                if !usesTopTabBar {
                    floatingHeaderButtons(scrollProxy: proxy)
                        .padding(.top, UIApplication.topSafeAreaInset)
                }
            }
            // Applied inside the ScrollViewReader because the identity capsule
            // scrolls back to the top, which needs this proxy.
            .tabBarHeader(isPinned: usesTopTabBar) {
                identityCapsule(scrollProxy: proxy)
                    .opacity(identityRevealProgress)
                    .allowsHitTesting(identityRevealProgress > 0.9)
            } trailing: {
                headerTools
            }
        }
        .task(id: app.authed) { await store.load(isAppAuthed: app.authed) }
        .task(id: tabTaskKey) { await store.loadTab(selectedTab) }
        // The tab has to be reloaded explicitly. `force` clears `actionItems`,
        // but `tabTaskKey` is username + tab — neither changes on a refresh, so
        // the `.task(id:)` above never re-runs and the list was left empty.
        .refreshable {
            await store.load(isAppAuthed: app.authed, force: true)
            await store.loadTab(selectedTab)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .badges: badgeSheet
            case .nodes: nodesSheet
            case .upgrade:
                if let progress = store.upgradeProgress {
                    UpgradeProgressSheet(report: progress)
                }
            }
        }
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
                .frame(height: bannerHeight + UIApplication.topSafeAreaInset + pullStretch)
                // On the banner rather than in the card: the banner spans the
                // full width, so its leading edge is the screen's, and its
                // bottom edge is the fixed reference the avatar is placed
                // against — both of which the column needs.
                .overlay(alignment: .bottomLeading) {
                    upgradeProgressColumn
                        .padding(.leading, progressTrackCentreX - progressTrackWidth / 2)
                        .offset(y: -(avatarCentreAboveBanner - progressTrackLength / 2))
                }
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

    // MARK: Skeleton

    /// The first open of an account, when there is no snapshot to draw instead.
    ///
    /// Shaped like `profileHero` + `redditStatsRow` + `tabBar` rather than being
    /// a generic shimmer, so the real page lands roughly where the placeholders
    /// were instead of shoving everything down when it arrives. One pulse on
    /// the container keeps every piece in phase, as on the feed.
    ///
    /// This replaces a screenful of `--`: `ProfileStat.placeholders` and the
    /// seeded initial used to be what a cold start showed, which reads as data
    /// that failed rather than data that is coming.
    private var profileSkeleton: some View {
        VStack(spacing: 18) {
            // Banner and card, including the card's overlap onto the banner —
            // the one piece of this layout that would be obvious if it moved.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.neutral300)
                    .frame(height: bannerHeight + UIApplication.topSafeAreaInset)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom, spacing: 12) {
                        Circle()
                            .fill(Theme.neutral300)
                            .frame(width: 76, height: 76)
                            .overlay { Circle().strokeBorder(Theme.bg, lineWidth: 4) }

                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonLine(widthFraction: 0.52, height: 18)
                            SkeletonLine(widthFraction: 0.34)
                        }
                        .padding(.bottom, 8)
                    }

                    SkeletonLine(widthFraction: 0.92)
                    SkeletonLine(widthFraction: 0.64)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                )
                .padding(.horizontal, 16)
                .offset(y: -54)
                .padding(.bottom, -54)
            }

            // Five evenly divided stats, as `redditStatsRow` lays them out.
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: 5) {
                        SkeletonLine(widthFraction: 0.46, height: 15)
                        SkeletonLine(widthFraction: 0.66, height: 9)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)

            // The five activity tabs.
            HStack(spacing: 24) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonLine(height: 14)
                        .frame(width: 32)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonLine(widthFraction: 0.88, height: 15)
                        SkeletonLine(widthFraction: 0.42)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 112)
        }
        .skeletonPulsing()
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

            headerTools
        }
        .padding(.horizontal, FloatingHeader.horizontalInset)
        .padding(.top, 8)
        .frame(height: headerBarHeight, alignment: .top)
    }

    /// 签到 · 设置 in one glass capsule, matching the node page and the post
    /// reader rather than floating separate circles. 升级进度 lives on the
    /// banner's bottom edge instead — see `upgradeProgressBar`.
    private var headerTools: some View {
        HStack(spacing: 6) {
            // Guests have nothing to sign in for.
            if !store.isGuest {
                Button {
                    Task { await store.checkIn() }
                } label: {
                    Group {
                        if store.isCheckingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            // The same mark the site's own checkin button
                            // uses. Dimmed once today is done — the control is
                            // disabled then, so it should read that way.
                            Image("LucideCalendarHeart")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 17, height: 17)
                                .foregroundStyle(store.hasCheckedInToday ? Theme.muted(0.35) : Theme.text)
                        }
                    }
                    .frame(width: 28, height: FloatingHeader.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(store.isCheckingIn || store.hasCheckedInToday)
                .accessibilityLabel(store.hasCheckedInToday ? AppString("今天已签到") : AppString("签到"))
            }

            Button { app.overlay = .settings } label: {
                toolIcon("gearshape")
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 8)
        // 7pt above/below a 34pt row reproduces what `.buttonStyle(.glass)`
        // does, so this capsule matches the hamburger's height exactly.
        .padding(.vertical, 7)
        .glassSurface(tint: FloatingHeader.glassTint, interactive: true)
        .shadow(color: FloatingHeader.shadow, radius: 9, y: 6)
    }

    private let progressTrackLength: CGFloat = 46
    private let progressTrackWidth: CGFloat = 3
    /// The avatar's centre, measured up from the banner's bottom edge: it is
    /// 96pt tall and lifted 42pt above the card's top, which the card in turn
    /// places 54pt above the banner's bottom. Keeping the column level with it
    /// is why this is derived rather than eyeballed.
    private let avatarCentreAboveBanner: CGFloat = 48

    /// Lines the track up with the hamburger above it. `.glass` grows a 34pt
    /// glyph into a 48pt circle, and that circle starts at the header's own
    /// inset — so its centre is the inset plus half of 48.
    private var progressTrackCentreX: CGFloat {
        FloatingHeader.horizontalInset + (FloatingHeader.controlHeight + 14) / 2
    }

    /// 升级进度 down the left edge of the banner: a vertical track that fills
    /// upward from the current level, named at the bottom, toward the level
    /// being climbed to, named at the top. Drawn in `Theme.text` at two
    /// strengths — so it inverts with the colour scheme — over a `Theme.bg`
    /// halo, which is what keeps it legible on top of banner artwork.
    /// Tapping opens the requirements.
    @ViewBuilder
    private var upgradeProgressColumn: some View {
        if !store.isGuest, let report = store.upgradeProgress, report.hasConditions {
            Button { activeSheet = .upgrade } label: {
                HStack(spacing: 7) {
                    Capsule()
                        .fill(Theme.text.opacity(0.28))
                        .frame(width: progressTrackWidth, height: progressTrackLength)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(Theme.text)
                                .frame(height: progressTrackLength * report.fraction)
                        }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(nextLevelLabel(report))
                        Spacer(minLength: 0)
                        Text(report.currentLevelName ?? AppString("当前等级"))
                    }
                    .frame(height: progressTrackLength, alignment: .leading)
                }
                .font(Theme.body(10, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 110, alignment: .leading)
                .contentShape(Rectangle())
                // A halo in the page colour, not a black drop shadow: it has to
                // separate the marks from a photo banner in both schemes.
                .shadow(color: Theme.bg.opacity(0.8), radius: 3)
                .shadow(color: Theme.bg.opacity(0.5), radius: 6)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("升级进度")
            .accessibilityValue("\(report.satisfiedCount)/\(report.allConditions.count)")
        }
    }

    /// At the top level there is no next level, and the requirements become
    /// upkeep — say that rather than showing a dash.
    private func nextLevelLabel(_ report: UpgradeProgressReport) -> String {
        if let next = report.nextLevelName, !next.isEmpty {
            return next
        }
        return report.isRetention
            ? AppString("维持中")
            : AppString("最高等级")
    }

    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 28, height: FloatingHeader.controlHeight)
            .contentShape(Rectangle())
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
                if store.isGuest {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.muted(0.4))
                        .frame(width: 26, height: 26)
                } else {
                    RemoteAvatar(
                        url: store.avatarURL,
                        letter: store.initial,
                        variant: abs(store.username.hashValue),
                        size: 26
                    )
                }
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

    /// Banner artwork. Scales to *cover* whatever height the hero gives it —
    /// enlarging a small image or shrinking a large one — then crops the
    /// overflow. It must not carry its own fixed height: the container is
    /// `bannerHeight` plus the status bar, so a hard-coded `bannerHeight` left
    /// the image short by the status bar, with gaps above and below.
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
            Group {
                if store.isGuest {
                    // The generic guest avatar, same as the post reader's.
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Theme.muted(0.4))
                        .frame(width: 96, height: 96)
                        .background(Theme.bg, in: Circle())
                } else {
                    RemoteAvatar(
                        url: store.avatarURL,
                        letter: store.initial,
                        variant: abs(store.username.hashValue),
                        size: 96
                    )
                }
            }
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
                    ForEach(store.roles) { role in
                        profileChip(role.label, color: roleColor(role))
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

    /// Guests still need a way into the login flow — the same glass 登录
    /// button the home header shows.
    private var guestLoginAction: some View {
        GuestLoginButton()
    }

    @ViewBuilder
    private var profileMeta: some View {
        let items = profileMetaItems
        if !items.isEmpty {
            // One row, wrapping only if it has to: 位置 and 网址 are each a few
            // words, and a line apiece left the card taller than the facts
            // justified. `FlowLayout` keeps them side by side on a normal phone
            // and drops the second one down when a long website would collide.
            FlowLayout(spacing: 14, alignment: .center) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        item.action()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text(item.text)
                                .font(Theme.body(12, weight: .medium))
                                .foregroundStyle(Theme.muted(0.62))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    /// 位置 opens Maps, 网址 opens the in-app browser. Both were plain text
    /// before, which read like links and did nothing.
    private var profileMetaItems: [(icon: String, text: String, action: () -> Void)] {
        var items: [(icon: String, text: String, action: () -> Void)] = []
        if let location = store.location, !location.isEmpty {
            items.append(("mappin.and.ellipse", location, { openInMaps(location) }))
        }
        if let website = store.website, !website.isEmpty {
            let url = store.websiteURL
            items.append(("link", website, { openProfileWebsite(url: url, displayText: website) }))
        }
        return items
    }

    // MARK: Achievements link + badge sheet

    private var achievementsLink: some View {
        Button { activeSheet = .badges } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.badgeDetails.prefix(3)) { badge in
                        ProfileBadgeIcon(badge: badge)
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
        .buttonStyle(.pressable)
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
        Button { activeSheet = .nodes } label: {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(store.recentNodes.prefix(3)) { node in
                        // The node's own logo, the same as the sheet shows —
                        // an initial on a colour disc was a placeholder that
                        // outlived the data being available.
                        NodeAvatar(node: node, size: 22, cornerRadius: 11)
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
        .buttonStyle(.pressable)
    }

    private var nodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.recentNodes) { node in
                        Button {
                            activeSheet = nil
                            app.tab = .nodes
                        } label: {
                            ProfileNodeRow(node: node)
                        }
                        .buttonStyle(.pressable)
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
                    Button { activeSheet = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet()
    }

    private var badgeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.badgeDetails) { item in
                        HStack(spacing: 12) {
                            ProfileBadgeIcon(badge: item, size: 44, cornerRadius: 12)

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
                    Button { activeSheet = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet()
    }


    // MARK: Reddit-style stats

    private var redditStatsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(store.stats.enumerated()), id: \.offset) { index, stat in
                VStack(spacing: 3) {
                    Text(stat.value)
                        .font(Theme.heading(17, weight: .bold))
                        .foregroundStyle(stat.isAccented ? Theme.accent : Theme.text)
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
                            Text(tab.label)
                                .font(Theme.body(14, weight: selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? Theme.text : Theme.muted(0.5))
                            Rectangle()
                                .fill(selectedTab == tab ? Theme.accent : Color.clear)
                                .frame(height: 2)
                                .clipShape(Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
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

                if store.tabsWithMore.contains(selectedTab) {
                    HStack {
                        ProgressView().tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        guard visible else { return }
                        Task { await store.loadMore(selectedTab) }
                    }
                }
            }
        } else if store.failedTabs.contains(selectedTab) {
            // A failed request is not an empty tab; offer the retry instead of
            // claiming there is nothing here.
            failedTab
        } else {
            emptyTab
        }
    }

    private var failedTab: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.muted(0.4))
            Text("加载失败")
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.55))
            Button {
                let tab = selectedTab
                Task { await store.loadTab(tab) }
            } label: {
                Text("重试")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
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
                Text(store.isGuest ? AppString("登录后查看你的能量历史") : AppString("暂无能量历史记录"))
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
                Text(entry.description ?? AppString("能量变动"))
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
                Text(item.title ?? AppString("无标题"))
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
        .buttonStyle(.pressable)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 16)
        }
    }

    private var emptyTab: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(store.isGuest ? AppString("登录后查看你的\(selectedTab.label)") : AppString("还没有\(selectedTab.label)"))
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

    /// Keyed on the role's kind, never on its label — the label is translated.
    private func roleColor(_ role: ProfileRole) -> Color {
        switch role.kind {
        case .admin, .moderator:
            return Theme.danger
        case .trustLevel(let level) where level >= 3:
            return Color(light: 0x8A36D6, dark: 0xC99BFF)
        case .guest:
            return Theme.muted(0.58)
        case .trustLevel:
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

// MARK: - 升级进度 (discourse-upgrade-process)

/// The full requirement list behind the banner's progress track.
private struct UpgradeProgressSheet: View {
    let report: UpgradeProgressReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary

                    if !statuses.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(statuses) { statusRow($0) }
                        }
                    }

                    if !metrics.isEmpty {
                        LazyVGrid(columns: metricColumns, spacing: 10) {
                            ForEach(metrics) { metricCard($0) }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("升级进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .standardSheet()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(Theme.heading(18, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text(report.isRetention
                 ? AppString("维持要求 \(report.satisfiedCount)/\(report.totalConditions ?? report.allConditions.count) 项达标")
                 : AppString("已满足 \(report.satisfiedCount)/\(report.totalConditions ?? report.allConditions.count) 项要求"))
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted(0.6))

            // At the top level the requirements are upkeep: falling behind
            // matters, so say so rather than implying there's nothing to do.
            if report.isRetention, !report.allMet {
                Label("有维持要求未达标", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            }

            ProgressView(value: report.fraction)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
    }

    private var headline: String {
        if report.isRetention {
            // Already at the top: this panel is about holding the level.
            if let level = report.currentLevelName {
                return AppString("\(level) · 维持中")
            }
            return AppString("等级维持")
        }
        if let next = report.nextLevelName {
            return AppString("距离 \(next) 还差一步")
        }
        return AppString("升级进度")
    }

    // MARK: Requirements

    private var metricColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    /// Yes/no requirements read as a list; everything countable is a card, two
    /// to a row — the same split the plugin's own panel makes.
    private var statuses: [UpgradeCondition] { ordered.filter(\.isStatus) }
    private var metrics: [UpgradeCondition] { ordered.filter { !$0.isStatus } }

    /// Unmet first: those are what the user opened this for. Sorted on the
    /// index as a tiebreak, since `sorted(by:)` gives no stability guarantee.
    private var ordered: [UpgradeCondition] {
        report.allConditions.enumerated()
            .sorted { lhs, rhs in
                let left = (lhs.element.met == true ? 1 : 0, lhs.offset)
                let right = (rhs.element.met == true ? 1 : 0, rhs.offset)
                return left < right
            }
            .map(\.element)
    }

    private func statusRow(_ condition: UpgradeCondition) -> some View {
        HStack(spacing: 10) {
            Image(systemName: condition.met == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(condition.met == true ? Theme.success : Theme.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text(condition.displayName)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.text)

                if let scope = condition.scope, !scope.isEmpty {
                    Text(scope)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.55))
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func metricCard(_ condition: UpgradeCondition) -> some View {
        let met = condition.met == true
        let tint = met ? Theme.success : Theme.accent

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Text(condition.displayName)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    // Reserved so both cards in a row are the same height even
                    // when one name wraps.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(met ? Theme.success : Theme.muted(0.3))
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(condition.value ?? 0))
                    .font(Theme.heading(19, weight: .bold))
                    .foregroundStyle(Theme.text)

                if let target = condition.target {
                    Text(condition.isLimit ? AppString("上限 \(number(target))") : AppString("目标 \(number(target))"))
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.5))
                }

                Spacer(minLength: 0)
            }

            ProgressView(value: condition.fraction)
                .tint(tint)

            Text(hint(for: condition))
                .font(Theme.body(10, weight: .medium))
                .foregroundStyle(met ? Theme.success : Theme.muted(0.55))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    /// The plugin's own wording, so the app and the site agree.
    private func hint(for condition: UpgradeCondition) -> String {
        if condition.met == true {
            return condition.isLimit ? AppString("未超限") : AppString("已达标")
        }
        let remaining = number(condition.shortfall)
        return condition.isLimit
            ? AppString("超出 \(remaining)")
            : AppString("还差 \(remaining)")
    }

    private func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
