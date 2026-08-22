//
//  FeedStore.swift
//  nodeloc
//
//  Loads the live "latest" topics from nodeloc.com and maps them onto the
//  Post card model. Falls back to sample data if the network is unavailable.
//

import Foundation

@MainActor
@Observable
final class FeedStore {
    private let client = DiscourseClient()

    var posts: [Post] = []
    var categoriesByID: [Int: DiscourseCategory] = [:]
    var isLoading = false
    var errorText: String?
    var usingSampleData = false

    func loadIfNeeded() async {
        if posts.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorText = nil
        do {
            async let latestCall = client.latest()
            async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
            let latest = try await latestCall
            let site = await siteCall

            categoriesByID = Dictionary(
                (site?.categories ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let usersByID = Dictionary(
                (latest.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            posts = latest.topicList.topics.map { map(topic: $0, usersByID: usersByID) }
            usingSampleData = false
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            if posts.isEmpty {
                posts = SampleData.posts
                usingSampleData = true
            }
        }
        isLoading = false
    }

    private func map(topic: TopicListItem, usersByID: [Int: DiscourseUser]) -> Post {
        FeedMapper.post(
            topic: topic,
            usersByID: usersByID,
            client: client,
            category: topic.categoryId.flatMap { categoriesByID[$0] }
        )
    }
}

/// Shared topic → Post mapping, used by the home feed and by node topic lists.
enum FeedMapper {
    static func post(
        topic: TopicListItem,
        usersByID: [Int: DiscourseUser],
        client: DiscourseClient,
        category: DiscourseCategory? = nil
    ) -> Post {
        let author = topic.posters?.compactMap { poster in
            poster.userId.flatMap { usersByID[$0] }
        }.first
        let media = DiscourseFormat.mediaItems(for: topic)
        let node = category.map { "n/\($0.slug)" } ?? "n/nodeloc"
        let letter = String((author?.username ?? category?.name ?? "N").prefix(1)).uppercased()
        // New topic, or read progress trailing the latest post.
        let hasUnreadPosts = (topic.lastReadPostNumber ?? 0) < (topic.highestPostNumber ?? 0)
            && topic.lastReadPostNumber != nil
        let isUnread = topic.unseen == true || hasUnreadPosts
        return Post(
            id: topic.id,
            node: node,
            avatarLetter: letter,
            variant: topic.id % 2,
            time: DiscourseFormat.relative(topic.bumpedAt ?? topic.lastPostedAt ?? topic.createdAt),
            // Titles can contain a bare URL with no wrap opportunity, which
            // would otherwise widen the whole row.
            title: topic.title.breakingLongTokens(),
            excerpt: DiscourseFormat.plainText(topic.excerpt),
            baseVotes: topic.likeCount ?? 0,
            comments: topic.replyCount ?? max(0, (topic.postsCount ?? 1) - 1),
            hasImage: !media.isEmpty,
            pinned: topic.pinned ?? false,
            isUnread: isUnread,
            imageURL: media.first?.url,
            avatarURL: author?.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
            authorUsername: author?.username,
            authorName: author?.name,
            media: media,
            tags: (topic.tags ?? []).compactMap(\.name),
            videoURL: topic.topicVideoUrl.flatMap { NodeSummaryFactory.resolvedURL($0) }
        )
    }
}
