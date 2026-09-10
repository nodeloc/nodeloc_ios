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
    /// How to get off screen. Nil means the app-level overlay owns this reader,
    /// which is the usual case (`MainView` renders it for `app.overlay ==
    /// .post`).
    ///
    /// A screen that is *itself* inside a full-screen cover has to present the
    /// reader locally and pass its own dismissal: `app.overlay` renders in
    /// `MainView`, behind the cover, so the reader would open where nobody can
    /// see it and the tap would look dead.
    var onClose: (() -> Void)?
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
    /// Where to move after posting a reply. An *edge*, never an interior row:
    /// asking a long `LazyVStack` to scroll to a row deep inside it is the
    /// manoeuvre that leaves the viewport blank, because the rows in between
    /// were never measured. Both ends are clamped by the scroll view itself and
    /// so cannot land on nothing.
    @State private var postedReplyEdge: PostedReplyEdge?

    private enum PostedReplyEdge {
        /// Newest-first sort: the reply went in at the top.
        case top
        /// Oldest-first (and most-liked): it went in at the end.
        case bottom
        /// A nested reply appears right next to the row it answers — the reader
        /// is already looking at it, so moving would only lose their place.
        case stay
    }
    /// Reports read progress (posts seen + time) so the server records it and
    /// the topic's unread dot clears.
    @State private var reader = TopicReadTracker()
    /// Latches the pull-to-close, so the gesture can't fire `close()` on every
    /// frame it stays past the threshold.
    @State private var isClosing = false
    @State private var showSortDialog = false
    /// The user being replied to (drives the composer's "回复xxx" header). Its
    /// post number becomes `reply_to_post_number` on submit.
    @State private var replyTarget: String?
    @State private var replyTargetNumber: Int?
    /// A reply the ellipsis (…) sheet is open for.
    @State private var moreSheetComment: PostComment?
    /// Which post the editor is open on, and whether it's the OP (whose body
    /// is the topic's first post rather than a reply).
    @State private var editTarget: EditTarget?
    @State private var deleteTargetPostID: Int?
    /// Post whose reaction breakdown is open.
    @State private var reactionDetail: ReactionTarget?

    /// `Int` isn't `Identifiable`, and retroactively conforming a stdlib type
    /// for one sheet is worse than a two-line wrapper.
    struct ReactionTarget: Identifiable {
        let postID: Int
        var id: Int { postID }
    }
    @State private var isConfirmingTopicDelete = false

    /// A *reply* being edited. The first post goes through the composer, which
    /// takes its node and title as well.
    struct EditTarget: Identifiable {
        let postID: Int
        var id: Int { postID }
    }
    /// The header ellipsis (…) sheet — actions on the topic itself.
    @State private var showTopicMoreSheet = false
    @State private var showPinSheet = false
    @State private var flagTarget: FlagTarget?
    /// The 注册/登录 gate a guest gets from the header avatar (and from
    /// actions that need an account).
    @State private var showGuestGate = false
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
            // Reset per topic: the overlay is reused, and a latched close from
            // the last one would fire on this one's first rubber-band.
            isClosing = false
            await topic.load(topicID: post.id)
            // Subscribed after loading, so a reply that arrives during the
            // fetch is either already in the response or counted — never both,
            // since the handler checks what is on screen.
            topic.startLiveUpdates(topicID: post.id)
        }
        .onDisappear {
            // A long poll for a topic nobody is reading is a connection and a
            // rate-limit budget spent on nothing.
            topic.stopLiveUpdates()
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
                // Every 30s, not every 10. This is read-progress reporting, so
                // nothing a reader sees depends on it being prompt — and at
                // ten seconds it was six writes a minute per open topic,
                // sharing a rate-limit budget with the requests that actually
                // draw the screen. The flush below still runs on leaving, so
                // nothing is lost by batching harder.
                if ticks % 30 == 0 { await reader.flush() }
            }
            await reader.flush()
        }
        // Keyed on both sources: a topic opened from a link starts with no node
        // at all and only learns it once loaded, so waiting on `post.node`
        // alone left the pill blank forever.
        .task(id: nodeLookupKey(for: post)) { await resolveNodeSummary(for: post) }
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
        // Ellipsis (…) menu on the topic, from the floating header.
        .sheet(isPresented: $showTopicMoreSheet) {
            topicMoreSheet(post)
        }
        // 置顶设置: node pin / global pin / banner / dismiss-for-me.
        .sheet(isPresented: $showPinSheet) {
            TopicPinSheet(topic: topic)
        }
        // 举报 — native, not a trip to the website.
        .sheet(item: $flagTarget) { target in
            FlagSheet(target: target)
        }
        // 注册/登录 bottom gate for guests.
        .sheet(isPresented: $showGuestGate) {
            guestGateSheet
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
        .sheet(item: $reactionDetail) { target in
            ReactionUsersSheet(postID: target.postID)
        }
        .sheet(item: $editTarget) { target in
            PostEditSheet(
                load: { await topic.rawBody(postID: target.postID) },
                save: { raw in await topic.saveEdit(postID: target.postID, raw: raw) }
            )
        }
        .confirmationDialog(
            AppString("删除这条回复？"),
            isPresented: Binding(
                get: { deleteTargetPostID != nil },
                set: { if !$0 { deleteTargetPostID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let postID = deleteTargetPostID else { return }
                deleteTargetPostID = nil
                Task { await topic.deletePost(id: postID) }
            }
            Button("取消", role: .cancel) { deleteTargetPostID = nil }
        }
        .confirmationDialog(
            AppString("删除整个主题？"),
            isPresented: $isConfirmingTopicDelete,
            titleVisibility: .visible
        ) {
            Button("删除主题", role: .destructive) {
                Task {
                    // Nothing to come back to once it's gone.
                    if await topic.deleteTopic() { close() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("主题及其下所有回复都会被删除。")
        }
    }

    /// The ellipsis (…) bottom sheet for a reply: 分享 / 转发 / 保存书签 / 举报.
    private func replyMoreSheet(_ comment: PostComment, post: Post) -> some View {
        let postURL = DiscourseConfig.baseURL.appending(path: "t/\(post.id)/\(comment.postNumber)")
        return NavigationStack {
            VStack(spacing: 0) {
                // Staff only, and only for a top-level reply — the two
                // conditions the site's own menu applies.
                if topic.canPin(comment) {
                    Button {
                        moreSheetComment = nil
                        Task { await topic.togglePin(postID: comment.id) }
                    } label: {
                        moreSheetRow(
                            comment.isPinned ? AppString("取消置顶") : AppString("置顶"),
                            systemImage: comment.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .buttonStyle(.pressable)
                }

                ShareLink(item: postURL) {
                    moreSheetRow(AppString("分享"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.pressable)

                Button {
                    moreSheetComment = nil
                    startRepost(for: post)
                } label: {
                    moreSheetRow(AppString("转发"), systemImage: "arrow.2.squarepath")
                }
                .buttonStyle(.pressable)

                Button {
                    moreSheetComment = nil
                    Task { await bookmarkWithToast(postID: comment.id) }
                } label: {
                    moreSheetRow(AppString("保存书签"), systemImage: "bookmark")
                }
                .buttonStyle(.pressable)

                Button {
                    moreSheetComment = nil
                    flagTarget = FlagTarget(
                        kind: .post,
                        id: comment.id,
                        authorUsername: comment.author.isEmpty ? nil : comment.author
                    )
                } label: {
                    moreSheetRow(AppString("举报"), systemImage: "flag", tint: Theme.danger)
                }
                .buttonStyle(.pressable)

                // Guideline 1.2 wants blocking reachable wherever reporting is,
                // so it sits beside 举报 here and not only on the topic sheet.
                if !comment.author.isEmpty, !comment.isMine {
                    Button {
                        moreSheetComment = nil
                        Task { await blockAuthor(comment.author, postID: comment.id) }
                    } label: {
                        moreSheetRow(
                            AppString("屏蔽作者"),
                            systemImage: "hand.raised",
                            tint: Theme.danger
                        )
                    }
                    .buttonStyle(.pressable)
                }

                if comment.canEdit || comment.canDelete {
                    Divider().padding(.vertical, 4)
                }

                if comment.canEdit {
                    Button {
                        moreSheetComment = nil
                        editTarget = EditTarget(postID: comment.id)
                    } label: {
                        moreSheetRow(AppString("编辑"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.pressable)
                }

                if comment.canDelete {
                    Button {
                        moreSheetComment = nil
                        deleteTargetPostID = comment.id
                    } label: {
                        moreSheetRow(
                            comment.isMine ? AppString("删除") : AppString("删除（管理）"),
                            systemImage: "trash",
                            tint: Theme.danger
                        )
                    }
                    .buttonStyle(.pressable)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium])
    }

    /// The header ellipsis (…) sheet: 更多操作 on the topic itself.
    private func topicMoreSheet(_ post: Post) -> some View {
        // The canonical `/t/{slug}/{id}` once the topic is loaded: an id-only
        // link works but only after a redirect, and it reads as nothing when
        // pasted into a chat.
        let topicURL = topic.url(forTopicID: post.id)
        return NavigationStack {
            VStack(spacing: 0) {
                Button {
                    showTopicMoreSheet = false
                    copyLink(topicURL)
                } label: {
                    moreSheetRow(AppString("复制链接"), systemImage: "link")
                }
                .buttonStyle(.pressable)

                ShareLink(item: topicURL) {
                    moreSheetRow(AppString("分享"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.pressable)

                Button {
                    guard requireAccountFromMoreSheet() else { return }
                    if let firstPostID = topic.firstPostID {
                        Task { await bookmarkWithToast(postID: firstPostID) }
                    }
                } label: {
                    moreSheetRow(AppString("保存书签"), systemImage: "bookmark")
                }
                .buttonStyle(.pressable)

                Button {
                    guard requireAccountFromMoreSheet() else { return }
                    startRepost(for: post)
                } label: {
                    moreSheetRow(AppString("转发"), systemImage: "arrow.2.squarepath")
                }
                .buttonStyle(.pressable)

                Button {
                    showTopicMoreSheet = false
                    flagTarget = FlagTarget(
                        kind: .topic,
                        id: post.id,
                        authorUsername: topic.firstAuthor?.username ?? post.authorUsername
                    )
                } label: {
                    moreSheetRow(AppString("举报"), systemImage: "flag", tint: Theme.danger)
                }
                .buttonStyle(.pressable)

                // Author and moderation actions. Every one is shown on a
                // `can_*` the server put on this topic for this viewer, so a
                // node moderator sees them on their own node and nowhere else,
                // and the app never guesses at who may do what.
                if topic.canEditTopic || topic.canEditFirstPost {
                    Divider().padding(.vertical, 4)
                }

                // One 编辑, not a title form and a body form: the composer takes
                // the node, the title and the body together, which is also how
                // the post was written in the first place.
                if topic.canEditTopic || topic.canEditFirstPost {
                    Button {
                        showTopicMoreSheet = false
                        Task { await startTopicEdit(for: post) }
                    } label: {
                        moreSheetRow(AppString("编辑"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.pressable)
                }

                if topic.canCloseTopic {
                    Button {
                        showTopicMoreSheet = false
                        Task { await topic.toggleClosed() }
                    } label: {
                        moreSheetRow(
                            topic.isTopicClosed ? AppString("重新开放") : AppString("关闭主题"),
                            systemImage: topic.isTopicClosed ? "lock.open" : "lock"
                        )
                    }
                    .buttonStyle(.pressable)
                }

                // 置顶 is not one switch: node pin, global pin, banner and the
                // per-reader dismissal are four different things, so this opens
                // the sheet that shows the current mode and the alternatives.
                if topic.canPinTopic || topic.canBannerTopic {
                    Button {
                        showTopicMoreSheet = false
                        showPinSheet = true
                    } label: {
                        moreSheetRow(
                            topic.isTopicPinned || topic.isTopicBanner ? AppString("置顶设置") : AppString("置顶主题"),
                            systemImage: topic.isTopicPinned || topic.isTopicBanner ? "pin.fill" : "pin"
                        )
                    }
                    .buttonStyle(.pressable)
                } else if topic.isTopicPinned, isSignedIn {
                    // Clearing a pin for yourself needs no moderation rights —
                    // it writes `topic_users.cleared_pinned_at` — but it does
                    // need an account to write it against.
                    Button {
                        showTopicMoreSheet = false
                        Task { await topic.setPinClearedForMe(!topic.isPinClearedForMe) }
                    } label: {
                        moreSheetRow(
                            topic.isPinClearedForMe ? AppString("恢复置顶") : AppString("对我取消置顶"),
                            systemImage: topic.isPinClearedForMe ? "pin" : "pin.slash"
                        )
                    }
                    .buttonStyle(.pressable)
                }

                // Either flag: `details.can_delete` is the moderator's, while an
                // author inside the edit window gets it on the first post
                // instead — deleting that *is* deleting the topic.
                if topic.canDeleteTopic || topic.canDeleteFirstPost {
                    Button {
                        showTopicMoreSheet = false
                        isConfirmingTopicDelete = true
                    } label: {
                        moreSheetRow(AppString("删除主题"), systemImage: "trash", tint: Theme.danger)
                    }
                    .buttonStyle(.pressable)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationTitle("更多操作")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.medium])
    }

    /// Bookmarks with a visible outcome either way — silently swallowing the
    /// failure left the button looking broken.
    private func bookmarkWithToast(postID: Int) async {
        do {
            try await topic.bookmark(postID: postID)
            ToastCenter.shared.show(AppString("已保存书签"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Dismisses the reader whichever way it was presented.
    private func close() {
        if let onClose {
            onClose()
        } else {
            closeOverlay(app)
        }
    }

    /// 屏蔽作者 from a reply's … sheet. The store reloads the topic, so the
    /// toast is confirmation of something the reader can also see happen.
    private func blockAuthor(_ username: String, postID: Int?) async {
        // The store shows its own confirmation: what it can say depends on how
        // far the server let the block go. See `BlockedUsersStore.Outcome`.
        await topic.blockAuthor(username: username, reportingPostID: postID)
    }

    /// Closes the more sheet; when no account is signed in, swaps it for the
    /// 注册/登录 gate and reports false. The swap waits a beat because
    /// presenting a sheet while another dismisses drops it.
    private func requireAccountFromMoreSheet() -> Bool {
        showTopicMoreSheet = false
        guard !isSignedIn else { return true }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showGuestGate = true
        }
        return false
    }

    /// Bottom gate for guests: sign up or log in to continue.
    private var guestGateSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("注册后可发帖、回复、点赞并加入感兴趣的节点。")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                Button {
                    showGuestGate = false
                    goToAuth(.signup)
                } label: {
                    moreSheetRow(AppString("注册"), systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.pressable)

                Button {
                    showGuestGate = false
                    goToAuth(.login)
                } label: {
                    moreSheetRow(AppString("登录"), systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.pressable)

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .background(Theme.bg)
            .navigationTitle("注册或登录以继续")
            .navigationBarTitleDisplayMode(.inline)
        }
        .standardSheet([.height(280)])
    }

    /// Leaves guest mode for the auth screen, opened on the chosen pane.
    private func goToAuth(_ mode: AuthMode) {
        presentAuth(app, mode: mode)
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
                // A notification deep link (/t/…/<post>) still jumps to the
                // exact reply — that happens on a freshly opened topic, where
                // the offset starts at the top and the walk down materialises
                // the rows on the way.
                .onChange(of: scrollTarget) { _, _ in
                    scrollToTargetIfLoaded(proxy)
                }
                .onChange(of: postedReplyEdge) { _, edge in
                    guard let edge else { return }
                    postedReplyEdge = nil
                    moveToPostedReply(edge, proxy: proxy)
                }
        }
    }

    /// Lands on the end of the thread the reply was added to, rather than on the
    /// reply itself. The row is already in the list — the store splices it in —
    /// so this is only about where the viewport sits.
    private func moveToPostedReply(_ edge: PostedReplyEdge, proxy: ScrollViewProxy) {
        switch edge {
        case .stay:
            return
        // Skipping the "load N more" rows: they carry no `.id`, so scrolling to
        // one is a no-op that would look like the move simply didn't happen.
        case .top:
            guard let first = topic.comments.first(where: { !$0.isLoadMore }) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(first.postNumber, anchor: .top)
            }
        case .bottom:
            guard let last = topic.comments.last(where: { !$0.isLoadMore }) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(last.postNumber, anchor: .bottom)
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
            // Lazy, not eager: the device froze in ScrollView's content
            // measurement walking the whole eager stack (an alignment-query
            // blowup deep in SwiftUI). A lazy stack only measures what's
            // materialized, which caps that pass regardless of content.
            LazyVStack(alignment: .leading, spacing: 0) {
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

                // The same band that separates one reply thread from the next,
                // so the first post reads as its own block rather than running
                // straight into the replies.
                groupSeparator
                    .padding(.top, 22)

                repliesSection(for: post)
                    .padding(.top, 22)
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
        // Pull down from the top to close, the way a sheet does.
        //
        // Keyed on the *release*, not on the offset: an offset threshold alone
        // closed the reader when you flung upward and momentum carried past
        // the top, which is not a request to leave. At the moment a fling is
        // released the offset is still positive — the overshoot happens
        // afterwards, while decelerating — so requiring the finger to have
        // just lifted separates "I pulled down" from "it bounced".
        //
        // Which is also how a sheet behaves, so the gesture should feel
        // familiar rather than merely correct.
        .onScrollPhaseChange { oldPhase, _, context in
            guard !isClosing,
                  oldPhase == .interacting || oldPhase == .tracking,
                  context.geometry.contentOffset.y < -90
            else { return }
            isClosing = true
            close()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func floatingReaderHeader(for post: Post) -> some View {
        HStack(spacing: 8) {
            readerHeaderGlassButton(borderShape: .circle) {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: readerHeaderControlHeight, height: readerHeaderControlHeight)
            }

            // Updates take the pill over while there are any, and are shown
            // at full opacity: the node name is decoration and can fade with
            // the scroll, but "3 条更新" is the only thing telling the reader
            // the page is behind, so hiding it at the top of the page — where
            // a reader most plausibly sits waiting — would defeat it.
            if topic.pendingUpdateCount > 0 {
                updatePill
            } else {
                // Only this subview reads `reveal`, so scroll updates re-render
                // the pill alone rather than the whole reader body.
                RevealingView(reveal: reveal) {
                    nodePill(for: post)
                }
            }

            Spacer(minLength: 0)

            readerTools(for: post)
        }
        .padding(.horizontal, readerHeaderHorizontalInset)
        .padding(.top, 8)
        .zIndex(2)
    }

    private func readerHeaderGlassButton<Label: View>(
        borderShape: GlassShape,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(height: readerHeaderControlHeight)
        }
        .glassButton(tint: readerHeaderGlassTint, shape: borderShape)
        .shadow(color: readerHeaderShadow, radius: 9, y: 6)
    }

    /// Re-keys the node lookup whenever either source of truth changes.
    private func nodeLookupKey(for post: Post) -> String {
        "\(post.node)|\(topic.topicCategoryID.map(String.init) ?? "")"
    }

    /// Resolves the node, preferring the loaded topic's category id.
    ///
    /// The id is authoritative — it comes straight off the topic payload —
    /// while `post.node` is a string the feed *mapped*: `FeedMapper` writes
    /// `"n/nodeloc"` whenever it can't find the topic's category, and
    /// `AppState.openTopic` writes `""`. Trusting the string first is what left
    /// the pill showing a raw `n/…` path instead of the node's name.
    ///
    /// The slug is still worth trying: it is available immediately, so a post
    /// opened from a list paints the right name before the topic finishes
    /// loading.
    private func resolveNodeSummary(for post: Post) async {
        if let categoryID = topic.topicCategoryID,
           let resolved = await NodeCatalog.shared.node(id: categoryID) {
            nodeSummary = resolved
            return
        }
        if !post.node.isEmpty,
           let resolved = await NodeCatalog.shared.node(slug: post.node) {
            nodeSummary = resolved
        }
    }

    /// Replaces the node pill while replies are waiting.
    private var updatePill: some View {
        readerHeaderGlassButton(
            borderShape: .capsule,
            action: {
                Task { await topic.loadPendingUpdates() }
            }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("\(topic.pendingUpdateCount) 条更新")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: readerHeaderControlHeight)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func nodePill(for post: Post) -> some View {
        readerHeaderGlassButton(
            borderShape: .capsule,
            action: { openNodeFromPill() }
        ) {
            HStack(spacing: 5) {
                if let logo = nodeSummary?.logoURL {
                    CachedRemoteImage(url: logo) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(nodePillLabel(for: post))
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(width: readerNodePillWidth, height: readerHeaderControlHeight, alignment: .leading)
        }
        // Only live once the node is known — the pill was unconditionally inert
        // before, so it never navigated anywhere.
        .allowsHitTesting(nodeSummary != nil)
    }

    /// Opens the node this topic lives in.
    private func openNodeFromPill() {
        guard let slug = nodeSummary?.slug, !slug.isEmpty else { return }
        app.openNode(slug: slug)
    }

    /// The node's real name once known.
    ///
    /// The fallback drops the `n/` so a topic still loading reads as a name
    /// rather than a URL path; `FeedMapper`'s placeholder slug would otherwise
    /// surface as "n/nodeloc".
    private func nodePillLabel(for post: Post) -> String {
        if let name = nodeSummary?.name, !name.isEmpty { return name }
        guard !post.node.isEmpty else { return "" }
        return post.node.hasPrefix("n/") ? String(post.node.dropFirst(2)) : post.node
    }

    /// Grouped glass capsule matching the node page's top-right tools.
    private func readerTools(for post: Post) -> some View {
        HStack(spacing: 6) {
            Button {
                close()
                app.tab = .search
            } label: {
                readerToolIcon("magnifyingglass")
            }
            .buttonStyle(.pressable)

            Button { showSortDialog = true } label: { readerToolIcon("slider.horizontal.3") }
                .buttonStyle(.pressable)

            Button { showTopicMoreSheet = true } label: { readerToolIcon("ellipsis") }
                .buttonStyle(.pressable)

            readerAvatar
        }
        .padding(.horizontal, 8)
        // Same as the node page: `.glass` adds 7pt above/below a 34pt label for
        // a 48pt capsule, reproduced here so the two headers match exactly.
        .padding(.vertical, 7)
        .glassSurface(tint: Theme.bg.opacity(0.34), interactive: true)
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
                    .buttonStyle(.pressable)
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

    /// The signed-in user's avatar (or a generic guest one). Tapping opens the
    /// own profile; guests get the 注册/登录 gate instead.
    private var readerAvatar: some View {
        let me = ProfileTabAvatarStore.shared
        return Button {
            if isSignedIn {
                guard !me.username.isEmpty else { return }
                openProfile(UserProfileTarget(
                    username: me.username,
                    displayName: me.displayName,
                    avatarURL: me.avatarURL
                ))
            } else {
                showGuestGate = true
            }
        } label: {
            if isSignedIn {
                RemoteAvatar(
                    url: me.avatarURL,
                    letter: me.initial,
                    variant: me.variant,
                    size: 26
                )
                .overlay(alignment: .bottomLeading) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.muted(0.4))
                    .frame(width: 26, height: 26)
            }
        }
        .buttonStyle(.pressable)
    }

    private var isSignedIn: Bool { app.authed && !app.isGuest }

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
            .buttonStyle(.pressable)
            .disabled(authorProfileTarget(for: post) == nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(topic.firstAuthor?.username ?? post.authorUsername ?? post.node)
                        .font(Theme.body(13, weight: .semibold))
                    authorFlairBadge(topic.firstAuthorFlairURL)
                    authorTitleChip(
                        topic.firstAuthorTitle,
                        style: topic.titleStyle(for: topic.firstAuthorTitle)
                    )
                }
                HStack(spacing: 6) {
                    // The topic's own post time, not the bump time the feed row
                    // carried in.
                    Text(topic.firstPostTime ?? post.time)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted(0.48))
                    postSourceBadge(topic.firstPostSource)
                }
            }
            Spacer(minLength: 0)
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
        return VStack(alignment: .leading, spacing: 10) {
            // Above the controls, on its own line: the tally is what the post
            // received, and reading it shouldn't mean parsing it out of a row
            // of things to press.
            if !topic.firstPostReactions.isEmpty || hasRewards {
                HStack(spacing: 14) {
                    if !topic.firstPostReactions.isEmpty, let firstPostID = topic.firstPostID {
                        Button {
                            reactionDetail = ReactionTarget(postID: firstPostID)
                        } label: {
                            ReactionSummary(reactions: topic.firstPostReactions)
                        }
                        .buttonStyle(.pressable)
                    }

                    // Beside the reactions, not among the controls: both lines
                    // report what the post received.
                    if hasRewards {
                        Button {
                            rewardDetail = RewardDetail(rewards: topic.firstPostRewards)
                        } label: {
                            rewardTotalLabel(topic.firstPostRewards)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }

            HStack(spacing: 10) {
                // Its own capsule. Grouping the score with the reply count read
                // as one control with two numbers in it.
                actionCapsule {
                    if let score = topic.firstPostVoteScore, let firstPostID = topic.firstPostID {
                        VoteControl(
                            score: score,
                            direction: topic.firstPostVoteDirection,
                            canVoteDown: topic.firstPostCanVoteDown,
                            isEnabled: !isOwn
                        ) { direction, reaction in
                            Task {
                                await topic.vote(direction, postID: firstPostID, reaction: reaction)
                            }
                        }
                    } else {
                        // No vote plugin for this category: the like it always
                        // was. You can't like your own post, so it's a stat then.
                        Button {
                            Task { await topic.toggleFirstPostLike() }
                        } label: {
                            Label(
                                "\(topic.firstPostLikeCount)",
                                systemImage: topic.firstPostLikedByMe ? "heart.fill" : "heart"
                            )
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(topic.firstPostLikedByMe ? Theme.love : Theme.muted(0.5))
                        }
                        .buttonStyle(.pressable)
                        .disabled(isOwn)
                    }
                }

                actionCapsule {
                    Label("\(replyCount(for: post))", systemImage: "bubble.left")
                        .labelStyle(CompactLabelStyle())
                        .foregroundStyle(Theme.muted(0.5))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 8)

                postActionIcon("arrow.2.squarepath") { startRepost(for: post) }
                // No 打赏 button on your own post.
                if !isOwn {
                    postActionAsset("LucideZap") {
                        if let id = topic.firstPostID { rewardTarget = id }
                    }
                }
            }
        }
        .foregroundStyle(Theme.muted(0.5))
    }

    private var hasRewards: Bool {
        topic.firstPostRewards.contains { $0.amount > 0 }
    }

    /// Every control in the OP's action row is this tall, so the capsules and
    /// the round buttons line up instead of each being sized by its contents.
    private static let actionControlHeight: CGFloat = 40

    /// The rounded container the OP's stat groups share.
    private func actionCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .font(Theme.body(12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: Self.actionControlHeight)
        .background(Theme.surface, in: Capsule())
    }

    /// The total-reward chip shared by the OP and reply action bars. Lucide's
    /// `zap`, filled, so it carries the same weight as the emoji beside it.
    private func rewardTotalLabel(_ rewards: [PostReward]) -> some View {
        let total = rewards.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        return HStack(spacing: 4) {
            Image("LucideZapFilled")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text("\(total)")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(Theme.body(12, weight: .semibold))
        .foregroundStyle(Theme.accent2)
    }

    /// Same button, drawn from a bundled asset rather than an SF Symbol.
    private func postActionAsset(_ assetName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(Theme.muted(0.55))
                .frame(width: Self.actionControlHeight, height: Self.actionControlHeight)
                .background(Theme.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressableIcon)
    }

    /// A tappable icon in the OP action bar, on the same filled shape the stat
    /// groups use — a bare glyph beside two capsules didn't read as a button.
    private func postActionIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted(0.55))
                .frame(width: Self.actionControlHeight, height: Self.actionControlHeight)
                .background(Theme.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressableIcon)
    }

    /// Opens the composer targeting a specific user's post.
    private func startReply(to author: String?, postNumber: Int) {
        replyTarget = author
        replyTargetNumber = postNumber
        isReplyFocused = true
    }

    /// Opens the composer pre-filled to repost this topic: original title, plus
    /// a link to the original that oneboxes into a preview. Both stay editable.
    /// Opens the composer on this topic.
    ///
    /// The raw comes from the server: the reader holds parsed blocks, and
    /// rebuilding markdown from them would quietly rewrite anything the parser
    /// didn't model.
    private func startTopicEdit(for post: Post) async {
        guard let firstPostID = topic.firstPostID else { return }
        guard let raw = await topic.rawBody(postID: firstPostID) else {
            ToastCenter.shared.show(AppString("无法读取正文，请稍后重试"))
            return
        }
        // The already-resolved node first; `post.node` is empty for a topic
        // opened from a link, which would have dropped the node from the edit
        // and made the composer look like it was moving the topic.
        var categoryID = nodeSummary?.id
        if categoryID == nil, !post.node.isEmpty {
            categoryID = await NodeCatalog.shared.node(slug: post.node)?.id
        }

        app.composeEditTarget = AppState.TopicEdit(
            topicID: post.id,
            postID: firstPostID,
            title: topic.topicTitle.isEmpty ? post.title : topic.topicTitle,
            raw: raw,
            categoryID: categoryID,
            rendered: topic.content.isEmpty ? nil : topic.content
        )
        withAnimation(.overlayPush) { app.overlay = .compose }
    }

    /// Opens the composer quoting this topic.
    ///
    /// The topic travels as a value, not as a URL typed into the body: the
    /// composer draws it as the card it will become and prepends the link when
    /// it builds the raw. A onebox is a bare topic URL alone on its own line —
    /// that is why the link can't just be dropped in front of whatever the
    /// reposter types.
    private func startRepost(for post: Post) {
        // The canonical slug URL, which only a loaded topic knows.
        app.startRepost(
            of: post,
            url: topic.url(forTopicID: post.id),
            author: topic.firstAuthor?.username ?? post.authorUsername
        )
    }

    /// The signed-in user's username, for "can't act on my own post" checks.
    private var currentUsername: String? { DiscourseAuth.shared.username }

    private func isOwnAuthor(_ username: String?) -> Bool {
        guard let me = currentUsername, let username else { return false }
        return me.caseInsensitiveCompare(username) == .orderedSame
    }

    private func repliesSection(for post: Post) -> some View {
        VStack(spacing: 0) {
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
                                titleStyle: topic.titleStyle(for: comment.authorTitle),
                                isCollapsed: collapsedCommentIDs.contains(comment.id),
                                onToggleCollapse: { toggleCollapse(comment) },
                                onOpenAuthor: { openProfile($0) },
                                isOwn: isOwnAuthor(comment.author),
                                onReply: { startReply(to: comment.author, postNumber: comment.postNumber) },
                                onLike: { Task { await topic.toggleReplyLike(id: comment.id) } },
                                onVote: { direction, reaction in
                                    Task {
                                        await topic.vote(direction, postID: comment.id, reaction: reaction)
                                    }
                                },
                                onReward: { rewardTarget = comment.id },
                                onRewardDetail: { rewardDetail = RewardDetail(rewards: comment.rewards) },
                                onMore: { moreSheetComment = comment },
                                onReactionDetail: {
                                    reactionDetail = ReactionTarget(postID: comment.id)
                                },
                                onRecover: { Task { await topic.recoverPost(id: comment.id) } },
                                onReveal: { Task { await topic.revealIgnored(postID: comment.id) } },
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
        .buttonStyle(.pressable)
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
        .skeletonPulsing()
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
        .skeletonPulsing()
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
                    if await topic.submitReply(text, topicID: post.id, replyToPostNumber: replyTo) != nil {
                        draft = ""          // resets + collapses the composer
                        replyTarget = nil
                        replyTargetNumber = nil
                        postedReplyEdge = postedEdge(nestedUnder: replyTo)
                        ToastCenter.shared.show(AppString("回复已发布"))
                    }
                }
            }
        )
    }

    /// Mirrors where the store put the row.
    private func postedEdge(nestedUnder parent: Int?) -> PostedReplyEdge {
        if let parent, parent > 1 { return .stay }
        return topic.replySort == .newest ? .top : .bottom
    }

    private var loadMoreTitle: String { AppString("加载更多回复") }

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

    /// Any reply can collapse to its header line, Reddit-style; its whole
    /// subtree hides with it (see `visibleComments`).
    private func toggleCollapse(_ comment: PostComment) {
        withAnimation(.quick) {
            if collapsedCommentIDs.contains(comment.id) {
                collapsedCommentIDs.remove(comment.id)
            } else {
                collapsedCommentIDs.insert(comment.id)
            }
        }
    }
}

private struct NestedReplyRow: View {
    let comment: PostComment
    /// The author's 头衔 design, resolved once per topic by the store.
    var titleStyle: TitleStyle?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpenAuthor: (UserProfileTarget) -> Void
    /// True when the reply is the current user's own (can't like/reward it).
    let isOwn: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onVote: (VoteDirection, String?) -> Void
    let onReward: () -> Void
    let onRewardDetail: () -> Void
    let onMore: () -> Void
    let onReactionDetail: () -> Void
    /// Undeletes the reply (staff, `can_recover`).
    var onRecover: (() -> Void)?
    /// Fetches back the body of a reply hidden by the viewer's ignore list.
    var onReveal: (() -> Void)?
    var onImageTap: ((PostImage) -> Void)?

    /// Staff-only, local: a deleted reply arrives with its body intact for
    /// staff, so revealing it is a disclosure toggle rather than a request.
    @State private var showsDeletedContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if comment.isPlaceholder {
                placeholderRow
            } else {
                fullRow
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

    /// A deleted reply, or one from someone this viewer ignores. The row stays
    /// so its surviving children keep their place in the thread, but there is
    /// nothing to read and nothing to act on — the same as the web, which draws
    /// a trash-can gutter and a one-line label.
    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: comment.isDeletedPlaceholder ? "trash" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                Text(comment.isDeletedPlaceholder ? AppString("此回复已删除") : AppString("已忽略该用户的回复"))
                    .font(Theme.body(12))

                // Staff get the deleted body in the same payload, so this only
                // toggles disclosure. An ignored reply's body has to be
                // fetched, hence the spinner.
                if comment.isDeletedPlaceholder, canRevealDeleted {
                    placeholderButton(showsDeletedContent ? "eye.slash" : "eye") {
                        withAnimation(.quick) { showsDeletedContent.toggle() }
                    }
                } else if comment.isIgnoredPlaceholder, let onReveal {
                    if comment.isRevealing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        placeholderButton("eye", action: onReveal)
                    }
                }

                if comment.canRecover, let onRecover {
                    placeholderButton("arrow.uturn.backward", action: onRecover)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.muted(0.45))

            if showsDeletedContent, canRevealDeleted {
                fullRow
            }
        }
        .padding(.vertical, 2)
    }

    /// True when there is actually something behind the placeholder: staff
    /// payloads keep `cooked`, everyone else's are blanked.
    private var canRevealDeleted: Bool {
        !comment.content.isEmpty
    }

    private func placeholderButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableIcon)
    }

    @ViewBuilder
    private var fullRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            replyHeader

            // Collapsed: just the header line (avatar + name); everything
            // else — content, actions, and the whole subtree — is hidden.
            if !isCollapsed {
                // Tapping the body collapses the reply, Reddit-style. Handed to
                // `PostContentView` rather than wrapped around it: it attaches
                // the gesture per block and lets a block holding a reference
                // badge report its own background taps, because a SwiftUI tap
                // around that block's `UIViewRepresentable` would cancel the
                // touch before the badge could be resolved.
                //
                // Links and image buttons keep their own gestures, which take
                // precedence.
                PostContentView(
                    content: comment.content,
                    metrics: .reply,
                    onImageTap: onImageTap,
                    onBackgroundTap: onToggleCollapse
                )

                // The red envelope plugin auto-claims on reply, so this is
                // the outcome of posting rather than an action to take.
                if let claim = comment.redEnvelopeClaim, let points = claim.pointsReceived {
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
    }

    private var replyHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            // The avatar still opens the profile; the *name* toggles the
            // collapse, so both destinations stay one tap away.
            Button {
                onOpenAuthor(UserProfileTarget(username: comment.author, displayName: nil, avatarURL: comment.avatarURL))
            } label: {
                RemoteAvatar(url: comment.avatarURL, letter: avatarLetter, variant: comment.id, size: 24)
            }
            .buttonStyle(.pressable)

            Button(action: onToggleCollapse) {
                Text(comment.author)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.pressable)

            authorFlairBadge(comment.flairURL)
            authorTitleChip(comment.authorTitle, style: titleStyle)

            if comment.isPinned {
                pinnedReplyBadge
            }

            Text("· \(comment.time)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.muted(0.42))

            postSourceBadge(comment.mobileSource)

            Spacer(minLength: 0)

            if comment.hasChildren || isCollapsed {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted(0.44))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isCollapsed ? AppString("展开回复") : AppString("收起回复"))
            }
        }
        // Collapsed rows re-expand from a tap anywhere on the line; the
        // avatar's own button keeps precedence for the profile.
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed { onToggleCollapse() }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 20) {
            // Total 打赏 received on this reply, tappable for the breakdown.
            if comment.rewards.contains(where: { $0.amount > 0 }) {
                Button(action: onRewardDetail) {
                    let total = comment.rewards.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                    HStack(spacing: 4) {
                        Image("LucideZapFilled")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text("\(total)")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.accent2)
                }
                .buttonStyle(.pressable)
            }

            Spacer(minLength: 0)

            // Left of the ⋮, so the tally sits with the row's other numbers
            // rather than among the buttons that change them.
            if !comment.reactions.isEmpty {
                Button(action: onReactionDetail) {
                    ReactionSummary(reactions: comment.reactions)
                }
                .buttonStyle(.pressable)
            }

            replyActionIcon("ellipsis", action: onMore)
            replyActionAsset("LucideReply", action: onReply)
            if let score = comment.voteScore {
                VoteControl(
                    score: score,
                    direction: comment.voteDirection,
                    canVoteDown: comment.canVoteDown,
                    isEnabled: !isOwn,
                    compact: true,
                    // No capsule around a reply's actions, so a rule between the
                    // arrows would be dividing nothing.
                    showsDivider: false,
                    onVote: onVote
                )
            } else {
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
                .buttonStyle(.pressable)
                .disabled(isOwn)
            }
            // No 打赏 button on your own reply.
            if !isOwn {
                replyActionAsset("LucideZap", action: onReward)
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
        .buttonStyle(.pressableIcon)
    }

    /// Same button for a bundled glyph. Sized to sit level with the SF Symbols
    /// beside it, which a 15pt font and a 17pt box happen to match.
    private func replyActionAsset(_ assetName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(Theme.muted(0.4))
        }
        .buttonStyle(.pressableIcon)
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

/// Marks a reply staff pinned to the top of the thread: the glyph alone, tinted.
/// The row is already dense with the name, flair, title and time, so the mark
/// has to earn its width — and a pin needs no caption.
var pinnedReplyBadge: some View {
    Image(systemName: "pin.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .accessibilityLabel("已置顶")
}

/// The 小尾巴 discourse-mobile attaches to a post: what the author's app said
/// it was running on, e.g. "iPhone". A bordered chip rather than more grey
/// text, matching the web plugin's own badge — and never emphasised, because
/// any client can claim any hardware and nothing here treats it as evidence.
@ViewBuilder
func postSourceBadge(_ source: String?) -> some View {
    if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(source)
            .font(Theme.body(10, weight: .medium))
            .foregroundStyle(Theme.muted(0.5))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
            .accessibilityLabel("发送自 \(source)")
    }
}

/// The user's worn title (头衔) after their name.
///
/// Styled with the admin's discourse-custom-badge design when there is one —
/// the profile page has always done this, and a reader showing the same title in
/// flat grey made the two screens disagree about the same fact. Plain text stays
/// the fallback for a title the plugin has no design for.
@ViewBuilder
func authorTitleChip(_ title: String?, style: TitleStyle? = nil) -> some View {
    if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
        if let style {
            StyledTitleText(text: title, style: style, font: Theme.body(11, weight: .semibold))
                .lineLimit(1)
        } else {
            Text(title)
                .font(Theme.body(11, weight: .medium))
                .foregroundStyle(Theme.muted(0.5))
                .lineLimit(1)
        }
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
                        .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                errorText = AppString("打赏失败，请稍后再试")
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
                Text(reward.username ?? AppString("未知用户"))
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
            HStack(spacing: 4) {
                Image("LucideZapFilled")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                Text("\(reward.amount)")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(Theme.body(14, weight: .semibold))
            .foregroundStyle(Theme.accent2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editing

/// Edits a post's markdown.
///
/// Loads the raw body from the server rather than trying to un-cook what's on
/// screen: the reader holds parsed blocks, and reconstructing markdown from them
/// would quietly rewrite whatever it didn't understand.
private struct PostEditSheet: View {
    let load: () async -> String?
    /// Returns whether it saved, so a failure keeps the draft on screen.
    let save: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var original = ""
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $draft)
                        .font(Theme.body(15))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                }
            }
            .background(Theme.bg)
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("保存") { submit() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .standardSheet([.large])
        .task {
            original = await load() ?? ""
            draft = original
            isLoading = false
        }
    }

    /// No empty saves, and no no-op saves — Discourse rejects an edit that
    /// changes nothing anyway.
    private var canSave: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard canSave else { return }
        isSaving = true
        Task {
            let saved = await save(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            isSaving = false
            if saved { dismiss() }
        }
    }
}


// MARK: - Reactions

/// The faces a post collected, at a glance: up to three, then the total.
///
/// Three because the row has to stay one line next to the action icons, and
/// because the tally is a summary — the breakdown is a tap away.
struct ReactionSummary: View {
    let reactions: [PostReaction]

    private static let maxFaces = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(topFaces, id: \.id) { reaction in
                CachedRemoteImage(url: reaction.id.flatMap(VoteFaces.imageURL(for:))) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 18, height: 18)
            }

            Text("\(total)")
                .font(Theme.body(12, weight: .semibold))
                .foregroundStyle(Theme.muted(0.6))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 2)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(total) 个表情回应")
    }

    /// Busiest first, so the three shown are the ones that carry the tally.
    private var topFaces: [PostReaction] {
        reactions
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .prefix(Self.maxFaces)
            .map { $0 }
    }

    private var total: Int {
        reactions.reduce(0) { $0 + ($1.count ?? 0) }
    }
}

extension PostReaction: Identifiable {}

/// Who reacted, grouped by face.
///
/// One request fills every tab: `reactions-users.json` answers with all the
/// groups, so switching tabs is local.
private struct ReactionUsersSheet: View {
    let postID: Int

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ReactionUsersResponse.ReactionGroup] = []
    @State private var selected: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !groups.isEmpty { tabs }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleUsers.isEmpty {
                    Text("还没有表情回应")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(visibleUsers.enumerated()), id: \.offset) { _, entry in
                                row(entry)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("表情回应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .standardSheet()
        .task { await load() }
    }

    /// 全部 plus one per face, counts included — the same shape the Android app
    /// shows.
    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                tab(face: nil, count: totalCount)
                ForEach(groups) { group in
                    tab(face: group.id, count: group.count ?? group.users?.count ?? 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func tab(face: String?, count: Int) -> some View {
        let isSelected = selected == face
        return Button {
            selected = face
        } label: {
            HStack(spacing: 6) {
                if let face {
                    CachedRemoteImage(url: VoteFaces.imageURL(for: face)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 18, height: 18)
                } else {
                    Text("全部")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Text("\(count)")
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.muted(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Theme.surface,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Theme.accent.opacity(0.5) : Theme.divider,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.pressable)
    }

    private func row(_ entry: (face: String, user: ReactionUsersResponse.ReactionUser)) -> some View {
        HStack(spacing: 12) {
            RemoteAvatar(
                url: entry.user.avatarTemplate.flatMap { DiscourseClient().avatarURL(template: $0, size: 80) },
                letter: String(entry.user.username.prefix(1)).uppercased(),
                variant: abs(entry.user.username.hashValue),
                size: 38
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.user.name?.isEmpty == false ? entry.user.name! : entry.user.username)
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("@\(entry.user.username)")
                    .font(Theme.body(11))
                    .foregroundStyle(Theme.muted(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            CachedRemoteImage(url: VoteFaces.imageURL(for: entry.face)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The selected tab's members, or everyone's when 全部 is chosen. The face
    /// travels with each row so the 全部 list can show which one it was.
    private var visibleUsers: [(face: String, user: ReactionUsersResponse.ReactionUser)] {
        groups
            .filter { selected == nil || $0.id == selected }
            .flatMap { group in (group.users ?? []).map { (face: group.id, user: $0) } }
    }

    private var totalCount: Int {
        groups.reduce(0) { $0 + ($1.count ?? $1.users?.count ?? 0) }
    }

    private func load() async {
        defer { isLoading = false }
        groups = (try? await DiscourseClient().reactionUsers(postID: postID))?.reactionUsers ?? []
    }
}
