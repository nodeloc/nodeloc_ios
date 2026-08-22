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
    let comments: Int
    let hasImage: Bool
    var pinned: Bool = false
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
    let votes: Int
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
        loadMoreRemaining: Int = 0
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

struct ChatCustomEmoji: Identifiable, Hashable {
    let shortcode: String
    let url: URL
    let width: Int?
    let height: Int?

    var id: String { "\(shortcode)-\(url.absoluteString)" }
}

struct ChatContentFragment: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(String)
        case customEmoji(ChatCustomEmoji)
        case lineBreak
    }

    let id: String
    let kind: Kind
}

struct ChatSearchResult: Identifiable, Hashable {
    let id: Int
    let chat: Chat
    let message: ChatConversationMessage
    let thread: ChatThreadListItem?
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
    var content: [ChatContentFragment] = []
    var media: [PostMedia] = []

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
    let unread: Bool
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

// MARK: - Navigation

enum Tab: Hashable { case home, nodes, search, chat, profile }
enum Overlay: Identifiable { case sidebar, post, compose, search, browseNodes, createNode, notifications, settings, pro, appsDirectory, appDetail
    var id: Int { hashValue }
}
enum AuthMode { case login, signup }
enum ProPlan { case monthly, yearly }

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
    var selectedPost: Post = SampleData.posts[0]
    /// App chosen from the directory, shown by the app detail overlay.
    var selectedApp: DirectoryApp?
    var likedPosts: Set<Int> = []
    var plan: ProPlan = .yearly
    var navCollapsed = false
    /// Node the composer should open with already selected, set by whoever
    /// opens it (the node page). Cleared by the composer once read, so a later
    /// compose started elsewhere doesn't inherit it.
    var composePreselectedNode: SidebarNodeSummary?
    /// Text the search overlay opens with, e.g. "#slug " to scope to one node.
    /// Cleared by the search view once read.
    var searchInitialQuery = ""

    // MARK: Derived

    func isPinned(_ post: Post) -> Bool { post.pinned }

    func isLiked(_ post: Post) -> Bool { likedPosts.contains(post.id) }

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
    var routedProfile: UserProfileTarget?

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

    func openProfile(username: String) {
        routedProfile = UserProfileTarget(username: username)
    }

    /// Node requested by a `/n/<slug>` or `/c/<slug>/<id>` link. The slug is
    /// all the URL carries; `NodeCatalog` resolves it to a full summary.
    var routedNodeSlug: String?

    func openNode(slug: String) {
        routedNodeSlug = slug
    }

    /// A group whose PM inbox a notification asked to open. The inbox watches
    /// this to switch to the 私信 pane and select that group's filter.
    var inboxRequestedGroup: String?

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

    // Pro copy
    var planPrice: String { plan == .monthly ? "$4.99" : "$39.99" }
    var planPeriod: String { plan == .monthly ? "per month" : "per year" }
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
