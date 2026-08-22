//
//  DiscourseModels.swift
//  nodeloc
//
//  Decodable DTOs for the Discourse JSON API. The client decodes with
//  `.convertFromSnakeCase`, so properties are camelCase. Most fields are
//  optional for resilience against schema differences.
//

import Foundation

// MARK: - Users

struct DiscourseUser: Decodable, Identifiable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
}

// MARK: - Topic lists (latest / search)

struct TopicPoster: Decodable {
    let userId: Int?
    let description: String?
}

struct TopicListItem: Decodable, Identifiable {
    let id: Int
    let title: String
    let slug: String?
    let postsCount: Int?
    let replyCount: Int?
    let likeCount: Int?
    let views: Int?
    let createdAt: String?
    let lastPostedAt: String?
    let bumpedAt: String?
    let categoryId: Int?
    let pinned: Bool?
    /// Per-user read state (present only when signed in), used for the new/
    /// unread dot: `unseen` is a brand-new topic; a `lastReadPostNumber` below
    /// `highestPostNumber` means there are unread posts.
    let unseen: Bool?
    let lastReadPostNumber: Int?
    let highestPostNumber: Int?
    let excerpt: String?
    let imageUrl: String?
    /// Discourse's responsive image set: the same picture at several widths
    /// (e.g. 1024/800/600/400/300/200/140 plus the original). Decoded as
    /// objects — the field is `thumbnails`, not the `topic_thumbnails` an
    /// earlier `[String]` version looked for, so it had always been nil.
    let thumbnails: [TopicThumbnail]?
    let posters: [TopicPoster]?
    let tags: [TopicTag]?
    /// First post's video, added by `discourse-community` expressly "for
    /// card-mode autoplay". Only serialized on topic *list* items — the single
    /// topic endpoint doesn't carry it.
    let topicVideoUrl: String?
}

struct TopicTag: Decodable, Hashable {
    let id: Int?
    let name: String?
    let slug: String?
}

/// One resolution in a topic's responsive image set. `width`/`height` are the
/// actual pixels of this variant; the largest entry is the original upload.
struct TopicThumbnail: Decodable {
    let maxWidth: Int?
    let maxHeight: Int?
    let width: Int?
    let height: Int?
    let url: String?
}

struct TopicList: Decodable {
    let topics: [TopicListItem]
    /// Present when more pages exist; nil on the last page.
    let moreTopicsUrl: String?
}

struct LatestResponse: Decodable {
    let users: [DiscourseUser]?
    let topicList: TopicList
}

struct SiteResponse: Decodable {
    let categories: [DiscourseCategory]?
    let popularApps: [SidebarDiscourseApp]?
    let appsBrowseUrl: String?
    /// Client-visible settings, used to mirror the plugins' own limits.
    let siteSettings: DiscourseSiteSettings?
    let trustLevels: DiscourseTrustLevels?
}

/// `site.json` serves trust levels as a **name → id dictionary**
/// (`{"newuser": 0, "basic": 1, …}`), not an array of objects. Decoding it as
/// an array threw and, because the caller uses `try?`, silently discarded the
/// whole response — including `categories`, which every post needs for its node.
struct DiscourseTrustLevels: Decodable {
    /// id → name, the direction the UI wants.
    let namesByLevel: [Int: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: Int].self)
        namesByLevel = Dictionary(
            raw.map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var isEmpty: Bool { namesByLevel.isEmpty }
}

/// The subset of `site.json`'s client settings the composer needs. All optional
/// — a site with a plugin disabled simply omits its keys.
struct DiscourseSiteSettings: Decodable {
    let pollEnabled: Bool?
    let pollMaximumOptions: Int?
    let redEnvelopeEnabled: Bool?
    let redEnvelopeMinPoints: Int?
    let redEnvelopeMinAvgPoints: Int?
    let redEnvelopeMinCount: Int?
    let redEnvelopeMaxCount: Int?
    let lotteryEnabled: Bool?
    let lotteryMinTrustLevel: Int?
    let lotteryMinTicketsPerUser: Int?
    let lotteryMaxTicketsPerUser: Int?
    let lotteryMaxDrawDays: Int?
}

/// `POST /posts` — the created post, needed for its `topicId` and, for replies,
/// its `postNumber` so the reader can scroll to it.
struct CreatePostResponse: Decodable {
    let id: Int?
    let topicId: Int?
    let postNumber: Int?
}

/// `POST /red-envelopes.json`
struct RedEnvelopeResponse: Decodable {
    let success: Bool?
    let error: String?
    let id: Int?
}

/// `POST /lottery` — returns the lottery on success, or `{success: false, error}`.
struct LotteryCreateResponse: Decodable {
    let success: Bool?
    let error: String?
    let id: Int?
}

// MARK: - Categories

struct DiscourseCategory: Decodable, Identifiable {
    let id: Int
    let name: String
    let color: String?
    let slug: String
    let topicCount: Int?
    let postCount: Int?
    let memberCount: Int?
    let descriptionExcerpt: String?
    let description: String?
    let parentCategoryId: Int?
    let isJoined: Bool?
    let isCreator: Bool?
    let uploadedLogo: DiscourseUploadAsset?
    let uploadedLogoDark: DiscourseUploadAsset?
    /// Banner image. Only present on site.json categories, not nodes.json.
    let uploadedBackground: DiscourseUploadAsset?
    let uploadedBackgroundDark: DiscourseUploadAsset?
    let url: String?
    /// Only populated when the request passes `include_subcategories=true`.
    /// On nodeloc the categories users actually post in are subcategories —
    /// the top level is 11 broad sections — so most lookups need this.
    let subcategoryList: [DiscourseCategory]?
    /// This user's notification setting for the node, as
    /// `NotificationLevels.all` integers. Only serialized for a signed-in
    /// request (`category_serializer.rb#include_notification_level?`); an
    /// anonymous fetch reports the site default rather than anything real.
    let notificationLevel: Int?
    /// Node moderators, shown in the about sheet. Present on 140 of nodeloc's
    /// 162 categories, so treat an empty list as normal.
    let moderators: [CategoryModerator]?
}

/// A node moderator as serialized on the category.
struct CategoryModerator: Decodable, Identifiable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
}

/// `/c/{path}/{id}.json` — a node's topic list.
struct CategoryTopicsResponse: Decodable {
    let topicList: TopicList?
    let users: [DiscourseUser]?
}

struct NodeMembershipResponse: Decodable {
    let success: Bool?
    let joined: Bool?
}

struct CategoryList: Decodable { let categories: [DiscourseCategory] }
struct CategoriesResponse: Decodable { let categoryList: CategoryList }

struct DiscourseUploadAsset: Decodable {
    let id: Int?
    let url: String?
}

struct SidebarCommunitiesResponse: Decodable {
    let communities: [DiscourseCategory]?
    let recommended: [DiscourseCategory]?
    let grouped: [String: SidebarGroupedNodeBucket]?
    let meta: SidebarCommunitiesMeta?
    let recommendedMeta: SidebarCommunitiesMeta?
}

struct SidebarGroupedNodeBucket: Decodable {
    let category: DiscourseCategory
    let totalCount: Int?
    let hasMore: Bool?
}

struct SidebarCommunitiesMeta: Decodable {
    let total: Int?
    let page: Int?
    let perPage: Int?
    let hasMore: Bool?
}

struct NodeSlugAvailabilityResponse: Decodable {
    let available: Bool
    let message: String?
}

struct CreateCommunityResponse: Decodable {
    let category: DiscourseCategory?
}

struct SidebarDiscourseApp: Decodable, Identifiable {
    let id: Int
    let slug: String
    let name: String
    let logoUrl: String?
    let url: String?
}

struct SidebarAppsDirectoryResponse: Decodable {
    let directoryApps: [SidebarDiscourseApp]?
    let discourseApps: [SidebarDiscourseApp]?
}

struct SidebarCustomFeed: Decodable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let description: String?
    let color: String?
    let url: String?
    let username: String?
    let nodeCount: Int?
}

struct SidebarCustomFeedsResponse: Decodable {
    let customFeeds: [SidebarCustomFeed]
}

// MARK: - Uploads

struct DiscourseUpload: Decodable, Identifiable {
    let id: Int
    let url: String?
    let originalFilename: String?
    let filesize: Int?
    let width: Int?
    let height: Int?
    let thumbnailWidth: Int?
    let thumbnailHeight: Int?
    let fileExtension: String?
    let shortUrl: String?
    let shortPath: String?

    var composerURLString: String? {
        shortUrl ?? url
    }

    var displayFilename: String {
        originalFilename ?? "媒体"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case originalFilename
        case filesize
        case width
        case height
        case thumbnailWidth
        case thumbnailHeight
        case fileExtension = "extension"
        case shortUrl
        case shortPath
    }
}

// MARK: - Account settings

/// Response of `PUT /u/:username/preferences/avatar/pick`.
struct AvatarPickResponse: Decodable {
    let success: Bool?
    let avatarTemplate: String?
}

/// A connected identity provider, owner-serialized on `GET /u/:username.json`.
struct AssociatedAccount: Decodable, Identifiable {
    let name: String          // provider, e.g. "github"
    let description: String?   // "Account: someone@example.com"

    var id: String { name }
}

/// A signed-in session, owner-serialized as `user_auth_tokens`.
struct UserAuthToken: Decodable, Identifiable {
    let id: Int
    let clientId: String?
    let deviceName: String?
    let osName: String?
    let clientName: String?
    let seenAt: String?
    let isActive: Bool?        // the token making this request
}

/// The owner-only slice of the profile we read for the account and security
/// screens. Everything is optional: the same endpoint serves other users too,
/// where these fields are absent.
struct AccountDetail: Decodable {
    let user: Payload
    struct Payload: Decodable {
        let associatedAccounts: [AssociatedAccount]?
        let userAuthTokens: [UserAuthToken]?
        let secondFactorEnabled: Bool?
    }
}

/// `POST /u/create_second_factor_totp`. `qr` is a `data:image/png;base64,…`.
struct TOTPCreateResponse: Decodable {
    let key: String?
    let qr: String?
    let error: String?
}

/// `PUT /u/second_factors_backup`.
struct BackupCodesResponse: Decodable {
    let backupCodes: [String]?
    let error: String?
}

/// `POST /u/second_factors`: what's already enabled.
struct SecondFactorsResponse: Decodable {
    let totps: [TOTPDevice]?
    let securityKeys: [SecurityKeyDevice]?

    struct TOTPDevice: Decodable, Identifiable {
        let id: Int
        let name: String?
        let lastUsed: String?
    }
    struct SecurityKeyDevice: Decodable, Identifiable {
        let id: Int
        let name: String?
    }
}

/// `GET /u/trusted-session` and `POST /u/confirm-session`.
struct SessionTrustResponse: Decodable {
    let success: String?       // "OK" / "FAILED" on some routes
    let failed: String?
    let error: String?

    var isTrusted: Bool { success == "OK" }
}

/// A group a user belongs to, with its flair. Only groups whose `flairUrl` is
/// set can be chosen as the user's 资质 (flair).
struct UserGroupFlair: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let fullName: String?
    let flairUrl: String?

    /// Prefer the human-readable full name, falling back to the slug-like name.
    var displayName: String {
        (fullName?.isEmpty == false ? fullName : nil) ?? name
    }
}

/// One entry from `GET /user-badges/:username.json`.
struct BadgeDefinition: Decodable, Identifiable {
    let id: Int
    let name: String
    let allowTitle: Bool?
    let imageUrl: String?
    let description: String?
}

struct UserBadgesResponse: Decodable {
    let badges: [BadgeDefinition]?
}

// MARK: - Topic detail

struct ActionSummary: Decodable {
    let id: Int
    let count: Int?
    /// Whether the current user has performed this action (e.g. already liked).
    let acted: Bool?
}

/// discourse-reward: one reward given to a post. Serialized in `post.rewards`.
struct PostReward: Decodable, Identifiable {
    let id: Int
    let userId: Int?
    let username: String?
    let avatarTemplate: String?
    let amount: Int
    let note: String?
    let createdAt: String?
    let isSystemReward: Bool?
}

struct TopicPost: Decodable, Identifiable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let createdAt: String?
    let cooked: String?
    let postNumber: Int?
    let replyToPostNumber: Int?
    let actionsSummary: [ActionSummary]?
    /// Edit revision. Part of the parsed-content cache key so an edited post
    /// re-parses while an unchanged one doesn't.
    let version: Int?
    /// poll plugin. Positioned in `cooked` as `<div class="poll" data-poll-name>`.
    let polls: [PostPoll]?
    /// `{poll_name: [option_digest]}` — the current user's votes.
    let pollsVotes: [String: [String]]?
    /// lottery plugin, attached to the post that created it.
    let lottery: PostLottery?
    /// discourse-red-envelope: what *this* reply won. Only serialized for
    /// `post_number > 1`, because replying is what claims the envelope.
    let redEnvelopeClaim: RedEnvelopeClaim?
    /// Nested-view (`/n/…`) only: direct replies inlined under this post (up to
    /// a few), and the total direct-reply count so the UI knows more remain.
    /// `var` so more can be appended from the children endpoint.
    var children: [TopicPost]?
    let directReplyCount: Int?
    /// All descendants under this post (what the web "N 条回复" count shows).
    let totalDescendantCount: Int?
    /// The author's worn title and flair (the badge icon shown by their name).
    let userTitle: String?
    let flairName: String?
    let flairUrl: String?
    /// discourse-reward: rewards this post has received.
    let rewards: [PostReward]?

    /// Like count lives in actions_summary with action id 2.
    var likeCount: Int { actionsSummary?.first { $0.id == 2 }?.count ?? 0 }
    /// Whether the current user has already liked this post.
    var likedByMe: Bool { actionsSummary?.first { $0.id == 2 }?.acted ?? false }
    /// Total energy this post has been rewarded (excludes system deducts, which
    /// are negative and shouldn't count as "被打赏").
    var rewardTotal: Int { (rewards ?? []).filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
}

/// `GET /n/{slug}/{id}.json?sort=` — Discourse's nested-replies view. The OP is
/// separate (`op_post`); `roots` are the top-level reply threads, each with its
/// own inlined `children`. `sort` is server-side (top / new / old).
struct NestedTopicResponse: Decodable {
    let opPost: TopicPost?
    let roots: [TopicPost]?
    let hasMoreRoots: FlexibleBool?
    let page: Int?
    let sort: String?
    let effectiveSort: String?
}

/// `GET /n/{slug}/{id}/children/{postNumber}.json` — more direct replies under
/// one post.
struct NestedChildrenResponse: Decodable {
    let children: [TopicPost]?
    let hasMore: FlexibleBool?
    let page: Int?
}

/// The nested endpoints return `has_more` / `has_more_roots` as either a JSON
/// bool or 0/1 depending on the path, so decode both.
struct FlexibleBool: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else {
            value = false
        }
    }
}

// MARK: - Poll (poll plugin)

/// Mirrors `PollSerializer`. `options[].votes` is omitted until the viewer is
/// allowed to see results, which is how `results=on_vote` hides counts.
struct PostPoll: Decodable, Identifiable, Equatable {
    let id: Int?
    let name: String?
    let type: String?
    let status: String?
    let results: String?
    let min: Int?
    let max: Int?
    let step: Int?
    let options: [PollOptionResult]?
    let voters: Int?
    let close: String?
    let chartType: String?
    let title: String?
    let `public`: Bool?

    /// `name` is what `polls_votes` and the vote endpoint key on; it defaults to
    /// "poll" for the first unnamed poll in a post.
    var pollName: String { name ?? "poll" }

    var isClosed: Bool { status == "closed" }
    var isMultiple: Bool { type == "multiple" }
    /// Ranked choice and number polls need UI this client doesn't have; they
    /// render read-only rather than pretending to accept a vote.
    var isVotable: Bool { type == "regular" || type == "multiple" }

    var totalVotes: Int {
        options?.reduce(0) { $0 + ($1.votes ?? 0) } ?? 0
    }
}

/// Named to avoid colliding with the composer's `PollOption` draft type.
/// `id` is a digest string, not a number.
struct PollOptionResult: Decodable, Identifiable, Equatable {
    let id: String
    let html: String?
    let votes: Int?
}

/// `PUT`/`DELETE /polls/vote` both return the updated poll.
struct PollVoteResponse: Decodable {
    let poll: PostPoll?
    let vote: [String]?
}

// MARK: - Lottery (lottery plugin)

/// Verified against a live nodeloc topic. `maxParticipants` comes back as
/// 1_000_000 when the creator left it unlimited.
struct PostLottery: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String?
    let userId: Int?
    let postId: Int?
    let minParticipants: Int?
    let maxParticipants: Int?
    let maxTicketsPerUser: Int?
    let minTrustLevel: Int?
    let drawAt: String?
    let status: String?
    let levels: [LotteryPrizeLevel]?
    let ticketsCount: Int?
    let participantsCount: Int?
    let userTickets: Int?
    let isParticipating: Bool?
    let canDraw: Bool?
    let canManage: Bool?
    let canClose: Bool?
    let participants: [LotteryParticipant]?
    let winners: [LotteryWinner]?

    var isOpen: Bool { status == "open" }
    /// The server stores "unlimited" as a sentinel rather than null.
    var hasParticipantCap: Bool {
        guard let maxParticipants else { return false }
        return maxParticipants > 0 && maxParticipants < 1_000_000
    }
    var totalPrizes: Int {
        levels?.reduce(0) { $0 + max(1, $1.quantity ?? 1) } ?? 0
    }
}

/// Named to avoid colliding with the composer's `LotteryLevel` draft type.
struct LotteryPrizeLevel: Decodable, Identifiable, Equatable {
    let id: Int?
    let name: String?
    let prize: String?
    let quantity: Int?
}

struct LotteryParticipant: Decodable, Equatable {
    let username: String?
    let avatarTemplate: String?
    let tickets: Int?
    let isRandom: Bool?
}

struct LotteryWinner: Decodable, Equatable {
    let username: String?
    let avatarTemplate: String?
    let levelName: String?
    let prize: String?
}

struct LotteryActionResponse: Decodable {
    let success: Bool?
    let error: String?
    let lottery: PostLottery?
}

// MARK: - Red envelope (discourse-red-envelope)

/// Topic-level, unlike polls and lotteries. There is no claim action: the
/// plugin auto-claims on `post_created`, so replying is what opens it.
struct TopicRedEnvelope: Decodable, Equatable {
    let id: Int
    let topicId: Int?
    let userId: Int?
    let totalPoints: Int?
    let totalCount: Int?
    let claimedCount: Int?
    let remainingPoints: Int?
    let availableCount: Int?
    let exhausted: Bool?
    let claimPercentage: Double?
    let createdAt: String?
}

/// What one reply received.
struct RedEnvelopeClaim: Decodable, Equatable {
    let id: Int?
    let userId: Int?
    let points: Int?
    let createdAt: String?
}

struct PostStream: Decodable {
    let posts: [TopicPost]
    let stream: [Int]?
}

struct TopicResponse: Decodable {
    let id: Int
    let title: String
    let postsCount: Int?
    let likeCount: Int?
    let views: Int?
    let categoryId: Int?
    let createdAt: String?
    let postStream: PostStream
    /// Serialized onto `topic_view`, not onto any individual post.
    let redEnvelope: TopicRedEnvelope?
}

struct TopicPostsResponse: Decodable {
    let postStream: PostStream
}

// MARK: - Search

struct SearchPost: Decodable, Identifiable {
    let id: Int
    let topicId: Int?
    let blurb: String?
    let username: String?
}

struct SearchResponse: Decodable {
    let topics: [TopicListItem]?
    let posts: [SearchPost]?
    let categories: [DiscourseCategory]?
    let users: [DiscourseUser]?
}

// MARK: - User profile

struct UserProfile: Decodable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let createdAt: String?
    let lastSeenAt: String?
    let title: String?
    let profileBackgroundUploadUrl: String?
    let cardBackgroundUploadUrl: String?
    let location: String?
    let websiteName: String?
    /// Full URL, as opposed to `websiteName` which is just the display host.
    let website: String?
    let bioRaw: String?
    /// The group whose flair (资质) shows on this user's posts, and the groups
    /// they belong to — the pool the flair can be chosen from.
    let flairGroupId: Int?
    let groups: [UserGroupFlair]?
    let bioExcerpt: String?
    let trustLevel: Int?
    let admin: Bool?
    let moderator: Bool?
    let badgeCount: Int?
    let postCount: Int?
    let topicCount: Int?
    let likesGiven: Int?
    let likesReceived: Int?
    let profileViewCount: Int?
    /// Group flair (资质): a Font Awesome icon name or an uploaded image path.
    let flairUrl: String?
    let flairName: String?
    let flairBgColor: String?
    let flairColor: String?
    /// discourse-follow counts and state.
    let totalFollowers: Int?
    let totalFollowing: Int?
    /// False when following is disabled for this user or it's your own profile.
    let canFollow: Bool?
    /// Whether the current user already follows this user.
    let isFollowed: Bool?
}

struct UserBadge: Decodable, Identifiable {
    let id: Int
    let name: String
    let badgeTypeId: Int?
}

struct UserResponse: Decodable {
    let user: UserProfile
    let badges: [UserBadge]?
}

// MARK: - User summary (u/:username/summary.json)

struct UserSummaryResponse: Decodable {
    let userSummary: UserSummary
    /// Full badge definitions referenced by `userSummary.badges`.
    let badges: [SummaryBadge]?
}

struct UserSummary: Decodable {
    let likesGiven: Int?
    let likesReceived: Int?
    let topicsEntered: Int?
    let postsReadCount: Int?
    let daysVisited: Int?
    let topicCount: Int?
    let postCount: Int?
    let timeRead: Int?
    let solvedCount: Int?
    let topCategories: [SummaryCategory]?
}

struct SummaryCategory: Decodable, Identifiable {
    let id: Int
    let name: String?
    let color: String?
    let slug: String?
    let topicCount: Int?
    let postCount: Int?
}

struct SummaryBadge: Decodable, Identifiable {
    let id: Int
    let name: String?
    let description: String?
    let grantCount: Int?
    let icon: String?
}

// MARK: - Apps (discourse-apps plugin)

/// A published app from `/apps/directory.json`.
struct DirectoryApp: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let name: String
    let description: String?
    let installsCount: Int?
    /// Scopes review granted, shown in the about sheet.
    let approvedScopes: [String]?
    /// "webview" apps can run natively; "blocks" apps cannot.
    let surface: String?
    let versionNumber: Int?
    let readmeCooked: String?
    let logoUrl: String?
    /// Topic hosting the app, e.g. "/t/topic/103048/1".
    let homeUrl: String?
    let categoryUrl: String?
    let author: DiscourseUser?

    var isWebview: Bool { surface == "webview" }

    /// Topic id parsed out of `home_url`, used to open the discussion and to
    /// resolve the app's install id.
    var hostTopicID: Int? {
        guard let homeUrl else { return nil }
        let parts = homeUrl.split(separator: "/")
        // ".../t/{slug}/{id}/{post}" — the id is the first all-digit segment
        // after "t".
        guard let tIndex = parts.firstIndex(of: "t") else { return nil }
        for part in parts[parts.index(after: tIndex)...] {
            if let value = Int(part) { return value }
        }
        return nil
    }

    static func == (lhs: DirectoryApp, rhs: DirectoryApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// `/apps/{slug}.json` wraps its payload; the list endpoint does not.
struct DirectoryAppResponse: Decodable {
    let directoryApp: DirectoryApp
}

// MARK: - Custom badge / title styles (discourse-custom-badge plugin)

struct CustomBadgeStyle: Decodable {
    let textColor: String?
    let textEffect: String?
    let glitchLeftColor: String?
    let glitchRightColor: String?
}

/// `/discourse_custom_badge/group-styles/list` — styles keyed by group name/title.
struct CustomGroupStyleItem: Decodable {
    let id: Int
    let name: String?
    let fullName: String?
    let title: String?
    let customGroupStyle: CustomBadgeStyle?
}

/// `/discourse_custom_badge/badge-styles/list` — styles for badges used as titles.
struct CustomBadgeStyleItem: Decodable {
    let id: Int
    let name: String?
    let customStyle: CustomBadgeStyle?
}

// MARK: - Points / 能量 (discourse-points-service plugin)

struct PointsHistoryResponse: Decodable {
    let pointsHistory: [PointsHistoryEntry]
    let page: Int?
    let hasMore: Bool?
}

struct PointsHistoryEntry: Decodable, Identifiable {
    let date: String?
    let points: Int?
    let description: String?
    let createdAt: String?
    let isPositive: Bool?

    var id: String { "\(createdAt ?? date ?? "")-\(points ?? 0)-\(description ?? "")" }
}

struct PointsScoresResponse: Decodable {
    let totalScores: Int?
}

// MARK: - User activity (user_actions.json)

struct UserActionsResponse: Decodable {
    let userActions: [UserActionItem]
}

struct UserActionItem: Decodable, Identifiable {
    let actionType: Int?
    let title: String?
    let excerpt: String?
    let createdAt: String?
    let avatarTemplate: String?
    let username: String?
    let name: String?
    let categoryId: Int?
    let topicId: Int?
    let postNumber: Int?
    let postId: Int?

    var id: String { "\(actionType ?? 0)-\(topicId ?? 0)-\(postNumber ?? 0)-\(postId ?? 0)" }
}

struct CurrentUser: Decodable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let recentApps: [SidebarDiscourseApp]?
    let recentPostCategoryIds: [Int]?
    let canCreateCommunity: Bool?
    /// Added by the poll plugin: staff, or a member of `poll_create_allowed_groups`.
    let canCreatePoll: Bool?
    /// Spendable balance for red envelopes (discourse-gamification).
    let gamificationScore: Int?
    /// Account preferences. Modelled by `UserPreferences`, which also carries
    /// discourse-community's `community_view_mode`.
    let userOption: UserPreferences?
    /// Unread counts for the inbox tab badge. `unreadNotifications` excludes
    /// PMs; `newPersonalMessagesNotificationsCount` is the unread-PM count.
    let unreadNotifications: Int?
    let newPersonalMessagesNotificationsCount: Int?
    /// The user's groups; those with `hasMessages` get a filter in the PM inbox.
    let groups: [CurrentUserGroup]?
}

struct CurrentUserGroup: Decodable {
    let id: Int?
    let name: String
    let hasMessages: Bool?
}

struct CurrentUserResponse: Decodable { let currentUser: CurrentUser }

// MARK: - GIF search (Klipy)

/// Klipy `/v2/search`. `mediaFormats` is keyed by format name (e.g. "gif");
/// each entry has a URL and `dims` = [width, height]. Decoded with
/// convertFromSnakeCase, so `media_formats` maps to `mediaFormats`.
struct KlipySearchResponse: Decodable {
    let results: [KlipyGif]?

    struct KlipyGif: Decodable {
        let title: String?
        let mediaFormats: [String: KlipyFormat]?
    }

    struct KlipyFormat: Decodable {
        let url: String?
        let dims: [Int]?
    }
}

// MARK: - Private messages

/// `GET /topics/private-messages/<username>.json`. Same envelope as the topic
/// lists, but the topics carry PM-only fields: read state and participants.
struct PrivateMessagesResponse: Decodable {
    let users: [DiscourseUser]?
    let topicList: PrivateMessageList

    struct PrivateMessageList: Decodable {
        let topics: [PrivateMessageTopic]
    }
}

struct PrivateMessageTopic: Decodable, Identifiable {
    let id: Int
    let title: String?
    let fancyTitle: String?
    let slug: String?
    let lastPostedAt: String?
    let bumpedAt: String?
    let excerpt: String?
    /// Unread = `lastReadPostNumber < highestPostNumber` (a nil last-read on a
    /// PM you were just added to also counts as unread).
    let highestPostNumber: Int?
    let lastReadPostNumber: Int?
    /// Everyone on the thread; the counterpart is whoever isn't the current
    /// user. Users (avatars, names) are resolved from the top-level `users`.
    let participants: [TopicPoster]?
    let posters: [TopicPoster]?
}

// MARK: - Notifications

struct NotificationData: Decodable {
    let topicTitle: String?
    let displayUsername: String?
    let username: String?
    let badgeName: String?
    // Routing hints for notifications that don't point at a topic.
    let badgeId: Int?
    let badgeSlug: String?
    let groupName: String?
    /// group_message_summary: how many messages are in the group inbox.
    let inboxCount: Int?
    let chatChannelId: Int?
    let chatMessageId: Int?
}

struct DiscourseNotification: Decodable, Identifiable {
    let id: Int
    let notificationType: Int
    let read: Bool
    let createdAt: String?
    let data: NotificationData?
    // Present on topic-based notifications (replies, mentions, likes, PMs);
    // together they build the /t/<slug>/<id>/<post> deep link the row taps.
    let topicId: Int?
    let postNumber: Int?
    let slug: String?
}

struct NotificationsResponse: Decodable {
    let notifications: [DiscourseNotification]
}

// MARK: - Chat (discourse-chat plugin)

struct ChatUser: Decodable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
}

struct ChatLastMessage: Decodable {
    let id: Int?
    let message: String?
    let cooked: String?
    let excerpt: String?
    let createdAt: String?
    let user: ChatUser?
}

struct ChatInReplyToMessage: Decodable {
    let id: Int?
    let message: String?
    let cooked: String?
    let excerpt: String?
    let user: ChatUser?
}

struct ChatThreadOriginalMessage: Decodable {
    let id: Int
    let message: String?
    let cooked: String?
    let excerpt: String?
    let createdAt: String?
    let chatChannelId: Int?
    let deletedAt: String?
    let user: ChatUser?
}

struct ChatThreadPreview: Decodable {
    let lastReplyCreatedAt: String?
    let lastReplyExcerpt: String?
    let lastReplyId: Int?
    let participantCount: Int?
    let replyCount: Int?
    let lastReplyUser: ChatUser?
    let participantUsers: [ChatUser]?
}

struct ChatThreadMembership: Decodable {
    let unreadCount: Int?
    let following: Bool?
    let lastReadMessageId: Int?
}

struct ChatThreadSummary: Decodable, Identifiable {
    let id: Int
    let title: String?
    let status: String?
    let channelId: Int?
    let replyCount: Int?
    let currentUserMembership: ChatThreadMembership?
    let preview: ChatThreadPreview?
    let lastMessageId: Int?
    let force: Bool?
    let channel: ChatChannel?
    let originalMessage: ChatThreadOriginalMessage?
}

struct ChatMessage: Decodable, Identifiable {
    let id: Int
    let message: String?
    let cooked: String?
    let excerpt: String?
    let createdAt: String?
    let deletedAt: String?
    let threadId: Int?
    let chatChannelId: Int?
    let streaming: Bool?
    let user: ChatUser?
    let inReplyTo: ChatInReplyToMessage?
    let uploads: [DiscourseUpload]?
    let thread: ChatThreadSummary?
    let threadTitle: String?
    let channel: ChatChannel?
}

struct ChatMessagesMeta: Decodable {
    let targetMessageId: Int?
    let canLoadMoreFuture: Bool?
    let canLoadMorePast: Bool?
}

struct ChatMessagesResponse: Decodable {
    let messages: [ChatMessage]
    let meta: ChatMessagesMeta?
}

struct ChatSearchMeta: Decodable {
    let hasMore: Bool?
    let limit: Int?
    let offset: Int?
}

struct ChatSearchResponse: Decodable {
    let messages: [ChatMessage]
    let meta: ChatSearchMeta?
}

struct ChatThreadsResponse: Decodable {
    let threads: [ChatThreadSummary]
}

struct ChatCreateMessageResponse: Decodable {
    let success: String?
    let messageId: Int?
}

struct ChatChannelChatable: Decodable {
    let id: Int?
    let name: String?
    let slug: String?
    let group: Bool?
    let users: [ChatUser]?
}

struct ChatTrackingState: Decodable {
    let unreadCount: Int?
    let mentionCount: Int?
    let watchedThreadsUnreadCount: Int?
    let lastReplyCreatedAt: String?

    var totalUnreadCount: Int {
        (unreadCount ?? 0) + (mentionCount ?? 0) + (watchedThreadsUnreadCount ?? 0)
    }
}

struct ChatTrackingReport: Decodable {
    let channelTracking: [String: ChatTrackingState]?

    func state(for channelID: Int) -> ChatTrackingState? {
        channelTracking?[String(channelID)]
    }
}

struct ChatChannel: Decodable, Identifiable {
    let id: Int
    let title: String?
    let unicodeTitle: String?
    let slug: String?
    let description: String?
    let chatable: ChatChannelChatable?
    let chatableType: String?
    let lastMessage: ChatLastMessage?
    let currentUserMembership: ChatMembership?

    var isDirectMessage: Bool {
        chatableType == "DirectMessage" || chatable?.users?.isEmpty == false
    }

    struct ChatMembership: Decodable {
        let unreadCount: Int?
        let lastViewedAt: String?
        let following: Bool?
        let muted: Bool?
    }
}

struct ChatChannelsResponse: Decodable {
    let channels: [ChatChannel]?
    let publicChannels: [ChatChannel]?
    let directMessageChannels: [ChatChannel]?
    let tracking: ChatTrackingReport?

    var allChannels: [ChatChannel] {
        let structuredChannels = (directMessageChannels ?? []) + (publicChannels ?? [])
        return structuredChannels.isEmpty ? (channels ?? []) : structuredChannels
    }
}
