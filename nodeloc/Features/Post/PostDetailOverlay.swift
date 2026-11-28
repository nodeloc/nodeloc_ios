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
    /// This presentation context's browser. `BrowserState.shared` belongs to
    /// the root, whose cover can't present above a routed page's cover.
    @Environment(BrowserState.self) private var browser
    /// Pops this page off the page stack (deleting the topic leaves).
    var onClose: (() -> Void)?
    /// The post this page shows: the list row's copy, so the title, node and
    /// author are on screen from the first frame while the topic loads.
    let post: Post
    @State private var topic = TopicStore()
    @State private var draft = ""
    @State private var collapsedCommentIDs: Set<Int> = []
    /// Full-screen image viewer state. Non-empty means the viewer is showing.
    @State private var viewerImages: [PostImage] = []
    @State private var viewerIndex = 0
    /// The post's node, resolved for its logo — `Post` carries only "n/slug".
    @State private var nodeSummary: SidebarNodeSummary?
    /// A reply's post number to scroll to once its row is loaded, taken from
    /// `AppState.pendingReplyPostNumber` when a notification opens the topic.
    @State private var scrollTarget: Int?
    /// Reply rows the lazy list has built, by post number. Not observed: a
    /// jump reads it, nothing draws from it.
    @State private var builtRows = BuiltRows()
    /// Drives the page by offset, for walking down to a row not built yet.
    @State private var scrollPosition = ScrollPosition()
    /// Reveals n/slug in the bar as the title scrolls under it. The range is
    /// set from the title's frame once it is laid out.
    @State private var chrome = BannerScrollChrome(revealStart: 60, revealLength: 60)
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
    /// The user being replied to (drives the composer's "回复xxx" header). Its
    /// post number becomes `reply_to_post_number` on submit.
    @State private var replyTarget: String?
    @State private var replyTargetNumber: Int?
    /// A reply the ellipsis (…) sheet is open for.
    @State private var showsAppealSheet = false
    /// A hidden reply its author is appealing (staff hiding).
    @State private var appealPostID: AppealPostTarget?
    /// Which post the editor is open on, and whether it's the OP (whose body
    /// is the topic's first post rather than a reply).
    @State private var editTarget: EditTarget?
    /// The bookmark whose 收藏夹 is being chosen, after 保存书签.
    @State private var folderChoice: FolderChoice?
    /// 关闭主题 / 重新开放 from the ⋯ menu asks first.
    @State private var confirmToggleClosed = false

    private struct FolderChoice: Identifiable {
        let bookmark: NLSaved.Bookmark
        var id: Int { bookmark.id }
    }
    /// 编辑历史 for the topic's first post or a reply.
    @State private var historyTarget: EditHistoryTarget?
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
    @State private var showPinSheet = false
    /// 版主操作 (App-iOS-PostMod).
    @State private var showModSheet = false
    /// 处理帖子和作者 on a post, once the server said what may be done.
    @State private var moderateRequest: ReaderModerateRequest?
    @State private var flagTarget: FlagTarget?
    /// The 注册/登录 gate a guest gets from the header avatar (and from
    /// actions that need an account).
    @State private var showGuestGate = false
    /// The reader asked to reply while the lottery's bar holds the bottom.
    @State private var lotteryReplyMode = false
    @FocusState private var isReplyFocused: Bool
    /// Bumped to open the reply panel focused (see `ReplyComposer.focusRequest`).
    @State private var replyFocusRequest = 0
    @State private var replyCollapseRequest = 0
    /// The reply panel is up: the page behind it dims (App-iOS-Reply).
    @State private var replyPanelOpen = false

    var body: some View {
        detailSurface(for: post)
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .tabRootNavigationBar()
            .toolbar { readerToolbar(for: post) }
            // "N 条更新": the replies that arrived while reading, under the bar.
            .overlay(alignment: .top) {
                if topic.pendingUpdateCount > 0 {
                    updatePill
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: topic.pendingUpdateCount > 0)
            // A topic that can't be opened is a page of its own (App-iOS-Gone,
            // NoAccess), whichever way the reader got here.
            .overlay {
                if topic.loadFailure == .missing || topic.loadFailure == .denied {
                    TopicUnavailableView(
                        status: topic.loadFailure == .missing ? 404 : 403,
                        code: topic.loadErrorCode,
                        message: topic.loadErrorMessage
                    )
                    .transition(.opacity)
                }
            }
        .task(id: post.id) {
            // Consume the scroll target before loading so it can't leak into a
            // later, unrelated topic opened in the same overlay.
            scrollTarget = app.pendingReplyPostNumber
            app.pendingReplyPostNumber = nil
            // A list row's comment button: arrive with the reply panel open.
            let wantsReply = app.pendingReplyFocus
            app.pendingReplyFocus = false
            // 草稿箱 › 继续编辑 on a reply draft.
            let replyDraft = app.pendingReplyDraft
            app.pendingReplyDraft = nil
            await topic.load(topicID: post.id)
            if topic.loadFailure == nil {
                // 浏览记录, kept on the device.
                BrowsingHistory.shared.record(HistoryEntry(
                    kind: .topic,
                    topicID: post.id,
                    title: topic.topicTitle.isEmpty ? post.title : topic.topicTitle,
                    nodeSlug: pillSlug(for: post),
                    author: topic.firstAuthor?.username ?? post.authorUsername,
                    viewedAt: Date(),
                    lastFloor: 1,
                    totalFloors: topic.totalReplyCount > 0 ? topic.totalReplyCount + 1 : nil,
                    votes: post.voteScore ?? post.baseVotes,
                    replies: replyCount(for: post),
                    imageURL: post.imageURL
                ))
            }
            await topic.refreshTrade()
            if let replyDraft, topic.removal == nil, isSignedIn {
                if let number = replyDraft.replyTo, number > 1 {
                    replyTarget = replyDraft.replyToUser
                    replyTargetNumber = number
                }
                draft = replyDraft.text
                focusReplyField()
            } else if wantsReply, topic.removal == nil, isSignedIn { focusReplyField() }
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
            BrowsingHistory.shared.updateFloor(
                topicID: post.id,
                floor: reader.furthest,
                total: topic.totalReplyCount > 0 ? topic.totalReplyCount + 1 : nil
            )
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
        // 置顶设置: node pin / global pin / banner / dismiss-for-me.
        .alert(
            topic.isTopicClosed ? AppString("重新开放这个主题？") : AppString("关闭这个主题？"),
            isPresented: $confirmToggleClosed
        ) {
            Button(topic.isTopicClosed ? AppString("重新开放") : AppString("关闭主题"), role: topic.isTopicClosed ? nil : .destructive) {
                Task { await topic.toggleClosed() }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text(topic.isTopicClosed ? AppString("大家又可以回复了。") : AppString("关闭后不能再回复，已有的内容保留。"))
        }
        .sheet(item: $folderChoice) { choice in
            BookmarkFolderChooser(current: choice.bookmark.folderId, onRemove: {
                Task {
                    do {
                        try await BookmarkAPI.remove([choice.bookmark.id])
                        ToastCenter.shared.show(AppString("已取消收藏"))
                    } catch {
                        ToastCenter.shared.show(BookmarkAPI.message(error))
                    }
                }
            }) { folderID in
                do {
                    try await BookmarkAPI.move([choice.bookmark.id], to: folderID)
                    ToastCenter.shared.show(AppString("已移到收藏夹"))
                    return nil
                } catch {
                    return BookmarkAPI.message(error)
                }
            }
        }
        .sheet(isPresented: $showPinSheet) {
            TopicPinSheet(topic: topic)
        }
        .sheet(isPresented: $showModSheet) {
            TopicModSheet(
                topic: topic,
                title: topic.topicTitle.isEmpty ? post.title : topic.topicTitle,
                nodeSlug: pillSlug(for: post),
                author: topic.firstAuthor?.username ?? post.authorUsername,
                onPin: { presentAfterSheet { showPinSheet = true } },
                onModerate: {
                    if let first = topic.firstPostID { presentAfterSheet { openModerate(postID: first) } }
                }
            )
            // Tall enough for the whole list at once, as in the design.
            .standardSheet([.fraction(0.8), .large])
        }
        .sheet(item: $moderateRequest) { request in
            PostModerateSheet(
                postID: request.postID,
                options: request.options,
                onDone: {
                    Task { await topic.load(topicID: post.id) }
                }
            )
            .standardSheet([.large])
        }
        // 举报 — native, not a trip to the website.
        .sheet(item: $flagTarget) { target in
            FlagSheet(target: target)
        }
        // The author contesting a removal. One attempt, seven days.
        .sheet(isPresented: $showsAppealSheet) {
            AppealSheet(
                title: AppString("申诉"),
                note: AppString("说明你认为这次处理不妥的理由。一次处理只能申诉一次，管理人员会复核。")
            ) { text in
                await topic.appealRemoval(text: text)
            }
        }
        .sheet(item: $appealPostID) { target in
            AppealSheet(
                title: AppString("申诉"),
                note: AppString("说明你认为这次处理不妥的理由。一次处理只能申诉一次，管理人员会复核。")
            ) { text in
                do {
                    try await DiscourseClient().appealRemoval(postID: target.id, text: text)
                    ToastCenter.shared.show(AppString("申诉已提交，管理人员会处理"))
                    return true
                } catch {
                    ToastCenter.shared.showError(error)
                    return false
                }
            }
        }
        // Guests get the shared login prompt (`requestLogin`).
        .sheet(item: $reactionDetail) { target in
            ReactionUsersSheet(postID: target.postID)
        }
        .sheet(item: $historyTarget) { target in
            EditHistorySheet(
                target: target,
                load: { try await topic.revisions(postID: target.postID) },
                restore: { number in await topic.restoreRevision(postID: target.postID, number: number) }
            )
        }
        .sheet(item: $editTarget) { target in
            PostEditSheet(
                load: { await topic.rawBody(postID: target.postID) },
                save: { raw in await topic.saveEdit(postID: target.postID, raw: raw) }
            )
        }
        .alert(
            AppString("删除这条回复？"),
            isPresented: Binding(
                get: { deleteTargetPostID != nil },
                set: { if !$0 { deleteTargetPostID = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                guard let postID = deleteTargetPostID else { return }
                deleteTargetPostID = nil
                Task { await topic.deletePost(id: postID) }
            }
            Button("取消", role: .cancel) { deleteTargetPostID = nil }
        }
        .alert(
            AppString("删除整个主题？"),
            isPresented: $isConfirmingTopicDelete
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

    /// A reply's ⋯ as the system pull-down, in the same sections as the
    /// topic's: everyday, the author's, moderation, then the destructive
    /// ones. Follow-up sheets and confirmations open after the menu closes.
    @ViewBuilder
    private func replyMenuContent(_ comment: PostComment, post: Post) -> some View {
        let postURL = DiscourseConfig.baseURL.appending(path: "t/\(post.id)/\(comment.postNumber)")
        Section {
            ShareLink(item: postURL) {
                Label(AppString("分享"), systemImage: "square.and.arrow.up")
            }
            Button {
                startRepost(for: post)
            } label: {
                Label(AppString("转发"), systemImage: "arrow.2.squarepath")
            }
            Button {
                Task { await bookmarkWithToast(postID: comment.id) }
            } label: {
                Label(AppString("保存书签"), systemImage: "bookmark")
            }
        }

        if comment.canEdit || comment.editCount > 0 {
            Section {
                if comment.canEdit {
                    Button {
                        editTarget = EditTarget(postID: comment.id)
                    } label: {
                        Label(AppString("编辑"), systemImage: "square.and.pencil")
                    }
                }
                if comment.editCount > 0 {
                    Button {
                        historyTarget = EditHistoryTarget(postID: comment.id, canRestore: comment.canEdit)
                    } label: {
                        Label(
                            AppString("编辑历史 · 已编辑 \(comment.editCount) 次"),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        }

        // Staff only and only for a top-level reply (置顶); the author or a
        // node moderator on a help topic (采纳) — the server reports both.
        if topic.canPin(comment) || topic.canAccept(comment) || (topic.canModerateTopic && !comment.isMine) {
            Section {
                if topic.canModerateTopic, !comment.isMine {
                    Button {
                        openModerate(postID: comment.id)
                    } label: {
                        Label(AppString("处理帖子和作者…"), systemImage: "checkmark.shield")
                    }
                }
                if topic.canPin(comment) {
                    Button {
                        Task { await topic.togglePin(postID: comment.id) }
                    } label: {
                        Label(
                            comment.isPinned ? AppString("取消置顶") : AppString("置顶"),
                            systemImage: comment.isPinned ? "pin.slash" : "pin"
                        )
                    }
                }
                if topic.canAccept(comment) {
                    Button {
                        Task { await topic.toggleAcceptedAnswer(postID: comment.id) }
                    } label: {
                        Label(
                            comment.isAcceptedAnswer ? AppString("撤销采纳") : AppString("采纳为最佳答案"),
                            systemImage: comment.isAcceptedAnswer ? "checkmark.seal.slash" : "checkmark.seal"
                        )
                    }
                }
            }
        }

        Section {
            Button(role: .destructive) {
                flagTarget = FlagTarget(
                    kind: .post,
                    id: comment.id,
                    authorUsername: comment.author.isEmpty ? nil : comment.author
                )
            } label: {
                Label(AppString("举报"), systemImage: "flag")
            }
            // Guideline 1.2 wants blocking reachable wherever reporting is.
            if !comment.author.isEmpty, !comment.isMine {
                Button(role: .destructive) {
                    Task { await blockAuthor(comment.author, postID: comment.id) }
                } label: {
                    Label(AppString("屏蔽作者"), systemImage: "hand.raised")
                }
            }
            if comment.canDelete, comment.isMine || !topic.canModerateTopic {
                Button(role: .destructive) {
                    deleteTargetPostID = comment.id
                } label: {
                    Label(
                        comment.isMine ? AppString("删除") : AppString("删除（管理）"),
                        systemImage: "trash"
                    )
                }
            }
        }
    }

    /// The header ⋯ as the system pull-down: 更多操作 on the topic itself.
    /// Everyday actions first, then the author's, then moderation, then 删除
    /// last. Every author and moderation entry is shown on a `can_*` the
    /// server put on this topic for this viewer, so a node moderator sees them
    /// on their own node and nowhere else. Entries that need a form or a
    /// confirmation open it after the menu closes.
    @ViewBuilder
    private func topicMenuContent(_ post: Post) -> some View {
        // The canonical `/t/{slug}/{id}` once the topic is loaded: an id-only
        // link works but only after a redirect, and it reads as nothing when
        // pasted into a chat.
        let topicURL = topic.url(forTopicID: post.id)
        Section {
            ShareLink(item: topicURL) {
                Label(AppString("分享"), systemImage: "square.and.arrow.up")
            }
            Button {
                copyLink(topicURL)
            } label: {
                Label(AppString("复制链接"), systemImage: "link")
            }
            Button {
                guard requireAccountFromMoreSheet() else { return }
                if let firstPostID = topic.firstPostID {
                    Task { await bookmarkWithToast(postID: firstPostID) }
                }
            } label: {
                Label(AppString("保存书签"), systemImage: "bookmark")
            }
            Button {
                guard requireAccountFromMoreSheet() else { return }
                startRepost(for: post)
            } label: {
                Label(AppString("转发"), systemImage: "arrow.2.squarepath")
            }
            if !(topic.canPinTopic || topic.canBannerTopic), topic.isTopicPinned, isSignedIn {
                // Clearing a pin for yourself needs no moderation rights — it
                // writes `topic_users.cleared_pinned_at` — but it does need an
                // account to write it against.
                Button {
                    Task { await topic.setPinClearedForMe(!topic.isPinClearedForMe) }
                } label: {
                    Label(
                        topic.isPinClearedForMe ? AppString("恢复置顶") : AppString("对我取消置顶"),
                        systemImage: topic.isPinClearedForMe ? "pin" : "pin.slash"
                    )
                }
            }
        }

        if topic.canEditTopic || topic.canEditFirstPost || topic.firstPostEditCount > 0 {
            Section {
                // One 编辑, not a title form and a body form: the composer
                // takes the node, the title and the body together.
                if topic.canEditTopic || topic.canEditFirstPost {
                    Button {
                        Task { await startTopicEdit(for: post) }
                    } label: {
                        Label(AppString("编辑"), systemImage: "square.and.pencil")
                    }
                }
                if topic.firstPostEditCount > 0, let firstPostID = topic.firstPostID {
                    Button {
                        historyTarget = EditHistoryTarget(postID: firstPostID, canRestore: topic.canEditFirstPost)
                    } label: {
                        Label(
                            AppString("编辑历史 · 已编辑 \(topic.firstPostEditCount) 次"),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        }

        if topic.canModerateTopic {
            // Everything a manager does to the topic is in one sheet, and
            // every removal or penalty in its 处理帖子和作者… (PostMod).
            Section {
                Button {
                    showModSheet = true
                } label: {
                    Label(AppString("版主操作…"), systemImage: "checkmark.shield")
                }
            }
        } else if topic.canCloseTopic || topic.canPinTopic || topic.canBannerTopic {
            Section {
                // 置顶 is not one switch: node pin, global pin, banner and the
                // per-reader dismissal are four different things, so this
                // opens the sheet that shows the current mode.
                if topic.canPinTopic || topic.canBannerTopic {
                    Button {
                        showPinSheet = true
                    } label: {
                        Label(
                            topic.isTopicPinned || topic.isTopicBanner ? AppString("置顶设置") : AppString("置顶主题"),
                            systemImage: topic.isTopicPinned || topic.isTopicBanner ? "pin.fill" : "pin"
                        )
                    }
                }
                if topic.canCloseTopic {
                    Button {
                        confirmToggleClosed = true
                    } label: {
                        Label(
                            topic.isTopicClosed ? AppString("重新开放") : AppString("关闭主题"),
                            systemImage: topic.isTopicClosed ? "lock.open" : "lock"
                        )
                    }
                }
            }
        }

        Section {
            Button(role: .destructive) {
                flagTarget = FlagTarget(
                    kind: .topic,
                    id: post.id,
                    authorUsername: topic.firstAuthor?.username ?? post.authorUsername
                )
            } label: {
                Label(AppString("举报"), systemImage: "flag")
            }
            // Either flag: `details.can_delete` is the moderator's, while an
            // author inside the edit window gets it on the first post instead
            // — deleting that *is* deleting the topic.
            // A manager deletes someone else's topic through 处理帖子和作者,
            // which also records why; the author keeps the plain 删除.
            if topic.canDeleteTopic || topic.canDeleteFirstPost,
               !topic.canModerateTopic || isOwnAuthor(topic.firstAuthor?.username ?? post.authorUsername) {
                Button(role: .destructive) {
                    isConfirmingTopicDelete = true
                } label: {
                    Label(AppString("删除主题"), systemImage: "trash")
                }
            }
        }
    }

    /// 处理帖子和作者: the server says what this reader may do with the post
    /// (403 when nothing), then the handling dialog opens on that.
    private func openModerate(postID: Int) {
        Task {
            do {
                let options = try await DiscourseClient().postModerateOptions(postID: postID)
                moderateRequest = ReaderModerateRequest(postID: postID, options: options)
            } catch {
                ToastCenter.shared.showError(error)
            }
        }
    }

    /// Presenting a sheet while another is still dismissing drops it.
    private func presentAfterSheet(_ action: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    /// Bookmarks with a visible outcome either way — silently swallowing the
    /// failure left the button looking broken.
    /// Saves at once (the server files it under 未分类; it takes no folder
    /// at save time), then offers 选择收藏夹 on the notice.
    private func bookmarkWithToast(postID: Int) async {
        do {
            try await topic.bookmark(postID: postID)
            ToastCenter.shared.show(AppString("已保存到未分类"), actionTitle: AppString("选择收藏夹")) {
                Task { await chooseFolder(postID: postID) }
            }
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Finds the bookmark just made (the save answers without its id) and
    /// opens the chooser for it.
    private func chooseFolder(postID: Int) async {
        let title = topic.topicTitle.isEmpty ? post.title : topic.topicTitle
        do {
            if let bookmark = try await BookmarkAPI.find(postID: postID, topicTitle: title) {
                folderChoice = FolderChoice(bookmark: bookmark)
            } else {
                ToastCenter.shared.show(AppString("没找到这条书签，可以在我的收藏里整理"))
            }
        } catch {
            ToastCenter.shared.show(BookmarkAPI.message(error))
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
        guard !isSignedIn else { return true }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            requestLogin(app, .generic)
        }
        return false
    }

    /// Bottom gate for guests: sign up or log in to continue.
    private var guestGateSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("注册后可发帖、回复、点赞并加入感兴趣的节点。")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
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
                .foregroundStyle(tint ?? Theme.textMuted)
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

    /// Space above the author line, under the system bar.
    private let readerContentTopInset: CGFloat = 8
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
                proxy.scrollTo(ReplyAnchor(postNumber: first.postNumber), anchor: .top)
            }
        case .bottom:
            guard let last = topic.comments.last(where: { !$0.isLoadMore }) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(ReplyAnchor(postNumber: last.postNumber), anchor: .bottom)
            }
        }
    }

    private static let repliesAnchor = "post-detail-replies"
    private static let contentSpace = "post-detail-content"

    private func scrollToTargetIfLoaded(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        // Post #1 is the original post — the view already opens at the top.
        guard target > 1 else { scrollTarget = nil; return }
        guard visibleComments.contains(where: { $0.postNumber == target && !$0.isLoadMore }) else { return }
        scrollTarget = nil
        // To the replies block first (the outer stack's own child, so it can
        // always be found), then a screen at a time through the rows: the
        // replies are a lazy stack inside the page's lazy stack, and a row it
        // hasn't built yet can't be scrolled to directly.
        proxy.scrollTo(Self.repliesAnchor, anchor: .top)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            walk(to: target, proxy: proxy, stepsLeft: 40)
        }
    }

    private func walk(to target: Int, proxy: ScrollViewProxy, stepsLeft: Int) {
        // Not `.top`: the bar floats over the content, and a row pinned to
        // the very top had its author line under it. A fifth of the way down
        // clears it for any reply shorter than ~3/4 screen.
        let landing = UnitPoint(x: 0.5, y: 0.2)
        if builtRows.numbers.contains(target) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(ReplyAnchor(postNumber: target), anchor: landing)
            }
            // Once more after the rows above have been measured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                proxy.scrollTo(ReplyAnchor(postNumber: target), anchor: landing)
            }
            return
        }
        // Another screen down builds the rows below; stop at the end.
        let before = builtRows.offset
        guard stepsLeft > 0, builtRows.offset < builtRows.maxOffset - 1 else { return }
        scrollPosition.scrollTo(y: min(before + builtRows.viewport * 0.9, builtRows.maxOffset))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            walk(to: target, proxy: proxy, stepsLeft: stepsLeft - 1)
        }
    }

    private func scrollBody(for post: Post) -> some View {
        ScrollView(.vertical) {
            // Lazy, not eager: the device froze in ScrollView's content
            // measurement walking the whole eager stack (an alignment-query
            // blowup deep in SwiftUI). A lazy stack only measures what's
            // materialized, which caps that pass regardless of content.
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: readerContentTopInset)

                authorLine(for: post)
                    .padding(.bottom, 12)

                Text(displayTitle(for: post))
                    .font(Theme.heading(24, weight: .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, hasTitleMeta(for: post) ? 8 : 14)
                    // The title standing in for the first post being on screen.
                    .onScrollVisibilityChange(threshold: 0.2) { reader.setVisible(1, $0) }
                    // The bar's n/slug starts to show as the title's top
                    // reaches the bar and is fully in once the title is gone.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: { frame in
                        chrome.setRevealRange(start: frame.minY, length: frame.height)
                    }

                // The topic's tags, then 已编辑 N 次 (design App-iOS-Post).
                // Nothing at all when there is neither.
                if hasTitleMeta(for: post) {
                    titleMeta(for: post)
                        .padding(.bottom, 14)
                }

                // N 人举报 · 去处理 (PostMod): only a manager is sent the
                // count, and it opens the node's queue on that item.
                if let reports = post.reportCount, reports > 0 {
                    FeedModStrip(reportCount: reports) {
                        app.pushPage(.reviewQueue(node: pillSlug(for: post), item: post.reviewItemID))
                    }
                    .padding(.bottom, 14)
                }

                // Hidden first post (App-iOS-PostHidden): why, and the way
                // out, for its author; the reason for a manager. A manager's
                // removal has its own panel below.
                if let hidden = topic.firstPostHidden, topic.removal == nil, !topic.content.isEmpty {
                    HiddenPostNotice(
                        state: hidden,
                        isFirstPost: true,
                        isAuthor: isOwnAuthor(topic.firstAuthor?.username ?? post.authorUsername),
                        onEdit: topic.canEditFirstPost ? { Task { await startTopicEdit(for: post) } } : nil,
                        onAppeal: { showsAppealSheet = true }
                    )
                    .padding(.bottom, 10)
                    if !hidden.isHeld {
                        Label(AppString("以下正文只有你和管理人员看得到"), systemImage: "eye.slash")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.bottom, 10)
                    }
                }

                // Above the body: what a manager did to this topic, and the
                // author's one chance to contest it.
                if let removal = topic.removal {
                    let isAuthor = isOwnAuthor(topic.firstAuthor?.username ?? post.authorUsername)
                    RemovalPanel(
                        removal: removal,
                        isAuthor: isAuthor,
                        nodeSlug: pillSlug(for: post),
                        authorName: topic.firstAuthor?.username ?? post.authorUsername,
                        onAppeal: { showsAppealSheet = true },
                        onRules: { if let url = nodelocSiteURL("/guidelines") { LinkRouter.open(url, app: app, browser: browser) } },
                        onReputation: { app.pushPage(.reputation) }
                    )
                    .padding(.bottom, 14)
                    if isAuthor, !topic.content.isEmpty {
                        Label(AppString("以下正文仅作者和版主可见"), systemImage: "eye.slash")
                            .font(Theme.body(12, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.bottom, 10)
                    }
                }

                if let envelope = topic.redEnvelope {
                    RedEnvelopeBanner(envelope: envelope, onReply: isSignedIn ? { focusReplyField() } : { requestLogin(app, .reply) })
                        .padding(.bottom, 14)
                }

                if topic.content.isEmpty {
                    if topic.isLoading {
                        postBodySkeleton
                    } else if topic.loadError != nil {
                        // The excerpt first when there is one — a row opened
                        // from a list still has something to show — then the
                        // notice, because half a post with no explanation is
                        // what this state used to be.
                        if !post.excerpt.isEmpty {
                            Text(post.excerpt)
                                .font(Theme.body(16))
                                .lineSpacing(6)
                                .foregroundStyle(Theme.text.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)
                        }
                        loadFailureNotice(for: post)
                    } else if topic.firstPostHidden != nil {
                        // Hidden, and this reader isn't told what it says.
                        HiddenPostPlaceholder()
                    } else {
                        // Falls back to the list excerpt if the body never loads.
                        Text(post.excerpt)
                            .font(Theme.body(16))
                            .lineSpacing(6)
                            .foregroundStyle(Theme.text.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // One lazy row per block, not one row for the whole body —
                    // see `PostContentRows`.
                    PostContentRows(
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
                    // Long-press range selection and Copy, on the first post
                    // only; replies keep plain text.
                    .environment(\.postTextSelectable, true)
                }

                if let trade = topic.trade {
                    TradeCard(
                        trade: trade,
                        isOwner: trade.owner.lowercased() == DiscourseAuth.shared.username?.lowercased(),
                        isSignedIn: isSignedIn,
                        onChanged: { await topic.refreshTrade() },
                        onSignIn: { requestLogin(app, .generic) },
                        onOpenURL: { url in LinkRouter.open(url, app: app, browser: browser) }
                    )
                    .padding(.top, 18)
                }

                if let lottery = topic.lottery {
                    LotteryView(
                        lottery: lottery,
                        isBusy: topic.isLotteryBusy,
                        onRefresh: { await topic.refreshLottery() },
                        onCancel: { Task { await topic.cancelLottery() } },
                        loadParticipants: { try await topic.lotteryParticipants() },
                        onOpenProfile: { name in
                            openProfile(UserProfileTarget(username: name, displayName: nil, avatarURL: nil))
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

                // 最佳答案 heads the replies (design App-iOS-Post2).
                if topic.acceptedAnswerPostID != nil {
                    bestAnswerBlock
                        .padding(.top, 22)
                }

                repliesSection(for: post)
                    .padding(.top, 22)
                    // The reply rows sit in their own lazy stack, which the
                    // outer one can't see into until it is materialised; a
                    // deep link scrolls here first (see scrollToTargetIfLoaded).
                    .id(Self.repliesAnchor)
            }
            .coordinateSpace(.named(Self.contentSpace))
            .padding(.horizontal, Theme.pagePadding)
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
        .scrollPosition($scrollPosition)
        // As the node page: raw offset, 0 at rest under the bar.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            chrome.update(offset: offset)
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y,
                viewport: geometry.containerSize.height,
                maxOffset: geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
            )
        } action: { _, metrics in
            builtRows.offset = metrics.offset
            builtRows.viewport = metrics.viewport
            builtRows.maxOffset = metrics.maxOffset
        }
        .overlay {
            if replyPanelOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { replyCollapseRequest += 1 }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: replyPanelOpen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(for: post)
        }
        // Pull down to refresh; leaving is the system back (‹ or the edge
        // swipe).
        .refreshable { await topic.refresh() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// The system navigation bar, like the node page's: the system back
    /// button, n/slug in its own glass capsule in the centre, and one capsule
    /// of 回复排序 / ⋯ / your avatar.
    @ToolbarContentBuilder
    private func readerToolbar(for post: Post) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            nodePill(for: post)
        }
        .sharedBackgroundVisibilityHiddenIfAvailable()
        ToolbarItem(placement: .topBarTrailing) {
            readerTools(for: post)
        }
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
        Button {
            Task { await topic.loadPendingUpdates() }
        } label: {
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
            .frame(height: 34)
            .glassSurface(tint: FloatingHeader.glassTint, interactive: true, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    /// The node page's centre capsule (`BarNodeCapsule`): hidden at rest,
    /// revealed as the title passes under the bar, so it takes over as the
    /// page's label once the title is gone.
    @ViewBuilder
    private func nodePill(for post: Post) -> some View {
        if let slug = pillSlug(for: post) {
            BarNodeCapsule(
                slug: slug,
                chrome: chrome,
                accessibilityLabel: AppString("打开 n/\(slug)")
            ) {
                app.openNodeFromReader(slug: slug)
            }
        }
    }

    /// The resolved node's slug, else the slug the list row already carried
    /// (so a post opened from a list shows it at once).
    private func pillSlug(for post: Post) -> String? {
        if let slug = nodeSummary?.slug, !slug.isEmpty { return slug }
        // A topic reached by id alone (a link, a notification) still shows
        // its node from the first frame when any list has carried it.
        return post.linkedNodeSlug ?? NodelocAdapterState.shared.nodeSlug(topicID: post.id)
    }

    /// Grouped glass capsule matching the node page's top-right tools.
    private func readerTools(for post: Post) -> some View {
        HStack(spacing: 2) {
            // 回复排序依据 as the system pull-down, each ordering with its icon
            // and one-line description.
            Menu {
                Picker(AppString("回复排序依据"), selection: Binding(
                    get: { topic.replySort },
                    set: { topic.applySort($0) }
                )) {
                    ForEach(ReplySort.allCases) { option in
                        Label {
                            Text(option.label)
                            Text(option.detail)
                        } icon: {
                            Image(systemName: option.icon)
                        }
                        .tag(option)
                    }
                }
            } label: {
                readerToolIcon("slider.horizontal.3")
            }
            .sensoryFeedback(.selection, trigger: topic.replySort)
            .accessibilityLabel(AppString("回复排序依据"))

            Menu {
                topicMenuContent(post)
            } label: {
                readerToolIcon("ellipsis")
            }
            .accessibilityLabel(AppString("更多操作"))

            readerAvatar
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    /// The node page's bar glyph, so the two bars can't drift apart.
    private func readerToolIcon(_ systemImage: String) -> some View {
        BarGlyph(systemName: systemImage)
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
                requestLogin(app, .generic)
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
                    .foregroundStyle(Theme.textFaint)
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
                    cornerRadius: Theme.cornerSmall
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
                        .foregroundStyle(Theme.textFaint)
                    postSourceBadge(topic.firstPostSource)
                }
            }
            Spacer(minLength: 0)
            authorNodeChip
        }
    }

    /// The topic's node beside the author, always visible — the header's
    /// pill only reveals itself once the page scrolls, so at the top there
    /// was no way into the node from here.
    @ViewBuilder
    private var authorNodeChip: some View {
        if let node = nodeSummary {
            Button { app.openNodeFromReader(slug: node.slug) } label: {
                HStack(spacing: 5) {
                    NodeAvatar(node: node, size: 20, cornerRadius: 10)
                    Text("n/\(node.slug)")
                        .font(Theme.body(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .frame(height: 28)
                .background(Theme.chip, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(node.name)
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
        app.pushPage(.profile(target))
    }

    /// Identity and counts shown over a full-screen video.
    /// Dismisses the video cover's keyboard target and focuses the reply box.
    private func focusReplyField() {
        guard DiscourseAuth.shared.isAuthenticated else { return }
        lotteryReplyMode = true
        isReplyFocused = true
        replyFocusRequest += 1
    }


    // MARK: Under the title

    /// The detail's tags once loaded, the list row's until then, so a post
    /// opened from a list doesn't grow a row a moment later.
    private func titleTags(for post: Post) -> [String] {
        topic.topicTags.isEmpty ? post.tags : topic.topicTags
    }

    private func hasTitleMeta(for post: Post) -> Bool {
        !titleTags(for: post).isEmpty || topic.firstPostEditCount > 0
    }

    /// Tags in their own looks, wrapping, then the 已编辑 N 次 pill. A tag
    /// opens the node's page filtered by it; the pill opens the edit history.
    private func titleMeta(for post: Post) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(titleTags(for: post), id: \.self) { tag in
                // The tag's own page, across every node (App-iOS-Tag); the
                // node page's filter row still narrows a node by tag.
                Button {
                    app.pushPage(.tag(tag))
                } label: {
                    TagLookChip(name: tag)
                }
                .buttonStyle(.pressable)
                .accessibilityHint(AppString("查看带这个标签的主题"))
            }
            if topic.firstPostEditCount > 0, let firstPostID = topic.firstPostID {
                Button {
                    historyTarget = EditHistoryTarget(postID: firstPostID, canRestore: topic.canEditFirstPost)
                } label: {
                    Label(AppString("已编辑 \(topic.firstPostEditCount) 次"), systemImage: "pencil")
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityHint(AppString("查看编辑历史"))
            }
        }
    }

    // MARK: 最佳答案

    /// The accepted reply, loaded or not yet.
    private var acceptedReply: PostComment? {
        guard let id = topic.acceptedAnswerPostID else { return nil }
        return topic.comments.first { $0.id == id && !$0.isLoadMore }
    }

    /// 楼主采纳 when the topic's author accepted it, else who did.
    private var acceptedByLine: String {
        let by = topic.acceptedAnswerBy ?? ""
        if by.isEmpty || by == "author" || by == topic.firstAuthor?.username {
            return AppString("楼主采纳")
        }
        return AppString("\(by) 采纳")
    }

    /// Pinned above the replies: who answered, the start of the answer, a way
    /// to the reply itself and — for whoever may — a way to withdraw it.
    private var bestAnswerBlock: some View {
        let reply = acceptedReply
        let username = reply?.author ?? topic.acceptedAnswerUsername ?? ""
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(AppString("最佳答案"), systemImage: "checkmark")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .frame(minHeight: 24)
                    .background(Theme.accentFill, in: Capsule())
                Text(acceptedByLine)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                RemoteAvatar(
                    url: reply?.avatarURL,
                    letter: String(username.first ?? "?"),
                    variant: reply?.id ?? topic.acceptedAnswerPostID ?? 0,
                    size: 28
                )
                Text(username)
                    .font(Theme.body(12, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let reply {
                    Text(verbatim: "· \(reply.time)")
                        .lineLimit(1)
                    if let score = reply.voteScore ?? (reply.votes > 0 ? reply.votes : nil), score > 0 {
                        Text(AppString("· \(score) 赞同"))
                            .lineLimit(1)
                    }
                } else if let number = topic.acceptedAnswerPostNumber {
                    Text(AppString("· \(number) 楼"))
                        .lineLimit(1)
                }
            }
            .font(Theme.body(12))
            .foregroundStyle(Theme.textMuted)
            .padding(.top, 10)

            // Three lines held while the reply isn't loaded yet (it arrives
            // with a later page), so the block doesn't jump on the way.
            Text(reply.map { $0.content.excerpt(limit: 160) } ?? AppString("回复还没加载，点“查看原楼层”跳过去。"))
                .font(Theme.body(14))
                .lineSpacing(4)
                .foregroundStyle(reply == nil ? Theme.textMuted : Theme.text)
                .lineLimit(3, reservesSpace: reply == nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .redacted(reason: reply == nil && topic.isLoading ? .placeholder : [])

            HStack(spacing: 8) {
                Button {
                    if let number = reply?.postNumber ?? topic.acceptedAnswerPostNumber {
                        scrollTarget = number
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(AppString("查看原楼层"))
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                        .font(Theme.body(13, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.pressable)

                if topic.canAcceptAnswer, let id = topic.acceptedAnswerPostID {
                    Button {
                        Task { await topic.toggleAcceptedAnswer(postID: id) }
                    } label: {
                        Text(AppString("撤销采纳"))
                            .font(Theme.body(13, weight: .bold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.07), in: shape)
        .overlay(shape.strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func postActions(for post: Post) -> some View {
        let isOwn = isOwnAuthor(topic.firstAuthor?.username ?? post.authorUsername)
        return VStack(alignment: .leading, spacing: 10) {
            // Above the controls, on its own line: the tally is what the post
            // received, and reading it shouldn't mean parsing it out of a row
            // of things to press.
            if !topic.firstPostReactions.isEmpty, let firstPostID = topic.firstPostID {
                Button {
                    reactionDetail = ReactionTarget(postID: firstPostID)
                } label: {
                    ReactionSummary(reactions: topic.firstPostReactions)
                }
                .buttonStyle(.pressable)
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
                            .foregroundStyle(topic.firstPostLikedByMe ? Theme.love : Theme.textMuted)
                        }
                        .buttonStyle(.pressable)
                        .disabled(isOwn)
                    }
                }

                Button {
                    if topic.removal != nil { return }
                    if isSignedIn { focusReplyField() } else { requestLogin(app, .reply) }
                } label: {
                    actionCapsule {
                        Label("\(replyCount(for: post))", systemImage: "bubble.left")
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .buttonStyle(.pressable)

                Spacer(minLength: 8)

                postActionIcon("arrow.2.squarepath") { startRepost(for: post) }
            }
        }
        .foregroundStyle(Theme.textMuted)
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

    /// A tappable icon in the OP action bar, on the same filled shape the stat
    /// groups use — a bare glyph beside two capsules didn't read as a button.
    private func postActionIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted)
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
        replyFocusRequest += 1
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
            rendered: topic.content.isEmpty ? nil : topic.content,
            rejudge: topic.firstPostHidden?.rejudge == true
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
                    // An empty thread invites the first reply, into the same
                    // panel as the bar.
                    VStack(spacing: 12) {
                        Text(AppString("还没有回复"))
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.textMuted)
                        if topic.removal == nil {
                            Button {
                                if isSignedIn { focusReplyField() } else { requestLogin(app, .reply) }
                            } label: {
                                Label(AppString("加入讨论"), systemImage: "bubble.left")
                                    .font(Theme.body(14, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 16)
                                    .frame(height: 38)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
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
                                moreMenu: { AnyView(replyMenuContent(comment, post: post)) },
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
                                },
                                onEdit: { editTarget = EditTarget(postID: comment.id) },
                                onAppeal: { appealPostID = AppealPostTarget(id: comment.id) }
                            )
                            // Scroll anchor for notification deep links (/t/…/<post>).
                            .id(ReplyAnchor(postNumber: comment.postNumber))
                            .onAppear { builtRows.numbers.insert(comment.postNumber) }
                            .onDisappear { builtRows.numbers.remove(comment.postNumber) }
                            // Credit read time to this reply while it's on screen.
                            .onScrollVisibilityChange(threshold: 0.5) { reader.setVisible(comment.postNumber, $0) }
                        }
                    }

                    if topic.hasMoreComments {
                        loadMoreRepliesButton(for: post)
                    }
                }

                // The web's three columns, at the foot of the page — under a
                // topic nobody has answered yet too, where a reader is the
                // most likely to want somewhere else to go.
                if !(topic.isLoading && topic.comments.isEmpty) {
                    RelatedTopicsSection(
                        topicID: post.id,
                        nodeSlug: pillSlug(for: post),
                        author: topic.firstAuthor?.username ?? post.authorUsername,
                        onOpen: { related in app.openPostPage(related) },
                        onOpenNode: { slug in app.openNodeFromReader(slug: slug) }
                    )
                    // Its own 16pt margins, whatever the page's padding is.
                    .padding(.horizontal, -Theme.pagePadding)
                    .padding(.top, 24)
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
                    ProgressView().controlSize(.mini).tint(Theme.textMuted)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(Theme.textMuted)
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

    private var failureIcon: String {
        switch topic.loadFailure {
        case .denied: "lock"
        case .missing: "questionmark.circle"
        default: "exclamationmark.triangle"
        }
    }

    private var failureTitle: String {
        switch topic.loadFailure {
        case .denied: AppString("你没有权限查看这个帖子")
        case .missing: AppString("这个帖子不存在或已被删除")
        default: AppString("帖子加载失败")
        }
    }

    /// The row's title, or the loaded topic's when there isn't one.
    ///
    /// A topic opened by *id* — a notification, a link, a push — carries a
    /// placeholder `Post` with an empty title, so the page had no heading at
    /// all until now: the title was sitting in the store, unread.
    private func displayTitle(for post: Post) -> String {
        post.title.isEmpty ? topic.topicTitle : post.title
    }

    /// Shown when the topic could not be loaded.
    ///
    /// Says which of the two it is, because the useful action differs: a
    /// refused topic (a private message, a staff-only category) will refuse
    /// again however many times it is retried, and the web page is the only
    /// place the reader can still get in — signed in as themselves, where the
    /// site can explain. Anything else is worth a retry.
    private func loadFailureNotice(for post: Post) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: failureIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text(failureTitle)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }

            if let detail = topic.loadError, topic.loadFailure == .temporary {
                Text(detail)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if topic.loadFailure == .temporary {
                    Button {
                        Task { await topic.refresh() }
                    } label: {
                        Text("重试")
                            .font(Theme.body(14, weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                    }
                    .buttonStyle(.pressable)
                    .background(Theme.surface, in: Capsule())
                }

                Button {
                    // Straight to the browser rather than through `openURL`:
                    // the app's own router would recognise this as a topic and
                    // send it back here, to fail again.
                    browser.open(post.topicURL)
                } label: {
                    Text("在浏览器中打开")
                        .font(Theme.body(14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                }
                .buttonStyle(.pressable)
                .background(Theme.surface, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: Skeleton

    /// Placeholder lines for the post body while it loads.
    private var postBodySkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            skeletonLine(widthFraction: 1)
            skeletonLine(widthFraction: 0.95)
            skeletonLine(widthFraction: 1)
            skeletonLine(widthFraction: 0.6)
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
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
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            guard visible else { return }
            Task { await topic.loadMoreComments(topicID: post.id) }
        }
    }

    /// While a lottery is open the reply bar gives way to its 买票 bar (the
    /// design's 日常 11); the bar's reply button brings the composer back.
    @ViewBuilder
    private func bottomBar(for post: Post) -> some View {
        if topic.removal != nil {
            // A removed topic takes no replies (App-iOS-PostRemoved).
            removedReplyBar
        } else if let lottery = topic.lottery, lottery.isOpen, lottery.isOwner != true,
           !lotteryReplyMode, replyTarget == nil, draft.isEmpty {
            LotteryActionBar(
                lottery: lottery,
                isGuest: !isSignedIn,
                onReply: {
                    if isSignedIn { lotteryReplyMode = true } else { requestLogin(app, .reply) }
                },
                onGuest: { requestLogin(app, .generic) },
                onBuy: { quantity, isRandom in
                    let before = topic.lottery?.userTickets ?? 0
                    if let total = await topic.participateInLottery(quantity: quantity, isRandom: isRandom) {
                        return .success(max(total - before, 0))
                    }
                    let message = topic.pluginErrorText ?? AppString("参与失败。")
                    topic.pluginErrorText = nil
                    return .failure(LotteryBuyError(message: message))
                }
            )
        } else {
            replyComposer(for: post, expandsOnAppear: lotteryReplyMode || replyTarget != nil)
        }
    }

    private var removedReplyBar: some View {
        Label(AppString("帖子已被移除，不能回复"), systemImage: "lock")
            .font(Theme.body(15, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func replyComposer(for post: Post, expandsOnAppear: Bool = false) -> some View {
        ReplyComposer(
            text: $draft,
            isSubmitting: topic.isSubmitting,
            isAuthenticated: DiscourseAuth.shared.isAuthenticated,
            onRequestLogin: { requestLogin(app, .reply) },
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
                        if !topic.lastReplyHeld { ToastCenter.shared.show(AppString("回复已发布")) }
                    }
                }
            },
            expandsOnAppear: expandsOnAppear,
            focusRequest: replyFocusRequest,
            collapseRequest: replyCollapseRequest,
            onExpandedChange: { replyPanelOpen = $0 },
            onCollapse: { lotteryReplyMode = false }
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
    /// True when the reply is the current user's own (can't like it).
    let isOwn: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onVote: (VoteDirection, String?) -> Void
    /// The ⋯ pull-down's items, built by the reader.
    let moreMenu: () -> AnyView
    let onReactionDetail: () -> Void
    /// Undeletes the reply (staff, `can_recover`).
    var onRecover: (() -> Void)?
    /// Fetches back the body of a reply hidden by the viewer's ignore list.
    var onReveal: (() -> Void)?
    var onImageTap: ((PostImage) -> Void)?
    /// For the author of a hidden reply: edit it (re-judged) or appeal it.
    var onEdit: (() -> Void)?
    var onAppeal: (() -> Void)?

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
    /// Who removed it, and why when a moderator said so — the same three
    /// readings the web's placeholder has.
    private var placeholderLabel: String {
        guard comment.isDeletedPlaceholder else { return AppString("已忽略该用户的回复") }
        guard comment.deletedByModerator else { return AppString("这条回复已被作者删除") }
        guard let reason = comment.deleteReason, !reason.isEmpty else {
            return AppString("这条回复已被版主删除")
        }
        return AppString("这条回复已被版主删除 · \(reason)")
    }

    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: comment.isDeletedPlaceholder ? "trash" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                Text(placeholderLabel)
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
            .foregroundStyle(Theme.textFaint)

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
                if comment.hidden != nil, comment.content.isEmpty {
                    // Everyone but its author and the node's managers.
                    HiddenPostPlaceholder()
                } else {
                    if let hidden = comment.hidden {
                        HiddenPostNotice(
                            state: hidden,
                            isFirstPost: false,
                            isAuthor: isOwn,
                            onEdit: comment.canEdit ? onEdit : nil,
                            onAppeal: onAppeal
                        )
                    }
                    PostContentView(
                        content: comment.content,
                        metrics: .reply,
                        onImageTap: onImageTap,
                        onBackgroundTap: onToggleCollapse
                    )
                }

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

            if comment.isAcceptedAnswer {
                acceptedAnswerBadge
            }

            // Only a manager of this node is sent a count at all.
            if let reports = comment.reportCount, reports > 0 {
                Label("\(reports)", systemImage: "flag.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(Theme.body(10, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(Theme.danger.opacity(0.1), in: Capsule())
            }

            Text("· \(comment.time)")
                .font(Theme.body(12))
                .foregroundStyle(Theme.textFaint)

            postSourceBadge(comment.mobileSource)

            Spacer(minLength: 0)

            if comment.hasChildren || isCollapsed {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
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
            Spacer(minLength: 0)

            // Left of the ⋮, so the tally sits with the row's other numbers
            // rather than among the buttons that change them.
            if !comment.reactions.isEmpty {
                Button(action: onReactionDetail) {
                    ReactionSummary(reactions: comment.reactions)
                }
                .buttonStyle(.pressable)
            }

            Menu {
                moreMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(AppString("更多操作"))
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
                    .foregroundStyle(comment.isLiked ? Theme.love : Theme.textFaint)
                }
                .buttonStyle(.pressable)
                .disabled(isOwn)
            }
        }
        .foregroundStyle(Theme.textFaint)
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
                .foregroundStyle(Theme.textFaint)
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

/// The accepted answer's chip. Named rather than a bare glyph, because this is
/// the one marker a reader scans a help topic for.
var acceptedAnswerBadge: some View {
    Label(AppString("最佳答案"), systemImage: "checkmark.seal.fill")
        .labelStyle(CompactLabelStyle())
        .font(Theme.body(10, weight: .semibold))
        .foregroundStyle(Theme.accent700)
        .padding(.vertical, 3)
        .padding(.horizontal, 7)
        .background(Theme.accent.opacity(0.12), in: Capsule())
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
            .foregroundStyle(Theme.textMuted)
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

/// The author's 头衔 after their name (`author_title`: their personal title,
/// else their group's), as the web's pill, in the admin's design
/// (`author_title_style`) when the post carried one.
@ViewBuilder
func authorTitleChip(_ title: String?, style: TitleStyle? = nil) -> some View {
    if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
        UserTitleChip(title: title, style: style, compact: true)
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
                .foregroundStyle(Theme.textMuted)
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
                        .foregroundStyle(Theme.textMuted)
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
                    .foregroundStyle(Theme.textMuted)
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
                    .foregroundStyle(Theme.textMuted)
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

/// A reply row's scroll identity.
///
/// Its own type, not the bare post number: the first post's body rows share
/// the same `LazyVStack` and are identified by their Int offset, so
/// `scrollTo(3)` used to land on the body's fourth block instead of reply #3
/// (t/119604/3 opened mid-way through the first post).
/// The reply rows a lazy list has built — a plain box, so rows coming and
/// going don't redraw the page.
final class BuiltRows {
    var numbers: Set<Int> = []
    var offset: CGFloat = 0
    var viewport: CGFloat = 600
    var maxOffset: CGFloat = 0
}

struct ScrollMetrics: Equatable {
    let offset: CGFloat
    let viewport: CGFloat
    let maxOffset: CGFloat
}

struct ReplyAnchor: Hashable {
    let postNumber: Int
}


/// A reply whose author is appealing its hiding.
struct ReaderModerateRequest: Identifiable {
    let id = UUID()
    let postID: Int
    let options: NLPostModerateOptions
}

struct AppealPostTarget: Identifiable {
    let id: Int
}
