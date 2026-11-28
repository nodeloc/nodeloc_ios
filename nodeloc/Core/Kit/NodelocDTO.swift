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

/// `GET /api/v1/me/groups`: the groups you're in, and which one you wear
/// (`primary_group_id`, 0 when none) — its 头衔 shows by your name when you
/// have no personal title.
nonisolated struct NLMyGroups: Codable, Sendable {
    struct Group: Codable, Sendable, Identifiable, Equatable {
        let id: Int
        let name: String
        let label: String?
        /// The group's 头衔 in the reader's language; nil when it grants none.
        let title: String?
        let color: String?
        let icon: String?
        let primary: Bool?
    }
    let groups: [Group]
    let primaryGroupId: Int?
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
    /// One tier and the reputation it starts at.
    nonisolated struct TierStep: Codable, Sendable {
        let level: Int
        let name: String?
        let threshold: Int?
    }
    let reputation: Int?
    let pending: Int?
    let tier: Int?
    let tierName: String?
    /// The tier above; absent at 传奇. An object, not a number — decoding it
    /// as `Int` failed the whole summary.
    let next: TierStep?
    let needed: Int?
    let progress: Double?
    let week: Int?
    /// All-time settled totals per source, in a fixed order (声望来源).
    let sources: [SourceTotal]?
    /// All nine tiers with their thresholds.
    let tiers: [TierStep]?
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
    /// Every image (up to 12) and the first video of the first post, for the
    /// card (2026-11-27). Null when there are none or the body is gated.
    let cardMedia: NLCardMedia?
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

/// `card_media` on topic list items (mobile-api.md, 主题列表). Absolute URLs.
nonisolated struct NLCardMedia: Codable, Sendable, Hashable {
    nonisolated struct Image: Codable, Sendable, Hashable {
        /// The card-size thumbnail, scaled (not cropped) into 1280×1040.
        let url: String
        /// The full image, for the viewer.
        let originalUrl: String?
        /// The original's size, for uploads only; external images have none.
        let w: Int?
        let h: Int?
        /// `#rrggbb`, drawn under the image until it loads.
        let color: String?
    }
    nonisolated struct Video: Codable, Sendable, Hashable {
        /// `upload`, `youtube` or `bilibili`.
        let provider: String
        let id: String?
        /// Uploads: what a native player plays (HLS or the file); null while
        /// transcoding. YouTube / bilibili: the page.
        let url: String?
        let hlsUrl: String?
        let poster: String?
        let w: Int?
        let h: Int?
        /// Seconds.
        let duration: Double?
    }
    let images: [Image]?
    let video: Video?
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
    /// Why it is hidden, for the author and the node's managers only:
    /// `rule` (the AI found it breaks the posting rules), `spam`, `held`
    /// (waiting for review), `staff` and others. Absent for everyone else.
    let hiddenReason: String?
    /// The one-sentence reason: the AI's for `rule`, the staff member's for
    /// `staff`. Same audience; may be absent.
    let hiddenNote: String?
    /// Author only: an edit sends the post back to the AI automatically.
    let rejudge: Bool?
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
        /// What happened to the item since it was queued: the author edited
        /// the post (`author_edit`), and what the AI made of each edit
        /// (`rejudge_ok`, `rejudge_rule`, `rejudge_spam`, the reason in
        /// `note`). Oldest first.
        let history: [HistoryEvent]?
    }

    nonisolated struct HistoryEvent: Codable, Sendable, Hashable {
        let action: String
        let note: String?
        let createdAt: String?
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
        /// The user it was done to: `target_name` in the site log,
        /// `target` in a node's (moderation/handlers.go, node/manage_handlers.go).
        let targetName: String?
        let target: String?
        let details: JSONValue?
        /// Whether this reader may reverse it now — not merely whether the
        /// action is reversible in principle.
        let undoable: Bool?
        let undoneAt: String?
        /// Node log only.
        let undoneBy: String?

        /// The server sends `target_name: ""` when the target isn't a user;
        /// that is no name, not an empty one ("u/" with nothing after it).
        ///
        /// A node log's `target` is the *title* when the target is a topic or
        /// post — read as a user, a moved topic showed as "u/〖…〗".
        var targetUser: String? {
            let named = targetName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if let named { return named }
            guard targetType == nil || targetType == "user" else { return nil }
            return target.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        /// The topic's title when the target is a topic or post (node log).
        var targetTitle: String? {
            guard targetType == "topic" || targetType == "post" else { return nil }
            return target.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
    }
    let items: [Entry]
    let nextBefore: Int?

    /// Both logs answer `{"logs": [...], "next_before": …}`.
    private enum CodingKeys: String, CodingKey {
        case items = "logs"
        case nextBefore
    }
}

/// `GET /api/v1/moderation/reasons` — the picklist a manager chooses from,
/// configured in site settings. "其他" is appended server-side and is always
/// last, so this list arrives ready to show.
nonisolated struct NLModerationReasons: Codable, Sendable {
    let reasons: [NLReason]
}

/// One reason from the server's shared list (后台「理由」): the same shape
/// for `GET /api/v1/report-reasons` and `GET /api/v1/moderation/reasons`.
/// `label` and `description` are in the reader's language; a report sends
/// `key`, a moderation decision writes `value`. 「其他」(`other`) is last.
nonisolated struct NLReason: Codable, Sendable, Hashable, Identifiable {
    let key: String
    let label: String
    let description: String?
    let report: Bool?
    let moderate: Bool?
    let value: String
    let other: Bool?

    var id: String { key }
    var isOther: Bool { other == true }
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
    /// `strikes_90d`: the snake-case decoder capitalises the "d" after the digits.
    let strikes90D: Int?
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
    /// Held for review: shown once a moderator approves it.
    let held: Bool?
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
    /// Held for review: shown once a moderator approves it.
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

/// `POST /api/v1/lotteries/{id}/tickets` → the viewer's total.
nonisolated struct NLLotteryTickets: Codable, Sendable {
    let tickets: Int
}

/// `GET /api/v1/lotteries/{id}/participants`.
nonisolated struct NLLotteryParticipants: Codable, Sendable {
    let participants: [NLLottery.Holder]
    let participantCount: Int?
    let ticketCount: Int?
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

/// One entry of a post's edit history (`GET /api/v1/posts/{id}/revisions`).
///
/// Number 1 is the post as first published; the highest number is what is
/// shown now. Each revision carries the whole body rather than a patch, so
/// the client diffs neighbours itself. Everything but `number` is optional
/// so an entry the server trims (an editor who has since been deleted, a
/// revision with no reason) still decodes.
nonisolated struct NLRevision: Codable, Sendable, Identifiable, Hashable {
    nonisolated struct Editor: Codable, Sendable, Hashable {
        let id: Int?
        let username: String?
        let name: String?
        let avatar: String?
    }
    let number: Int
    let raw: String?
    let title: String?
    let editor: Editor?
    /// The reason the editor wrote when saving, if any.
    let reason: String?
    /// Saved by a moderator or staff rather than the author.
    let byModerator: Bool?
    let createdAt: String?

    var id: Int { number }
}

/// `GET /api/v1/posts/{id}/revisions` answers one entry per counted edit,
/// each carrying the body before and after it (`raw: [old, new]`, `title`
/// likewise and only on a first post), plus the original author and
/// `posted_at` (content/revisions.go `listRevisions`). This folds that into
/// whole versions the way the web does: v1 is the body before the first
/// edit, by the author; every later one keeps the server's `number`, which is
/// what `…/revisions/{n}/restore` matches on.
nonisolated struct NLRevisionList: Decodable, Sendable {
    let revisions: [NLRevision]

    private nonisolated struct Entry: Decodable {
        let number: Int
        let editor: String?
        let editorAvatar: String?
        let editorSystem: Bool?
        let byAuthor: Bool?
        let reason: String?
        let raw: [String]?
        let title: [String]?
        let createdAt: String?
    }

    private enum Keys: String, CodingKey { case revisions, author, authorAvatar, postedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let entries = try container.decodeIfPresent([Entry].self, forKey: .revisions) ?? []
        guard let first = entries.first else {
            revisions = []
            return
        }
        let author = try container.decodeIfPresent(String.self, forKey: .author)
        var out = [NLRevision(
            number: 1,
            raw: first.raw?.first,
            title: first.title?.first,
            editor: NLRevision.Editor(
                id: nil, username: author, name: nil,
                avatar: try container.decodeIfPresent(String.self, forKey: .authorAvatar)
            ),
            reason: nil,
            byModerator: false,
            createdAt: try container.decodeIfPresent(String.self, forKey: .postedAt)
        )]
        for entry in entries {
            let system = entry.editorSystem == true
            let editor = entry.editor.flatMap { $0.isEmpty ? nil : $0 }
            out.append(NLRevision(
                number: entry.number,
                raw: entry.raw?.last,
                title: entry.title?.last,
                editor: NLRevision.Editor(
                    id: nil, username: editor, name: system ? AppString("系统") : nil, avatar: entry.editorAvatar
                ),
                reason: entry.reason,
                // Neither the author nor an app or scheduled job: a manager.
                byModerator: !(entry.byAuthor ?? true) && !system,
                createdAt: entry.createdAt
            ))
        }
        revisions = out
    }
}

// MARK: - Node access, channels, drafts
//
// First written from the design; now matched to the backend (node/access.go,
// channel/handlers.go, content/handlers.go `draftJSON`).

/// `GET /api/v1/nodes/{slug}/access` — the node's access list: each entry
/// gives one group a step in this node, and `groups` is what the viewer may
/// pick from. The list only lets more people in; it never shuts anyone out.
nonisolated struct NLNodeAccess: Codable, Sendable {
    /// One row: a group (`subject`) and how far it gets — 1 能看, 2 能回帖,
    /// 3 能发主题, 4 能帮着管 (node/service.go `AccessView`…`AccessModerate`).
    nonisolated struct Entry: Codable, Sendable, Hashable {
        let subject: String
        var level: Int
    }
    nonisolated struct Group: Codable, Sendable, Identifiable, Hashable {
        let subject: String
        /// `everyone` (signed out too), `members` (signed in), `level`
        /// (a trust level and up), `moderators` or `group` (a custom group).
        let kind: String
        /// Shown for `level` and `group`; the others are named by the client.
        let name: String?
        let level: Int?
        var id: String { subject }
    }
    let entries: [Entry]?
    let groups: [Group]?
}

/// `GET /api/v1/nodes/{slug}/channels` — outside feeds a node imports as
/// topics. Only the fields the app shows or must send back on an update are
/// decoded; the update is a whole replacement (channel/handlers.go `channelBody`).
nonisolated struct NLNodeChannels: Codable, Sendable {
    nonisolated struct Channel: Codable, Sendable, Identifiable {
        nonisolated struct Item: Codable, Sendable, Hashable {
            let id: Int?
            /// `published`, `pending`, `skipped`, `failed`, …
            let status: String?
            let title: String
            let topicId: Int?
            let createdAt: String?
        }
        let id: Int
        /// `rss`, `youtube`, `telegram`, `bilibili` or `webhook`.
        let kind: String?
        let name: String?
        let feedUrl: String?
        let siteUrl: String?
        let source: String?
        let postAs: String?
        let titlePrefix: String?
        let tags: [String]?
        let dailyLimit: Int?
        let review: Bool?
        let embed: Bool?
        let enabled: Bool?
        /// `ok`, `paused` or `error`.
        let status: String?
        let pollMinutes: Int?
        let lastPolledAt: String?
        let lastSyncedAt: String?
        let pausedAt: String?
        let lastError: String?
        let lastErrorCode: String?
        let recent: [Item]?

        /// What the card shows as the channel's address.
        var displayURL: String? { siteUrl ?? feedUrl ?? source }
    }
    let channels: [Channel]
}

/// `GET /api/v1/drafts` — drafts kept on the server, so the phone and the
/// computer see the same ones. Each is keyed by where it was written
/// (`new_topic:<random>` or `topic:<id>` for a reply) and its `data` is the
/// web composer's own object, so the fields below are read out of it the way
/// the web's drafts.js does.
nonisolated struct NLDrafts: Decodable, Sendable {
    nonisolated struct Draft: Decodable, Sendable, Identifiable {
        /// The draft's key, the handle for `DELETE /api/v1/drafts/{key}`.
        let id: String
        /// `topic` or `reply`, from the key.
        let kind: String
        let title: String?
        let raw: String?
        let nodeSlug: String?
        let nodeName: String?
        /// For a reply: what it answers.
        let topicId: Int?
        let topicTitle: String?
        let replyToUsername: String?
        let updatedAt: String?
        /// `phone` or `pc` — where it was last saved.
        let device: String?
        /// Set when it is scheduled to publish.
        let scheduledAt: String?
        let imageCount: Int?
        /// When the server will delete it for inactivity.
        let expiresAt: String?
        /// For a reply to a particular floor: its number.
        let replyTo: Int?
        /// A topic draft's tags (`data.tags`: a list, or the older
        /// space-separated string — content/drafts.go `topicDraft.tags`).
        let tags: [String]
        /// Why a scheduled publish failed, when it did.
        let scheduleError: String?
        /// Another device's save that the server held back (409
        /// `draft_conflict`), waiting for the author to choose.
        let conflict: Conflict?

        nonisolated struct Conflict: Decodable, Sendable {
            let raw: String?
            let device: String?
            let savedAt: String?
        }

        private nonisolated struct Payload: Decodable {
            let title: String?
            let raw: String?
            let node: String?
            let nodeName: String?
            let topicTitle: String?
            let replyToUser: String?
            let replyTo: Int?
            let tags: [String]?

            private enum K: String, CodingKey { case title, raw, node, nodeName, topicTitle, replyToUser, replyTo, tags }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                title = try? c.decodeIfPresent(String.self, forKey: .title)
                raw = try? c.decodeIfPresent(String.self, forKey: .raw)
                node = try? c.decodeIfPresent(String.self, forKey: .node)
                nodeName = try? c.decodeIfPresent(String.self, forKey: .nodeName)
                topicTitle = try? c.decodeIfPresent(String.self, forKey: .topicTitle)
                replyToUser = try? c.decodeIfPresent(String.self, forKey: .replyToUser)
                replyTo = try? c.decodeIfPresent(Int.self, forKey: .replyTo)
                if let list = try? c.decodeIfPresent([String].self, forKey: .tags) {
                    tags = list
                } else if let text = try? c.decodeIfPresent(String.self, forKey: .tags) {
                    tags = text.split(separator: " ").map(String.init)
                } else {
                    tags = nil
                }
            }
        }
        private nonisolated struct ConflictBody: Decodable {
            let data: Payload?
            let device: String?
            let savedAt: String?
        }
        private enum Keys: String, CodingKey { case key, data, updatedAt, device, publishAt, expiresAt, scheduleError, conflict }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let key = try c.decode(String.self, forKey: .key)
            let data = try? c.decodeIfPresent(Payload.self, forKey: .data)
            id = key
            let isReply = key.hasPrefix("topic:")
            kind = isReply ? "reply" : "topic"
            topicId = isReply ? Int(key.dropFirst("topic:".count)) : nil
            title = data?.title
            raw = data?.raw
            nodeSlug = data?.node
            nodeName = data?.nodeName
            topicTitle = data?.topicTitle
            replyToUsername = data?.replyToUser
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            device = try c.decodeIfPresent(String.self, forKey: .device)
            scheduledAt = try c.decodeIfPresent(String.self, forKey: .publishAt)
            expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
            replyTo = data?.replyTo
            tags = data?.tags ?? []
            scheduleError = try? c.decodeIfPresent(String.self, forKey: .scheduleError)
            if let held = try? c.decodeIfPresent(ConflictBody.self, forKey: .conflict) {
                conflict = Conflict(raw: held.data?.raw, device: held.device, savedAt: held.savedAt)
            } else {
                conflict = nil
            }
            // Same count as the web: markdown images in the body.
            imageCount = raw.map { $0.components(separatedBy: "![").count - 1 }
        }
    }
    let drafts: [Draft]
    let limit: Int?
}

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
    /// One of the node's rules; older nodes stored bare titles, which the
    /// server folds into this shape.
    struct Rule: Codable, Sendable, Hashable {
        let title: String
        let description: String?
    }
    /// The node's rules, for 关于 (Android shows them as its 规则 panel).
    let rules: [Rule]?
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
        /// The title with the matched words in `<mark>`.
        let titleHtml: String?
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
        /// The reader owns the node (`role` is `moderator` for an owner too).
        var owner: Bool? = nil
        /// Only on a node the reader manages: what waits in its queue.
        var pending: NLManagedNodes.Node.Pending? = nil
    }
    struct Favorite: Codable, Sendable {
        let slug: String
        let name: String?
        var color: String? = nil
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

    /// Parsed by hand from the UTF-8 bytes: a `DateFormatter` here cost
    /// ~40µs a call through ICU, and every row of every list carries a few
    /// of these, all on the main thread.
    static func parse(_ raw: String) -> Date? {
        var raw = raw
        return raw.withUTF8 { Self.parse(bytes: $0) }
    }

    static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ length: Int) -> Int? {
            var value = 0
            for i in from..<(from + length) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116 || b[10] == 32, b[13] == 58, b[16] == 58,
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 46 {
            index += 1
            var scale = 0.1
            while index < b.count, b[index] >= 48, b[index] <= 57 {
                fraction += Double(b[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        if index < b.count {
            let sign = b[index]
            if sign == 90 || sign == 122 {
                index += 1
            } else if sign == 43 || sign == 45 {
                var digits: [Int] = []
                index += 1
                while index < b.count, digits.count < 4 {
                    let c = b[index]
                    if c >= 48, c <= 57 { digits.append(Int(c - 48)) } else if c != 58 { return nil }
                    index += 1
                }
                guard digits.count == 4 else { return nil }
                offsetSeconds = ((digits[0] * 10 + digits[1]) * 3600 + (digits[2] * 10 + digits[3]) * 60) * (sign == 45 ? -1 : 1)
            } else {
                return nil
            }
            guard index == b.count else { return nil }
        }
        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, written without a formatter.
    static func format(_ date: Date) -> String {
        let total = date.timeIntervalSince1970
        var millis = Int((total * 1000).rounded(.down))
        let ms = ((millis % 1000) + 1000) % 1000
        millis -= ms
        var secs = millis / 1000
        var days = secs / 86_400
        secs -= days * 86_400
        if secs < 0 { secs += 86_400; days -= 1 }
        let (y, m, d) = civilFromDays(days)
        func pad(_ v: Int, _ w: Int) -> String {
            let s = String(v)
            return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
        }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(secs / 3600, 2)):\(pad(secs % 3600 / 60, 2)):\(pad(secs % 60, 2)).\(pad(ms, 3))Z"
    }

    /// Howard Hinnant's days-from-civil (proleptic Gregorian, 1970-01-01 = 0).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

/// `GET /api/v1/me/nodes`, read for the moderation dashboard: the same
/// answer as `NLMyNodes`, plus the two fields only a node's managers get.
/// `pending` is present exactly on the nodes the reader owns or moderates
/// (web/mynodes_api.go), so it doubles as "can manage this node".
nonisolated struct NLManagedNodes: Codable, Sendable {
    nonisolated struct Node: Codable, Sendable {
        nonisolated struct Pending: Codable, Sendable {
            /// Pending reports on posts in this node (anything but `pending_post`).
            let reports: Int?
            /// Posts held for review.
            let queued: Int?
            let joinRequests: Int?
        }
        let slug: String
        let name: String?
        let color: String?
        let role: String?
        let owner: Bool?
        let pending: Pending?
    }
    let joined: [Node]
}

/// `GET /api/v1/me/permissions`.
nonisolated struct NLMyPermissions: Decodable, Sendable {
    let permissions: [String]
    let limits: [String: Int]?
}

/// The `fields` of a 422: which input the server refused and why.
nonisolated enum ServerFieldErrors {
    static func last() -> [String: String] {
        struct Envelope: Decodable {
            struct Body: Decodable { let fields: [String: String]? }
            let error: Body?
        }
        guard let data = DiscourseError.lastErrorBody,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [:] }
        return envelope.error?.fields ?? [:]
    }
}
