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
    let node: SidebarNodeSummary
    let onClose: () -> Void

    @State private var store = NodeDetailStore()
    /// Shared and persisted, so the choice survives leaving the node and relaunching.
    private let readingMode = NodeReadingModeStore.shared
    @State private var descriptionExpanded = false
    @State private var showSortPicker = false
    @State private var showAbout = false
    @State private var scrollOffset: CGFloat = 0
    /// Media opened straight from a card, without entering the post.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    @State private var viewerVideo: PostVideo?
    /// The post whose media is open, for the viewer's chrome and actions.
    @State private var viewerMediaPost: Post?

    private let headerControlHeight: CGFloat = 34
    /// Extends below the floating buttons; the safe-area inset is added on top.
    private let bannerHeight: CGFloat = 78
    /// Anchor for the scroll-to-top the node capsule performs.
    private let topAnchor = "node-top"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                // Everything scrolls together: banner, node info, sort bar, list.
                ScrollView {
                    VStack(spacing: 0) {
                        banner
                            .id(topAnchor)
                        nodeSummary
                        modeBar
                        topicList
                            .padding(.bottom, 40)
                    }
                    // Root of the width chain. Without this the VStack sizes to its
                    // widest descendant and the ScrollView adopts that, so a single
                    // long title or description shifts the entire page sideways.
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh() }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    max(0, geo.contentOffset.y)
                } action: { _, newValue in
                    scrollOffset = newValue
                }

                // Floating chrome, kept clear of the status bar. The banner still
                // bleeds up behind it via its own safe-area padding.
                floatingHeader(scrollProxy: proxy)
                    .padding(.top, UIApplication.topSafeAreaInset)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(10)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .task(id: node.id) { await store.load(node: node) }
        .sheet(isPresented: $showSortPicker) { sortSheet }
        .sheet(isPresented: $showAbout) { aboutSheet }
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
    private func openMedia(for post: Post) {
        viewerMediaPost = post
        if let videoURL = post.videoURL {
            viewerVideo = PostVideo(src: videoURL.absoluteString, posterSrc: post.imageURL?.absoluteString)
            return
        }
        let images = post.media.map {
            PostImage(src: $0.url.absoluteString, width: $0.width, height: $0.height)
        }
        guard !images.isEmpty else {
            // No media to show; fall back to opening the topic.
            open(post)
            return
        }
        viewerImages = images
        viewerIndex = 0
    }

    /// Sort picker, presented like Reddit's "帖子排序依据" sheet.
    private var sortSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(store.availableSorts) { option in
                    Button {
                        showSortPicker = false
                        Task { await store.select(sort: option) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(store.sort == option ? Theme.accent : Theme.muted(0.55))
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(Theme.body(15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(option.detail)
                                    .font(Theme.body(11))
                                    .foregroundStyle(Theme.muted(0.5))
                            }

                            Spacer(minLength: 0)

                            if store.sort == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(store.sort == option ? Theme.accent.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationTitle("话题排序依据")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium])
    }

    /// Mirrors the web plugin's about panel: identity, description, the three
    /// counts, and the moderator list.
    private var aboutSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        NodeAvatar(node: node, size: 52, cornerRadius: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("n/\(store.slug)")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.muted(0.58))
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
                        aboutStat(store.memberCount, "成员")
                        aboutStat(store.topicCount, "主题")
                        aboutStat(store.postCount, "帖子")
                    }

                    if !store.moderators.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("版主")
                                .font(Theme.body(13, weight: .semibold))
                                .foregroundStyle(Theme.muted(0.6))

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
                                            .foregroundStyle(Theme.muted(0.55))
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
            .navigationTitle("关于节点")
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
                .foregroundStyle(Theme.muted(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private static func groupedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    // MARK: Header chrome

    /// 0 → 1 as the node header scrolls away, revealing the inline node pill.
    private var titleRevealProgress: CGFloat {
        min(max((scrollOffset - 50) / 70, 0), 1)
    }

    private func floatingHeader(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            FloatingHeaderButton(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.headerText)
                    .frame(width: headerControlHeight, height: headerControlHeight)
            }

            // Node identity, revealed once the header has scrolled past. Tapping
            // returns to the top, the same gesture as the profile capsule.
            FloatingHeaderButton(borderShape: .capsule) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy.scrollTo(topAnchor, anchor: .top)
                }
            } label: {
                HStack(spacing: 6) {
                    NodeAvatar(node: node, size: 22, cornerRadius: 11)
                    Text("n/\(store.slug)")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        // Long slugs shrink rather than widen the capsule: the
                        // row has ~74pt of slack on a 393pt screen and none on
                        // an SE, so growing here would clip the back button.
                        .minimumScaleFactor(0.75)
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(height: headerControlHeight)
            }
            // Claims its intrinsic width before the Spacer takes the rest;
            // without this the slug collapses to "n..." even with room to spare.
            .layoutPriority(1)
            // Only tappable once nearly opaque, matching the profile capsule, so
            // a faint capsule can't swallow taps meant for what's underneath.
            .allowsHitTesting(titleRevealProgress > 0.9)
            .opacity(titleRevealProgress)
            .accessibilityLabel("回到顶部")

            // All the slack sits between the pill and the tools, so the pill
            // stays next to the back button instead of floating in the centre.
            Spacer(minLength: 8)

            headerTools
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 新建 / 搜索 / 更多 in one glass capsule.
    ///
    /// The glass goes on the capsule with `.interactive()`, which is what gives
    /// the press response. The previous version layered `.plain` buttons over a
    /// capsule marked `allowsHitTesting(false)`, so neither the capsule nor the
    /// buttons could ever react — that inert glass layer was the bug.
    ///
    /// Three icons, not four: measured in a real host the row needs 319pt with
    /// three, against 320pt of usable width on an SE. 分享 lives in the menu.
    private var headerTools: some View {
        HStack(spacing: 6) {
            Button(action: startCompose) { toolIcon("plus") }
                .buttonStyle(.plain)
                .accessibilityLabel("在本节点发帖")

            Button(action: startNodeSearch) { toolIcon("magnifyingglass") }
                .buttonStyle(.plain)
                .accessibilityLabel("在本节点内搜索")

            Menu {
                nodeMenuContent
            } label: {
                toolIcon("ellipsis")
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 8)
        // Matches the node pill exactly: `.buttonStyle(.glass)` adds 7pt above
        // and below its 34pt label for a 48pt capsule, so this reproduces that
        // padding rather than pinning a height that would drift if the shared
        // control height changes.
        .padding(.vertical, 7)
        .glassEffect(
            .regular.tint(Theme.bg.opacity(0.34)).interactive(),
            in: .capsule
        )
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
    }

    /// A tap target inside the shared capsule. Narrower than the control height
    /// so three of them plus the node pill still fit on a small phone.
    private func toolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 28, height: headerControlHeight)
            .contentShape(Rectangle())
    }

    /// The node's public page, for sharing.
    private var nodeShareURL: URL {
        DiscourseConfig.baseURL.appending(path: "n/\(store.slug.isEmpty ? node.slug : store.slug)")
    }

    @ViewBuilder
    private var nodeMenuContent: some View {
        Button {
            showAbout = true
        } label: {
            Label("关于本节点", systemImage: "info.circle")
        }

        ShareLink(item: nodeShareURL) {
            Label("分享", systemImage: "square.and.arrow.up")
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

    /// Opens the composer with this node already chosen.
    private func startCompose() {
        app.composePreselectedNode = node
        withAnimation(.overlayPush) {
            app.overlay = .compose
        }
    }

    /// Opens search scoped to this node. `#slug` is Discourse's own category
    /// filter; the trailing space leaves the caret ready for the search terms.
    private func startNodeSearch() {
        let slug = store.slug.isEmpty ? node.slug : store.slug
        app.searchInitialQuery = "#\(slug) "
        withAnimation(.panelSlide) {
            app.overlay = .search
        }
    }

    /// Inline 加入 button, sitting on the name row like Reddit's.
    private var joinButton: some View {
        Button {
            Task { await store.toggleJoin() }
        } label: {
            HStack(spacing: 4) {
                if store.isTogglingJoin {
                    ProgressView().controlSize(.mini).tint(store.isJoined ? Theme.text : .white)
                } else if !store.isJoined {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                Text(store.isJoined ? "已加入" : "加入")
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundStyle(store.isJoined ? Theme.text : .white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(store.isJoined ? Theme.surface : Theme.text, in: Capsule())
            .overlay {
                if store.isJoined {
                    Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.isTogglingJoin)
    }

    // MARK: Banner + summary

    @ViewBuilder
    private var banner: some View {
        // Runs to the very top, behind the status bar and floating buttons.
        let height = bannerHeight + UIApplication.topSafeAreaInset
        return Group {
            if let backgroundURL = store.backgroundURL {
                CachedRemoteImage(url: backgroundURL) { image in
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
    }

    private var bannerFallback: some View {
        LinearGradient(
            colors: [nodeAccentColor(store.colorHex).opacity(0.55), nodeAccentColor(store.colorHex).opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(maxWidth: .infinity)
    }

    /// Reddit-style: logo + name + 加入 on one row, stats underneath, then the
    /// description with an expand toggle.
    private var nodeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                NodeAvatar(node: node, size: 52, cornerRadius: 26)
                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))

                VStack(alignment: .leading, spacing: 2) {
                    Text("n/\(store.slug)")
                        .font(Theme.heading(19, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(statsText)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.58))
                        .lineLimit(1)
                }
                // Yields width to the avatar and join button rather than
                // reporting the slug's intrinsic size.
                .frame(maxWidth: .infinity, alignment: .leading)

                joinButton
            }

            if !store.descriptionText.isEmpty {
                Text(store.descriptionText)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .lineLimit(descriptionExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    // Measured 455pt unbounded on a 393pt screen for
                    // n/chit-chat: without a width budget it drags the whole
                    // page sideways.
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.quick) { descriptionExpanded.toggle() }
                } label: {
                    Text(descriptionExpanded ? "收起" : "查看更多内容")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Color(light: 0x2F6DF6, dark: 0x7EA7FF))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// "每周 47 千位访客 · 758 个贡献" style line under the name.
    private var statsText: String {
        var parts: [String] = []
        if let members = store.memberCount { parts.append("\(compact(members)) 位成员") }
        if let topics = store.topicCount { parts.append("\(compact(topics)) 主题") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    // MARK: Reading mode bar

    private var modeBar: some View {
        HStack(spacing: 10) {
            Button { showSortPicker = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.sort.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.sort.label)
                        .font(Theme.body(13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.5))
                }
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Menu {
                // Writes go through the store rather than straight to a
                // @State, so the choice is persisted for next launch.
                Picker("阅读模式", selection: Binding(
                    get: { readingMode.mode },
                    set: { readingMode.select($0) }
                )) {
                    ForEach(NodeReadingMode.allCases) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
            } label: {
                Image(systemName: readingMode.mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: Topics

    @ViewBuilder
    private var topicList: some View {
        if store.isLoading && store.posts.isEmpty {
            NodelocLoader(progress: nil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.posts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.35))
                Text(store.errorText ?? "还没有主题")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.5))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.posts) { post in
                    NodeTopicRow(
                        post: post,
                        mode: readingMode.mode,
                        onTap: { open(post) },
                        onMediaTap: { openMedia(for: post) }
                    )
                }

                if store.isLoadingMore {
                    ProgressView().tint(Theme.accent).padding(.vertical, 20)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { Task { await store.loadMore() } }
                }
            }
            // A LazyVStack sizes to its widest child, and the ScrollView then
            // adopts that. Bounding the stack itself gives every row a real
            // width to lay out within, instead of each row's content deciding.
            .frame(maxWidth: .infinity)
        }
    }

    private func open(_ post: Post) {
        app.selectedPost = post
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
    }

}

/// Node logo, falling back to a colored initial.
/// One topic, rendered per reading mode.
private struct NodeTopicRow: View {
    let post: Post
    let mode: NodeReadingMode
    let onTap: () -> Void
    /// Card mode only: media opens straight into its own viewer, skipping the
    /// post. Nil elsewhere, where a tap anywhere should open the topic.
    var onMediaTap: (() -> Void)?

    /// Measured, not assumed — the card's own width, minus its padding.
    @State private var mediaWidth: CGFloat = 0

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
            switch mode {
            case .compact, .expand:
                Button(action: onTap) {
                    if mode == .compact { compactRow } else { expandRow }
                }
                .buttonStyle(.plain)

            case .card:
                // Not a Button: the media inside needs its own tap target, and a
                // nested Button inside a Button doesn't reliably take precedence.
                // A tap gesture on the container plus one on the media does.
                cardRow
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        // Backstop for the whole row. A ScrollView adopts its widest child as
        // the content width, so one row that reports an oversized minimum drags
        // every sibling out with it.
        .clampedToWidth()
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
                        .foregroundStyle(Theme.muted(0.5))
                    Text("·").foregroundStyle(Theme.muted(0.35))
                    Text(post.time)
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted(0.45))
                }
            }

            Spacer(minLength: 8)

            Text("\(post.comments)")
                .font(Theme.body(13, weight: .semibold))
                .foregroundStyle(post.comments > 0 ? Theme.accent : Theme.muted(0.4))
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
        }
    }

    /// Reddit "expand": author line, then title + tags on the left with a small
    /// square thumbnail on the right, then the action row.
    private var expandRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(Theme.heading(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        // Vertical-only fixedSize: the horizontal axis must stay
                        // flexible or a long CJK title (measured at 873pt on a
                        // real chit-chat post) reports that as its width.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !post.tags.isEmpty {
                        tagBadges
                    }
                }
                // Takes the width left over beside the thumbnail rather than
                // its content's intrinsic size, which is what lets the title
                // wrap instead of pushing the row wider.
                .frame(maxWidth: .infinity, alignment: .leading)

                if let imageURL = post.imageURL {
                    CachedRemoteImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.neutral300
                    }
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

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
                FeedVideoTile(url: videoURL, posterURL: post.imageURL, onTap: onMediaTap)
            } else if let imageURL = post.imageURL {
                // Reddit-style: the card takes the image's own shape rather
                // than a fixed height, so portrait photos aren't letterboxed
                // and panoramas aren't cropped to a sliver.
                CachedRemoteImage(url: imageURL) { image in
                    image.resizable()
                } placeholder: {
                    Theme.neutral300
                }
                .filledBanner(
                    height: cardMediaHeight,
                    clip: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                // Opens the image viewer rather than the post.
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Inside the horizontal padding, so this is the media's own width.
            proxy.size.width - 28
        } action: { width in
            mediaWidth = width
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    /// Topic tags, styled like Reddit's flair chips.
    private var tagBadges: some View {
        HStack(spacing: 6) {
            ForEach(post.tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(Theme.body(11, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .lineLimit(1)
                    // Three capsules of unbounded text can exceed the screen.
                    // Truncating a long tag is better than widening the page.
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
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
                .foregroundStyle(Theme.muted(0.46))
                .fixedSize()
            if post.pinned {
                Label("置顶", systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Label("\(post.baseVotes)", systemImage: "arrow.up")
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
            Label("\(post.comments)", systemImage: "bubble.right")
                .labelStyle(CompactLabelStyle())
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
            Spacer(minLength: 0)
        }
    }
}
