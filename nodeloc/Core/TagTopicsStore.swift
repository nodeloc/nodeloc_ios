//
//  TagTopicsStore.swift
//  nodeloc
//
//  Topics for one tag, behind a `#tag` badge in a post.
//
//  `/tag/{slug}.json` answers the same `topic_list` shape as the home feed and
//  a node's list, so this is deliberately a thin copy of `FeedStore` rather
//  than a new mapping: rows, excerpt handling and unread logic all stay in
//  `FeedMapper`.
//

import Foundation

@MainActor
@Observable
final class TagTopicsStore {
    private let client = DiscourseClient()

    var posts: [Post] = []

    /// `posts` minus authors this reader has blocked — what a list should
    /// actually render. Blocking has to clear rows from the screen at once
    /// rather than at the next fetch, and reading the blocked set here is what
    /// makes SwiftUI redraw the list the moment it changes (guideline 1.2).
    var visiblePosts: [Post] { BlockedUsersStore.shared.visible(posts) }
    var isLoading = false
    var isLoadingMore = false
    var errorText: String?
    /// Another page is available (the list carried a `more_topics_url`).
    private(set) var hasMore = false

    private var slug: String?
    private var page = 0
    /// Accumulated across pages so later pages' authors still resolve.
    private var usersByID: [Int: DiscourseUser] = [:]
    private var categoriesByID: [Int: DiscourseCategory] = [:]

    /// Loads a tag once. Re-entrant for the same slug so reopening the sheet
    /// doesn't refetch what's on screen.
    func loadIfNeeded(slug: String) async {
        guard self.slug != slug || posts.isEmpty else { return }
        await load(slug: slug)
    }

    func load(slug: String) async {
        self.slug = slug
        isLoading = posts.isEmpty
        errorText = nil
        page = 0
        defer { isLoading = false }

        do {
            async let topicsCall = client.tagTopics(slug: slug)
            async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
            let response = try await topicsCall
            let site = await siteCall

            categoriesByID = Dictionary(
                (site?.categories ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            usersByID = Dictionary(
                (response.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let topics = response.topicList?.topics ?? []
            posts = topics.map(map(topic:))
            hasMore = response.topicList?.moreTopicsUrl != nil
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            hasMore = false
        }
    }

    func loadMore() async {
        guard let slug, hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await client.tagTopics(slug: slug, page: page + 1)
            page += 1
            for user in response.users ?? [] { usersByID[user.id] = user }

            let existingIDs = Set(posts.map(\.id))
            let newPosts = (response.topicList?.topics ?? [])
                .filter { !existingIDs.contains($0.id) }
                .map(map(topic:))
            posts.append(contentsOf: newPosts)
            // `more_topics_url` keeps pointing forward even on the last page, so
            // an empty result is the real terminator.
            hasMore = response.topicList?.moreTopicsUrl != nil && !newPosts.isEmpty
        } catch {
            // Keep what's shown; the sentinel retries when it reappears.
        }
    }

    private func map(topic: TopicListItem) -> Post {
        FeedMapper.post(
            topic: topic,
            usersByID: usersByID,
            client: client,
            category: topic.categoryId.flatMap { categoriesByID[$0] }
        )
    }
}
