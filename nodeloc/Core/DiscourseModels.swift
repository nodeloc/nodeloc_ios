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
    /// Discourse's cooked title, and the *only* field content localization
    /// translates in a topic list — `title` and `excerpt` come back in the
    /// original language whatever `Accept-Language` asks for. Verified against
    /// the live site: 22 of 30 topics returned a different `fancy_title` for
    /// `en` while `title` never changed.
    ///
    /// Cooked, so it carries HTML entities and `:shortcode:` emoji rather than
    /// characters — see `DiscourseFormat.localizedTitle`.
    let fancyTitle: String?
    /// Whether `fancyTitle` actually *is* a translation. False means it is just
    /// the cooked original, and `title` is the nicer source (real emoji, no
    /// escaping).
    let fancyTitleLocalized: Bool?
    let slug: String?
    let postsCount: Int?
    /// Discourse's count of posts that reply to *another post* — not the number
    /// of replies in the topic. Kept for completeness; anything showing a reply
    /// count wants `postsCount - 1`.
    let replyCount: Int?
    /// Likes across the *whole topic*, not the first post's. Verified on
    /// t/105869: topic 3, first post 2.
    let likeCount: Int?
    /// The first post's own likes — a nodeloc addition to the list serializer,
    /// alongside `topic_video_url`.
    let opLikeCount: Int?
    /// Whether the current user has liked the first post. Null anonymously.
    let liked: Bool?
    /// discourse-vote, batch-loaded for a whole page. A row votes on the
    /// *first post*, so these describe that post. `opVoteScore` present is the
    /// signal that the control belongs on this row: the plugin only serializes
    /// them when its preloader ran and voting applies to the category, so a
    /// list built another way shows no control rather than likes masquerading
    /// as a score.
    let opPostId: Int?
    let opVoteScore: Int?
    let opVoteDirection: VoteDirection?
    let opCanVoteDown: Bool?
    /// This user's notification level for the topic (`NotificationLevels.all`),
    /// and whether they've bookmarked it. Serialized only for a signed-in
    /// request, so absence means "not watching" / "not bookmarked".
    let notificationLevel: Int?
    let bookmarked: Bool?
    let views: Int?
    let createdAt: String?
    let lastPostedAt: String?
    let bumpedAt: String?
    let categoryId: Int?
    /// `PinnedCheck.pinned?`: featured *and* not cleared by this user. Discourse
    /// lets a reader dismiss a pin for themselves, and this field is what says
    /// so, which is why the row badge follows it rather than `pinned_at`.
    let pinned: Bool?
    /// True when the topic is pinned but this reader cleared it; nil when the
    /// topic isn't pinned at all.
    let unpinned: Bool?
    /// A global pin sits above every list; a plain pin only tops its own node.
    let pinnedGlobally: Bool?
    /// `regular`, `banner`, `private_message` — banner being the third way a
    /// topic gets featured.
    let archetype: String?
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
    /// Social sign-in options the site has enabled, in its own order.
    let authProviders: [DiscourseAuthProvider]?
    /// discourse-vote. The faces each direction offers — `excluded_from_like`
    /// reactions downward, the rest upward — which the client can't derive:
    /// `discourse_reactions_excluded_from_like` isn't sent to it.
    let voteUpvoteReactions: [String]?
    let voteDownvoteReactions: [String]?
    let voteCollapseScoreThreshold: Int?
    /// Flag definitions, served to everyone. Two lists, because a topic and a
    /// post don't offer the same set.
    let postActionTypes: [FlagType]?
    let topicFlagTypes: [FlagType]?
    /// Custom profile fields the admin defined. Signup has to submit the ones
    /// required at registration or the server rejects it — see
    /// `DiscourseUserField`.
    let userFields: [DiscourseUserField]?
}

/// A custom user field, as the admin configured it.
///
/// Read from `site.json` rather than hardcoded, because these are *site*
/// configuration: nodeloc added a required "Gender" dropdown after the app
/// shipped, and every signup then failed on a field the app had never heard
/// of. Anything the server marks required at registration is collected and
/// submitted, whatever it turns out to be.
struct DiscourseUserField: Decodable, Identifiable {
    let id: Int
    let name: String?
    let description: String?
    /// `text`, `confirm`, `dropdown` or `multiselect`.
    let fieldType: String?
    let required: Bool?
    /// `on_signup`, `for_all_users`, or absent when optional. The distinction
    /// matters: `for_all_users` also nags existing users, but only `on_signup`
    /// and `for_all_users` block registration.
    let requirement: String?
    let showOnSignup: Bool?
    /// Present for `dropdown` and `multiselect`. The server validates the
    /// submitted value against these exactly, so they must not be translated.
    let options: [String]?
    let position: Int?

    /// Must be filled in to register. A field can be required without being
    /// shown on the signup form, in which case registration would fail with no
    /// way for the reader to fix it — so treat "required" as reason enough to
    /// ask.
    var isRequiredAtSignup: Bool {
        requirement == "on_signup" || requirement == "for_all_users" || required == true
    }

    var isDropdown: Bool { fieldType == "dropdown" }
    var isConfirm: Bool { fieldType == "confirm" }

    /// What Discourse expects in the signup form body.
    var formKey: String { "user_fields[\(id)]" }
}

/// One entry of `site.json`'s `auth_providers` — a provider Discourse will
/// run the OAuth round-trip for at `/auth/<name>`.
struct DiscourseAuthProvider: Decodable {
    let name: String
    let customUrl: String?
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
    /// How the site draws this node's badge: `square` (a colour chip), `icon`
    /// (a Font Awesome / Lucide glyph named by `icon`) or `emoji`. Only 82 of
    /// nodeloc's 176 categories have an uploaded logo — the rest rely on this,
    /// which is why a logo-only avatar fell back to an initial so often.
    let styleType: String?
    let icon: String?
    let emoji: String?
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

/// One custom feed, as discourse-community serializes it.
///
/// The same object comes back from every custom-feed endpoint — the drawer's
/// list, a user's public feeds, and the feed's own page — with more fields
/// filled in the deeper you go. So there is one model rather than one per
/// endpoint, and everything the drawer doesn't need is optional.
struct CustomFeed: Decodable, Identifiable {
    let id: Int
    let name: String
    let slug: String
    let description: String?
    let color: String?
    /// The web route, `/f/<username>/<slug>`. `LinkRouter` sends it to the
    /// native page instead.
    let url: String?
    let username: String?
    let nodeCount: Int?
    let canEdit: Bool?
    /// Only its owner can see a private feed, and a private one can't also be
    /// shown on a profile.
    let isPrivate: Bool?
    let showOnProfile: Bool?
    let creator: CustomFeedCreator?
    /// The nodes gathered into the feed. Only the single-feed endpoint carries
    /// these, and it serializes them as ordinary categories — same `id`,
    /// `slug`, `color`, `uploaded_logo`, `topic_count`, `is_joined` — so they
    /// reuse `DiscourseCategory` and go through `NodeSummaryFactory` like every
    /// other node in the app. (Their `description` is HTML.)
    let nodes: [DiscourseCategory]?

    enum CodingKeys: String, CodingKey {
        // `convertFromSnakeCase` has already camel-cased the incoming keys by
        // the time they are matched here, so these raw values are camelCase.
        // `private` is the exception — no underscore to convert, so it arrives
        // verbatim, and it can't be a property name in Swift.
        case id, name, slug, description, color, url, username, creator, nodes
        case nodeCount, canEdit, showOnProfile
        case isPrivate = "private"
    }
}

struct CustomFeedCreator: Decodable {
    let id: Int?
    let username: String?
    let name: String?
    let avatarTemplate: String?
}

struct CustomFeedsResponse: Decodable {
    let customFeeds: [CustomFeed]
}

struct CustomFeedResponse: Decodable {
    let customFeed: CustomFeed
}

/// `/custom-feeds/node-search?term=` — candidates to add to a feed, serialized
/// the same way as a feed's own nodes.
struct CustomFeedNodeSearchResponse: Decodable {
    let nodes: [DiscourseCategory]?
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
        originalFilename ?? AppString("媒体")
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

/// One of discourse-reactions' faces, as it appears on a post.
struct PostReaction: Decodable {
    let id: String?
    let type: String?
    let count: Int?
}

/// `GET /discourse-reactions/posts/{id}/reactions-users.json` — who reacted, in
/// one response covering every face, so the detail sheet's tabs need no further
/// requests.
struct ReactionUsersResponse: Decodable {
    let reactionUsers: [ReactionGroup]?

    struct ReactionGroup: Decodable, Identifiable {
        let id: String
        let count: Int?
        let users: [ReactionUser]?
    }

    struct ReactionUser: Decodable {
        let username: String
        let name: String?
        let avatarTemplate: String?
        let canUndo: Bool?
    }
}

/// Whether a post's markdown carries anything the app's rich-text editor cannot
/// represent — and therefore has to be edited as source.
///
/// The rich editor knows inline emphasis, links and images. Everything else
/// arrives as literal text: it survives a round trip untouched (nothing here
/// escapes), but it reads as syntax on screen, and using the B/I buttons on it
/// produces nonsense like `**## 标题**`. Discourse's own mobile composer is a
/// markdown textarea for exactly this reason.
enum MarkdownSource {
    /// Ordered roughly by how common each is in a desktop-written post.
    private static let patterns: [String] = [
        #"(?m)^\s{0,3}#{1,6}\s"#,          // ATX heading
        #"(?m)^\s{0,3}>\s"#,               // blockquote
        #"(?m)^\s{0,3}(```|~~~)"#,         // fenced code
        #"(?m)^\s{0,3}\|.*\|"#,            // table row
        #"(?m)^\s{0,3}(\*|-|_){3,}\s*$"#,  // thematic break
        #"(?m)^\s{0,3}\d+\.\s"#,           // ordered list
        #"(?m)^\s{0,3}[-*+]\s"#,           // bullet list
        #"\[/?(poll|wrap|quote|grid|details|spoiler|chat)"#, // BBCode-ish plugin markup
        #"<(details|summary|div|img|a|table|iframe|kbd|br)\b"#, // raw HTML
        #"!\[[^\]]*\]\(upload://"#,        // an upload the editor can't re-resolve
        #"(?m)^\s{0,3}\[\^[^\]]+\]:"#,     // footnote definition
    ]
    // No pattern for `$…$` maths on purpose: on a forum full of "$5 到 $10" it
    // would fire on half the posts, and unrecognised maths round-trips fine as
    // literal text anyway.

    /// True when the body should be edited as source rather than as rich text.
    static func needsSourceEditing(_ raw: String) -> Bool {
        patterns.contains { raw.range(of: $0, options: .regularExpression) != nil }
    }
}

/// A member's standing vote — discourse-vote's three states, sent and received
/// verbatim. Absolute, never a toggle: the request says where to end up, so a
/// double tap or a replayed call can't drift from the server.
enum VoteDirection: String, Codable, Identifiable {
    case up
    case down
    case none

    var id: String { rawValue }

    /// Tapping the way you already voted takes the vote back, as on Reddit.
    func next(_ target: VoteDirection) -> VoteDirection {
        self == target ? .none : target
    }
}

struct TopicPost: Decodable, Identifiable {
    let id: Int
    /// Optional because the nested view *omits it entirely* for a deleted reply
    /// seen by a non-staff viewer: `PostTreeSerializer` slices that post's JSON
    /// down to eight keys (id, post_number, reply_to_post_number,
    /// deleted_post_placeholder, cooked, raw, actions_summary and the two
    /// counts). Declared non-optional, one deleted reply anywhere in a topic
    /// failed the whole `roots` decode and the reader showed no replies at all.
    let username: String?
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
    /// discourse-vote. A vote is now a *reaction*, so the server reports the
    /// direction rather than the app inferring it: an upvote still creates a
    /// core like, but a downvote is a reaction excluded from likes and leaves
    /// `likedByMe` false. Score is `like_count - downvotes + 1` — a post starts
    /// at one for its author's own implicit vote, Reddit-style — so the client
    /// displays it and never recomputes it. Absent unless voting applies to the
    /// category, which is what says whether to draw the control.
    let voteScore: Int?
    let voteDirection: VoteDirection?
    let canVoteDown: Bool?
    /// discourse-reactions: which face this member used, if any, and the tally
    /// per face for the summary beside the actions.
    let currentUserReaction: PostReaction?
    let reactions: [PostReaction]?
    let reactionUsersCount: Int?

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
    /// The viewer's own permissions on this post, decided server-side. A
    /// category moderator gets `canEdit`/`canDelete` on posts in their node and
    /// not elsewhere, so reading these is what keeps a node moderator's reach
    /// inside their node without the app modelling any of it.
    let canEdit: Bool?
    let canDelete: Bool?
    let canRecover: Bool?
    let canViewEditHistory: Bool?
    /// True when the current user wrote it.
    let yours: Bool?
    /// Set once a post is deleted but still recoverable by staff.
    let deletedAt: String?
    /// Nested view: this reply is deleted. Staff still get the whole post
    /// alongside the flag; everyone else gets the stub described above. Either
    /// way the row has to stay, because its children are still there.
    let deletedPostPlaceholder: Bool?
    /// Nested view: written by someone this viewer ignores. Keys are intact but
    /// `cooked` is blanked.
    let ignoredPostPlaceholder: Bool?

    /// discourse-mobile 小尾巴: the device string the author's app reported when
    /// the post was written, already reduced to the disclosure level they
    /// chose. Absent unless they chose to show one — and pure decoration: any
    /// client can claim any hardware, so nothing may give it weight.
    let mobileSource: String?

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
    /// Replies the topic has pinned. Membership *is* the flag — there is no
    /// per-post `pinned` field — and the server already returns a pinned root
    /// first in `roots`.
    let pinnedPostIds: [Int]?
}

/// What `PUT /n/{slug}/{id}/pin.json` answers: the topic's pinned replies after
/// the toggle.
struct PinnedPostsResponse: Decodable {
    let pinnedPostIds: [Int]?
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
/// One reply's red-envelope award. The plugin serializes the amount as
/// `points_received` — an earlier `points` spelling never decoded, so the
/// claim badge never appeared on replies.
struct RedEnvelopeClaim: Decodable, Equatable {
    let id: Int?
    let redEnvelopeId: Int?
    let userId: Int?
    let postId: Int?
    let pointsReceived: Int?
    let createdAt: String?
}

struct PostStream: Decodable {
    let posts: [TopicPost]
    let stream: [Int]?
}

struct TopicResponse: Decodable {
    let id: Int
    let title: String
    /// The translated title when content localization has one — same story as
    /// `TopicListItem.fancyTitle`: `title` is never localized, only this is.
    let fancyTitle: String?
    let fancyTitleLocalized: Bool?
    /// The topic's own slug, for building the canonical `/t/{slug}/{id}` URL.
    let slug: String?
    let postsCount: Int?
    let likeCount: Int?
    let views: Int?
    let categoryId: Int?
    let createdAt: String?
    let postStream: PostStream
    /// Serialized onto `topic_view`, not onto any individual post.
    let redEnvelope: TopicRedEnvelope?
    let closed: Bool?
    let archived: Bool?
    /// Pinned *for this reader* — false once they clear it, even though the
    /// topic is still featured. Staff actions must read `pinnedAt` instead.
    let pinned: Bool?
    let unpinned: Bool?
    /// When the pin was placed; nil means the topic isn't featured at all. This
    /// is the field the web's 置顶 modal branches on.
    let pinnedAt: String?
    /// Auto-unpin deadline, scheduled server-side as an `unpin_topic` job.
    let pinnedUntil: String?
    let pinnedGlobally: Bool?
    let archetype: String?
    let details: TopicDetails?
}

/// `GET /topics/feature_stats.json` — how many topics already occupy each
/// featured slot, so the 置顶 sheet can warn before a fourth global pin buries
/// the others.
struct TopicFeatureStats: Decodable {
    let pinnedGloballyCount: Int?
    let bannerCount: Int?
    /// Only returned when a `category_id` was passed.
    let pinnedInCategoryCount: Int?
}

/// The viewer's own permissions on a topic.
///
/// Discourse only serializes each `can_*` when it is true *for this viewer*, so
/// absence means "not allowed" — and that is what makes a node moderator work
/// without the app knowing anything about categories: they get these flags on
/// their own node's topics and nothing on anyone else's.
struct TopicDetails: Decodable {
    let canEdit: Bool?
    let canDelete: Bool?
    let canRecover: Bool?
    let canModerate: Bool?
    let canCloseTopic: Bool?
    /// Category pin/unpin. Aliased server-side to
    /// `can_perform_action_available_to_group_moderators?`, so a node moderator
    /// has it on their own node. A *global* pin additionally needs staff, which
    /// no flag reports — the web reads `currentUser.canManageTopic` for that.
    let canPinUnpinTopic: Bool?
    /// Banner topics are staff-only and never on a read-restricted node.
    let canBannerTopic: Bool?
    let canArchiveTopic: Bool?
    let canSplitMergeTopic: Bool?
}

/// `GET /posts/{id}.json` — the markdown behind a cooked post, which is what an
/// editor has to start from.
struct PostRawResponse: Decodable {
    let id: Int
    let raw: String?
    let topicId: Int?
    let postNumber: Int?
    let canEdit: Bool?
}

/// One emoji from `GET /emojis.json`.
///
/// Both kinds arrive from the same endpoint: the standard set as
/// `/images/emoji/unicode/<name>.png`, and the site's custom ones as uploads,
/// grouped under whatever the admin named the group ("ac", "simsimi" here).
/// `tonable` is only present on the standard set.
/// `Codable`, not just `Decodable`: the catalogue is written back out to disk
/// (`EmojiDiskCache`). Safe to encode because every property maps straight to a
/// key — there is no custom `init(from:)` for an `encode(to:)` to contradict.
struct DiscourseEmoji: Codable, Identifiable, Hashable {
    let name: String
    let url: String?
    let group: String?
    let tonable: Bool?
    /// Set on custom emoji only.
    let createdBy: String?
    /// Extra terms the web's picker matches on.
    let searchAliases: [String]?

    var id: String { name }
    /// What goes in the message: Discourse cooks `:name:` into the image.
    var shortcode: String { ":\(name):" }
}

/// One entry of `site.json`'s `post_action_types` / `topic_flag_types`: the
/// flags this site offers, admin-editable and including custom ones (nodeloc
/// adds 推广信息 and 谣言信息), which is why they are read rather than hardcoded.
struct FlagType: Decodable, Identifiable, Equatable {
    /// `notify_moderators` — "something else", the flag Discourse routes to
    /// the staff inbox as a message rather than scoring it as spam or abuse.
    /// Fixed in core's `PostActionType`, so it is safe to name here; blocking
    /// an author sends it so moderators hear about the content (guideline 1.2).
    static let notifyModeratorsTypeID = 7

    let id: Int
    let nameKey: String?
    /// Display name. `notify_user`'s carries a `%{username}` placeholder.
    let name: String?
    let isFlag: Bool?
    /// True for the flags that only mean something with an explanation
    /// (notify_user, notify_moderators, illegal, and any custom flag set that
    /// way). The server rejects an empty message for these.
    let requireMessage: Bool?
    let description: String?
    let shortDescription: String?
    let enabled: Bool?
    /// "Post", "Topic", "Chat::Message".
    let appliesTo: [String]?

    /// Illegal-content flags need an extra confirmation in the web modal, and
    /// the same here.
    var isIllegal: Bool { nameKey == "illegal" }
    /// A private message to the author rather than a report to staff.
    var isNotifyUser: Bool { nameKey == "notify_user" }
}

/// `GET /anyvideo/videos/by_sha1/{sha1}.json` — discourse-anyvideo's record for
/// one upload. `hls_url` is served only once `status` is `ready`.
///
/// Asking for an upload the plugin hasn't seen creates the record and queues a
/// transcode, which is what the web client does too.
struct AnyVideoResponse: Decodable {
    let id: Int?
    let status: String?
    let thumbnailUrl: String?
    let durationSeconds: Int?
    let width: Int?
    let height: Int?
    let hlsUrl: String?

    var isReady: Bool { status == "ready" }
}

/// `GET /anyvideo/videos/suggestions.json` — discourse-anyvideo's own random
/// pick of topics whose *first post* holds a ready-transcoded video. Anonymous
/// callers are allowed (`ensure_logged_in` skips this action). Topic metadata
/// only: the playable URL lives in the post's cooked HTML.
struct VideoSuggestionsResponse: Decodable {
    struct Topic: Decodable, Identifiable {
        let id: Int
        let slug: String?
        let title: String?
        let fancyTitle: String?
        let imageUrl: String?
        let categoryName: String?
        let postsCount: Int?
        let replyCount: Int?
    }

    let topics: [Topic]?
}

/// `GET /posts/{id}/cooked.json`
struct PostCookedResponse: Decodable {
    let cooked: String?
}

struct TopicPostsResponse: Decodable {
    let postStream: PostStream
}

// MARK: - Search

/// A search hit. This — not the paired topic — is where the excerpt and the
/// author live: search topics carry no `excerpt`, `image_url` or posters.
struct SearchPost: Decodable, Identifiable {
    let id: Int
    let topicId: Int?
    let blurb: String?
    let username: String?
    let name: String?
    let avatarTemplate: String?
    let likeCount: Int?
    let createdAt: String?
    let postNumber: Int?
}

/// `POST /checkin` — discourse-checkin. `success: false` with a message is a
/// normal refusal (already signed in today), not an error.
struct CheckinResponse: Decodable {
    let success: Bool?
    let points: Int?
    /// The server's idea of today, in the user's timezone.
    let userDate: String?
    let message: String?
}

/// `/u/{username}/upgrade-progress.json` — discourse-upgrade-process.
///
/// Conditions arrive either pre-merged in `conditions` or split across
/// `met_conditions`/`unmet_conditions`, so readers should use `allConditions`.
struct UpgradeProgressReport: Decodable {
    let currentLevelName: String?
    let nextLevelName: String?
    let metCount: Int?
    let totalConditions: Int?
    let conditions: [UpgradeCondition]?
    let metConditions: [UpgradeCondition]?
    let unmetConditions: [UpgradeCondition]?
    /// True once at the top level: the panel then reports upkeep, not progress.
    let retention: Bool?
    let maxLevelReached: Bool?
    let evaluationPeriod: Int?
    let trustLevelLocked: Bool?

    private enum CodingKeys: String, CodingKey {
        case currentLevelName, nextLevelName, metCount, totalConditions
        case conditions, metConditions, unmetConditions
        case retention, maxLevelReached, evaluationPeriod, trustLevelLocked
    }

    /// Field-by-field and forgiving: this is a third-party plugin payload, and
    /// a single unexpected type (a count as a string, a flag as 0/1) must not
    /// discard the whole report — callers use `try?` and would see only nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentLevelName = try? container.decodeIfPresent(String.self, forKey: .currentLevelName)
        nextLevelName = try? container.decodeIfPresent(String.self, forKey: .nextLevelName)
        metCount = Self.int(container, .metCount)
        totalConditions = Self.int(container, .totalConditions)
        conditions = try? container.decodeIfPresent([UpgradeCondition].self, forKey: .conditions)
        metConditions = try? container.decodeIfPresent([UpgradeCondition].self, forKey: .metConditions)
        unmetConditions = try? container.decodeIfPresent([UpgradeCondition].self, forKey: .unmetConditions)
        retention = Self.bool(container, .retention)
        maxLevelReached = Self.bool(container, .maxLevelReached)
        evaluationPeriod = Self.int(container, .evaluationPeriod)
        trustLevelLocked = Self.bool(container, .trustLevelLocked)
    }

    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func bool(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return ["true", "t", "1", "yes"].contains(value.lowercased())
        }
        return nil
    }

    var allConditions: [UpgradeCondition] {
        if let conditions, !conditions.isEmpty { return conditions }
        return (unmetConditions ?? []).map { $0.marked(false) }
            + (metConditions ?? []).map { $0.marked(true) }
    }

    /// 0…1 across every condition, for the compact indicator.
    var fraction: Double {
        let total = totalConditions ?? allConditions.count
        guard total > 0 else { return 0 }
        return min(Double(satisfiedCount) / Double(total), 1)
    }

    var satisfiedCount: Int {
        metCount ?? allConditions.filter { $0.met == true }.count
    }

    /// Every requirement satisfied. Independent of `retention`: at the top
    /// level the conditions become upkeep, and they can be *unmet* — which is
    /// exactly when the user needs to see it.
    var allMet: Bool {
        let total = totalConditions ?? allConditions.count
        return total > 0 && satisfiedCount >= total
    }

    /// The plugin renders nothing without conditions; so should the app,
    /// rather than showing an empty 0% ring.
    var hasConditions: Bool {
        (totalConditions ?? allConditions.count) > 0
    }

    /// Top level: the panel reports upkeep rather than progress to a next rank.
    var isRetention: Bool { retention == true || maxLevelReached == true }
}

struct UpgradeCondition: Decodable, Identifiable {
    /// Field names read off the plugin's own client bundle rather than
    /// guessed: it renders `label`, keeps a long form in `text` (its tooltip),
    /// and adds `scope` as a qualifier on yes/no requirements. Looking for
    /// `title`/`name` here is what left every requirement nameless.
    let key: String?
    let label: String?
    let text: String?
    let scope: String?
    let group: String?
    let value: Double?
    let target: Double?
    /// "boolean" (a yes/no requirement), "max" (a ceiling), else a floor.
    let comparison: String?
    private(set) var met: Bool?

    private enum CodingKeys: String, CodingKey {
        case key, label, text, scope, group, value, target, comparison, met
    }

    /// Same tolerance as the report: numbers may arrive as strings. A bare
    /// string is accepted too, because that is the shape the plugin falls back
    /// to for `met_conditions` / `unmet_conditions`.
    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            key = name
            label = name
            text = name
            scope = nil
            group = nil
            value = nil
            target = nil
            comparison = "boolean"
            met = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try? container.decodeIfPresent(String.self, forKey: .key)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
        value = Self.double(container, .value)
        target = Self.double(container, .target)
        comparison = try? container.decodeIfPresent(String.self, forKey: .comparison)
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .met) {
            met = flag
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .met) {
            met = number != 0
        } else {
            met = nil
        }
    }

    private static func double(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    /// Stable: the `UUID()` fallback this used to have handed every redraw a
    /// brand-new identity.
    var id: String { key ?? label ?? text ?? "" }
    var displayName: String { label ?? text ?? key ?? "" }
    var isLimit: Bool { comparison == "max" }
    var isStatus: Bool { comparison == "boolean" }

    /// How far along this one requirement is, 0…1.
    var fraction: Double {
        guard let target, target > 0 else { return met == true ? 1 : 0 }
        return min((value ?? 0) / target, 1)
    }

    /// Distance from target, unsigned — what "还差 N" and "超出 N" report.
    var shortfall: Double {
        guard let target else { return 0 }
        return abs(isLimit ? (value ?? 0) - target : target - (value ?? 0))
    }

    /// The met/unmet arrays carry no flag of their own: which array a
    /// requirement came from *is* the flag.
    func marked(_ flag: Bool) -> Self {
        var copy = self
        copy.met = flag
        return copy
    }
}

/// `/tags/filter/search` — tag completion.
struct TagSearchResponse: Decodable {
    let results: [TagSearchResult]?

    struct TagSearchResult: Decodable {
        let id: FlexibleID?
        let name: String?
        let text: String?
        let slug: String?
        let count: Int?
    }
}

/// Tag ids come back as a number for real tags and as a string for synonyms,
/// so neither type alone decodes the list.
struct FlexibleID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = String(number)
        } else {
            value = (try? container.decode(String.self)) ?? ""
        }
    }
}

/// `/u/search/users.json` — the endpoint the site's own user pickers use.
struct UserSearchResponse: Decodable {
    let users: [DiscourseUser]?
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
    /// The interface language chosen on the forum, e.g. `zh_CN`. A private
    /// attribute — Discourse only serializes it to the account's owner — and
    /// empty when the user never picked one.
    let locale: String?
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
    /// The viewer's 通知方式 for this user. Only serialized for a signed-in
    /// viewer looking at somebody else, so absence means "常规".
    let ignored: Bool?
    let muted: Bool?

    /// Everyone this account has blocked or muted, and whether it is allowed
    /// to. Owner-only (`private_attributes` on Discourse's user serializer), so
    /// these arrive on your *own* profile and are nil on anyone else's.
    ///
    /// `canIgnoreUsers` is the server's own answer to the trust-level gate
    /// behind `ignore_allowed_groups` — worth reading rather than inferring
    /// from a failed request.
    let ignoredUsernames: [String]?
    let mutedUsernames: [String]?
    let canIgnoreUsers: Bool?
    let canMuteUsers: Bool?
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
    /// The summary payload carries the badge style too, so a node missing from
    /// the catalog can still be drawn correctly.
    let styleType: String?
    let icon: String?
    let emoji: String?
}

struct SummaryBadge: Decodable, Identifiable {
    let id: Int
    let name: String?
    let description: String?
    let grantCount: Int?
    /// A FontAwesome name ("heart", "far-eye", "gem"), never a URL — the same
    /// shape as `flair_url`, which once had the image loader fetching "gem".
    let icon: String?
    /// Uploaded artwork. Only a couple of nodeloc's 71 badges have one, so the
    /// icon is the normal case rather than the fallback.
    let imageUrl: String?
    /// 1 = Gold, 2 = Silver, 3 = Bronze (`/badges.json` → `badge_types`).
    let badgeTypeId: Int?
    /// discourse-custom-badge's colour, which wins over the type's when set.
    let customStyle: BadgeCustomStyle?
}

struct BadgeCustomStyle: Decodable {
    let textColor: String?
    let textEffect: String?
}

/// `GET /mobile/feature_flags.json` from the companion plugin.
///
/// Every field is optional so the server can send only what it wants to
/// override, and so adding a flag later doesn't break older builds.
struct FeatureFlagConfig: Decodable {
    let miniAppsEnabled: Bool?
    let lotteryEnabled: Bool?
    /// Whether `/mobile/profile.json` is deployed. Unlike the two above, this
    /// one stays off until the server says otherwise — see `FeatureFlags`.
    ///
    /// Named for the wire key, which is `profile_aggregate` and not
    /// `profile_aggregate_enabled` like its neighbours: the requirement doc's
    /// example spelled it that way and the server followed the doc. Renaming it
    /// to match the pattern would silently switch the feature off, since a
    /// missing key decodes to nil.
    let profileAggregate: Bool?
}

// MARK: - Profile aggregate (discourse-mobile)

/// `GET /mobile/profile.json` — the whole profile page in one response.
///
/// Every member is optional, and every value is the **verbatim** body of the
/// endpoint it replaces. That is the point of the design: these are the same
/// models already used against those endpoints individually, so this envelope
/// adds no new parsing surface, and a plugin that fails server-side arrives as
/// `null` rather than taking the page down with it.
///
/// Requirement doc: `SERVER_TASKS_PROFILE_AGGREGATE.md`.
struct ProfileAggregateResponse: Decodable {
    let version: Int?
    /// `GET /u/{username}.json`
    let user: UserResponse?
    /// `GET /u/{username}/summary.json`
    let summary: UserSummaryResponse?
    /// `GET /node/recently-visited.json`
    let nodes: SidebarCommunitiesResponse?
    /// `GET /u/{username}/points-scores.json`
    let points: PointsScoresResponse?
    /// `GET /u/{username}/upgrade-progress.json`
    let upgrade: UpgradeProgressReport?
    /// `GET /user_actions.json` for the requested `activity_filter`.
    let activity: UserActionsResponse?
    /// New here rather than a replacement: the server knows whether today's
    /// check-in happened, where the device could only remember its own.
    let checkin: ProfileCheckinState?
}

struct ProfileCheckinState: Decodable {
    let checkedInToday: Bool?
    let nextAvailableAt: String?
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

/// `GET /apps/directory.json` — one page of the directory.
///
/// An object, not the bare array this endpoint was once read as. `page` is
/// zero-based and `per_page` is reported but ignored as input (it stays 24
/// whatever you ask for), so reading the whole directory means walking pages
/// until `total` is covered.
struct AppsDirectoryResponse: Decodable {
    let apps: [DirectoryApp]
    let total: Int?
    let page: Int?
    let perPage: Int?
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
    /// Staff, which gates the moderation actions the app offers.
    let admin: Bool?
    let moderator: Bool?
    /// Whether the server will let this account delete *itself*. False once the
    /// user has more posts than `delete_user_self_max_post_count`, and for admins
    /// — `UserGuardian#can_delete_user?`. When it's false the only route left is
    /// asking staff.
    let canDeleteAccount: Bool?
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

/// GET /u/check_username.json — signup username availability.
struct UsernameCheckResponse: Decodable {
    let available: Bool?
    let suggestion: String?
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

/// One emoji tally on a chat message, as `Chat::MessageSerializer#reactions`
/// builds it: the emoji's bare name, how many reacted, up to five of them, and
/// whether you are one.
struct ChatMessageReaction: Decodable, Identifiable {
    let emoji: String
    let count: Int?
    let reacted: Bool?
    let users: [ChatUser]?

    var id: String { emoji }
}

struct ChatMessage: Decodable, Identifiable {
    let id: Int
    let message: String?
    let cooked: String?
    let excerpt: String?
    let createdAt: String?
    let deletedAt: String?
    /// Set once the message has been edited.
    let edited: Bool?
    let reactions: [ChatMessageReaction]?
    /// The flag types the server will accept *for this message*, as name keys
    /// ("spam", "off_topic", …). Empty when this reader can't flag it — a direct
    /// message drops `notify_moderators`, your own message drops `notify_user`,
    /// and an already-flagged one comes back empty.
    ///
    /// Entries can be `null`. The list comes from Discourse's flag-type name
    /// lookup and this site's custom flags resolve to nil there, so the real
    /// payload is `[null, "off_topic", "custom_", null, "custom__1002"]`.
    /// Typed as `[String]` this throws `valueNotFound` and takes the *whole
    /// channel* down — every message from another user carries the nulls, so
    /// opening such a chat just showed "数据加载出错". The nulls are kept here
    /// and dropped where the list is consumed.
    let availableFlags: [String?]?
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

/// `GET /chat/api/channels/{id}/pins` — `Chat::ChannelPinsSerializer`.
struct ChatPinsResponse: Decodable {
    struct Pin: Decodable, Identifiable {
        let id: Int
        let chatMessageId: Int?
        let pinnedAt: String?
        /// Built with `strip_links: false` for this surface specifically.
        let excerpt: String?
        let pinnedBy: ChatUser?
        let message: ChatMessage?
    }

    let pinnedMessages: [Pin]?
}

/// `POST /chat/{id}/quote` — chat messages rendered as forum markdown.
struct ChatTranscriptResponse: Decodable {
    let markdown: String?
}

/// `GET /chat/api/channels/{id}/memberships` — who is in a channel.
///
/// The channel payload's `chatable.users` is not a substitute: for a direct
/// message the serializer *subtracts the current user* (`users - [scope.user]`),
/// and for a category channel it is empty. This endpoint lists everyone, 50 at a
/// time, with `meta.total_rows` for the real size.
struct ChatMembershipsResponse: Decodable {
    struct Membership: Decodable {
        let user: ChatUser?
    }

    struct Meta: Decodable {
        let totalRows: Int?
        let loadMoreUrl: String?
    }

    let memberships: [Membership]?
    let meta: Meta?
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
        /// "always" / "mention" / "never" — the three the web offers.
        let notificationLevel: String?
    }
}

/// `GET|PUT /mobile/preferences/post_source` — the account's 小尾巴 disclosure
/// level. `levels` is the ladder the server supports, so a client added to
/// later can render rungs it wasn't built with.
struct PostSourceLevelResponse: Decodable {
    let level: Int?
    let levels: [Int]?
}

/// `DELETE /mobile/preferences/post_source/history` — how many rows went.
struct ClearPostSourcesResponse: Decodable {
    let cleared: Int?
}

/// What the notification-settings endpoint answers.
struct ChatMembershipResponse: Decodable {
    let membership: ChatChannel.ChatMembership?
}

/// One channel, as `POST /chat/api/direct-message-channels` answers.
struct ChatChannelResponse: Decodable {
    let channel: ChatChannel

    private enum CodingKeys: String, CodingKey { case channel }

    init(from decoder: Decoder) throws {
        // The endpoint serializes the channel under a "channel" root; accept a
        // bare channel too rather than failing the whole call over a wrapper.
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let wrapped = try? container.decode(ChatChannel.self, forKey: .channel) {
            channel = wrapped
        } else {
            channel = try ChatChannel(from: decoder)
        }
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
