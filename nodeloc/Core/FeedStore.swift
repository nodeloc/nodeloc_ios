//
//  FeedStore.swift
//  nodeloc
//
//  Loads the home tab's topics from nodeloc.com and maps them onto the Post
//  card model. A failed load keeps the list empty and sets `errorText`;
//  HomeView shows the friendly retry state — never sample data.
//
//  Which list is loaded comes from `UserPreferencesStore.homeFeed` (default
//  `best`, the community feed) and is read at the start of every `load()`, so
//  changing the preference and returning to the tab shows the new feed.
//

import Foundation

@MainActor
@Observable
final class FeedStore {
    private let client = DiscourseClient()

    var posts: [Post] = []

    /// `posts` minus authors this reader has blocked — what a list should
    /// actually render. Blocking has to clear rows from the screen at once
    /// rather than at the next fetch, and reading the blocked set here is what
    /// makes SwiftUI redraw the list the moment it changes (guideline 1.2).
    var visiblePosts: [Post] { BlockedUsersStore.shared.visible(posts) }
    var categoriesByID: [Int: DiscourseCategory] = [:]
    var isLoading = false
    var isLoadingMore = false
    var errorText: String?
    /// Another page is available (the list carried a `more_topics_url`).
    private(set) var hasMore = false

    /// The list these posts came from, so a preference change can be noticed.
    private(set) var feed = UserPreferencesStore.shared.homeFeed

    private var page = 0
    /// `best`'s random ordering, as reported by the first page's
    /// `more_topics_url`. Carried into later pages — see `HomeFeed.isSeeded`.
    private var seed: String?
    /// Accumulated across pages so later pages' authors still resolve.
    private var usersByID: [Int: DiscourseUser] = [:]

    func loadIfNeeded() async {
        // A stale feed counts as needing a load: the preference can change
        // while this tab sits in the background with its posts intact.
        if posts.isEmpty || feed != UserPreferencesStore.shared.homeFeed {
            await load()
        }
    }

    func load() async {
        isLoading = true
        errorText = nil
        page = 0
        seed = nil
        feed = UserPreferencesStore.shared.homeFeed
        do {
            async let listCall = client.topicList(feed: feed)
            async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()
            let list = try await listCall
            let site = await siteCall

            categoriesByID = Dictionary(
                (site?.categories ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            usersByID = Dictionary(
                (list.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            posts = list.topicList.topics.map { map(topic: $0, usersByID: usersByID) }
            hasMore = list.topicList.moreTopicsUrl != nil
            seed = Self.seed(from: list.topicList.moreTopicsUrl)
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            hasMore = false
        }
        isLoading = false
    }

    /// Appends the next page. Safe to call repeatedly — no-op while a page is
    /// in flight or when there's nothing more.
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let list = try await client.topicList(feed: feed, page: page + 1, seed: seed)
            page += 1
            for user in list.users ?? [] { usersByID[user.id] = user }
            let existingIDs = Set(posts.map(\.id))
            let newPosts = list.topicList.topics
                .filter { !existingIDs.contains($0.id) }
                .map { map(topic: $0, usersByID: usersByID) }
            posts.append(contentsOf: newPosts)
            hasMore = list.topicList.moreTopicsUrl != nil && !newPosts.isEmpty
            // The seed travels along the whole chain of pages, so keep taking
            // it from the latest one rather than assuming it never changes.
            if let next = Self.seed(from: list.topicList.moreTopicsUrl) { seed = next }
        } catch {
            // Keep what's shown; the sentinel retries when it reappears.
        }
    }

    /// Digs the `seed` out of a `more_topics_url` like
    /// `/best.json?page=1&seed=6`. Nil for the feeds that don't use one.
    private static func seed(from moreTopicsUrl: String?) -> String? {
        guard let moreTopicsUrl,
              let components = URLComponents(string: moreTopicsUrl)
        else { return nil }
        return components.queryItems?.first { $0.name == "seed" }?.value
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
            // Localized when a translation exists — content localization only
            // rewrites `fancy_title`, never `title`. Titles can also contain a
            // bare URL with no wrap opportunity, which would otherwise widen
            // the whole row.
            title: DiscourseFormat.displayTitle(for: topic).breakingLongTokens(),
            excerpt: DiscourseFormat.plainText(topic.excerpt),
            // The *first post's* likes, which is what the card's heart acts on
            // and what the reader shows for the same topic. `like_count` is the
            // whole topic's and would disagree with both (t/105832: topic 11,
            // first post 5). `op_like_count` is a nodeloc addition to the list
            // serializer; falling back to the topic total keeps the number
            // sensible if it ever isn't served.
            baseVotes: topic.opLikeCount ?? topic.likeCount ?? 0,
            // discourse-vote's score for the first post, which is what a row
            // votes on. Nil when the plugin didn't serialize one, and the card
            // then falls back to showing likes.
            voteScore: topic.opVoteScore,
            voteDirection: topic.opVoteDirection ?? .none,
            canVoteDown: topic.opCanVoteDown ?? false,
            opPostID: topic.opPostId,
            notificationLevel: topic.notificationLevel,
            isBookmarked: topic.bookmarked ?? false,
            // `posts_count - 1`, never `reply_count`. Discourse's `reply_count`
            // counts only posts that answer *another post*, which is a much
            // smaller and unrelated number — measured on t/105832: 25 posts
            // (24 replies) but `reply_count` 7. The replies column in the site's
            // own list is `posts_count - 1`.
            comments: max(0, (topic.postsCount ?? 1) - 1),
            hasImage: !media.isEmpty,
            pinned: topic.pinned ?? false,
            pinnedGlobally: topic.pinnedGlobally ?? false,
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
