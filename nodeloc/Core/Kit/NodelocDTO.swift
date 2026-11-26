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
    /// How many achievements are unlocked — the "n / N" on the profile and the
    /// hover card. A repeatable one counts once.
    let achievementCount: Int?
    /// Public nodes this user owns, busiest first, at most eight. `name` is
    /// already in the reader's language. Empty rather than absent when none.
    let ownedNodes: [OwnedNode]?

    nonisolated struct OwnedNode: Codable, Sendable, Identifiable {
        let slug: String
        let name: String

        var id: String { slug }
    }

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
    let unlockedCount: Int?
    let total: Int?
    /// Achievements only award reputation, so `energyEarned` is always 0 and
    /// `reputationEarned` is the one worth showing.
    let energyEarned: Int?
    let reputationEarned: Int?
}

nonisolated struct NLTiers: Codable, Sendable {
    nonisolated struct Unlock: Codable, Sendable {
        /// The row of the web's tier table this came from, e.g. `topics`.
        let key: String
        /// Plain text, already in the reader's language.
        let label: String?
        let from: String?
        let to: String?
    }
    nonisolated struct Tier: Codable, Sendable {
        let level: Int
        let name: String
        let english: String?
        let initial: String?
        let bg: String?
        let fg: String?
        let darkBg: String?
        let darkFg: String?
        /// What this tier widens over the one below (bronze is compared with
        /// signed out). Empty where a tier adds nothing.
        let unlocks: [Unlock]?
    }
    let tiers: [Tier]
}

/// `GET /api/v1/me/reputation` — the numbers behind the web's reputation page.
nonisolated struct NLReputation: Codable, Sendable {
    nonisolated struct SourceTotal: Codable, Sendable {
        /// `like`, `accept`, `featured`, `achievement` or `task`.
        let source: String
        /// May be negative: a clawback is recorded against its own source.
        let total: Int
    }
    nonisolated struct Tasks: Codable, Sendable {
        let done: Int?
        let cap: Int?
        /// False at bronze, where tasks pay energy but no reputation.
        let eligible: Bool?
    }
    let reputation: Int?
    let pending: Int?
    let tier: Int?
    let tierName: String?
    let next: Int?
    let needed: Int?
    let progress: Double?
    let week: Int?
    /// All five sources, always, in a fixed order; they sum to `week`.
    let weekBySource: [SourceTotal]?
    let tasks: Tasks?
    /// Settled change over the last 30 days, rolling.
    let rate30d: Int?
    /// Set and in the future while a penalty blocks promotion.
    let upgradeLockedUntil: String?
}

/// `GET /api/v1/points/leaderboard` — the same table as the web's /rank,
/// recomputed server-side every `refreshMinutes`. Readable signed out.
nonisolated struct NLLeaderboard: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable, Identifiable {
        let rank: Int
        let userId: Int
        let username: String
        let name: String?
        let avatarUrl: String?
        /// Null when that reader hides their tier and reputation.
        let tier: Int?
        let tierName: String?
        /// Energy on the all-time board, income over the period on the others.
        let value: Int
        /// Against this reader's first standing today; null means new today.
        let rankChange: Int?
        let me: Bool?

        var id: Int { userId }
    }
    nonisolated struct Me: Codable, Sendable {
        /// 0 when this reader isn't on the board at all.
        let rank: Int?
        let value: Int?
        /// How far behind the place above; 0 at the top.
        let gap: Int?
    }
    let period: String?
    let total: Int?
    let page: Int?
    let nextPage: Int?
    let updatedAt: String?
    let refreshMinutes: Int?
    let users: [Entry]
    /// Only present for a signed-in reader.
    let me: Me?
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
    /// Pending reports across every post in the topic, and the newest review
    /// item. Only sent to a reader who can manage the node — absent, not
    /// zero, for everyone else — and never on the personal feed.
    let reportCount: Int?
    let reviewItemId: Int?
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
    /// Pending reports against this post and the review item they belong to.
    /// Managers of the node only.
    let reportCount: Int?
    let reviewItemId: Int?
    /// Only `GET /topics/{id}` sends these.
    let canEdit: Bool?
    let canDelete: Bool?
    let createdAt: String?
    // /thread only
    let depth: Int?
    let replies: Int?

    var score: Int { (upvotes ?? 0) - (downvotes ?? 0) }
}

/// `GET /api/v1/me/restrictions` — every penalty currently on this account,
/// one row each, with whatever appeal has been made against it.
nonisolated struct NLRestrictions: Codable, Sendable {
    nonisolated struct Appeal: Codable, Sendable {
        let id: Int?
        /// `pending`, `accepted` or `rejected` — an ignored appeal counts as
        /// rejected.
        let status: String?
        /// `wrong` or `will_improve`.
        let kind: String?
        let text: String?
        /// What the handler wrote back.
        let note: String?
        let createdAt: String?
        let resolvedAt: String?
    }
    nonisolated struct Node: Codable, Sendable {
        let slug: String
        let name: String?
    }
    nonisolated struct Restriction: Codable, Sendable, Identifiable {
        /// `penalty` (site-wide, by a person), `legacy` (carried over from the
        /// old site), `risk` (the current automatic one) or `node`.
        let kind: String
        /// The penalty's own id, which the appeal path needs. Named apart from
        /// `id` because ids repeat between kinds, so row identity has to be
        /// the pair — see `id` below.
        let penaltyID: Int
        /// `silence`/`suspend` site-wide, `mute`/`ban` in a node, or one of
        /// risk control's levels.
        let type: String?
        let reason: String?
        let startedAt: String?
        /// Null means it doesn't lapse on its own.
        let endsAt: String?
        /// `staff`, `risk`, `node_owner` or `node_moderator` — never a name.
        let by: String?
        /// Only on a node restriction.
        let node: Node?
        /// Energy risk control clawed back, on a `reset`.
        let clawed: Int?
        let appeal: Appeal?
        /// The server's own answer to "may this be appealed now"; the only
        /// thing worth gating the button on.
        let canAppeal: Bool?

        /// Ids repeat between kinds, so identity has to carry both.
        var id: String { "\(kind)-\(penaltyID)" }

        /// The payload spells it `id`, so the renamed property needs a key of
        /// its own. The rest stay as written: `convertFromSnakeCase` has
        /// already camel-cased the incoming keys by the time these are
        /// matched, so these raw values are camelCase, not snake_case.
        enum CodingKeys: String, CodingKey {
            case kind
            case penaltyID = "id"
            case type, reason, by, node, clawed, appeal
            case startedAt
            case endsAt
            case canAppeal
        }
    }
    let restrictions: [Restriction]
}

/// The review queue, site-wide (`/api/v1/admin/review`) or inside one node
/// (`/api/v1/nodes/{slug}/review`). The two answer the same shape; a node's
/// counts only cover that node.
nonisolated struct NLReviewQueue: Codable, Sendable {
    nonisolated struct Report: Codable, Sendable {
        let reporter: String?
        let reason: String?
        /// The reason already written out in the reader's language.
        let reasonLabel: String?
        let note: String?
        let createdAt: String?
    }

    /// Who the item is about. Inside a node's queue the three counts only
    /// cover that node, which is how a node's managers see them without
    /// needing site-wide user permissions.
    nonisolated struct Author: Codable, Sendable {
        let id: Int
        let avatar: String?
        let createdAt: String?
        let trustLevel: Int?
        let tierName: String?
        let posts: Int?
        /// Topics and replies somebody else removed; self-deletions don't
        /// count.
        let deletedPosts: Int?
        /// Review items raised against them.
        let timesReported: Int?
    }

    nonisolated struct Item: Codable, Sendable, Identifiable {
        let id: Int
        /// `pending_post`, `content_appeal`, `penalty_appeal`,
        /// `node_restriction_appeal`, `risk_flag`, a report, …
        let kind: String
        let status: String?
        let score: Double?
        let targetType: String?
        let targetId: Int?
        let targetUsername: String?
        let targetUserId: Int?
        let nodeSlug: String?
        let nodeName: String?
        let reportCount: Int?
        /// Somebody whose reports are handled first raised this one.
        let priority: Bool?
        /// Shape depends on `kind` — see the spec's per-kind tables — so it
        /// stays loose and each kind reads what it needs.
        let payload: JSONValue?
        let topicId: Int?
        let topicTitle: String?
        let postNumber: Int?
        let postHtml: String?
        let reports: [Report]?
        let resolution: String?
        let resolvedBy: String?
        let resolvedAt: String?
        let createdAt: String?
        /// Whether the post is already deleted or hidden — worth knowing
        /// before reopening a settled item.
        let postDeleted: Bool?
        let postHidden: Bool?
        /// True when this appeals the reader's *own* penalty: handling it is
        /// 403 for everyone but a site administrator.
        let ownAction: Bool?
        let author: Author?
    }

    let items: [Item]
    let nextBefore: Int?
    /// Items per status, and — within the current status — per kind.
    let counts: [String: Int]?
    let kindCounts: [String: Int]?
    /// The most reputation this reader may take in one go: 1000 with the
    /// site-wide review permission, 20 for someone who is only a node's owner
    /// or moderator. Anything above is 422.
    let reputationPenaltyMax: Int?
}

/// The moderation audit trail — `/api/v1/admin/audit-logs` site-wide, or a
/// node's `/mod-log`. Each entry says whether *this* reader can reverse it,
/// which depends on both the action and who performed it.
nonisolated struct NLModerationLog: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable, Identifiable {
        let id: Int
        /// e.g. `post.delete`, `user.silence`, `topic.pin`, `review.*`.
        let action: String
        let actor: String?
        let createdAt: String?
        /// What it was done to: `post`, `topic`, `review_item`, `user` or
        /// `node`. Older post-level entries only recorded the topic.
        let targetType: String?
        let targetId: Int?
        let details: JSONValue?
        /// Whether this reader may reverse it now — not merely whether the
        /// action is reversible in principle.
        let undoable: Bool?
        let undoneAt: String?
        /// Node log only.
        let undoneBy: String?
    }
    let items: [Entry]
    let nextBefore: Int?
}

/// `GET /api/v1/moderation/reasons` — the picklist a manager chooses from,
/// configured in site settings. "其他" is appended server-side and is always
/// last, so this list arrives ready to show.
nonisolated struct NLModerationReasons: Codable, Sendable {
    let reasons: [String]
}

nonisolated struct NLAppealEnvelope: Codable, Sendable {
    let appeal: NLRestrictions.Appeal
}

/// What `POST /api/v1/appeals` answers for a deleted or hidden post.
nonisolated struct NLContentAppeal: Codable, Sendable {
    nonisolated struct Appeal: Codable, Sendable {
        let itemId: Int?
        let status: String?
    }
    let appeal: Appeal
}

/// What a moderator did to a topic's first post, and what it cost. Present on
/// `GET /api/v1/topics/{id}` only when the first post was hidden or deleted by
/// a manager and there is a record of it.
///
/// Three audiences see three slices of the same object, which is why so much
/// of it is optional: the before/after reputation goes to the author and to
/// anyone who can manage the node, `canAppeal` only to the author, and
/// `reviewItemId` only to a manager. Everyone else gets the public part — the
/// reason, who did it, and the penalty — the way the design has it.
nonisolated struct NLRemoval: Codable, Sendable {
    /// `hide`, `post` or `topic`.
    let kind: String?
    let reason: String?
    /// Display name of whoever did it; `byStaff` marks a site-wide manager
    /// rather than one of the node's.
    let by: String?
    let byStaff: Bool?
    let at: String?
    /// Reputation actually taken — capped at the author's balance, so it can
    /// be less than the moderator chose.
    let reputationPenalty: Int?
    let refunded: Bool?
    /// How many times a manager has acted on this author in 90 days, this one
    /// included.
    let strikes90d: Int?
    let appealable: Bool?
    let appealed: Bool?
    /// Seven days after the action; past it the appeal endpoint answers 409.
    let appealDeadline: String?
    let reputationBefore: Int?
    let reputationAfter: Int?
    /// Author only.
    let canAppeal: Bool?
    /// Managers only — what `refund-reputation` and undo act on.
    let reviewItemId: Int?
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
        /// Set when a manager hid or deleted the first post.
        let removal: NLRemoval?
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
    /// Signed-in readers who looked at this node in the last fifteen minutes,
    /// counted once each; guests don't count. Asking for this endpoint while
    /// signed in is itself what records the visit, which is how someone who
    /// only ever uses the app gets counted at all.
    let onlineCount: Int?
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
