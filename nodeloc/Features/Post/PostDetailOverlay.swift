//
//  PostDetailOverlay.swift
//  nodeloc
//
//  The post reader: body, threaded replies, and the reply composer.
//

import PhotosUI
import SwiftUI

// MARK: - Post detail

struct PostDetailOverlay: View {
    @Environment(AppState.self) private var app
    let postTransitionNamespace: Namespace.ID
    @State private var topic = TopicStore()
    @State private var draft = ""
    @State private var collapsedCommentIDs: Set<Int> = []
    @State private var detailScrollOffset: CGFloat = 0
    @State private var selectedProfile: UserProfileTarget?
    /// Full-screen image viewer state. Non-empty means the viewer is showing.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    /// The post's node, resolved for its logo — `Post` carries only "n/slug".
    @State private var nodeSummary: SidebarNodeSummary?
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        let post = app.selectedPost
        GeometryReader { _ in
            ZStack(alignment: .top) {
                Theme.bg
                    .matchedGeometryEffect(
                        id: postTransitionID(post.id),
                        in: postTransitionNamespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: true
                    )
                    .allowsHitTesting(false)
                    .zIndex(0)

                detailSurface(for: post)
                    .zIndex(1)

                floatingReaderHeader(for: post)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(10)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.bg)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: post.id) { await topic.load(topicID: post.id) }
        .task(id: post.node) { nodeSummary = await NodeCatalog.shared.node(slug: post.node) }
        // Identity for the full-screen video chrome. Set here rather than
        // inside PostContentView so the video sees the same like state the
        // post's own action bar does. The loaded topic supplies a better author
        // and reply count than the list item can.
        .environment(
            \.postVideoPresentation,
            PostVideoPresentation(
                post: post,
                node: nodeSummary,
                author: authorProfileTarget(for: post),
                commentCount: replyCount(for: post)
            )
        )
        .environment(
            \.postVideoActions,
            PostVideoActions(
                remoteLike: { Task { await topic.like() } },
                comment: { focusReplyField() }
            )
        )
        // Same chrome as the video viewer, from the same presentation.
        .postImageFullScreen(
            images: $viewerImages,
            selection: $viewerIndex,
            presentation: PostVideoPresentation(
                post: post,
                node: nodeSummary,
                author: authorProfileTarget(for: post),
                commentCount: replyCount(for: post)
            ),
            onRemoteLike: { Task { await topic.like() } },
            onComment: { focusReplyField() }
        )
        .alert(
            topic.pluginErrorText ?? "",
            isPresented: Binding(
                get: { topic.pluginErrorText != nil },
                set: { if !$0 { topic.pluginErrorText = nil } }
            )
        ) {
            Button("好", role: .cancel) { topic.pluginErrorText = nil }
        }
    }

    private let readerTopInset: CGFloat = 62
    // Shared with the full-screen video header so the two stay identical.
    private let readerHeaderControlHeight = FloatingHeader.controlHeight
    private let readerNodePillWidth = FloatingHeader.nodePillWidth
    private let readerHeaderHorizontalInset = FloatingHeader.horizontalInset
    private let readerHeaderGlassTint = FloatingHeader.glassTint
    private let readerHeaderShadow = FloatingHeader.shadow

    private func detailSurface(for post: Post) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: readerTopInset)

                authorLine(for: post)
                    .padding(.bottom, 12)

                Text(post.title)
                    .font(Theme.heading(24, weight: .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                if let envelope = topic.redEnvelope {
                    RedEnvelopeBanner(envelope: envelope)
                        .padding(.bottom, 14)
                }

                if topic.content.isEmpty {
                    // Falls back to the list excerpt until the body arrives.
                    Text(post.excerpt)
                        .font(Theme.body(16))
                        .lineSpacing(6)
                        .foregroundStyle(Theme.text.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    PostContentView(
                        content: topic.content,
                        metrics: .body,
                        onImageTap: { image in
                            let images = topic.content.images
                            viewerImages = images
                            viewerIndex = images.firstIndex { $0.src == image.src } ?? 0
                        },
                        pollProvider: { name in
                            guard let poll = topic.firstPostPolls.first(where: { $0.pollName == name }) else {
                                return nil
                            }
                            return AnyView(
                                PollView(
                                    poll: poll,
                                    myVotes: topic.myPollVotes[name] ?? [],
                                    isBusy: topic.pollsInFlight.contains(name),
                                    onVote: { options in
                                        Task { await topic.vote(pollName: name, options: options) }
                                    },
                                    onRemoveVote: {
                                        Task { await topic.removeVote(pollName: name) }
                                    }
                                )
                            )
                        }
                    )
                }

                if let lottery = topic.lottery {
                    LotteryView(
                        lottery: lottery,
                        isBusy: topic.isLotteryBusy,
                        onParticipate: { quantity, isRandom in
                            Task { await topic.participateInLottery(quantity: quantity, isRandom: isRandom) }
                        }
                    )
                    .padding(.top, 18)
                }

                if topic.isLoading && topic.content.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Loading full post")
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.muted(0.42))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                }

                // No cover image here. `post.imageURL` is the feed thumbnail —
                // the body's own first image — so showing it after the content
                // repeated a picture the reader had just scrolled past. It
                // predates the native renderer, which draws body images inline.

                postActions(for: post)
                    .padding(.top, 20)

                repliesSection(for: post)
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Backstop: keeps any single over-wide child from setting the
            // scroll content width for the whole page.
            .clampedToWidth()
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            replyComposer(for: post)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y)
        } action: { _, newValue in
            detailScrollOffset = newValue
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var nodeRevealProgress: CGFloat {
        min(max((detailScrollOffset - 36) / 72, 0), 1)
    }

    private func floatingReaderHeader(for post: Post) -> some View {
        HStack(spacing: 8) {
            readerHeaderGlassButton(borderShape: .circle) {
                closeOverlay(app)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: readerHeaderControlHeight, height: readerHeaderControlHeight)
            }

            nodePill(for: post)
                .opacity(nodeRevealProgress)
                .offset(y: (1 - nodeRevealProgress) * -4)

            Spacer(minLength: 0)

            readerTools(for: post)
        }
        .padding(.horizontal, readerHeaderHorizontalInset)
        .padding(.top, 8)
        .zIndex(2)
    }

    private func readerHeaderGlassButton<Label: View>(
        borderShape: ButtonBorderShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(height: readerHeaderControlHeight)
        }
        .buttonStyle(.glass(.regular.tint(readerHeaderGlassTint)))
        .buttonBorderShape(borderShape)
        .shadow(color: readerHeaderShadow, radius: 9, y: 6)
    }

    private func nodePill(for post: Post) -> some View {
        readerHeaderGlassButton(borderShape: .capsule, action: {}) {
            Text(post.node)
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: readerNodePillWidth, height: readerHeaderControlHeight, alignment: .leading)
        }
        .allowsHitTesting(false)
    }

    private func readerTools(for post: Post) -> some View {
        ZStack {
            readerHeaderGlassButton(borderShape: .capsule, action: {}) {
                readerToolsChrome
                    .opacity(0)
            }
            .allowsHitTesting(false)

            readerToolsContent
        }
    }

    private var readerToolsChrome: some View {
        HStack(spacing: 4) {
            readerToolIcon("magnifyingglass")
            readerToolIcon("slider.horizontal.3")
            readerToolIcon("ellipsis")
            readerAvatar
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: readerHeaderControlHeight)
    }

    private var readerToolsContent: some View {
        HStack(spacing: 4) {
            Button {
                closeOverlay(app)
                app.tab = .search
            } label: {
                readerToolIcon("magnifyingglass")
            }
            .buttonStyle(.plain)

            Button {} label: {
                readerToolIcon("slider.horizontal.3")
            }
            .buttonStyle(.plain)

            Button {} label: {
                readerToolIcon("ellipsis")
            }
            .buttonStyle(.plain)

            readerAvatar
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: readerHeaderControlHeight)
    }

    private func readerToolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
    }

    private var readerAvatar: some View {
        RemoteAvatar(
            url: nil,
            letter: SampleData.userInitial,
            variant: 0,
            size: 26
        )
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Theme.success)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                .offset(x: 1, y: -1)
        }
    }

    private func authorLine(for post: Post) -> some View {
        HStack(spacing: 9) {
            Button {
                openProfile(authorProfileTarget(for: post))
            } label: {
                RemoteAvatar(
                    url: topic.firstAuthor?.avatarURL ?? post.avatarURL,
                    letter: topic.firstAuthor?.initial ?? post.avatarLetter,
                    variant: post.variant,
                    size: 30,
                    cornerRadius: 9
                )
            }
            .buttonStyle(.plain)
            .disabled(authorProfileTarget(for: post) == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.firstAuthor?.username ?? post.authorUsername ?? post.node)
                    .font(Theme.body(13, weight: .semibold))
                Text(post.time)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.muted(0.48))
            }
            Spacer(minLength: 0)
            Text("#1")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.28))
        }
    }

    private func authorProfileTarget(for post: Post) -> UserProfileTarget? {
        if let firstAuthor = topic.firstAuthor {
            return firstAuthor
        }
        guard let username = post.authorUsername else { return nil }
        return UserProfileTarget(
            username: username,
            displayName: post.authorName,
            avatarURL: post.avatarURL
        )
    }

    private func openProfile(_ target: UserProfileTarget?) {
        guard let target else { return }
        withAnimation(.overlayPush) {
            selectedProfile = target
        }
    }

    /// Identity and counts shown over a full-screen video.
    /// Dismisses the video cover's keyboard target and focuses the reply box.
    private func focusReplyField() {
        guard DiscourseAuth.shared.isAuthenticated else { return }
        isReplyFocused = true
    }


    private func postActions(for post: Post) -> some View {
        HStack(spacing: 18) {
            Button {
                let wasLiked = app.isLiked(post)
                app.toggleLike(post)
                if !wasLiked { Task { await topic.like() } }
            } label: {
                Label("\(app.voteCount(post))", systemImage: app.isLiked(post) ? "heart.fill" : "heart")
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(app.isLiked(post) ? Theme.love : Theme.muted(0.42))
            }
            .buttonStyle(.plain)

            Label("\(replyCount(for: post))", systemImage: "bubble.left")
                .labelStyle(CompactLabelStyle())

            Spacer(minLength: 0)

            Image(systemName: "arrowshape.turn.up.left")
            Image(systemName: "link")
        }
        .font(Theme.body(12, weight: .medium))
        .foregroundStyle(Theme.muted(0.42))
    }

    private func repliesSection(for post: Post) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(replyCount(for: post)) replies")
                    .font(Theme.heading(15, weight: .semibold))
                Spacer()
                Text(post.node)
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.42))
            }
            .padding(.bottom, 10)

            LazyVStack(spacing: 0) {
                if topic.isLoading && topic.comments.isEmpty {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else if topic.comments.isEmpty {
                    Text("No replies yet.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ForEach(visibleComments) { comment in
                        NestedReplyRow(
                            comment: comment,
                            isCollapsed: collapsedCommentIDs.contains(comment.id),
                            onToggleCollapse: { toggleCollapse(comment) },
                            onOpenAuthor: { openProfile($0) },
                            onImageTap: { image in
                                // Page through just this reply's images.
                                let images = comment.content.images
                                viewerImages = images
                                viewerIndex = images.firstIndex { $0.src == image.src } ?? 0
                            }
                        )
                    }

                    if topic.hasMoreComments {
                        loadMoreRepliesButton(for: post)
                    }
                }
            }
        }
    }

    private func loadMoreRepliesButton(for post: Post) -> some View {
        Button {
            Task { await topic.loadMoreComments(topicID: post.id) }
        } label: {
            HStack(spacing: 8) {
                if topic.isLoadingMore {
                    ProgressView()
                        .tint(Theme.accent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .medium))
                }

                Text(loadMoreTitle)
                    .font(Theme.body(13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(topic.isLoadingMore)
    }

    private func replyComposer(for post: Post) -> some View {
        HStack(spacing: 10) {
            PlainField(placeholder: DiscourseAuth.shared.isAuthenticated ? "Add a reply…" : "Log in to reply",
                       text: $draft)
                .focused($isReplyFocused)
                .disabled(!DiscourseAuth.shared.isAuthenticated)

            Button {
                let text = draft
                Task {
                    if await topic.submitReply(text, topicID: post.id) { draft = "" }
                }
            } label: {
                ZStack {
                    if topic.isSubmitting {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .background(Theme.accent.opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!DiscourseAuth.shared.isAuthenticated
                      || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || topic.isSubmitting)
            .opacity(replyDisabled ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private var replyDisabled: Bool {
        !DiscourseAuth.shared.isAuthenticated
        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || topic.isSubmitting
    }

    private var loadMoreTitle: String {
        let count = min(topic.remainingCommentCount, 20)
        return count > 0 ? "Load \(count) more replies" : "Load more replies"
    }

    private func replyCount(for post: Post) -> Int {
        topic.totalReplyCount > 0 ? topic.totalReplyCount : (topic.comments.isEmpty ? post.comments : topic.comments.count)
    }

    private var visibleComments: [PostComment] {
        var output: [PostComment] = []
        var hiddenDepth: Int?

        for comment in topic.comments {
            if let depth = hiddenDepth {
                if comment.nestingDepth > depth {
                    continue
                }
                hiddenDepth = nil
            }

            output.append(comment)

            if collapsedCommentIDs.contains(comment.id), comment.hasChildren {
                hiddenDepth = comment.nestingDepth
            }
        }

        return output
    }

    private func toggleCollapse(_ comment: PostComment) {
        guard comment.hasChildren else { return }
        if collapsedCommentIDs.contains(comment.id) {
            collapsedCommentIDs.remove(comment.id)
        } else {
            collapsedCommentIDs.insert(comment.id)
        }
    }
}

private struct NestedReplyRow: View {
    let comment: PostComment
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpenAuthor: (UserProfileTarget) -> Void
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RedditThreadRails(depth: railDepth)
                .frame(width: contentLeading)

            VStack(alignment: .leading, spacing: 8) {
                replyHeader

                if isCollapsed {
                    Text("Replies hidden")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.42))
                } else {
                    PostContentView(
                        content: comment.content,
                        metrics: .reply,
                        onImageTap: onImageTap
                    )

                    // The red envelope plugin auto-claims on reply, so this is
                    // the outcome of posting rather than an action to take.
                    if let claim = comment.redEnvelopeClaim, let points = claim.points {
                        Label("领取了 \(points) 能量", systemImage: "yensign.circle.fill")
                            .font(Theme.body(11, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.danger.opacity(0.1), in: Capsule())
                    }

                    actionBar
                }
            }
            .padding(.leading, contentLeading)
            .padding(.vertical, Self.verticalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The indent grows with nesting depth. Without clipping, a deep reply
        // is wider than the screen and the ScrollView adopts that width,
        // dragging every sibling — banner, images, other replies — with it.
        .clampedToWidth()
    }

    private var replyHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                onOpenAuthor(UserProfileTarget(username: comment.author, displayName: nil, avatarURL: comment.avatarURL))
            } label: {
                RemoteAvatar(url: comment.avatarURL, letter: avatarLetter, variant: comment.id, size: 24)
            }
            .buttonStyle(.plain)

            Text(comment.author)
                .font(Theme.body(12, weight: .semibold))

            Text("· \(comment.time)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.42))

            if let parentNumber = comment.replyToPostNumber, parentNumber > 1 {
                Text("to #\(parentNumber)")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.34))
            }

            Spacer(minLength: 0)

            Text("#\(comment.postNumber)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.26))

            if comment.hasChildren {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.44))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand replies" : "Collapse replies")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            if comment.votes > 0 {
                Label("\(comment.votes)", systemImage: "heart")
                    .labelStyle(CompactLabelStyle())
            }

            Spacer(minLength: 0)

            Image(systemName: "arrowshape.turn.up.left")
            Image(systemName: "link")
        }
        .font(Theme.body(12, weight: .medium))
        .foregroundStyle(Theme.muted(0.38))
    }

    private var contentLeading: CGFloat {
        guard railDepth > 0 else { return 0 }
        return CGFloat(railDepth) * Self.indentStep + Self.railContentGap
    }

    private var railDepth: Int {
        min(max(comment.nestingDepth, 0), Self.maxIndentLevels)
    }

    private var avatarLetter: String {
        comment.author.first.map { String($0).uppercased() } ?? "?"
    }

    fileprivate static let verticalPadding: CGFloat = 12
    fileprivate static let indentStep: CGFloat = 16
    fileprivate static let railContentGap: CGFloat = 8
    fileprivate static let maxIndentLevels: Int = 5
}

private struct RedditThreadRails: View {
    let depth: Int

    var body: some View {
        Canvas { context, size in
            guard visibleDepth > 0 else { return }

            for index in 0..<visibleDepth {
                var path = Path()
                let x = CGFloat(index) * Self.indentStep + Self.railWidth / 2
                path.move(to: CGPoint(x: x, y: -1))
                path.addLine(to: CGPoint(x: x, y: size.height + 1))
                context.stroke(
                    path,
                    with: .color(railColor(for: index)),
                    lineWidth: Self.railWidth
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var visibleDepth: Int {
        min(max(depth, 0), Self.maxIndentLevels)
    }

    private func railColor(for index: Int) -> Color {
        let colors: [Color] = [
            Theme.accent.opacity(0.46),
            Theme.success.opacity(0.38),
            Theme.accent2_600.opacity(0.34),
            Theme.love.opacity(0.32),
            Theme.muted(0.22),
        ]
        return colors[index % colors.count]
    }

    private static let indentStep: CGFloat = NestedReplyRow.indentStep
    private static let maxIndentLevels: Int = NestedReplyRow.maxIndentLevels
    private static let railWidth: CGFloat = 2
}
