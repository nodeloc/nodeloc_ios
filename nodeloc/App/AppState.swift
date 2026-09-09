//
//  AppState.swift
//  nodeloc
//
//  Models, sample data, and observable app state. Mirrors the DCLogic
//  component in design_import/rendered.html.
//

import SwiftUI

// MARK: - Models

struct Post: Identifiable {
    let id: Int
    let node: String
    let avatarLetter: String
    let variant: Int
    let time: String
    let title: String
    let excerpt: String
    let baseVotes: Int
    /// discourse-vote on the topic's first post, which is what a row votes on.
    /// `voteScore` nil means the plugin didn't serialize a score for this row —
    /// draw no control rather than a like count pretending to be one.
    var voteScore: Int? = nil
    var voteDirection: VoteDirection = .none
    var canVoteDown: Bool = true
    /// The first post's id, which is what the vote call needs.
    var opPostID: Int? = nil
    /// This user's topic notification level, and whether it's bookmarked — for
    /// the row's 更多操作 sheet.
    var notificationLevel: Int? = nil
    var isBookmarked: Bool = false
    let comments: Int
    let hasImage: Bool
    /// Pinned *for this reader*: false once they dismiss it, which is what the
    /// list serializer's `pinned` already accounts for.
    var pinned: Bool = false
    /// A global pin tops every list, a plain one only its own node — worth
    /// distinguishing on the badge, since the first is site-wide news.
    var pinnedGlobally: Bool = false
    /// New or has-unread-posts for the signed-in user — shows the read dot.
    var isUnread: Bool = false
    /// Real topic image (when loaded from Discourse); nil falls back to the hatch placeholder.
    var imageURL: URL? = nil
    /// Real author avatar (when loaded from Discourse); nil falls back to initials.
    var avatarURL: URL? = nil
    /// Discourse username for navigating to the public profile.
    var authorUsername: String? = nil
    var authorName: String? = nil
    /// Feed media previews. Uses Discourse's topic thumbnails when available.
    var media: [PostMedia] = []
    /// Discourse topic tags, shown as badges under the title.
    var tags: [String] = []
    /// First post's video, when the topic has one. Card mode autoplays it.
    var videoURL: URL? = nil

    /// The topic this row points at. The id-only form redirects to the
    /// canonical slug URL, which is all a repost or a report needs.
    var topicURL: URL {
        DiscourseConfig.baseURL.appending(path: "t/topic/\(id)")
    }

    /// Target for opening the author's public profile from the feed.
    var authorProfileTarget: UserProfileTarget? {
        guard let authorUsername else { return nil }
        let trimmed = authorUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let displayName = authorName == trimmed ? nil : authorName
        return UserProfileTarget(username: trimmed, displayName: displayName, avatarURL: avatarURL)
    }
}

struct PostMedia: Identifiable, Hashable {
    let url: URL
    let width: Int?
    let height: Int?
    /// The same image at several widths, ascending. Empty when the server gave
    /// only one URL. Lets each display site fetch a size that matches how big
    /// it draws, instead of upscaling one middling image everywhere.
    var variants: [ImageVariant] = []

    var id: URL { url }

    /// The smallest variant at least as wide as the target (display points ×
    /// screen scale), so it's crisp without over-fetching. Falls back to the
    /// largest variant, then to `url`. This is the standard responsive-image
    /// choice Reddit/Instagram make from their own multi-resolution sets.
    func bestURL(forWidth pointWidth: CGFloat, scale: CGFloat) -> URL {
        guard !variants.isEmpty, pointWidth > 0 else { return url }
        let targetPx = pointWidth * scale
        return variants.first { CGFloat($0.width) >= targetPx }?.url
            ?? variants.last?.url
            ?? url
    }
}

struct ImageVariant: Hashable {
    let width: Int
    let url: URL
}

func postTransitionID(_ id: Int) -> String {
    "post-transition-\(id)"
}

struct PostComment: Identifiable {
    let id: Int
    let author: String
    let time: String
    /// Parsed body. Replies render through the same pipeline as the main post
    /// so quotes and code blocks look identical in both places.
    let content: PostContent
    /// What this reply won, when the topic has a red envelope. The plugin
    /// auto-claims on reply, so this is a result rather than an action.
    let redEnvelopeClaim: RedEnvelopeClaim?
    var votes: Int
    let postNumber: Int
    let replyToPostNumber: Int?
    let parentAuthor: String?
    let parentText: String?
    let avatarURL: URL?
    let nestingDepth: Int
    let isLastSibling: Bool
    let ancestorTrails: [Bool]
    let hasChildren: Bool
    /// The post number of the top-level reply this comment's thread hangs off —
    /// its "nest group". Comments render grouped by this, with a gap between
    /// groups.
    let groupID: Int
    /// When true this row isn't a reply but a "load N more replies" affordance
    /// under `loadMoreParent`.
    let isLoadMore: Bool
    let loadMoreParent: Int
    let loadMoreRemaining: Int
    /// The author's worn title and flair badge icon.
    let authorTitle: String?
    let flairURL: URL?
    /// Whether the current user has liked this reply — an upvote, in
    /// discourse-vote's terms.
    var isLiked: Bool
    /// The faces this reply collected, for the summary in its action bar.
    let reactions: [PostReaction]
    /// discourse-vote. Nil score means voting doesn't apply to this topic.
    var voteScore: Int?
    var voteDirection: VoteDirection
    var canVoteDown: Bool
    /// discourse-reward rewards this reply has received.
    let rewards: [PostReward]
    /// The 小尾巴 the author's app reported at posting time, e.g. "iPhone" —
    /// decoration only, since a client asserts its own hardware.
    let mobileSource: String?
    /// Pinned to the top of the thread by staff (discourse-community).
    let isPinned: Bool
    /// The reply is deleted, or its author is on this viewer's ignore list. Its
    /// row still has to exist: the nested view hangs surviving children off it,
    /// and dropping it would orphan them.
    let isDeletedPlaceholder: Bool
    let isIgnoredPlaceholder: Bool
    /// A reveal request is in flight for this reply.
    let isRevealing: Bool
    /// Staff may undelete it (`can_recover`).
    let canRecover: Bool
    /// Either placeholder state: nothing to read, nothing to act on.
    var isPlaceholder: Bool { isDeletedPlaceholder || isIgnoredPlaceholder }

    /// What the viewer may do to this reply, as the server reported it. A node
    /// moderator has these on their own node's posts and not on others'.
    let canEdit: Bool
    let canDelete: Bool
    let isMine: Bool

    init(
        id: Int,
        author: String,
        time: String,
        content: PostContent,
        redEnvelopeClaim: RedEnvelopeClaim? = nil,
        votes: Int,
        postNumber: Int = 0,
        replyToPostNumber: Int? = nil,
        parentAuthor: String? = nil,
        parentText: String? = nil,
        avatarURL: URL? = nil,
        nestingDepth: Int = 0,
        isLastSibling: Bool = true,
        ancestorTrails: [Bool] = [],
        hasChildren: Bool = false,
        groupID: Int = 0,
        isLoadMore: Bool = false,
        loadMoreParent: Int = 0,
        loadMoreRemaining: Int = 0,
        authorTitle: String? = nil,
        flairURL: URL? = nil,
        isLiked: Bool = false,
        reactions: [PostReaction] = [],
        voteScore: Int? = nil,
        voteDirection: VoteDirection = .none,
        canVoteDown: Bool = true,
        rewards: [PostReward] = [],
        mobileSource: String? = nil,
        isPinned: Bool = false,
        isDeletedPlaceholder: Bool = false,
        isIgnoredPlaceholder: Bool = false,
        isRevealing: Bool = false,
        canRecover: Bool = false,
        canEdit: Bool = false,
        canDelete: Bool = false,
        isMine: Bool = false
    ) {
        self.id = id
        self.author = author
        self.time = time
        self.content = content
        self.redEnvelopeClaim = redEnvelopeClaim
        self.votes = votes
        self.postNumber = postNumber
        self.replyToPostNumber = replyToPostNumber
        self.parentAuthor = parentAuthor
        self.parentText = parentText
        self.avatarURL = avatarURL
        self.nestingDepth = nestingDepth
        self.isLastSibling = isLastSibling
        self.ancestorTrails = ancestorTrails
        self.hasChildren = hasChildren
        self.groupID = groupID
        self.isLoadMore = isLoadMore
        self.loadMoreParent = loadMoreParent
        self.loadMoreRemaining = loadMoreRemaining
        self.authorTitle = authorTitle
        self.flairURL = flairURL
        self.isLiked = isLiked
        self.reactions = reactions
        self.voteScore = voteScore
        self.voteDirection = voteDirection
        self.canVoteDown = canVoteDown
        self.rewards = rewards
        self.mobileSource = mobileSource
        self.isPinned = isPinned
        self.isDeletedPlaceholder = isDeletedPlaceholder
        self.isIgnoredPlaceholder = isIgnoredPlaceholder
        self.isRevealing = isRevealing
        self.canRecover = canRecover
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.isMine = isMine
    }

    /// Convenience for sample data and previews, where the body is a literal
    /// string rather than parsed HTML.
    init(id: Int, author: String, time: String, text: String, votes: Int) {
        self.init(
            id: id,
            author: author,
            time: time,
            content: PostContent(blocks: [.paragraph([.text(text)])]),
            votes: votes
        )
    }
}

struct UserProfileTarget: Identifiable, Hashable {
    let username: String
    var displayName: String?
    var avatarURL: URL?

    var id: String { username.lowercased() }

    var initial: String {
        let source = displayName?.isEmpty == false ? displayName! : username
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}

struct Chat: Identifiable, Hashable {
    let id: Int
    let name: String
    let letter: String
    let variant: Int
    let lastMsg: String
    let time: String
    var unread: Bool
    var avatarURL: URL? = nil
    var threadUnreadCount: Int = 0
}

struct ChatThreadListItem: Identifiable, Hashable {
    let id: Int
    let channelID: Int
    let title: String
    let channelName: String
    let excerpt: String
    let time: String
    let replyCount: Int
    let unread: Bool
    let avatarLetter: String
    let variant: Int
    var avatarURL: URL? = nil
}

struct ChatEmojiImage: Identifiable, Hashable {
    let shortcode: String
    let url: URL
    let width: Int?
    let height: Int?

    var id: String { "\(shortcode)-\(url.absoluteString)" }
}

struct ChatContentFragment: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(String)
        case emojiImage(ChatEmojiImage)
        case lineBreak
    }

    let id: String
    let kind: Kind
}

/// The three shapes a chat can take.
///
/// Discourse models the first two the same way — a `DirectMessage` chatable —
/// and only `chatable.group` tells them apart, which is why a group chat used to
/// behave like a one-to-one one and show a single person's profile.
enum ChatChannelKind {
    /// One other person.
    case direct
    /// A direct message with several people in it.
    case groupDirect
    /// A category channel.
    case category

    init(_ channel: ChatChannel) {
        guard channel.isDirectMessage else {
            self = .category
            return
        }
        self = channel.chatable?.group == true ? .groupDirect : .direct
    }

    /// Whether a member list makes sense; a one-to-one chat just has the one
    /// person, and their profile is the more direct answer.
    var hasMemberList: Bool { self != .direct }

    var memberListTitle: String {
        self == .category ? AppString("频道成员") : AppString("群成员")
    }
}

struct ChatSearchResult: Identifiable, Hashable {
    let id: Int
    let chat: Chat
    let message: ChatConversationMessage
    let thread: ChatThreadListItem?
}

/// The message a chat message replies to, as `in_reply_to` carries it.
struct ChatQuotedMessage: Identifiable, Hashable {
    let id: Int
    let authorName: String
    let username: String
    /// One line of the original. Discourse's own `excerpt_for_display`.
    let excerpt: String
}

/// One pinned chat message, as the pinned bar shows it.
struct ChatPinnedMessage: Identifiable, Hashable {
    let id: Int
    let messageID: Int
    let authorName: String
    let excerpt: String
    let pinnedBy: String?
}

/// An emoji tally under a chat bubble.
struct ChatReaction: Identifiable, Hashable {
    /// Bare emoji name, e.g. `heart` or a custom `ac01`.
    let emoji: String
    let count: Int
    /// Whether the current user is one of them — the tap toggles accordingly.
    let reacted: Bool

    var id: String { emoji }
    var shortcode: String { ":\(emoji):" }
}

struct ChatConversationMessage: Identifiable, Hashable {
    let id: Int
    let authorName: String
    let username: String
    let text: String
    let time: String
    let avatarLetter: String
    let variant: Int
    let avatarURL: URL?
    let isMine: Bool
    let thread: ChatThreadListItem?
    /// Set when this message quotes another (`in_reply_to`).
    var replyTo: ChatQuotedMessage?
    /// Emoji tallies, newest server state.
    var reactions: [ChatReaction] = []
    /// Shown as a marker beside the time.
    var isEdited = false
    /// Which flag types the server will take for this message; empty means it
    /// can't be flagged (already flagged, or your own).
    var availableFlags: [String] = []
    /// Whether this reader may edit or delete it. The chat API has no `can_*`
    /// per message, so authorship is the client-side rule and the server is the
    /// real gate — a refusal surfaces as an error.
    var canModify: Bool { isMine }
    var content: [ChatContentFragment] = []
    var media: [PostMedia] = []
    /// Video uploads. Separate from `media`, which is images: the two need
    /// different rendering, and lumping them together made a sent clip show up
    /// as a broken picture.
    var videos: [URL] = []

    var authorProfileTarget: UserProfileTarget? {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, trimmedUsername.lowercased() != "system" else {
            return nil
        }
        let displayName = authorName == trimmedUsername ? nil : authorName
        return UserProfileTarget(username: trimmedUsername, displayName: displayName, avatarURL: avatarURL)
    }
}

enum NotificationKind { case like, comment, message, success, star, system }

struct AppNotification: Identifiable {
    let id: Int
    let kind: NotificationKind
    let name: String
    let text: String
    let time: String
    /// `var` so 全部已读 can clear the rows' dots without refetching.
    var unread: Bool
    /// Where tapping the row goes. Routed through `LinkRouter`, so topics/PMs
    /// open natively and badge/group/chat notifications open in the in-app
    /// browser. `nil` means the row isn't tappable.
    var url: URL? = nil
}

struct PMConversation: Identifiable {
    /// The PM topic id — tapping opens it as a native post detail.
    let id: Int
    let title: String
    let counterpart: String
    let avatarURL: URL?
    let letter: String
    let variant: Int
    let time: String
    var unread: Bool
}

struct Community: Identifiable {
    let id: Int
    let name: String
    let letter: String
    let variant: Int
    let members: String
    let desc: String
}

/// One 用户组 chip on a profile.
///
/// The label is localised (see `DiscourseRoleNames`), so the *kind* has to travel
/// with it: colouring by the displayed text worked only while the text was
/// hardcoded English, and would have quietly turned every chip blue the moment
/// it became 管理员 or 活跃用户.
/// One figure in the profile's stats row.
///
/// Same lesson as `ProfileRole` above: which two figures draw in the accent
/// colour used to be decided by `label == "能量" || label == "声望"`, which stops
/// being true the moment the label is translated. `isAccented` carries the
/// intent instead of re-deriving it from the display string.
struct ProfileStat: Identifiable, Hashable {
    let value: String
    let label: String
    let isAccented: Bool

    var id: String { label }

    init(value: String, label: String, isAccented: Bool = false) {
        self.value = value
        self.label = label
        self.isAccented = isAccented
    }

    /// The row in its fixed order, which is also the order the placeholders use.
    static func row(
        points: String,
        likes: String,
        topics: String,
        posts: String,
        accountAge: String
    ) -> [ProfileStat] {
        [
            ProfileStat(value: points, label: AppString("能量"), isAccented: true),
            ProfileStat(value: likes, label: AppString("声望"), isAccented: true),
            ProfileStat(value: topics, label: AppString("主题")),
            ProfileStat(value: posts, label: AppString("回复")),
            ProfileStat(value: accountAge, label: AppString("账户年龄"))
        ]
    }

    /// Shown while the summary endpoint is still in flight.
    static var placeholders: [ProfileStat] {
        row(points: "--", likes: "--", topics: "--", posts: "--", accountAge: "--")
    }
}

struct ProfileRole: Identifiable, Hashable {
    enum Kind: Hashable {
        case admin
        case moderator
        case trustLevel(Int)
        case guest
    }

    let kind: Kind
    let label: String

    var id: String { "\(kind)-\(label)" }
}

// MARK: - Navigation

enum Tab: Hashable { case home, nodes, search, chat, profile }
enum Overlay: Identifiable { case sidebar, post, compose, search, browseNodes, createNode, notifications, settings, appsDirectory, appDetail, auth
    var id: Int { hashValue }
}
enum AuthMode { case login, signup }

// MARK: - App State

@Observable
final class AppState {
    // Flow
    var authed = false
    var isGuest = false
    var authMode: AuthMode = .login
    var onboardingDone = false

    // Onboarding
    var interests: Set<String> = []

    // Main
    var tab: Tab = .home
    var overlay: Overlay?
    /// Blank placeholder until a real post is opened — never sample content.
    var selectedPost = Post(
        id: 0, node: "", avatarLetter: "N", variant: 0, time: "",
        title: "", excerpt: "", baseVotes: 0, comments: 0, hasImage: false
    )
    /// App chosen from the directory, shown by the app detail overlay.
    var selectedApp: DirectoryApp?
    var likedPosts: Set<Int> = []
    var navCollapsed = false
    /// Node the composer should open with already selected, set by whoever
    /// opens it (the node page). Cleared by the composer once read, so a later
    /// compose started elsewhere doesn't inherit it.
    var composePreselectedNode: SidebarNodeSummary?
    /// Title the composer opens pre-filled with, set when reposting a topic.
    /// Cleared by the composer once read.
    var composePrefillTitle: String?
    /// Body the composer opens with. Set when quoting a chat transcript, which
    /// the server renders as markdown — so it must go in verbatim, and the
    /// composer opens in source mode for it.
    var composePrefillBody: String?
    /// A topic being edited in the composer. The same screen as posting, so
    /// changing a node, a title and a body is one flow rather than three
    /// half-forms.
    var composeEditTarget: TopicEdit?

    struct TopicEdit: Identifiable, Equatable {
        let topicID: Int
        /// The first post, which is what carries the body.
        let postID: Int
        let title: String
        let raw: String
        let categoryID: Int?
        /// The post as it renders now, shown read-only above the editor: while
        /// editing source there is nothing else to compare against.
        let rendered: PostContent?

        var id: Int { topicID }
    }

    /// The topic a repost quotes. Held as its own thing rather than a URL typed
    /// into the body: the composer shows it as the card it will become, and the
    /// link is prepended to the raw at submit time.
    var composeRepostTopic: RepostTopic?

    struct RepostTopic: Identifiable, Equatable {
        let id: Int
        let title: String
        let url: URL
        var node: String?
        var author: String?
        var excerpt: String?
        var imageURL: URL?
    }
    /// Text the search overlay opens with, e.g. "#slug " to scope to one node.
    /// Cleared by the search view once read.
    var searchInitialQuery = ""
    /// The search tab's query. Lives here because the field is the system one
    /// in the tab bar (`.searchable` on the TabView, in MainView), while the
    /// results render in SearchView — two views that never meet otherwise.
    var searchQuery = ""
    /// The search tab's scope row (全部/节点/帖子/…), rendered by the system
    /// at the top while search is presented.
    var searchScope: SearchScope = .all


    // MARK: Derived

    func isPinned(_ post: Post) -> Bool { post.pinned }

    func isLiked(_ post: Post) -> Bool { likedPosts.contains(post.id) }

    /// A row's standing vote. Local overrides win, so a tap answers at once and
    /// survives the list being remapped from a later fetch.
    func voteDirection(for post: Post) -> VoteDirection {
        voteOverrides[post.id] ?? post.voteDirection
    }

    /// The score with this session's own change folded in: the server's number
    /// plus the difference between where the vote is now and where it started.
    func voteScore(for post: Post) -> Int? {
        guard let base = post.voteScore else { return nil }
        guard let override = voteOverrides[post.id] else { return base }
        return base + weight(override) - weight(post.voteDirection)
    }

    private func weight(_ direction: VoteDirection) -> Int {
        switch direction {
        case .up: return 1
        case .down: return -1
        case .none: return 0
        }
    }

    /// Votes cast in this session, keyed by topic id. Kept here rather than in
    /// the feed store because the same row is drawn by the home feed, the node
    /// page and search, and all three should agree the moment one is tapped.
    var voteOverrides: [Int: VoteDirection] = [:]

    func castVote(_ direction: VoteDirection, on post: Post, reaction: String? = nil) {
        guard let postID = post.opPostID else { return }
        voteOverrides[post.id] = direction
        Task {
            do {
                try await DiscourseClient().castVote(
                    postID: postID,
                    direction: direction,
                    reaction: reaction
                )
            } catch {
                voteOverrides[post.id] = nil
                ToastCenter.shared.showError(error)
            }
        }
    }

    func voteCount(_ post: Post) -> Int {
        post.baseVotes + (isLiked(post) ? 1 : 0)
    }

    func toggleLike(_ post: Post) {
        if likedPosts.contains(post.id) { likedPosts.remove(post.id) }
        else { likedPosts.insert(post.id) }
    }

    func toggleInterest(_ name: String) {
        if interests.contains(name) { interests.remove(name) }
        else { interests.insert(name) }
    }

    // MARK: Link routing

    /// Profile requested by a `/u/<name>` link. The post detail and feed watch
    /// this so a tapped mention lands on the native profile.
    ///
    /// A full-screen cover, presented by `ContentView`. That means it rises
    /// from the bottom, which reads as a modal for something that is really a
    /// page — but it is also what makes it work from *any* depth, including
    /// from the post reader, which draws in `MainView` below the covers. See
    /// the note on `Overlay`.
    var routedProfile: UserProfileTarget?

    /// An `@user` / `#node` / `#tag` badge tapped inside a post body.
    ///
    /// Deliberately separate from `routedProfile` and `routedNodeSlug`: a
    /// reference opens as a half sheet over what you were reading, while those
    /// two still take the whole screen when they come from the sidebar, an
    /// author row, or a notification.
    var routedReference: PostReference?

    /// A reply's post number to scroll to once the topic's replies load, set
    /// when a notification (or a deep link with a post anchor) opens a topic.
    /// The post detail consumes it; unset means "open at the top."
    var pendingReplyPostNumber: Int?

    /// Opens a nodeloc topic natively. Only the id is known from the URL, so
    /// the post detail fills in the rest when it loads the topic. `postNumber`,
    /// when present, scrolls to that reply once it's loaded.
    /// Topics opened this session, so their unread dot clears immediately
    /// without waiting for the list to reload from the server.
    var locallyReadTopicIDs: Set<Int> = []

    func markTopicOpened(id: Int) {
        locallyReadTopicIDs.insert(id)
    }

    /// Opens an app's page from a slug alone — the form `/apps/{slug}` carries,
    /// which is the universal link guideline 4.7.4 requires for each mini app.
    /// The directory opens first so there is something on screen while the
    /// payload loads.
    func openApp(slug: String) {
        overlay = .appsDirectory
        Task {
            guard let fetched = try? await DiscourseClient().app(slug: slug).directoryApp else { return }
            selectedApp = fetched
            overlay = .appDetail
        }
    }

    func openTopic(id: Int, postNumber: Int? = nil) {
        markTopicOpened(id: id)
        pendingReplyPostNumber = postNumber
        // Already open — nothing to do, and rebuilding would lose scroll.
        guard !(overlay == .post && selectedPost.id == id) else { return }
        selectedPost = Post(
            id: id,
            node: "",
            avatarLetter: "N",
            variant: id % 2,
            time: "",
            title: "",
            excerpt: "",
            baseVotes: 0,
            comments: 0,
            hasImage: false
        )
        withAnimation(.expandCollapse) {
            overlay = .post
        }
    }

    /// Opens the composer prefilled to quote a topic — the 转发 every surface
    /// offers. `url` is passed in because the canonical `/t/{slug}/{id}` is only
    /// known where the topic has been loaded; elsewhere the id-only form works.
    func startRepost(of post: Post, url: URL, author: String? = nil) {
        composePrefillTitle = post.title
        composeRepostTopic = RepostTopic(
            id: post.id,
            title: post.title,
            url: url,
            node: post.node,
            author: author ?? post.authorUsername,
            excerpt: post.excerpt.isEmpty ? nil : post.excerpt,
            imageURL: post.imageURL
        )
        withAnimation(.overlayPush) { overlay = .compose }
    }

    func openProfile(username: String) {
        routedProfile = UserProfileTarget(username: username)
    }

    /// When the caller already has a name and avatar, so the page draws its
    /// header before the request lands.
    func openProfile(_ target: UserProfileTarget) {
        routedProfile = target
    }

    /// Node requested by a `/n/<slug>` or `/c/<slug>/<id>` link. The slug is
    /// all the URL carries; `NodeCatalog` resolves it to a full summary.
    var routedNodeSlug: String?

    func openNode(slug: String) {
        routedNodeSlug = slug
    }

    /// A custom feed requested by an `/f/<username>/<slug>` link, by the
    /// drawer, or from someone's profile. Presented natively — the whole point
    /// is not to fall out to the web page.
    var routedCustomFeed: CustomFeedTarget?

    func openCustomFeed(username: String, slug: String, name: String? = nil) {
        routedCustomFeed = CustomFeedTarget(username: username, slug: slug, name: name)
    }

    /// A group whose PM inbox a notification asked to open. The inbox watches
    /// this to switch to the 私信 pane and select that group's filter.
    var inboxRequestedGroup: String?

    /// Person whose chat a profile asked to open. The chat tab watches this,
    /// resolves the direct-message channel and pushes the conversation.
    var chatRequestedUsername: String?

    /// 聊天 from a profile. The profile is presented above the tabs, so its own
    /// screen still has to dismiss itself.
    func openDirectMessage(username: String) {
        overlay = nil
        tab = .chat
        chatRequestedUsername = username
    }

    func openGroupInbox(group: String) {
        overlay = nil
        tab = .chat
        inboxRequestedGroup = group
    }

    // Auth copy
    var authTitle: String { authMode == .login ? "Welcome back." : "Create your account." }
    var authSubtitle: String {
        authMode == .login ? "Log in to keep up with your Nodes." : "Join NODELOC — it takes a minute."
    }
    var authCta: String { authMode == .login ? "Log in" : "Create account" }
}

// MARK: - Sample Data

enum SampleData {
    static let posts: [Post] = [
        Post(id: 1, node: "n/indiehackers", avatarLetter: "I", variant: 0, time: "2h",
             title: "Shipped my first paid feature after 40 rejections",
             excerpt: "Small win, but it finally clicked — here is what changed in how I talked to users.",
             baseVotes: 214, comments: 38, hasImage: false, pinned: true),
        Post(id: 2, node: "n/houseplants", avatarLetter: "H", variant: 1, time: "4h",
             title: "My monstera finally split a leaf after 2 years",
             excerpt: "Patience is apparently a fertilizer.",
             baseVotes: 89, comments: 12, hasImage: true),
        Post(id: 3, node: "n/retrogaming", avatarLetter: "R", variant: 0, time: "6h",
             title: "Found a sealed copy of the original cart at a garage sale",
             excerpt: "Paid $4. Still shaking.",
             baseVotes: 512, comments: 74, hasImage: true),
        Post(id: 4, node: "n/climbing", avatarLetter: "C", variant: 1, time: "9h",
             title: "Sent my first 5.11 today",
             excerpt: "Six months of Tuesday nights at the gym finally paid off.",
             baseVotes: 156, comments: 21, hasImage: false),
    ]

    static let comments: [PostComment] = [
        PostComment(id: 1, author: "juno_v", time: "1h",
                    text: "This is such a good reminder to actually talk to users instead of guessing.", votes: 24),
        PostComment(id: 2, author: "petra.k", time: "45m",
                    text: "Congrats! What was the one change that mattered most?", votes: 11),
        PostComment(id: 3, author: "devrel_marcus", time: "30m",
                    text: "Saving this thread for later, going through the same thing right now.", votes: 6),
        PostComment(id: 4, author: "lil_amber", time: "12m",
                    text: "Rejections are just data. Love seeing this pay off.", votes: 3),
    ]

    static let chats: [Chat] = [
        Chat(id: 1, name: "petra.k", letter: "P", variant: 0, lastMsg: "sent you the plant care doc", time: "2m", unread: true),
        Chat(id: 2, name: "n/climbing mods", letter: "C", variant: 1, lastMsg: "Your post was approved ✓", time: "1h", unread: true),
        Chat(id: 3, name: "juno_v", letter: "J", variant: 0, lastMsg: "haha yes exactly that", time: "3h", unread: false),
        Chat(id: 4, name: "devrel_marcus", letter: "D", variant: 1, lastMsg: "let’s hop on a call next week", time: "1d", unread: false),
        Chat(id: 5, name: "retro_sam", letter: "S", variant: 0, lastMsg: "deal, meet at the flea market?", time: "2d", unread: false),
    ]

    static let notifications: [AppNotification] = [
        AppNotification(id: 1, kind: .like, name: "juno_v", text: "liked your post in n/indiehackers", time: "10m", unread: true),
        AppNotification(id: 2, kind: .comment, name: "petra.k", text: "commented on your post", time: "32m", unread: true),
        AppNotification(id: 3, kind: .success, name: "n/climbing", text: "approved your membership request", time: "2h", unread: false),
        AppNotification(id: 4, kind: .like, name: "lil_amber", text: "liked your comment", time: "5h", unread: false),
        AppNotification(id: 5, kind: .star, name: "NODELOC", text: "Your weekly recap is ready", time: "1d", unread: false),
    ]

    static let communities: [Community] = [
        Community(id: 1, name: "n/design", letter: "D", variant: 0, members: "84k", desc: "Craft & critique"),
        Community(id: 2, name: "n/indiehackers", letter: "I", variant: 1, members: "61k", desc: "Build in public"),
        Community(id: 3, name: "n/houseplants", letter: "H", variant: 0, members: "47k", desc: "Leaf gang"),
        Community(id: 4, name: "n/retrogaming", letter: "R", variant: 1, members: "92k", desc: "Cartridges & consoles"),
        Community(id: 5, name: "n/climbing", letter: "C", variant: 0, members: "33k", desc: "Send it"),
    ]

    static let interestNames = ["Design", "Tech", "Gaming", "Fitness", "Plants", "Music", "Cooking", "Travel", "Books", "Startups"]
    static let activity: [Double] = [30, 55, 40, 80, 60, 25, 45]
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let tags = ["#buildinpublic", "#firstascent", "#retro", "#plantcare", "#launchweek", "#gearcheck"]

    // Current user
    static let userName = "rowan.codes"
    static let userInitial = "R"
    static let userJoined = "Joined Mar 2024"
    static let userKarma = "2,481"
    static let userPosts = "64"
    static let userComments = "312"
}
