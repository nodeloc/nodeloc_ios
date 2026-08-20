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
    /// Real topic image (when loaded from Discourse); nil falls back to the hatch placeholder.
    var imageURL: URL? = nil
    /// Real author avatar (when loaded from Discourse); nil falls back to initials.
    var avatarURL: URL? = nil
    /// Discourse username for navigating to the public profile.
    var authorUsername: String? = nil
    var authorName: String? = nil
    /// Feed media previews. Uses Discourse's topic thumbnails when available.
    var media: [PostMedia] = []
}

struct PostMedia: Identifiable, Hashable {
    let url: URL
    let width: Int?
    let height: Int?

    var id: URL { url }
}

func postTransitionID(_ id: Int) -> String {
    "post-transition-\(id)"
}

struct PostComment: Identifiable {
    let id: Int
    let author: String
    let time: String
    let text: String
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

    init(
        id: Int,
        author: String,
        time: String,
        text: String,
        votes: Int,
        postNumber: Int = 0,
        replyToPostNumber: Int? = nil,
        parentAuthor: String? = nil,
        parentText: String? = nil,
        avatarURL: URL? = nil,
        nestingDepth: Int = 0,
        isLastSibling: Bool = true,
        ancestorTrails: [Bool] = [],
        hasChildren: Bool = false
    ) {
        self.id = id
        self.author = author
        self.time = time
        self.text = text
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

struct Chat: Identifiable {
    let id: Int
    let name: String
    let letter: String
    let variant: Int
    let lastMsg: String
    let time: String
    let unread: Bool
}

enum NotificationKind { case like, comment, message, success, star }

struct AppNotification: Identifiable {
    let id: Int
    let kind: NotificationKind
    let name: String
    let text: String
    let time: String
    let unread: Bool
}

struct Community: Identifiable {
    let id: Int
    let name: String
    let letter: String
    let variant: Int
    let members: String
    let desc: String
}

struct SettingRow: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    var danger: Bool = false
}

// MARK: - Navigation

enum Tab: Hashable { case home, search, chat, profile }
enum Overlay: Identifiable { case sidebar, post, compose, search, browseNodes, createNode, notifications, settings, pro
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
    var likedPosts: Set<Int> = []
    var plan: ProPlan = .yearly
    var navCollapsed = false

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

    static let settings: [SettingRow] = [
        SettingRow(label: "Account", detail: "rowan.codes"),
        SettingRow(label: "Notifications", detail: "On"),
        SettingRow(label: "Privacy & Safety", detail: ""),
        SettingRow(label: "Appearance", detail: "Light"),
        SettingRow(label: "Help", detail: ""),
        SettingRow(label: "Log out", detail: "", danger: true),
    ]

    // Current user
    static let userName = "rowan.codes"
    static let userInitial = "R"
    static let userJoined = "Joined Mar 2024"
    static let userKarma = "2,481"
    static let userPosts = "64"
    static let userComments = "312"
}
