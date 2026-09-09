//
//  TopicMoreSheet.swift
//  nodeloc
//
//  更多操作 for a topic row: the ⋮ on a feed card.
//

import SwiftUI

/// The actions a list row offers without opening the topic.
///
/// Every entry is something the backend actually supports. Reddit's own sheet
/// also carries "减少显示此类帖子", "语言和翻译" and "为何向我推荐此内容？" — a
/// feed-ranking control, discourse-translator and an ads explainer respectively,
/// none of which exist here, and a row that does nothing is worse than a row
/// that isn't there.
struct TopicMoreSheet: View {
    let post: Post
    /// Opens the composer quoting this topic. Optional because not every list
    /// can present a composer: `app.overlay = .compose` draws in `MainView`,
    /// so a list inside a full-screen cover has to hand its own way of doing
    /// it — and a row that can't is better absent than dead.
    var onRepost: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var isWatching: Bool
    @State private var isBookmarked: Bool
    @State private var isBusy = false
    @State private var isFlagging = false
    @State private var confirmsBlock = false

    /// Discourse's own "watching" level; 1 is the default "regular".
    private static let watchingLevel = 3
    private static let regularLevel = 1

    init(post: Post, onRepost: (() -> Void)? = nil) {
        self.post = post
        self.onRepost = onRepost
        isWatching = (post.notificationLevel ?? Self.regularLevel) >= Self.watchingLevel
        isBookmarked = post.isBookmarked
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ShareLink(item: topicURL) {
                        row(AppString("分享"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.pressable)

                    button(AppString("复制链接"), systemImage: "link") {
                        copyLink(topicURL)
                        dismiss()
                    }

                    button(
                        isBookmarked ? AppString("取消保存") : AppString("保存"),
                        systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
                    ) {
                        Task { await toggleBookmark() }
                    }

                    button(
                        isWatching ? AppString("取消关注帖子") : AppString("关注帖子"),
                        systemImage: isWatching ? "bell.fill" : "bell"
                    ) {
                        Task { await toggleWatching() }
                    }

                    if let onRepost {
                        button(AppString("转发"), systemImage: "arrow.2.squarepath") {
                            dismiss()
                            onRepost()
                        }
                    }

                    if let author = post.authorProfileTarget {
                        button(AppString("查看作者"), systemImage: "person.crop.circle") {
                            dismiss()
                            app.openProfile(author)
                        }
                    }

                    Divider()
                        .overlay(Theme.divider)
                        .padding(.vertical, 6)

                    button(AppString("举报"), systemImage: "flag", tint: Theme.danger) {
                        // Both of these need an account — the endpoints answer
                        // `not_logged_in` otherwise, which used to surface as a
                        // bare error. A guest gets the sign-in gate instead, so
                        // the action is reachable rather than merely visible.
                        guard requireAccount() else { return }
                        isFlagging = true
                    }

                    if let author = post.authorUsername, !isOwnPost {
                        button(AppString("屏蔽作者"), systemImage: "hand.raised", tint: Theme.danger) {
                            guard requireAccount() else { return }
                            confirmsBlock = true
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("更多操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
            .disabled(isBusy)
        }
        .standardSheet()
        // Native flag flow, layered over this sheet.
        .sheet(isPresented: $isFlagging) {
            FlagSheet(
                target: FlagTarget(kind: .topic, id: post.id, authorUsername: post.authorUsername)
            )
        }
        // Says what blocking actually does, because it does two things: hides
        // their content here and reports it to the moderators.
        .confirmationDialog(
            AppString("屏蔽 @\(post.authorUsername ?? "")？"),
            isPresented: $confirmsBlock,
            titleVisibility: .visible
        ) {
            Button(AppString("屏蔽并举报"), role: .destructive) {
                guard let author = post.authorUsername else { return }
                Task { await block(author) }
            }
            Button(AppString("取消"), role: .cancel) {}
        } message: {
            Text("他们的主题和回复会立即从你的列表中消失，同时该内容会举报给管理员审核。")
        }
    }

    private var topicURL: URL {
        DiscourseConfig.baseURL.appending(path: "t/\(post.id)")
    }

    private var isOwnPost: Bool {
        guard let me = DiscourseAuth.shared.username, let author = post.authorUsername else {
            return false
        }
        return me.caseInsensitiveCompare(author) == .orderedSame
    }

    private func button(
        _ title: String,
        systemImage: String,
        tint: Color = Theme.text,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            row(title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.pressable)
    }

    private func row(_ title: String, systemImage: String, tint: Color = Theme.text) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint == Theme.text ? Theme.muted(0.65) : tint)
                .frame(width: 24)
            Text(title)
                .font(Theme.body(15))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Bookmarks the *first post*, which is what bookmarking a topic means —
    /// hence needing `opPostID` rather than the topic id.
    private func toggleBookmark() async {
        guard let postID = post.opPostID else {
            ToastCenter.shared.show(AppString("暂时无法保存这个帖子"))
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await DiscourseClient().bookmark(postID: postID)
            isBookmarked = true
            ToastCenter.shared.show(AppString("已保存"))
            dismiss()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    private func toggleWatching() async {
        let target = isWatching ? Self.regularLevel : Self.watchingLevel
        isBusy = true
        defer { isBusy = false }
        do {
            try await DiscourseClient().setTopicNotification(topicID: post.id, level: target)
            isWatching.toggle()
            ToastCenter.shared.show(isWatching ? AppString("已关注此帖子") : AppString("已取消关注"))
            dismiss()
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Closes this sheet and opens the sign-in gate when there's no account,
    /// reporting false. The two moderation actions both need one.
    private func requireAccount() -> Bool {
        guard !app.authed else { return true }
        dismiss()
        // Presenting the gate while this sheet is still dismissing drops it.
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            presentAuth(app)
        }
        return false
    }

    /// Blocks the author, hides everything of theirs still on screen, and
    /// reports the post to the moderators — see `BlockedUsersStore`.
    private func block(_ username: String) async {
        isBusy = true
        defer { isBusy = false }
        await BlockedUsersStore.shared.blockAndConfirm(
            username: username,
            reportingPostID: post.opPostID
        )
        dismiss()
    }
}
