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
            async let siteCall: SiteResponse? = try? client.site()
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
        let category = topic.categoryId.flatMap { categoriesByID[$0] }
        let author = topic.posters?.compactMap { poster in
            poster.userId.flatMap { usersByID[$0] }
        }.first
        let media = DiscourseFormat.mediaItems(for: topic)
        let node = category.map { "n/\($0.slug)" } ?? "n/nodeloc"
        let letter = String((author?.username ?? category?.name ?? "N").prefix(1)).uppercased()
        return Post(
            id: topic.id,
            node: node,
            avatarLetter: letter,
            variant: topic.id % 2,
            time: DiscourseFormat.relative(topic.bumpedAt ?? topic.lastPostedAt ?? topic.createdAt),
            title: topic.title,
            excerpt: DiscourseFormat.plainText(topic.excerpt),
            baseVotes: topic.likeCount ?? 0,
            comments: topic.replyCount ?? max(0, (topic.postsCount ?? 1) - 1),
            hasImage: !media.isEmpty,
            pinned: topic.pinned ?? false,
            imageURL: media.first?.url,
            avatarURL: author?.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
            authorUsername: author?.username,
            authorName: author?.name,
            media: media
        )
    }
}
