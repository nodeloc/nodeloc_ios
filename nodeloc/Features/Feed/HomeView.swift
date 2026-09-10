//
//  HomeView.swift
//  nodeloc
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    /// Decided once by MainView; drives whether the bar's leading slot holds
    /// the menu button or the wordmark.
    @Environment(\.sidebarIsPinned) private var sidebarIsPinned
    @Environment(\.usesTopTabBar) private var usesTopTabBar
    let postTransitionNamespace: Namespace.ID
    @State private var feed = FeedStore()
    @State private var lastOffset: CGFloat = 0
    @State private var headerHiddenAmount: CGFloat = 0
    /// Content offset when the current drag started, so its direction can be
    /// judged on release. Nil between drags.
    @State private var dragStartOffset: CGFloat?
    @State private var selectedProfile: UserProfileTarget?
    /// Same store as the node pages, so one choice drives every list.
    private var readingMode = NodeReadingModeStore.shared
    /// Watched for the default-homepage choice.
    private var preferences = UserPreferencesStore.shared

    init(postTransitionNamespace: Namespace.ID) {
        self.postTransitionNamespace = postTransitionNamespace
    }

    var body: some View {
        feedBody
            .tabBarHeader(isPinned: usesTopTabBar) {
                // The mark, not the wordmark. In the tab bar's own row the
                // wordmark reads as a title for the row rather than as the
                // app, and on iPad portrait it was doing that directly above
                // a tab bar that already says where you are.
                toolbarLeadingMark
            } trailing: {
                // No glass of our own here: the toolbar already puts each item
                // in a glass container on iOS 26, and ours nested a circle
                // inside that rounded rectangle.
                headerTrailingAction(inToolbar: true)
            }
    }

    private var feedBody: some View {
        ZStack(alignment: .top) {
            // Feed
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: usesTopTabBar ? 0 : headerHeight)

                    if showsLoader {
                        feedSkeleton
                    } else if feed.visiblePosts.isEmpty {
                        // Load failed or nothing came back: say so instead of
                        // an unexplained blank screen.
                        feedUnavailable
                    } else {
                        ForEach(feed.visiblePosts) { post in
                            switch readingMode.mode {
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
                                    mode: readingMode.mode,
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
            .refreshable { await feed.load() }
            .task { await feed.loadIfNeeded() }
            // Settings is an overlay over this view, so `task` won't run again
            // when it closes. Reload the moment the choice changes instead.
            .onChange(of: preferences.homeFeed) { _, _ in
                Task { await feed.load() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                handleScroll(newValue)
            }
            // The wordmark comes back on a released flick, not on any downward
            // drag — see `handleScrollPhase`.
            .onScrollPhaseChange { oldPhase, newPhase, context in
                handleScrollPhase(from: oldPhase, to: newPhase, context: context)
            }

            if app.overlay != .post, !usesTopTabBar {
                persistentHeaderButtons
            }

            if let selectedProfile {
                PublicProfileOverlay(target: selectedProfile) {
                    withAnimation(.overlayPush) {
                        self.selectedProfile = nil
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(30)
            }
        }
        // The page colour, safe area included.
        //
        // Every row paints `Theme.bg` itself, but the strip above the first
        // one — the status bar and the 56pt spacer the floating header sits
        // over — was painted by nobody, so it showed the window's black. In
        // dark mode that is a visible seam at 107pt: pure black above,
        // 0x0B0F0E below. In light mode white-on-white hid it, which is why it
        // read as "only dark mode is wrong".
        .background(Theme.bg.ignoresSafeArea())
    }

    private let headerHeight: CGFloat = 56
    private let logoHeight: CGFloat = 30
    /// Release speed, in points per second, that counts as a flick rather than
    /// a drag. Empirical: a deliberate flick leaves the finger at well over a
    /// thousand, while easing the list back down sits near zero.
    private let flickRevealSpeed: CGFloat = 500

    /// First load with nothing to show yet — the skeleton stands in for it.
    private var showsLoader: Bool {
        feed.visiblePosts.isEmpty && feed.isLoading
    }

    /// 1 when the header is fully shown, 0 once it has scrolled away.
    private var logoRevealProgress: CGFloat {
        guard headerHeight > 0 else { return 1 }
        return 1 - min(max(headerHiddenAmount / headerHeight, 0), 1)
    }

    // MARK: Scroll → collapse behaviour

    private func handleScroll(_ top: CGFloat) {
        let last = lastOffset
        lastOffset = top
        let delta = top - last

        if top <= 0 {
            revealHeader(animated: true)
            return
        }

        if delta > 0 {
            headerHiddenAmount = min(headerHeight, max(0, headerHiddenAmount + delta))
            if headerHiddenAmount >= headerHeight, top > 32, !app.navCollapsed {
                withAnimation(.spring(duration: 0.3)) { app.navCollapsed = true }
            }
        } else if delta < 0, top < headerHeight {
            // Within the header's own height the wordmark just tracks the
            // offset. Further down the feed a downward drag deliberately does
            // *nothing* — only a flick brings it back, decided on release in
            // `handleScrollPhase`.
            headerHiddenAmount = min(headerHiddenAmount, max(0, top))
            if headerHiddenAmount == 0, app.navCollapsed {
                withAnimation(.spring(duration: 0.3)) { app.navCollapsed = false }
            }
        }
    }

    /// Reveals the wordmark only when a downward drag is *released with
    /// momentum*: easing the list back down leaves the header hidden, a flick
    /// snaps it back. Replaces a per-frame delta threshold, which couldn't tell
    /// a slow drag from a fast one reliably — one slow finger can produce the
    /// same 14pt step as a flick, just less often.
    ///
    /// Direction is taken from the offset travelled during the drag, not from
    /// the sign of `velocity`: Apple's own `onScrollPhaseChange` example works
    /// that way, and the vector's sign convention isn't documented. Only the
    /// magnitude comes from the velocity.
    ///
    /// The `top <= 0` branch in `handleScroll` stays the safety net — reaching
    /// the very top always reveals the header, even if no flick is recognised.
    private func handleScrollPhase(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        context: ScrollPhaseChangeContext
    ) {
        if newPhase == .interacting {
            dragStartOffset = context.geometry.contentOffset.y
            return
        }

        guard oldPhase == .interacting, let start = dragStartOffset else { return }
        dragStartOffset = nil

        // Negative travel means the content moved back toward the top, which is
        // a downward drag.
        let travelled = context.geometry.contentOffset.y - start
        let speed = abs(context.velocity?.dy ?? 0)
        guard travelled < 0, speed >= flickRevealSpeed else { return }
        revealHeader(animated: true)
    }

    private func revealHeader(animated: Bool) {
        let changes = {
            headerHiddenAmount = 0
            app.navCollapsed = false
        }

        if animated {
            withAnimation(.spring(duration: 0.26)) { changes() }
        } else {
            changes()
        }
    }

    // MARK: Header

    /// Always the plain wordmark: the skeleton (first load) and the system
    /// refresh spinner are the loading signals, so the header stays still.
    private var headerWordmark: some View {
        Image("NodelocWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: logoHeight)
            .accessibilityLabel("NodeLoc")
    }

    /// The phone's floating header. Unused while the sidebar is pinned: there
    /// the menu button is gone and both the wordmark and the trailing action
    /// have moved into the tab bar's own row as toolbar items.
    private var persistentHeaderButtons: some View {
        HStack {
            SidebarMenuButton()

            Spacer()

            // Scrolls up out of the way with the header, while the glass
            // buttons stay pinned.
            headerWordmark
                .opacity(logoRevealProgress)
                .offset(y: -(1 - logoRevealProgress) * headerHeight * 0.6)

            Spacer()

            headerTrailingAction(inToolbar: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The app mark, for the tab bar's leading slot.
    ///
    /// Tappable only where there is a drawer to open: pinned, the sidebar is
    /// already a column and a button that does nothing is worse than a logo.
    @ViewBuilder
    private var toolbarLeadingMark: some View {
        if sidebarIsPinned {
            Image("NodelocMark")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 26)
                .accessibilityLabel("NodeLoc")
        } else {
            SidebarMenuButton()
        }
    }

    /// 发帖 for members, 登录 for guests — posting needs an account either way.
    /// Shared so the floating header and the iPad toolbar show the same control.
    ///
    /// - Parameter inToolbar: drops this view's own glass, because a toolbar
    ///   item on iOS 26 already sits in a glass container and the two nest
    ///   visibly — a circle inside a rounded rectangle.
    @ViewBuilder
    private func headerTrailingAction(inToolbar: Bool) -> some View {
        Group {
            if app.isGuest {
                GuestLoginButton()
            } else {
                composeButton(inToolbar: inToolbar)
            }
        }
    }

    @ViewBuilder
    private func composeButton(inToolbar: Bool) -> some View {
        let label = Image(systemName: "plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 34, height: 34)

        // Not `glassButton(tint: nil)` for the toolbar case: an untinted glass
        // is still a glass, and what doubles up there is the glass itself
        // rather than its colour.
        if inToolbar {
            Button {
                withAnimation(.overlayPush) { app.overlay = .compose }
            } label: {
                label
            }
        } else {
            Button {
                withAnimation(.overlayPush) { app.overlay = .compose }
            } label: {
                label
            }
            .glassButton(tint: Theme.accent.opacity(0.14), shape: .circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
    }

    private func openPost(_ post: Post) {
        app.markTopicOpened(id: post.id)
        app.selectedPost = post
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
    }

    /// Friendly failure/empty state with a retry, shown when the first load
    /// produced nothing (usually no network).
    private var feedUnavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: feed.errorText == nil ? "tray" : "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.muted(0.35))
            Text(feed.errorText ?? AppString("暂时没有内容"))
                .font(Theme.body(14))
                .foregroundStyle(Theme.muted(0.55))
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
            switch readingMode.mode {
            case .card:
                ForEach(0..<3, id: \.self) { _ in cardSkeleton }
            case .compact:
                ForEach(0..<10, id: \.self) { _ in compactSkeleton }
            case .expand:
                ForEach(0..<5, id: \.self) { _ in expandSkeleton }
            }
        }
        .skeletonPulsing()
    }

    /// Mirrors PostCard: author line, title, media block, action pills.
    private var cardSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.neutral300).frame(width: 26, height: 26)
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
        .padding(.horizontal, 14)
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

    /// Mirrors NodeTopicRow's expand row: author line, title next to a square
    /// thumbnail, then the action pills.
    private var expandSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.neutral300).frame(width: 24, height: 24)
                SkeletonLine(widthFraction: 0.3)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(widthFraction: 1, height: 15)
                    SkeletonLine(widthFraction: 0.7, height: 15)
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.neutral300)
                    .frame(width: 78, height: 78)
            }
            HStack(spacing: 8) {
                Capsule().fill(Theme.neutral300).frame(width: 80, height: 28)
                Capsule().fill(Theme.neutral300).frame(width: 56, height: 28)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

// MARK: - Post card

struct PostCard: View {
    @Environment(AppState.self) private var app
    let post: Post
    let postTransitionNamespace: Namespace.ID
    /// Opens the author's public profile; nil disables the avatar tap.
    var onOpenAuthor: ((UserProfileTarget) -> Void)? = nil
    @State private var selectedMediaIndex = 0
    @State private var voteFaces = VoteFaces.shared
    /// Which arrow's face picker is open on this card, if any.
    @State private var pickingFaces: VoteDirection?
    /// Which arrow is under a finger, for the pressed state.
    @State private var pressingFaces: VoteDirection?
    @State private var showsMoreSheet = false
    /// Media opened straight from the card, without entering the post.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    @State private var viewerVideo: PostVideo?
    /// Resolved node, so the player's header shows the same logo as elsewhere.
    @State private var nodeSummary: SidebarNodeSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            postHeader
            postBody
            mediaPreview
            actionRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .matchedGeometryEffect(
            id: postTransitionID(post.id),
            in: postTransitionNamespace,
            properties: .frame,
            anchor: .center,
            isSource: app.overlay != .post || app.selectedPost.id != post.id
        )
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
        app.markTopicOpened(id: post.id)
        app.selectedPost = post
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
    }

    /// New/unread for the signed-in user, unless opened this session.
    private var showsUnreadDot: Bool {
        post.isUnread && !app.locallyReadTopicIDs.contains(post.id)
    }

    /// Opens the tapped media directly rather than the post.
    private func openMedia(at index: Int) {
        if let videoURL = post.videoURL {
            viewerVideo = PostVideo(src: videoURL.absoluteString, posterSrc: post.imageURL?.absoluteString)
            return
        }
        let images = mediaItems.map {
            PostImage(src: $0.url.absoluteString, width: $0.width, height: $0.height)
        }
        guard !images.isEmpty else { return }
        viewerImages = images
        viewerIndex = min(max(index, 0), images.count - 1)
    }

    private var postHeader: some View {
        HStack(spacing: 7) {
            let avatar = RemoteAvatar(
                url: post.avatarURL,
                letter: post.avatarLetter,
                variant: post.variant,
                size: 26
            )

            if let onOpenAuthor, let target = post.authorProfileTarget {
                Button { onOpenAuthor(target) } label: { avatar }
                    .buttonStyle(.pressable)
            } else {
                avatar
            }

            if showsUnreadDot {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
            }

            Text(post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Text("· \(post.time)")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted(0.46))
                .lineLimit(1)

            if app.isPinned(post) {
                Label(post.pinnedGlobally ? AppString("全站置顶") : AppString("置顶"), systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }

            Spacer(minLength: 0)

            Button {
                showsMoreSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.4))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableIcon)
            .sheet(isPresented: $showsMoreSheet) {
                TopicMoreSheet(post: post) { startRepost() }
            }
        }
    }

    private var postBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(post.title)
                .font(Theme.heading(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if !post.excerpt.isEmpty {
                Text(post.excerpt)
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
            FeedVideoTile(url: videoURL, posterURL: post.imageURL) {
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

    /// Up / score / down. Two tap targets in one capsule — the arrows were a
    /// single button before, so the down arrow was decoration.
    private var votePill: some View {
        let score = app.voteScore(for: post)
        let direction = app.voteDirection(for: post)
        return HStack(spacing: 7) {
            // Arrow and score share one hit region, as in the reader's control:
            // the number belongs to the upvote next to it.
            voteArrow(target: .up, direction: direction, score: score) {
                HStack(spacing: 7) {
                    voteGlyph(target: .up, direction: direction, score: score)

                    Text("\(score ?? app.voteCount(post))")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.74))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1, height: 14)

            voteArrow(target: .down, direction: direction, score: score) {
                voteGlyph(target: .down, direction: direction, score: score)
            }
            .opacity(post.canVoteDown || score == nil ? 1 : 0.4)
            .disabled(score != nil && !post.canVoteDown)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Theme.neutral300, in: Capsule())
        .sheet(item: $pickingFaces) { target in
            VoteFacePicker(direction: target) { face in
                pickingFaces = nil
                app.castVote(target, on: post, reaction: face)
            }
        }
    }

    /// Wraps a region that votes in one direction. A plain view with two
    /// gestures, not a Button: see `VoteControl.votable` — a button swallows the
    /// long press, and making it simultaneous casts a vote on release as well as
    /// opening the picker.
    private func voteArrow<Content: View>(
        target: VoteDirection,
        direction: VoteDirection,
        score: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(7)
            .contentShape(Rectangle())
            .padding(-7)
            .scaleEffect(pressingFaces == target ? 0.88 : 1)
            .opacity(pressingFaces == target ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: pressingFaces)
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                if score == nil {
                    // No vote data: the up arrow is still the like it used to
                    // be, and the down arrow has nothing sensible to do.
                    if target == .up { app.toggleLike(post) }
                } else {
                    app.castVote(direction.next(target), on: post)
                }
            }
            // Hold for the faces, as in the reader. Only where the plugin drives
            // the row: with no score there's no vote to flavour.
            // `onPressingChanged` also drives the pressed state above: these are
            // gestures, not buttons, so nothing else would answer the touch.
            .onLongPressGesture(
                minimumDuration: 0.32,
                perform: {
                    guard score != nil, !voteFaces.faces(for: target).isEmpty else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    pickingFaces = target
                },
                onPressingChanged: { isPressing in
                    pressingFaces = isPressing ? target : nil
                }
            )
    }

    private func voteGlyph(target: VoteDirection, direction: VoteDirection, score: Int?) -> some View {
        let isCast = score == nil
            ? (target == .up && app.isLiked(post))
            : direction == target
        return Image(VoteControl.assetName(for: target, filled: isCast))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 17, height: 17)
            .foregroundStyle(tint(target: target, direction: direction, score: score))
    }

    private func tint(target: VoteDirection, direction: VoteDirection, score: Int?) -> Color {
        if score == nil {
            return target == .up && app.isLiked(post) ? Theme.accent : Theme.muted(0.5)
        }
        guard direction == target else { return Theme.muted(0.45) }
        return target == .down ? Theme.accent2 : Theme.accent
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
        HStack(spacing: 8) {
            // The pill always looked like a vote control; now both arrows are
            // real. `voteScore` nil means discourse-vote doesn't cover this
            // category, and the row falls back to the like it always was.
            votePill

            // Opens the topic, where replies live. The card's own tap does the
            // same thing, but a count that looks like a button should behave
            // like one.
            Button(action: openPost) {
                FeedActionPill(systemImage: "bubble.left", text: "\(post.comments)")
            }
            .buttonStyle(.pressable)

            ShareLink(item: topicURL) {
                FeedActionPill(systemImage: "arrowshape.turn.up.right", text: AppString("分享"))
            }
            .buttonStyle(.pressable)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var mediaItems: [PostMedia] {
        if !post.media.isEmpty { return post.media }
        if let imageURL = post.imageURL {
            return [PostMedia(url: imageURL, width: nil, height: nil)]
        }
        return []
    }
}

private struct FeedMediaCarousel: View {
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
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
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }

    private var carouselControls: some View {
        ZStack {
            HStack {
                pageButton(systemImage: "chevron.left") {
                    guard selection > 0 else { return }
                    withAnimation(.quicker) { selection -= 1 }
                }
                .opacity(selection > 0 ? 1 : 0)

                Spacer(minLength: 0)

                pageButton(systemImage: "chevron.right") {
                    guard selection < items.count - 1 else { return }
                    withAnimation(.quicker) { selection += 1 }
                }
                .opacity(selection < items.count - 1 ? 1 : 0)
            }
            .padding(.horizontal, 8)

            VStack {
                HStack {
                    Spacer(minLength: 0)
                    Text("\(selection + 1)/\(items.count)")
                        .font(Theme.body(11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.black.opacity(0.58), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }

    private func pageButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.46), in: Circle())
        }
        .buttonStyle(.pressable)
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

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // CachedRemoteImage (not AsyncImage): it caches and decodes to the
        // card's pixel size. The URL is the variant sized to the card, so the
        // source is neither the blurry mid-size default nor the heavy original.
        CachedRemoteImage(url: item.bestURL(forWidth: width, scale: displayScale)) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            StripePattern()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct FeedActionPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(CompactLabelStyle())
            .font(Theme.body(12, weight: .semibold))
            .foregroundStyle(Theme.text.opacity(0.62))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(Theme.neutral300, in: Capsule())
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
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
