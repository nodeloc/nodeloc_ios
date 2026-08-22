//
//  HomeView.swift
//  nodeloc
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    @State private var feed = FeedStore()
    @State private var lastOffset: CGFloat = 0
    @State private var headerHiddenAmount: CGFloat = 0
    @State private var selectedProfile: UserProfileTarget?
    /// Negative content offset while over-pulling at the top.
    @State private var pullDistance: CGFloat = 0
    @State private var isRefreshing = false

    var body: some View {
        ZStack(alignment: .top) {
            // Feed
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: headerHeight)
                    ForEach(feed.posts) { post in
                        PostCard(
                            post: post,
                            postTransitionNamespace: postTransitionNamespace,
                            onOpenAuthor: { target in
                                withAnimation(.panelSlide) {
                                    selectedProfile = target
                                }
                            }
                        )
                    }
                }
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            .task { await feed.loadIfNeeded() }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, newValue in
                handleScroll(newValue)
            }
            // Over-pull past the natural resting position. The scroll view's
            // resting offset is -contentInsets.top, so measure against that
            // rather than against 0.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, -(geo.contentOffset.y + geo.contentInsets.top))
            } action: { _, newValue in
                pullDistance = newValue
            }
            .onScrollPhaseChange { _, newPhase in
                // Fire once the drag ends past the threshold.
                guard !newPhase.isScrolling, pullDistance >= refreshThreshold, !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await feed.load()
                    isRefreshing = false
                }
            }

            if app.overlay != .post {
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
    }

    private let headerHeight: CGFloat = 56
    private let quickRevealThreshold: CGFloat = 14
    private let refreshThreshold: CGFloat = 72
    private let logoHeight: CGFloat = 30

    /// Spinning (rather than drag-proportional) while actually loading.
    private var isIndeterminate: Bool {
        isRefreshing || (feed.posts.isEmpty && feed.isLoading)
    }

    private var showsLoader: Bool {
        isIndeterminate || pullDistance > 4
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
        } else if delta < 0 {
            let pullDistance = abs(delta)
            if pullDistance >= quickRevealThreshold {
                revealHeader(animated: true)
            } else if top < headerHeight {
                headerHiddenAmount = min(headerHiddenAmount, max(0, top))
                if headerHiddenAmount == 0, app.navCollapsed {
                    withAnimation(.spring(duration: 0.3)) { app.navCollapsed = false }
                }
            }
        }
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

    @ViewBuilder
    private var headerWordmark: some View {
        if showsLoader {
            NodelocLoader(
                progress: isIndeterminate ? nil : pullDistance / refreshThreshold,
                height: logoHeight
            )
        } else {
            Image("NodelocWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: logoHeight)
                .accessibilityLabel("NodeLoc")
        }
    }

    private var persistentHeaderButtons: some View {
        HStack {
            SidebarMenuButton()

            Spacer()

            // Doubles as the loading indicator: idle it's the plain wordmark,
            // while pulling/refreshing it animates. Scrolls up out of the way
            // with the header, while the glass buttons stay pinned.
            headerWordmark
                .opacity(logoRevealProgress)
                .offset(y: -(1 - logoRevealProgress) * headerHeight * 0.6)

            Spacer()

            Button {
                withAnimation(.overlayPush) {
                    app.overlay = .compose
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass(.regular.tint(Theme.accent.opacity(0.14))))
            .buttonBorderShape(.circle)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
        app.selectedPost = post
        withAnimation(.expandCollapse) {
            app.overlay = .post
        }
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
                    .buttonStyle(.plain)
            } else {
                avatar
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
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.accent700)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }

            Spacer(minLength: 0)

            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.4))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
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

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                app.toggleLike(post)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(app.isLiked(post) ? Theme.accent : Theme.muted(0.5))
                    Text("\(app.voteCount(post))")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.74))
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1, height: 14)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.muted(0.42))
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.neutral300, in: Capsule())
            }
            .buttonStyle(.plain)

            FeedActionPill(systemImage: "bubble.left", text: "\(post.comments)")
            FeedActionPill(systemImage: "arrowshape.turn.up.right", text: "Share")

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
        .buttonStyle(.plain)
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
