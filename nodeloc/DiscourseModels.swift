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
    let excerpt: String?
    let imageUrl: String?
    let topicImages: [String]?
    let topicThumbnails: [String]?
    let posters: [TopicPoster]?
}

struct TopicList: Decodable {
    let topics: [TopicListItem]
}

struct LatestResponse: Decodable {
    let users: [DiscourseUser]?
    let topicList: TopicList
}

struct SiteResponse: Decodable {
    let categories: [DiscourseCategory]?
    let popularApps: [SidebarDiscourseApp]?
    let appsBrowseUrl: String?
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
    let url: String?
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

// MARK: - Topic detail

struct ActionSummary: Decodable { let id: Int; let count: Int? }

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

    /// Like count lives in actions_summary with action id 2.
    var likeCount: Int { actionsSummary?.first { $0.id == 2 }?.count ?? 0 }
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
    let bioRaw: String?
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

struct CurrentUser: Decodable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let recentApps: [SidebarDiscourseApp]?
    let recentPostCategoryIds: [Int]?
    let canCreateCommunity: Bool?
}

struct CurrentUserResponse: Decodable { let currentUser: CurrentUser }

// MARK: - Notifications

struct NotificationData: Decodable {
    let topicTitle: String?
    let displayUsername: String?
    let username: String?
    let badgeName: String?
}

struct DiscourseNotification: Decodable, Identifiable {
    let id: Int
    let notificationType: Int
    let read: Bool
    let createdAt: String?
    let data: NotificationData?
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
