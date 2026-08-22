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
    var isLoadingMore = false
    var errorText: String?
    var usingSampleData = false
    /// Another page is available (the list carried a `more_topics_url`).
    private(set) var hasMore = false

    private var page = 0
    /// Accumulated across pages so later pages' authors still resolve.
    private var usersByID: [Int: DiscourseUser] = [:]

    func loadIfNeeded() async {
        if posts.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorText = nil
        page = 0
        do {
            async let latestCall = client.latest()
            async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
            let latest = try await latestCall
            let site = await siteCall

            categoriesByID = Dictionary(
                (site?.categories ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            usersByID = Dictionary(
                (latest.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            posts = latest.topicList.topics.map { map(topic: $0, usersByID: usersByID) }
            hasMore = latest.topicList.moreTopicsUrl != nil
            usingSampleData = false
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            if posts.isEmpty {
                posts = SampleData.posts
                usingSampleData = true
            }
            hasMore = false
        }
        isLoading = false
    }

    /// Appends the next page. Safe to call repeatedly — no-op while a page is in
    /// flight, when there's nothing more, or on the sample-data fallback.
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !usingSampleData else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let latest = try await client.latest(page: page + 1)
            page += 1
            for user in latest.users ?? [] { usersByID[user.id] = user }
            let existingIDs = Set(posts.map(\.id))
            let newPosts = latest.topicList.topics
                .filter { !existingIDs.contains($0.id) }
                .map { map(topic: $0, usersByID: usersByID) }
            posts.append(contentsOf: newPosts)
            hasMore = latest.topicList.moreTopicsUrl != nil && !newPosts.isEmpty
        } catch {
            // Keep what's shown; the sentinel retries when it reappears.
        }
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
