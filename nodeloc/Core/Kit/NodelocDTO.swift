//
//  NodelocDTO.swift
//  nodeloc
//
//  Wire types for the NodeLoc backend's `/api/v1`, decoded with
//  `.convertFromSnakeCase`. Times stay strings here: the server writes Go's
//  RFC 3339 with up to nine fractional digits and an offset, which
//  `NLDate.normalize` turns into what the rest of the app parses.
//
//  Fields the server documents as optional (omitempty) or nullable are
//  optional; the rest are required, so a contract change fails a test rather
//  than quietly blanking a screen.
//

import Foundation

// MARK: - Users and auth

nonisolated struct NLUser: Codable, Sendable {
    let id: Int
    let username: String
    let name: String?
    let role: String?
    let trustLevel: Int?
    let tierName: String?
    let title: String?
    let createdAt: String?
    // /me only
    let email: String?
    let emailVerified: Bool?
    let bioRaw: String?
    let website: String?
    let location: String?
    let avatarUrl: String?
    let coverUrl: String?
    let bioHtml: String?
    let followerCount: Int?
    let followingCount: Int?
    /// The viewer's relation to this user; all false on your own profile.
    let viewerFollowing: Bool?
    let viewerBlocked: Bool?
    let canMessage: Bool?
    let messageNote: String?

    var isStaff: Bool { role == "admin" || role == "moderator" }
}

nonisolated struct NLUserEnvelope: Codable, Sendable {
    let user: NLUser
}

/// What a login, registration or token exchange answers. `token` is the app
/// session when the server issues one; without it the session arrives as the
/// `nl_session` cookie.
nonisolated struct NLAuthResponse: Codable, Sendable {
    let user: NLUser
    let token: String?
    /// "Don't ask for the second factor on this device again", returned when
    /// a login sent a code with `trust_device`; sent back as `X-Nodeloc-Trust`.
    let trustToken: String?
    let pendingApproval: Bool?
    let emailVerified: Bool?
    let loggedIn: Bool?
}

nonisolated struct NLMeStatus: Codable, Sendable {
    struct Me: Codable, Sendable {
        let username: String
        let name: String?
        let avatarUrl: String?
        let coverUrl: String?
    }
    struct Status: Codable, Sendable {
        let emoji: String?
        let text: String?
        let expiresAt: String?
        let pause: Bool?
    }
    let me: Me
    let status: Status?
}

nonisolated struct NLUserProfile: Codable, Sendable {
    struct Stats: Codable, Sendable {
        let topicCount: Int?
        let postCount: Int?
        let votesReceived: Int?
        let daysVisited: Int?
        let followerCount: Int?
        let followingCount: Int?
    }
    struct Viewer: Codable, Sendable {
        let following: Bool?
        let blocked: Bool?
        let canFollow: Bool?
    }
    let user: NLUser
    let stats: Stats?
    let viewer: Viewer?
}

nonisolated struct NLMentionCandidates: Codable, Sendable {
    struct User: Codable, Sendable {
        let username: String
        let name: String?
        let avatar: String?
        let group: String?
    }
    let users: [User]
}

nonisolated struct NLFollowList: Codable, Sendable {
    struct User: Codable, Sendable {
        let username: String
        let avatar: String?
        let since: String?
        let name: String?
    }
    let users: [User]
}

nonisolated struct NLIdentities: Codable, Sendable {
    struct Identity: Codable, Sendable {
        let provider: String
        let label: String?
        let linked: Bool
        let name: String?
        let email: String?
        let linkedAt: String?
    }
    let identities: [Identity]
    let hasPassword: Bool?
}

nonisolated struct NLSessions: Codable, Sendable {
    struct Session: Codable, Sendable {
        let id: Int
        let userAgent: String?
        let ip: String?
        let lastSeenAt: String?
        let createdAt: String?
        let current: Bool?
    }
    let sessions: [Session]
}

nonisolated struct NLTwoFactorState: Codable, Sendable {
    let enabled: Bool
    let backupCodesLeft: Int?
}

nonisolated struct NLTwoFactorSetup: Codable, Sendable {
    let secret: String
    let uri: String?
}

nonisolated struct NLBackupCodes: Codable, Sendable {
    let backupCodes: [String]
}

nonisolated struct NLAuthProviders: Codable, Sendable {
    struct Provider: Codable, Sendable {
        let name: String
        let label: String?
        let icon: String?
        let url: String?
    }
    let providers: [Provider]
    /// Whether `POST /api/v1/auth/apple/native` is configured.
    let appleNative: Bool?
}

nonisolated struct NLUsernameCheck: Codable, Sendable {
    let ok: Bool?
}

nonisolated struct NLAchievements: Codable, Sendable {
    struct Achievement: Codable, Sendable {
        let key: String
        let name: String?
        let description: String?
        let icon: String?
        let tier: Int?
        let tierName: String?
    }
    let showcase: [Achievement]
    let reputation: Int?
}

nonisolated struct NLTiers: Codable, Sendable {
    struct Tier: Codable, Sendable {
        let level: Int
        let name: String
    }
    let tiers: [Tier]
}

// MARK: - Topics and posts

nonisolated struct NLTopicSummary: Codable, Sendable {
    let id: Int
    let title: String
    let excerpt: String?
    let nodeSlug: String
    let nodeName: String?
    let author: String
    let authorId: Int?
    let authorAvatar: String?
    let tags: [String]?
    let closed: Bool?
    let pinned: Bool?
    let featured: Bool?
    let views: Int?
    let replyCount: Int?
    let voteScore: Int?
    let lastPostedAt: String?
    let createdAt: String?
    let lastReadPostNumber: Int?
    let unreadCount: Int?
    /// Lets a list row vote on the first post. Not on the personal feed.
    let firstPostId: Int?
    let viewerVote: Int?
    /// The first post's first image as a card thumbnail (absolute URL).
    let imageUrl: String?
    let adult: Bool?
    let bumpedAt: String?
    /// The topic accepted a best answer, so the row shows a "solved" badge.
    let solved: Bool?
    /// The first post is hidden. Only moderators and the node's managers see
    /// such a topic in a list at all; the author sees it in his own topics.
    let hidden: Bool?
}

nonisolated struct NLTopicPage: Codable, Sendable {
    let topics: [NLTopicSummary]
    let nextCursor: String?
    let nextOffset: Int?
}

nonisolated struct NLPost: Codable, Sendable {
    struct TitleStyle: Codable, Sendable {
        let color: String?
        let effect: String?
    }
    struct Group: Codable, Sendable {
        let name: String
        let label: String?
        let color: String?
    }
    struct Flair: Codable, Sendable {
        let id: Int?
        let text: String?
        let color: String?
        let style: String?
        let icon: String?
    }

    let id: Int
    let postNumber: Int
    let author: String
    let authorId: Int?
    let authorAvatar: String?
    let authorTitle: String?
    let authorTitleStyle: TitleStyle?
    let authorGroup: Group?
    let replyToPostNumber: Int?
    let kind: String?
    let actionCode: String?
    let html: String
    let upvotes: Int?
    let downvotes: Int?
    let replyCount: Int?
    let version: Int?
    let editedAt: String?
    let deleted: Bool?
    let hidden: Bool?
    let locked: Bool?
    let collapsed: Bool?
    let adult: Bool?
    let viewerVote: Int?
    let viewerBookmarked: Bool?
    let authorFlair: Flair?
    let authorBlocked: Bool?
    let ackLabel: String?
    let viewerAcknowledged: Bool?
    /// Only on a deleted post: `author` when the author deleted it himself,
    /// `moderator` otherwise (a system account or old data without an actor
    /// counts as `moderator`). `deleteReason` comes only with a moderator's
    /// deletion, and only when one was written.
    let deletedBy: String?
    let deleteReason: String?
    /// Only `GET /topics/{id}` sends these.
    let canEdit: Bool?
    let canDelete: Bool?
    let createdAt: String?
    // /thread only
    let depth: Int?
    let replies: Int?

    var score: Int { (upvotes ?? 0) - (downvotes ?? 0) }
}

/// The accepted best answer. `acceptedBy` is `author` or `moderator` (a
/// moderator may accept on the author's behalf). Null once that reply is
/// deleted or hidden, even though the topic still counts as solved.
nonisolated struct NLAcceptedAnswer: Codable, Sendable {
    let postId: Int
    let postNumber: Int?
    let username: String?
    let acceptedBy: String?
}

nonisolated struct NLTopicDetail: Codable, Sendable {
    struct Topic: Codable, Sendable {
        let id: Int
        let title: String
        let nodeSlug: String
        let nodeName: String?
        let author: String?
        let tags: [String]?
        let closed: Bool?
        let pinned: Bool?
        let pinnedUntil: String?
        let featured: Bool?
        let views: Int?
        let replyCount: Int?
        let highestPostNumber: Int?
        let voteScore: Int?
        let createdAt: String?
        /// watching / normal / muted; nil when signed out.
        let notificationLevel: String?
        let lastReadPostNumber: Int?
        let hasLottery: Bool?
        let hasTrade: Bool?
        let hasRedEnvelope: Bool?
        /// Best answer. `canAccept` is true when the topic carries the help
        /// tag and the reader is the author or can moderate the node — the
        /// signal to draw "Accept" on someone else's reply.
        let acceptedAnswer: NLAcceptedAnswer?
        let canAccept: Bool?
    }
    struct Permissions: Codable, Sendable {
        let reply: Bool?
        let moderate: Bool?
    }
    let topic: Topic
    let posts: [NLPost]
    let nextAfter: Int?
    let permissions: Permissions?
}

nonisolated struct NLThreadPage: Codable, Sendable {
    let posts: [NLPost]
    let nextOffset: Int?
    let nextAfter: Int?
    /// `/thread` carries no `topic`, so these two sit at the top level.
    let acceptedAnswer: NLAcceptedAnswer?
    let canAccept: Bool?
}

nonisolated struct NLCreatedTopic: Codable, Sendable {
    struct Topic: Codable, Sendable { let id: Int; let title: String? }
    struct Post: Codable, Sendable { let id: Int; let postNumber: Int?; let html: String? }
    let topic: Topic
    let post: Post?
}

nonisolated struct NLCreatedReply: Codable, Sendable {
    struct Post: Codable, Sendable {
        let id: Int
        let postNumber: Int
        let replyToPostNumber: Int?
        let html: String?
        let createdAt: String?
    }
    let post: Post
    let held: Bool?
}

nonisolated struct NLPostRaw: Codable, Sendable {
    struct Topic: Codable, Sendable {
        let id: Int
        let title: String?
        let node: String?
        let tags: [String]?
        let minTrustLevel: Int?
        let loginOnly: Bool?
    }
    let raw: String
    let topic: Topic?
}

nonisolated struct NLVoteResult: Codable, Sendable {
    let upvotes: Int
    let downvotes: Int
    let viewerVote: Int
}

nonisolated struct NLBookmarks: Codable, Sendable {
    struct Bookmark: Codable, Sendable {
        let id: Int
        let postId: Int
        let postNumber: Int
        let topicId: Int
        let topicTitle: String
        let author: String
        let html: String?
        let createdAt: String?
    }
    let bookmarks: [Bookmark]
    let nextBefore: Int?
}

nonisolated struct NLPolls: Codable, Sendable {
    let polls: [NLPoll]
}

nonisolated struct NLPollEnvelope: Codable, Sendable {
    let poll: NLPoll
}

nonisolated struct NLPoll: Codable, Sendable {
    struct Option: Codable, Sendable {
        let id: Int
        let text: String
        let votes: Int?
        let chosen: Bool?
    }
    let id: Int
    let postId: Int?
    let name: String
    let type: String?
    let min: Int?
    let max: Int?
    let results: String?
    let `public`: Bool?
    let closeAt: String?
    let closed: Bool?
    let voters: Int?
    let voted: Bool?
    let resultsVisible: Bool?
    let options: [Option]
}

nonisolated struct NLLotteryEnvelope: Codable, Sendable {
    let lottery: NLLottery
}

nonisolated struct NLLottery: Codable, Sendable {
    struct Holder: Codable, Sendable {
        let username: String
        let avatarUrl: String?
        let tickets: Int?
        let joinedAt: String?
    }
    struct Prize: Codable, Sendable {
        let name: String?
        let prize: String?
        let quantity: Int?
        let winners: [Holder]?
    }
    let id: Int
    let postId: Int?
    let title: String?
    let status: String?
    let drawAt: String?
    let drawnAt: String?
    let minTickets: Int?
    let maxTickets: Int?
    let minParticipants: Int?
    let maxParticipants: Int?
    let minTrustLevel: Int?
    let participantCount: Int?
    let ticketCount: Int?
    let myTickets: Int?
    let prizes: [Prize]?
    let participants: [Holder]?
}

nonisolated struct NLRedEnvelopeEnvelope: Codable, Sendable {
    let redEnvelope: NLRedEnvelope
}

nonisolated struct NLRedEnvelope: Codable, Sendable {
    struct Claim: Codable, Sendable {
        let username: String
        let postId: Int?
        let points: Int?
        let createdAt: String?
    }
    let topicId: Int
    let totalPoints: Int?
    let totalCount: Int?
    let claimedCount: Int?
    let remainingPoints: Int?
    let expiresAt: String?
    let ended: Bool?
    let claims: [Claim]?
    let createdAt: String?
}

nonisolated struct NLTags: Codable, Sendable {
    struct Tag: Codable, Sendable {
        let id: Int?
        let name: String
        let label: String?
        let topicCount: Int?
    }
    let tags: [Tag]
}

nonisolated struct NLEmojis: Codable, Sendable {
    struct Pack: Codable, Sendable {
        struct Emoji: Codable, Sendable {
            let code: String
            let name: String?
            let url: String
        }
        let id: String?
        let name: String?
        let enabled: Bool?
        let emojis: [Emoji]
    }
    let emojis: [String: String]?
    let packs: [Pack]?
}

nonisolated struct NLRevision: Codable, Sendable {}

// MARK: - Nodes

nonisolated struct NLNode: Codable, Sendable {
    let id: Int
    let parentId: Int?
    let slug: String
    let name: String
    let description: String?
    let color: String?
    let logoUrl: String?
    let icon: String?
    let visibility: String?
    let topicPolicy: String?
    let official: Bool?
    let inHomeFeed: Bool?
    let topicCount: Int?
    let postCount: Int?
    let memberCount: Int?
    let ownerId: Int?
    let createdAt: String?
    let joined: Bool?
    // Newer servers: the reader's own settings for the node.
    let favorite: Bool?
    let notificationLevel: String?
}

nonisolated struct NLNodeList: Codable, Sendable {
    let nodes: [NLNode]
    let nextPage: Int?
    let nextCursor: String?
}

nonisolated struct NLNodeDetail: Codable, Sendable {
    struct Permissions: Codable, Sendable {
        let createTopic: Bool?
        let reply: Bool?
        let moderate: Bool?
    }
    let node: NLNode
    let bannerUrl: String?
    let logoDarkUrl: String?
    let bannerDarkUrl: String?
    let permissions: Permissions?
}

nonisolated struct NLNodeEnvelope: Codable, Sendable {
    let node: NLNode
}

/// A node's pinned carousel. Same rows as a topic list plus when the pin was
/// placed and when it lapses (null = forever). Not paged — there are only ever
/// a handful — and readable signed out.
nonisolated struct NLNodePins: Codable, Sendable {
    nonisolated struct Pin: Codable, Sendable {
        let id: Int
        let title: String
        let excerpt: String?
        let nodeSlug: String?
        let author: String?
        let authorAvatar: String?
        let replyCount: Int?
        let voteScore: Int?
        let createdAt: String?
        let imageUrl: String?
        let pinnedAt: String?
        let pinnedUntil: String?
    }
    let topics: [Pin]
}

/// The home banner carousel, readable signed out.
nonisolated struct NLHomeAnnouncements: Codable, Sendable {
    nonisolated struct Announcement: Codable, Sendable, Identifiable {
        let id: Int
        /// `notice`, `event`, `maintenance` or `rules`; `kindName` is the same
        /// thing already written in the reader's language.
        let kind: String?
        let kindName: String?
        let title: String
        let excerpt: String?
        let coverUrl: String?
        let topicId: Int?
        let url: String?
        let publishedAt: String?
        /// Always true today. A signed-in reader dismisses through the API so
        /// it stays dismissed across devices; a guest has no account, so the
        /// app remembers it locally and must *not* call that endpoint (401).
        let dismissible: Bool?
    }
    let announcements: [Announcement]
}

nonisolated struct NLSlugAvailability: Codable, Sendable {
    let slug: String?
    let available: Bool?
}

nonisolated struct NLNodeOptions: Codable, Sendable {
    struct Option: Codable, Sendable {
        let slug: String
        let name: String
        let color: String?
        let description: String?
        let logoUrl: String?
        let members: Int?
        let joined: Bool?
    }
    let nodes: [Option]
}

// MARK: - Custom feeds

nonisolated struct NLCustomFeed: Codable, Sendable {
    struct Node: Codable, Sendable {
        let slug: String
        let name: String?
        let color: String?
        let memberCount: Int?
    }
    let id: Int
    let name: String
    let description: String?
    let `public`: Bool?
    let color: String?
    let owner: String?
    let mine: Bool?
    let nodes: [Node]?
    let nodeCount: Int?
}

nonisolated struct NLCustomFeeds: Codable, Sendable {
    let feeds: [NLCustomFeed]
}

nonisolated struct NLCustomFeedEnvelope: Codable, Sendable {
    let feed: NLCustomFeed
}

// MARK: - Notifications

nonisolated struct NLNotification: Codable, Sendable {
    let id: Int
    let kind: String
    let actor: String?
    let actorCount: Int?
    let topicId: Int?
    let topicTitle: String?
    let postNumber: Int?
    let postId: Int?
    let actorAvatar: String?
    let followingActor: Bool?
    let data: JSONValue?
    let read: Bool
    let createdAt: String?
}

nonisolated struct NLNotifications: Codable, Sendable {
    let notifications: [NLNotification]
    let unread: Int?
    let nextBefore: Int?
}

// MARK: - Chat

nonisolated struct NLChatEvent: Codable, Sendable {
    struct User: Codable, Sendable {
        let username: String
        let me: Bool?
    }
    let type: String
    let users: [User]?
    let name: String?
    let slug: String?
}

nonisolated struct NLChatChannel: Codable, Sendable {
    let id: Int
    let slug: String?
    let name: String
    let description: String?
    let memberCount: Int?
    let joined: Bool?
    let staffOnly: Bool?
    let unreadCount: Int?
    let muted: Bool?
    let mentionCount: Int?
    let excerpt: String?
    let lastKind: String?
    let lastEvent: NLChatEvent?
    let lastSender: String?
    let lastMessageAt: String?
}

nonisolated struct NLChatGroup: Codable, Sendable {
    let id: Int
    let name: String
    let memberCount: Int?
    let members: [String]?
    let owner: String?
    let ownerMe: Bool?
    let unreadCount: Int?
    let muted: Bool?
    let mentionCount: Int?
    let excerpt: String?
    let lastKind: String?
    let lastEvent: NLChatEvent?
    let lastSender: String?
    let lastMessageAt: String?
}

nonisolated struct NLChatDirect: Codable, Sendable {
    let id: Int
    let with: String
    let avatar: String?
    let excerpt: String?
    let lastKind: String?
    let lastFromMe: Bool?
    let unreadCount: Int?
    let muted: Bool?
    let lastMessageAt: String?
}

nonisolated struct NLChatOverview: Codable, Sendable {
    struct Cursor: Codable, Sendable {
        let before: String
        let beforeId: Int
    }
    let channels: [NLChatChannel]
    let groups: [NLChatGroup]
    let directs: [NLChatDirect]
    let directsNext: Cursor?
    let unreadCount: Int?
}

nonisolated struct NLChatMessage: Codable, Sendable {
    struct Quote: Codable, Sendable {
        let id: Int
        let sender: String?
        let excerpt: String?
        let kind: String?
    }
    let id: Int
    let fromMe: Bool?
    let sender: String
    let avatar: String?
    let html: String
    let createdAt: String?
    let deleted: Bool?
    let deletedByMe: Bool?
    let event: NLChatEvent?
    let reply: Quote?
}

nonisolated struct NLChatPage: Codable, Sendable {
    let messages: [NLChatMessage]
    let nextBefore: Int?
    let conversationId: Int?
    let lastReadId: Int?
    let unreadCount: Int?
}

nonisolated struct NLChatMessageEnvelope: Codable, Sendable {
    let message: NLChatMessage
}

nonisolated struct NLChatGroupMembers: Codable, Sendable {
    struct Member: Codable, Sendable {
        let username: String
        let name: String?
        let avatar: String?
        let owner: Bool?
        let me: Bool?
    }
    let members: [Member]
}

nonisolated struct NLCreatedGroup: Codable, Sendable {
    struct Group: Codable, Sendable { let id: Int }
    let group: Group
}

nonisolated struct NLUnread: Codable, Sendable {
    let unreadCount: Int?
}

// MARK: - Uploads, video, points, mobile

nonisolated struct NLUpload: Codable, Sendable {
    let id: Int
    let url: String
    let width: Int?
    let height: Int?
    let image: Bool?
    let filename: String?
    let size: Int?
}

nonisolated struct NLUploadEnvelope: Codable, Sendable {
    let upload: NLUpload
}

nonisolated struct NLVideo: Codable, Sendable {
    let sha1: String
    let status: String
    let width: Int?
    let height: Int?
    let duration: Int?
    let hlsUrl: String?
    let posterUrl: String?
}

nonisolated struct NLVideoEnvelope: Codable, Sendable {
    let video: NLVideo
}

nonisolated struct NLCheckinState: Codable, Sendable {
    let checkedInToday: Bool
    let todayPoints: Int?
    let days: [String]?
    let total: Int?
    let streak: Int?
}

nonisolated struct NLCheckinResult: Codable, Sendable {
    let points: Int
    let balance: Int?
    let day: String?
}

nonisolated struct NLPointsBalance: Codable, Sendable {
    let balance: Int
}

nonisolated struct NLPointsHistory: Codable, Sendable {
    struct Entry: Codable, Sendable {
        struct Ref: Codable, Sendable {
            let type: String?
            let label: String?
            let url: String?
        }
        let id: Int
        let kind: String
        let amount: Int
        let balanceAfter: Int?
        let memo: String?
        let ref: Ref?
        let counterpart: String?
        let createdAt: String?
    }
    let entries: [Entry]
    let total: Int?
    let nextBefore: Int?
}

nonisolated struct NLMobileFlags: Codable, Sendable {
    let flags: [String: Bool]
}

nonisolated struct NLRelease: Codable, Sendable {
    struct Latest: Codable, Sendable {
        let version: String
        let build: Int
        let minSupportedBuild: Int?
        let notes: String?
        let downloadUrl: String?
        let publishedAt: String?
    }
    let latest: Latest?
    let updateAvailable: Bool
    let updateRequired: Bool
}

nonisolated struct NLDevice: Codable, Sendable {
    let id: Int
    let platform: String
    let appBuild: Int?
    let name: String?
}

nonisolated struct NLDeviceEnvelope: Codable, Sendable {
    let device: NLDevice
}

nonisolated struct NLLinkPreviews: Codable, Sendable {
    struct Preview: Codable, Sendable {
        let url: String
        let status: String
        let provider: String?
        let title: String?
        let description: String?
        let imageUrl: String?
        let siteName: String?
        let iconUrl: String?
    }
    let previews: [Preview]
}

nonisolated struct NLSearchResults: Codable, Sendable {
    struct Post: Codable, Sendable {
        let id: Int
        let topicId: Int
        let postNumber: Int?
        let topicTitle: String?
        let excerpt: String?
        let blurb: String?
        let author: String?
        let authorId: Int?
        let nodeSlug: String?
        let nodeName: String?
        let createdAt: String?
        let upvotes: Int?
        let replyCount: Int?
        let folded: Bool?
    }
    struct Node: Codable, Sendable {
        let slug: String
        let name: String
        let color: String?
        let description: String?
        let memberCount: Int?
        let joined: Bool?
    }
    struct User: Codable, Sendable {
        let username: String
        let name: String?
        let avatar: String?
        let following: Bool?
    }
    struct Tag: Codable, Sendable {
        let name: String
        let label: String?
        let topicCount: Int?
    }
    let posts: [Post]?
    let nodes: [Node]?
    let users: [User]?
    let tags: [Tag]?
    let hasMore: Bool?
}

/// `GET /api/v1/users/{u}/posts`.
nonisolated struct NLUserPosts: Codable, Sendable {
    struct Post: Codable, Sendable {
        let id: Int
        let topicId: Int
        let postNumber: Int
        let topicTitle: String?
        let nodeSlug: String?
        let nodeName: String?
        let html: String?
        let excerpt: String?
        let createdAt: String?
    }
    let posts: [Post]
    let nextCursor: String?
}

/// `GET /api/v1/me/nodes`: the reader's relation to nodes.
nonisolated struct NLMyNodes: Codable, Sendable {
    struct Joined: Codable, Sendable {
        let slug: String
        let name: String?
        let color: String?
        let memberCount: Int?
        let role: String?
        let notificationLevel: String?
    }
    struct Favorite: Codable, Sendable {
        let slug: String
        let name: String?
    }
    let joined: [Joined]
    let favorites: [Favorite]?
    let muted: [String]?
}

nonisolated struct NLBookmarkFolders: Codable, Sendable {
    struct Folder: Codable, Sendable {
        let id: Int
        let name: String
        let count: Int?
        let `public`: Bool?
    }
    let folders: [Folder]
    let total: Int?
    let unfiled: Int?
}

/// `GET /api/v1/saved`.
nonisolated struct NLSaved: Codable, Sendable {
    struct Bookmark: Codable, Sendable {
        let id: Int
        let postId: Int
        let postNumber: Int
        let topicId: Int
        let topicTitle: String?
        let folderId: Int?
        let note: String?
        let excerpt: String?
        let author: String?
        let nodeSlug: String?
        let createdAt: String?
    }
    let bookmarks: [Bookmark]
    let total: Int?
    let nextOffset: Int?
}

// MARK: - Untyped JSON

/// Arbitrary JSON, for the few payloads whose shape is open-ended
/// (`notification.data`).
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Looks a key up as written and in camelCase: whether a snake_case
    /// decoding strategy rewrites dictionary keys differs between Foundation
    /// implementations.
    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        if let value = object[key] { return value }
        let parts = key.split(separator: "_")
        guard parts.count > 1 else { return nil }
        let camel = String(parts[0]) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return object[camel]
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}

// MARK: - Dates

nonisolated enum NLDate {
    /// Go writes RFC 3339 with 0–9 fractional digits and a numeric offset;
    /// `ISO8601DateFormatter` reliably takes neither more than three digits
    /// nor every offset form, so times are re-written as UTC with
    /// milliseconds — the shape the app's parsers were written for.
    static func normalize(_ raw: String?) -> String? {
        guard let raw, let date = parse(raw) else { return raw }
        return format(date)
    }

    static func parse(_ raw: String) -> Date? {
        // Split "2026-11-25T01:33:46.723291+08:00" into its parts by hand.
        guard raw.count >= 19 else { return nil }
        let chars = Array(raw)
        let base = String(chars[0..<19])
        var index = 19
        var fraction = 0.0
        if index < chars.count, chars[index] == "." {
            index += 1
            var digits = ""
            while index < chars.count, chars[index].isNumber {
                digits.append(chars[index])
                index += 1
            }
            fraction = Double("0." + digits) ?? 0
        }
        var offsetSeconds = 0
        if index < chars.count {
            let zone = String(chars[index...])
            if zone == "Z" || zone == "z" {
                offsetSeconds = 0
            } else if let sign = zone.first, sign == "+" || sign == "-" {
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
                    return nil
                }
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            } else {
                return nil
            }
        }
        guard let date = baseFormatter.date(from: base) else { return nil }
        return date.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    static func format(_ date: Date) -> String {
        outputFormatter.string(from: date)
    }

    private static let baseFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let outputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
}
