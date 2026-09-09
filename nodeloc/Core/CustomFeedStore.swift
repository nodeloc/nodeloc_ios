//
//  CustomFeedStore.swift
//  nodeloc
//
//  One custom feed: the feed itself, the nodes it gathers, and its topics.
//
//  A custom feed is discourse-community's "several nodes read as one list".
//  `/f/{username}/{slug}.json` answers the same `topic_list` (with `users`) as
//  the home feed, so the rows come straight from `FeedMapper` and this is a
//  close relative of `TagTopicsStore` — only the metadata and the node editing
//  are new.
//
//  Both loads run together, the way the plugin's own route does: the feed
//  header and the first page of topics are independent requests and neither
//  should wait for the other.
//

import Foundation

@MainActor
@Observable
final class CustomFeedStore {
    private let client = DiscourseClient()

    private(set) var feed: CustomFeed?
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
    /// The node currently being added or removed, so only its own row shows
    /// progress rather than the whole picker.
    private(set) var busyNodeID: Int?

    private var username: String?
    private var slug: String?
    private var page = 0
    /// Accumulated across pages so later pages' authors still resolve.
    private var usersByID: [Int: DiscourseUser] = [:]
    private var categoriesByID: [Int: DiscourseCategory] = [:]

    /// The nodes in the feed, as the rest of the app models a node.
    var nodes: [SidebarNodeSummary] {
        (feed?.nodes ?? []).map(NodeSummaryFactory.node)
    }

    var canEdit: Bool { feed?.canEdit == true }

    /// Loads once. Re-entrant for the same feed so returning to it doesn't
    /// refetch what is already on screen.
    func loadIfNeeded(username: String, slug: String) async {
        guard self.username != username || self.slug != slug || posts.isEmpty else { return }
        await load(username: username, slug: slug)
    }

    func load(username: String, slug: String) async {
        self.username = username
        self.slug = slug
        isLoading = posts.isEmpty
        errorText = nil
        page = 0
        defer { isLoading = false }

        async let feedCall = client.customFeed(username: username, slug: slug)
        async let topicsCall = client.customFeedTopics(username: username, slug: slug)
        async let siteCall: SiteResponse? = await SiteResources.shared.siteResponse()

        // The header is the part worth an error: without it there is no page.
        // An empty topic list is a legitimate state (a feed with no nodes yet),
        // so the two are reported separately.
        do {
            feed = try await feedCall.customFeed
        } catch {
            errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
        }

        let site = await siteCall
        categoriesByID = Dictionary(
            (site?.categories ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        do {
            let response = try await topicsCall
            usersByID = Dictionary(
                (response.users ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            posts = (response.topicList?.topics ?? []).map(map(topic:))
            hasMore = response.topicList?.moreTopicsUrl != nil
        } catch {
            if errorText == nil {
                errorText = (error as? DiscourseError)?.errorDescription ?? error.localizedDescription
            }
            hasMore = false
        }
    }

    func loadMore() async {
        guard let username, let slug, hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await client.customFeedTopics(
                username: username,
                slug: slug,
                page: page + 1
            )
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

    // MARK: Editing

    /// Adopts a feed the server just returned — after an edit, or after a node
    /// was added or removed.
    ///
    /// Changing the nodes changes what the feed contains, so the topics are
    /// refetched rather than left showing the previous set.
    func adopt(_ updated: CustomFeed, reloadTopics: Bool) async {
        feed = updated
        guard reloadTopics, let username, let slug else { return }
        page = 0
        do {
            let response = try await client.customFeedTopics(username: username, slug: slug)
            for user in response.users ?? [] { usersByID[user.id] = user }
            posts = (response.topicList?.topics ?? []).map(map(topic:))
            hasMore = response.topicList?.moreTopicsUrl != nil
        } catch {
            // The node change itself succeeded; leave the old rows rather than
            // emptying the list over a failed refresh.
        }
    }

    func addNode(categoryID: Int) async {
        guard let id = feed?.id else { return }
        busyNodeID = categoryID
        defer { busyNodeID = nil }
        do {
            let response = try await client.addCustomFeedNode(feedID: id, categoryID: categoryID)
            await adopt(response.customFeed, reloadTopics: true)
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    func removeNode(categoryID: Int) async {
        guard let id = feed?.id else { return }
        busyNodeID = categoryID
        defer { busyNodeID = nil }
        do {
            let response = try await client.removeCustomFeedNode(feedID: id, categoryID: categoryID)
            await adopt(response.customFeed, reloadTopics: true)
        } catch {
            ToastCenter.shared.showError(error)
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

/// Searches nodes to add to a feed.
///
/// Separate from `CustomFeedStore` because it is the picker's own transient
/// state: typing a term shouldn't touch the feed being edited.
@MainActor
@Observable
final class CustomFeedNodeSearchStore {
    private let client = DiscourseClient()

    var term = ""
    private(set) var results: [SidebarNodeSummary] = []
    private(set) var isSearching = false

    /// Debounced, so holding down a key doesn't queue a request per character.
    private var searchTask: Task<Void, Never>?

    func search() {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            let response = try? await self.client.customFeedNodeSearch(term: trimmed)
            guard !Task.isCancelled else { return }
            self.results = (response?.nodes ?? []).map(NodeSummaryFactory.node)
        }
    }

    func clear() {
        searchTask?.cancel()
        term = ""
        results = []
        isSearching = false
    }
}
