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
    /// Header reveal progress (0…1). Held in an @Observable read only by the
    /// floating header so scroll updates don't invalidate the whole reader body.
    @State private var reveal = ReaderHeaderReveal()
    @State private var selectedProfile: UserProfileTarget?
    /// Full-screen image viewer state. Non-empty means the viewer is showing.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    /// The post's node, resolved for its logo — `Post` carries only "n/slug".
    @State private var nodeSummary: SidebarNodeSummary?
    /// A reply's post number to scroll to once its row is loaded, taken from
    /// `AppState.pendingReplyPostNumber` when a notification opens the topic.
    @State private var scrollTarget: Int?
    /// Reports read progress (posts seen + time) so the server records it and
    /// the topic's unread dot clears.
    @State private var reader = TopicReadTracker()
    @State private var skeletonPulse = false
    @State private var showSortDialog = false
    /// The user being replied to (drives the composer's "回复xxx" header). Its
    /// post number becomes `reply_to_post_number` on submit.
    @State private var replyTarget: String?
    @State private var replyTargetNumber: Int?
    /// A reply the ellipsis (…) sheet is open for.
    @State private var moreSheetComment: PostComment?
    /// The post id the 打赏 sheet is giving to.
    @State private var rewardTarget: Int?
    /// Rewards to show in the per-user 打赏 detail sheet.
    @State private var rewardDetail: RewardDetail?
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
        .task(id: post.id) {
            // Consume the scroll target before loading so it can't leak into a
            // later, unrelated topic opened in the same overlay.
            scrollTarget = app.pendingReplyPostNumber
            app.pendingReplyPostNumber = nil
            await topic.load(topicID: post.id)
        }
        .task(id: post.id) {
            // Read-progress heartbeat: credit on-screen posts each second,
            // flush periodically, and flush once more on leaving or switching
            // topics (the task is cancelled then).
            reader.begin(topicID: post.id)
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                reader.tick()
                ticks += 1
                if ticks % 10 == 0 { await reader.flush() }
            }
            await reader.flush()
        }
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
                remoteLike: { Task { await topic.toggleFirstPostLike() } },
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
            onRemoteLike: { Task { await topic.toggleFirstPostLike() } },
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
        // Ellipsis (…) menu on a reply.
        .sheet(item: $moreSheetComment) { comment in
            replyMoreSheet(comment, post: post)
        }
        // 打赏 amount picker.
        .sheet(isPresented: Binding(
            get: { rewardTarget != nil },
            set: { if !$0 { rewardTarget = nil } }
        )) {
            if let postID = rewardTarget {
                RewardSheet(postID: postID) { amount, note in
                    try await topic.giveReward(postID: postID, amount: amount, note: note)
                }
            }
        }
        // 打赏 detail — who rewarded, and how much.
        .sheet(item: $rewardDetail) { detail in
            RewardDetailSheet(rewards: detail.rewards)
        }
    }

    /// The ellipsis (…) bottom sheet for a reply: 分享 / 转发 / 保存书签 / 举报.
    private func replyMoreSheet(_ comment: PostComment, post: Post) -> some View {
        let postURL = DiscourseConfig.baseURL.appending(path: "t/\(post.id)/\(comment.postNumber)")
        return NavigationStack {
            VStack(spacing: 0) {
                ShareLink(item: postURL) {
                    moreSheetRow("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Button {
                    moreSheetComment = nil
                    startRepost(for: post)
                } label: {
                    moreSheetRow("转发", systemImage: "arrow.2.squarepath")
                }
                .buttonStyle(.plain)

                Button {
                    moreSheetComment = nil
                    Task { try? await topic.bookmark(postID: comment.id) }
                } label: {
                    moreSheetRow("保存书签", systemImage: "bookmark")
                }
                .buttonStyle(.plain)

                Button {
                    moreSheetComment = nil
                    BrowserState.shared.open(postURL)
                } label: {
                    moreSheetRow("举报", systemImage: "flag", tint: Theme.danger)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium])
    }

    private func moreSheetRow(_ title: String, systemImage: String, tint: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? Theme.muted(0.55))
                .frame(width: 26)
            Text(title)
                .font(Theme.body(15, weight: .semibold))
                .foregroundStyle(tint ?? Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private let readerTopInset: CGFloat = 62
    // Shared with the full-screen video header so the two stay identical.
    private let readerHeaderControlHeight = FloatingHeader.controlHeight
    private let readerNodePillWidth = FloatingHeader.nodePillWidth
    private let readerHeaderHorizontalInset = FloatingHeader.horizontalInset
    private let readerHeaderGlassTint = FloatingHeader.glassTint
    private let readerHeaderShadow = FloatingHeader.shadow

    private func detailSurface(for post: Post) -> some View {
        ScrollViewReader { proxy in
            scrollBody(for: post)
                // Replies arrive after the topic loads (and again on "load
                // more"); each change is a chance to land on the target reply
                // once its row exists. If it never loads, we stay put.
                .onChange(of: topic.comments.count) { _, _ in
                    scrollToTargetIfLoaded(proxy)
                }
                // Fired after posting a reply: scroll to it once its row exists.
                .onChange(of: scrollTarget) { _, _ in
                    scrollToTargetIfLoaded(proxy)
                }
        }
    }

    private func scrollToTargetIfLoaded(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        // Post #1 is the original post — the view already opens at the top.
        guard target > 1 else { scrollTarget = nil; return }
        guard topic.comments.contains(where: { $0.postNumber == target }) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(target, anchor: .top)
        }
        scrollTarget = nil
    }

    private func scrollBody(for post: Post) -> some View {
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
                    // The title standing in for the first post being on screen.
                    .onScrollVisibilityChange(threshold: 0.2) { reader.setVisible(1, $0) }

                if let envelope = topic.redEnvelope {
                    RedEnvelopeBanner(envelope: envelope)
                        .padding(.bottom, 14)
                }

                if topic.content.isEmpty {
                    if topic.isLoading {
                        postBodySkeleton
                    } else {
                        // Falls back to the list excerpt if the body never loads.
                        Text(post.excerpt)
                            .font(Theme.body(16))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.text.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        // Map straight to the reveal progress: identical values coalesce, so
        // scrolling the long body past the reveal band doesn't churn state
        // every frame (the previous raw-offset state invalidated the whole
        // reader body continuously).
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let offset = max(0, geometry.contentOffset.y)
            return min(max((offset - 36) / 72, 0), 1)
        } action: { _, newValue in
            reveal.progress = newValue
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
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

            // Only this subview reads `reveal`, so scroll updates re-render the
            // pill alone rather than the whole reader body.
            RevealingView(reveal: reveal) {
                nodePill(for: post)
            }

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

    /// Grouped glass capsule matching the node page's top-right tools.
    private func readerTools(for post: Post) -> some View {
        HStack(spacing: 6) {
            Button {
                closeOverlay(app)
                app.tab = .search
            } label: {
                readerToolIcon("magnifyingglass")
            }
            .buttonStyle(.plain)

            Button { showSortDialog = true } label: { readerToolIcon("slider.horizontal.3") }
                .buttonStyle(.plain)

            Button {} label: { readerToolIcon("ellipsis") }
                .buttonStyle(.plain)

            readerAvatar
        }
        .padding(.horizontal, 8)
        // Same as the node page: `.glass` adds 7pt above/below a 34pt label for
        // a 48pt capsule, reproduced here so the two headers match exactly.
        .padding(.vertical, 7)
        .glassEffect(
            .regular.tint(Theme.bg.opacity(0.34)).interactive(),
            in: .capsule
        )
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        .sheet(isPresented: $showSortDialog) { replySortSheet }
    }

    /// Reply sort picker, styled like the node list's "话题排序依据" sheet.
    private var replySortSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(ReplySort.allCases) { option in
                    Button {
                        showSortDialog = false
                        topic.applySort(option)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(topic.replySort == option ? Theme.accent : Theme.muted(0.55))
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

                            if topic.replySort == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(topic.replySort == option ? Theme.accent.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationTitle("回复排序依据")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium])
    }

    private func readerToolIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 28, height: readerHeaderControlHeight)
            .contentShape(Rectangle())
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
                HStack(spacing: 6) {
                    Text(topic.firstAuthor?.username ?? post.authorUsername ?? post.node)
                        .font(Theme.body(13, weight: .semibold))
                    authorFlairBadge(topic.firstAuthorFlairURL)
                    authorTitleChip(topic.firstAuthorTitle)
                }
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
        let isOwn = isOwnAuthor(topic.firstAuthor?.username ?? post.authorUsername)
        return HStack(spacing: 16) {
            // Like + comment counts grouped in a rounded rect.
            HStack(spacing: 14) {
                // You can't like your own post, so it's a static stat then.
                Button {
                    Task { await topic.toggleFirstPostLike() }
                } label: {
                    Label("\(topic.firstPostLikeCount)", systemImage: topic.firstPostLikedByMe ? "heart.fill" : "heart")
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(topic.firstPostLikedByMe ? Theme.love : Theme.muted(0.5))
                }
                .buttonStyle(.plain)
                .disabled(isOwn)

                Label("\(replyCount(for: post))", systemImage: "bubble.left")
                    .labelStyle(CompactLabelStyle())
                    .foregroundStyle(Theme.muted(0.5))

                // Total 打赏 received, tappable for the per-user breakdown.
                if topic.firstPostRewards.contains(where: { $0.amount > 0 }) {
                    Button {
                        rewardDetail = RewardDetail(rewards: topic.firstPostRewards)
                    } label: {
                        rewardTotalLabel(topic.firstPostRewards)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(Theme.body(12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface, in: Capsule())

            Spacer(minLength: 0)

            postActionIcon("arrowshape.turn.up.left") {
                startReply(to: topic.firstAuthor?.username ?? post.authorUsername, postNumber: 1)
            }
            postActionIcon("arrow.2.squarepath") { startRepost(for: post) }
            // No 打赏 button on your own post.
            if !isOwn {
                postActionIcon("bolt") {
                    if let id = topic.firstPostID { rewardTarget = id }
                }
            }
        }
        .foregroundStyle(Theme.muted(0.5))
    }

    /// The "⚡ N" total-reward chip shared by the OP and reply action bars.
    private func rewardTotalLabel(_ rewards: [PostReward]) -> some View {
        let total = rewards.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        return HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
            Text("\(total)")
        }
        .font(Theme.body(12, weight: .medium))
        .foregroundStyle(Theme.accent)
    }

    /// A tappable icon used in the OP action bar.
    private func postActionIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted(0.5))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }

    /// Opens the composer targeting a specific user's post.
    private func startReply(to author: String?, postNumber: Int) {
        replyTarget = author
        replyTargetNumber = postNumber
        isReplyFocused = true
    }

    /// Opens the composer pre-filled to repost this topic: original title, plus
    /// a link to the original that oneboxes into a preview. Both stay editable.
    private func startRepost(for post: Post) {
        app.composePrefillTitle = post.title
        app.composePrefillBody = DiscourseConfig.baseURL.appending(path: "t/\(post.id)").absoluteString
        withAnimation(.overlayPush) { app.overlay = .compose }
    }

    /// The signed-in user's username, for "can't act on my own post" checks.
    private var currentUsername: String? { DiscourseAuth.shared.username }

    private func isOwnAuthor(_ username: String?) -> Bool {
        guard let me = currentUsername, let username else { return false }
        return me.caseInsensitiveCompare(username) == .orderedSame
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
                    ForEach(0..<3, id: \.self) { _ in replySkeleton }
                } else if topic.comments.isEmpty {
                    Text("No replies yet.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted(0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    let comments = visibleComments
                    ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                        // A short blank row separates one nest group from the
                        // next (a new top-level reply thread).
                        if index > 0, comment.groupID != comments[index - 1].groupID {
                            groupSeparator
                        }

                        if comment.isLoadMore {
                            loadMoreChildrenRow(comment)
                        } else {
                            NestedReplyRow(
                                comment: comment,
                                isCollapsed: collapsedCommentIDs.contains(comment.id),
                                onToggleCollapse: { toggleCollapse(comment) },
                                onOpenAuthor: { openProfile($0) },
                                isOwn: isOwnAuthor(comment.author),
                                onReply: { startReply(to: comment.author, postNumber: comment.postNumber) },
                                onLike: { Task { await topic.toggleReplyLike(id: comment.id) } },
                                onReward: { rewardTarget = comment.id },
                                onRewardDetail: { rewardDetail = RewardDetail(rewards: comment.rewards) },
                                onMore: { moreSheetComment = comment },
                                onImageTap: { image in
                                    // Page through just this reply's images.
                                    let images = comment.content.images
                                    viewerImages = images
                                    viewerIndex = images.firstIndex { $0.src == image.src } ?? 0
                                }
                            )
                            // Scroll anchor for notification deep links (/t/…/<post>).
                            .id(comment.postNumber)
                            // Credit read time to this reply while it's on screen.
                            .onScrollVisibilityChange(threshold: 0.5) { reader.setVisible(comment.postNumber, $0) }
                        }
                    }

                    if topic.hasMoreComments {
                        loadMoreRepliesButton(for: post)
                    }
                }
            }
        }
    }

    /// A "view N more replies" affordance under a nested post, indented to match
    /// where those replies will appear.
    private func loadMoreChildrenRow(_ comment: PostComment) -> some View {
        let depth = min(max(comment.nestingDepth, 0), NestedReplyRow.maxIndentLevels)
        let leading = depth > 0
            ? CGFloat(depth) * NestedReplyRow.indentStep + NestedReplyRow.railContentGap
            : 0

        return Button {
            Task { await topic.loadMoreChildren(parentPostNumber: comment.loadMoreParent) }
        } label: {
            HStack(spacing: 5) {
                Text("另外 \(comment.loadMoreRemaining) 个回复")
                    .font(Theme.body(13, weight: .semibold))
                if topic.isLoadingChildren(comment.loadMoreParent) {
                    ProgressView().controlSize(.mini).tint(Theme.muted(0.5))
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Theme.muted(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.leading, leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(topic.isLoadingChildren(comment.loadMoreParent))
        // Same rails as the replies so it lines up beside the level's thread line.
        .background(alignment: .leading) {
            RedditThreadRails(depth: depth)
                .frame(width: leading)
        }
    }

    // MARK: Skeleton

    /// Placeholder lines for the post body while it loads.
    private var postBodySkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            skeletonLine(widthFraction: 1)
            skeletonLine(widthFraction: 0.95)
            skeletonLine(widthFraction: 1)
            skeletonLine(widthFraction: 0.6)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.neutral300)
                .frame(height: 180)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SkeletonPulse(active: skeletonPulse))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                skeletonPulse = true
            }
        }
    }

    /// One placeholder reply row (avatar + a couple of lines).
    private var replySkeleton: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.neutral300).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 8) {
                skeletonLine(widthFraction: 0.35)
                skeletonLine(widthFraction: 0.9)
                skeletonLine(widthFraction: 0.7)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SkeletonPulse(active: skeletonPulse))
    }

    private func skeletonLine(widthFraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.neutral300)
            .frame(height: 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: widthFraction, anchor: .leading)
    }

    /// The short blank band between nest groups.
    private var groupSeparator: some View {
        Rectangle()
            .fill(Theme.divider.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .padding(.horizontal, -20)
    }

    /// Auto-loads the next page of replies when it scrolls into view — no tap.
    private func loadMoreRepliesButton(for post: Post) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Theme.accent)
            Text(loadMoreTitle)
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            guard visible else { return }
            Task { await topic.loadMoreComments(topicID: post.id) }
        }
    }

    private func replyComposer(for post: Post) -> some View {
        ReplyComposer(
            text: $draft,
            isSubmitting: topic.isSubmitting,
            isAuthenticated: DiscourseAuth.shared.isAuthenticated,
            replyingTo: replyTarget,
            onClearReplyTarget: {
                replyTarget = nil
                replyTargetNumber = nil
            },
            onSubmit: {
                let text = draft
                let replyTo = replyTargetNumber
                Task {
                    if let number = await topic.submitReply(text, topicID: post.id, replyToPostNumber: replyTo) {
                        draft = ""          // resets + collapses the composer
                        replyTarget = nil
                        replyTargetNumber = nil
                        scrollTarget = number   // scroll to the new reply once it's laid out
                    }
                }
            }
        )
    }

    private var loadMoreTitle: String { "加载更多回复" }

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
    /// True when the reply is the current user's own (can't like/reward it).
    let isOwn: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onReward: () -> Void
    let onRewardDetail: () -> Void
    let onMore: () -> Void
    var onImageTap: ((PostImage) -> Void)?

    var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        // Rails as a background so the Canvas gets the row's exact height
        // (in a ZStack the greedy Canvas could collapse and draw nothing).
        .background(alignment: .leading) {
            RedditThreadRails(depth: railDepth)
                .frame(width: contentLeading)
        }
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

            authorFlairBadge(comment.flairURL)
            authorTitleChip(comment.authorTitle)

            Text("· \(comment.time)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.42))

            Spacer(minLength: 0)

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
        HStack(spacing: 20) {
            // Total 打赏 received on this reply, tappable for the breakdown.
            if comment.rewards.contains(where: { $0.amount > 0 }) {
                Button(action: onRewardDetail) {
                    let total = comment.rewards.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                        Text("\(total)")
                    }
                    .font(Theme.body(12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            replyActionIcon("ellipsis", action: onMore)
            replyActionIcon("arrowshape.turn.up.left", action: onReply)
            // Can't like your own reply.
            Button(action: onLike) {
                HStack(spacing: 4) {
                    Image(systemName: comment.isLiked ? "heart.fill" : "heart")
                    if comment.votes > 0 {
                        Text("\(comment.votes)")
                    }
                }
                .font(Theme.body(12, weight: .medium))
                .foregroundStyle(comment.isLiked ? Theme.love : Theme.muted(0.4))
            }
            .buttonStyle(.plain)
            .disabled(isOwn)
            // No 打赏 button on your own reply.
            if !isOwn {
                replyActionIcon("bolt", action: onReward)
            }
        }
        .foregroundStyle(Theme.muted(0.4))
    }

    private func replyActionIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted(0.4))
        }
        .buttonStyle(.plain)
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
    // Indent deeper (up to 8 levels) with a tighter step so nested sub-threads
    // stay visibly nested instead of collapsing onto one level, while still
    // fitting a phone's width.
    fileprivate static let indentStep: CGFloat = 13
    fileprivate static let railContentGap: CGFloat = 8
    fileprivate static let maxIndentLevels: Int = 8
}

/// Holds the header reveal progress separately from the view so scroll updates
/// invalidate only the views that read it.
@MainActor
@Observable
final class ReaderHeaderReveal {
    var progress: CGFloat = 0
}

/// Fades/slides its content by the reveal progress. Isolated so scrolling
/// re-renders just the node pill, not the whole reader.
private struct RevealingView<Content: View>: View {
    let reveal: ReaderHeaderReveal
    @ViewBuilder let content: Content

    var body: some View {
        content
            .opacity(reveal.progress)
            .offset(y: (1 - reveal.progress) * -4)
    }
}

/// Gentle opacity pulse for skeleton placeholders.
private struct SkeletonPulse: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.opacity(active ? 0.55 : 1)
    }
}

private struct RedditThreadRails: View {
    let depth: Int

    var body: some View {
        // Plain Rectangles rather than a Canvas: each fills the row's height
        // deterministically as a background, so deep/newly-expanded rows always
        // get their lines (a greedy Canvas could collapse to zero height).
        HStack(spacing: 0) {
            ForEach(0..<visibleDepth, id: \.self) { _ in
                Rectangle()
                    .fill(Self.railColor)
                    .frame(width: Self.railWidth)
                Color.clear
                    .frame(width: Self.indentStep - Self.railWidth)
            }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var visibleDepth: Int {
        min(max(depth, 0), Self.maxIndentLevels)
    }

    private static let railColor = Theme.divider
    private static let indentStep: CGFloat = NestedReplyRow.indentStep
    private static let maxIndentLevels: Int = NestedReplyRow.maxIndentLevels
    private static let railWidth: CGFloat = 1
}

// MARK: - Author flair + title

/// The small badge icon a user wears next to their name (Discourse "flair").
@ViewBuilder
func authorFlairBadge(_ url: URL?) -> some View {
    if let url {
        CachedRemoteImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.clear
        }
        .frame(width: 15, height: 15)
        .clipShape(Circle())
    }
}

/// The user's worn title (头衔), shown as a subtle chip after their name.
@ViewBuilder
func authorTitleChip(_ title: String?) -> some View {
    if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(title)
            .font(Theme.body(11, weight: .medium))
            .foregroundStyle(Theme.muted(0.5))
            .lineLimit(1)
    }
}

// MARK: - 打赏 (reward) sheet

/// Gives energy to a post via discourse-reward. Quick amounts plus an optional note.
private struct RewardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let postID: Int
    /// Performs the give; throws so the sheet can surface a failure.
    let onGive: (Int, String?) async throws -> Void

    private let amounts = [1, 5, 10, 20, 50]
    @State private var amount = 5
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("选择打赏能量")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.5))

                HStack(spacing: 10) {
                    ForEach(amounts, id: \.self) { value in
                        Button {
                            amount = value
                        } label: {
                            Text("\(value)")
                                .font(Theme.body(15, weight: .semibold))
                                .foregroundStyle(amount == value ? Theme.bg : Theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    amount == value ? Theme.accent : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("附言（可选）", text: $note, axis: .vertical)
                    .font(Theme.body(15))
                    .lineLimit(1...3)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let errorText {
                    Text(errorText)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.danger)
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(Theme.bg)
                        } else {
                            Text("打赏 \(amount)")
                                .font(Theme.body(15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.bg)
            .navigationTitle("打赏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .standardSheet([.medium])
    }

    private func submit() {
        isSubmitting = true
        errorText = nil
        Task {
            do {
                try await onGive(amount, note.isEmpty ? nil : note)
                dismiss()
            } catch {
                errorText = "打赏失败，请稍后再试"
            }
            isSubmitting = false
        }
    }
}

// MARK: - 打赏 detail

/// Wrapper so an array of rewards can drive a `.sheet(item:)`.
struct RewardDetail: Identifiable {
    let id = UUID()
    let rewards: [PostReward]
}

/// Lists who rewarded a post and how much.
private struct RewardDetailSheet: View {
    let rewards: [PostReward]

    private var visible: [PostReward] { rewards.filter { $0.amount > 0 } }
    private var total: Int { visible.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { reward in
                        rewardRow(reward)
                    }
                }
                .padding(.top, 6)
            }
            .background(Theme.bg)
            .navigationTitle("打赏 \(total)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium, .large])
    }

    private func rewardRow(_ reward: PostReward) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(
                url: reward.avatarTemplate.flatMap { DiscourseClient().avatarURL(template: $0, size: 80) },
                letter: String(reward.username?.first ?? "?"),
                variant: reward.id,
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(reward.username ?? "未知用户")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let note = reward.note, !note.isEmpty {
                    Text(note)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.55))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                Text("\(reward.amount)")
            }
            .font(Theme.body(14, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
