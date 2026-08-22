//
//  TopicStore.swift
//  nodeloc
//
//  Loads a single topic's full body + replies for the post-detail overlay.
//

import Foundation
import UIKit

/// How the top-level reply threads are ordered — mirrors Discourse's post
/// stream orderings (chronological by default, plus newest and most-liked).
enum ReplySort: String, CaseIterable, Identifiable {
    case oldest
    case newest
    case mostLiked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oldest: return "最早回复"
        case .newest: return "最新回复"
        case .mostLiked: return "最多点赞"
        }
    }

    var icon: String {
        switch self {
        case .oldest: return "arrow.up"
        case .newest: return "arrow.down"
        case .mostLiked: return "heart"
        }
    }

    var detail: String {
        switch self {
        case .oldest: return "按发布时间从早到晚"
        case .newest: return "最新的回复在前"
        case .mostLiked: return "点赞最多的在前"
        }
    }

    /// The value Discourse's nested view expects for `?sort=`.
    var apiValue: String {
        switch self {
        case .oldest: return "old"
        case .newest: return "new"
        case .mostLiked: return "top"
        }
    }

    /// Orders the root posts of each thread.
    var rootComparator: (TopicPost, TopicPost) -> Bool {
        switch self {
        case .oldest:
            return { ($0.postNumber ?? 0) < ($1.postNumber ?? 0) }
        case .newest:
            return { ($0.postNumber ?? 0) > ($1.postNumber ?? 0) }
        case .mostLiked:
            return { lhs, rhs in
                if lhs.likeCount != rhs.likeCount { return lhs.likeCount > rhs.likeCount }
                return (lhs.postNumber ?? 0) < (rhs.postNumber ?? 0)
            }
        }
    }
}

/// Tracks which posts the reader sees and for how long, then reports it to
/// Discourse (POST /topics/timings). That marks the posts read, accrues the
/// user's read time and posts-read count, and clears the topic's unread dot —
/// the same bookkeeping the web client's screen tracker does.
@MainActor
final class TopicReadTracker {
    private let client = DiscourseClient()
    private var topicID: Int?
    /// Post numbers currently on screen.
    private var visible: Set<Int> = []
    /// Unsent read time per post number, and total time in the topic, in ms.
    private var pendingByPost: [Int: Int] = [:]
    private var pendingTopicTime = 0

    func begin(topicID: Int) {
        self.topicID = topicID
        visible = [1]        // the first post is on screen when a topic opens
        pendingByPost = [:]
        pendingTopicTime = 0
    }

    func setVisible(_ postNumber: Int, _ isVisible: Bool) {
        if isVisible { visible.insert(postNumber) } else { visible.remove(postNumber) }
    }

    /// Called on a ~1s heartbeat: credit the elapsed time to on-screen posts.
    func tick(elapsedMs: Int = 1000) {
        guard topicID != nil, !visible.isEmpty else { return }
        for postNumber in visible {
            pendingByPost[postNumber, default: 0] += elapsedMs
        }
        pendingTopicTime += elapsedMs
    }

    /// Sends and clears accumulated timings. A no-op when nothing is pending.
    func flush() async {
        guard let topicID, !pendingByPost.isEmpty else { return }
        let timings = pendingByPost
        let time = pendingTopicTime
        pendingByPost = [:]
        pendingTopicTime = 0
        try? await client.sendTopicTimings(topicID: topicID, topicTimeMs: time, timings: timings)
    }
}

@MainActor
@Observable
final class TopicStore {
    private let client = DiscourseClient()

    /// Parsed body of the first post. Replaces the old plain-text `body`.
    var content = PostContent.empty
    var comments: [PostComment] = []
    var isLoading = false
    var isLoadingMore = false
    var isSubmitting = false
    var totalReplyCount = 0
    var firstAuthor: UserProfileTarget?
    /// Plugin payloads for the first post and the topic.
    var firstPostPolls: [PostPoll] = []
    var myPollVotes: [String: [String]] = [:]
    var lottery: PostLottery?
    var redEnvelope: TopicRedEnvelope?
    /// How top-level reply threads are ordered.
    private(set) var replySort: ReplySort = .oldest
    private(set) var firstPostID: Int?
    private var loadedID: Int?
    private var topicID: Int?
    private var allPosts: [TopicPost] = []
    private var streamPostIDs: [Int] = []
    private var loadedPostIDs: Set<Int> = []
    private let pageSize = 20
    // Nested-view (/n/…) reply state: replies come from the server already
    // sorted, so no client-side reordering.
    private var nestedRoots: [TopicPost] = []
    private var nestedPage = 0
    private(set) var nestedHasMore = false
    /// Next children page to fetch per parent post number, and which parents
    /// have a fetch in flight (drives the per-node "load more" spinner).
    private var childPages: [Int: Int] = [:]
    private(set) var loadingChildren: Set<Int> = []
    /// Parsed bodies keyed by post id + edit version, so scrolling back through
    /// a long topic doesn't re-parse HTML that hasn't changed.
    private let contentCache = ParsedContentCache.shared

    var hasMoreComments: Bool { nestedHasMore }

    func load(topicID: Int) async {
        guard loadedID != topicID else { return }
        self.topicID = topicID
        isLoading = true
        content = .empty
        comments = []
        totalReplyCount = 0
        firstAuthor = nil
        firstPostPolls = []
        myPollVotes = [:]
        lottery = nil
        redEnvelope = nil
        nestedRoots = []
        do {
            let topic = try await client.topic(id: topicID)
            let posts = topic.postStream.posts
            firstPostID = posts.first?.id
            if let firstPost = posts.first {
                firstAuthor = UserProfileTarget(
                    username: firstPost.username,
                    displayName: firstPost.name,
                    avatarURL: firstPost.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 120) }
                )
                firstPostPolls = firstPost.polls ?? []
                myPollVotes = firstPost.pollsVotes ?? [:]
                lottery = firstPost.lottery
            }
            redEnvelope = topic.redEnvelope
            totalReplyCount = max(0, (topic.postsCount ?? 1) - 1)

            // Parse the OP off the main actor before touching @Observable state.
            await parseContents(for: posts)
            content = posts.first.map { parsedContent(for: $0) } ?? .empty
            loadedID = topicID
        } catch {
            // Leave content empty; the overlay falls back to the excerpt.
        }
        // Replies come from the nested view (server-sorted).
        await loadNested(reset: true)
        isLoading = false
    }

    /// Loads (or appends) the nested reply tree for the current `replySort`.
    private func loadNested(reset: Bool) async {
        guard let topicID else { return }
        if reset {
            nestedPage = 0
            childPages = [:]
            loadingChildren = []
        } else {
            nestedPage += 1
            isLoadingMore = true
        }
        defer { if !reset { isLoadingMore = false } }
        do {
            let response = try await client.nestedTopic(
                id: topicID,
                sort: replySort.apiValue,
                page: nestedPage
            )
            let roots = response.roots ?? []
            if reset { nestedRoots = roots } else { nestedRoots.append(contentsOf: roots) }
            nestedHasMore = response.hasMoreRoots?.value ?? false
            await parseContents(for: flatten(nestedRoots))
            comments = buildNestedComments(from: nestedRoots)
        } catch {
            if reset { nestedRoots = []; comments = [] }
        }
    }

    func isLoadingChildren(_ postNumber: Int) -> Bool {
        loadingChildren.contains(postNumber)
    }

    /// Fetches the next page of direct replies under one post and splices them
    /// into that node, then rebuilds the thread rows.
    func loadMoreChildren(parentPostNumber: Int) async {
        guard let topicID, !loadingChildren.contains(parentPostNumber) else { return }
        loadingChildren.insert(parentPostNumber)
        defer { loadingChildren.remove(parentPostNumber) }

        let page = childPages[parentPostNumber] ?? 0
        do {
            let response = try await client.nestedChildren(
                topicID: topicID,
                postNumber: parentPostNumber,
                sort: replySort.apiValue,
                page: page
            )
            childPages[parentPostNumber] = page + 1
            let fetched = response.children ?? []
            guard !fetched.isEmpty else { return }
            appendChildren(fetched, toParent: parentPostNumber, in: &nestedRoots)
            await parseContents(for: flatten(fetched))
            comments = buildNestedComments(from: nestedRoots)
        } catch {
            // Leave the affordance in place so the user can retry.
        }
    }

    /// Appends children under the post with `parentNumber`, deduping by id so a
    /// page that overlaps the inlined preview doesn't double up.
    @discardableResult
    private func appendChildren(_ newKids: [TopicPost], toParent parentNumber: Int, in posts: inout [TopicPost]) -> Bool {
        for index in posts.indices {
            if posts[index].postNumber == parentNumber {
                let existing = Set((posts[index].children ?? []).map(\.id))
                posts[index].children = (posts[index].children ?? []) + newKids.filter { !existing.contains($0.id) }
                return true
            }
            if var kids = posts[index].children {
                if appendChildren(newKids, toParent: parentNumber, in: &kids) {
                    posts[index].children = kids
                    return true
                }
            }
        }
        return false
    }

    /// Re-fetches the replies with a new server sort.
    func applySort(_ sort: ReplySort) {
        guard sort != replySort else { return }
        replySort = sort
        comments = []
        isLoading = true
        Task {
            await loadNested(reset: true)
            isLoading = false
        }
    }

    // MARK: Plugin actions

    /// Poll names with a request in flight. Guards against double-taps sending
    /// duplicate votes.
    private(set) var pollsInFlight: Set<String> = []
    private(set) var isLotteryBusy = false
    var pluginErrorText: String?

    func vote(pollName: String, options: [String]) async {
        guard let postID = firstPostID, !pollsInFlight.contains(pollName) else { return }
        pollsInFlight.insert(pollName)
        defer { pollsInFlight.remove(pollName) }

        // Optimistic: reflect the selection immediately, roll back on failure.
        let previousVotes = myPollVotes[pollName]
        let previousPolls = firstPostPolls
        myPollVotes[pollName] = options

        do {
            let response = try await client.votePoll(postID: postID, pollName: pollName, options: options)
            if let poll = response.poll { replacePoll(poll, name: pollName) }
            if let vote = response.vote { myPollVotes[pollName] = vote }
        } catch {
            myPollVotes[pollName] = previousVotes
            firstPostPolls = previousPolls
            pluginErrorText = failureText(error)
        }
    }

    func removeVote(pollName: String) async {
        guard let postID = firstPostID, !pollsInFlight.contains(pollName) else { return }
        pollsInFlight.insert(pollName)
        defer { pollsInFlight.remove(pollName) }

        let previousVotes = myPollVotes[pollName]
        let previousPolls = firstPostPolls
        myPollVotes[pollName] = []

        do {
            let response = try await client.removePollVote(postID: postID, pollName: pollName)
            if let poll = response.poll { replacePoll(poll, name: pollName) }
        } catch {
            myPollVotes[pollName] = previousVotes
            firstPostPolls = previousPolls
            pluginErrorText = failureText(error)
        }
    }

    func participateInLottery(quantity: Int, isRandom: Bool) async {
        guard let lottery, !isLotteryBusy else { return }
        isLotteryBusy = true
        defer { isLotteryBusy = false }

        do {
            let response = try await client.participateInLottery(
                lotteryID: lottery.id,
                quantity: quantity,
                isRandom: isRandom
            )
            if response.success == false {
                pluginErrorText = response.error ?? "参与失败。"
                return
            }
            if let updated = response.lottery {
                self.lottery = updated
            } else if let topicID = loadedID {
                // The endpoint doesn't always echo the lottery back; refetch so
                // ticket counts stay truthful.
                await refreshLottery(topicID: topicID)
            }
        } catch {
            pluginErrorText = failureText(error)
        }
    }

    private func replacePoll(_ poll: PostPoll, name: String) {
        if let index = firstPostPolls.firstIndex(where: { $0.pollName == name }) {
            firstPostPolls[index] = poll
        }
    }

    private func refreshLottery(topicID: Int) async {
        guard let topic = try? await client.topic(id: topicID),
              let first = topic.postStream.posts.first
        else { return }
        lottery = first.lottery
    }

    private func failureText(_ error: Error) -> String {
        if case DiscourseError.badResponse(let status) = error {
            switch status {
            case 403: return "没有权限执行该操作。"
            case 422: return "操作被拒绝，可能条件不满足。"
            default: return "操作失败（\(status)）。"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Parsed content

    private static func cacheKey(_ post: TopicPost) -> String {
        "\(post.id)-\(post.version ?? 0)"
    }

    /// Parsed bodies, shared across `TopicStore` instances.
    ///
    /// This used to be a per-instance dictionary that died with the store, so
    /// backing out of a topic and reopening it re-parsed every post from HTML.
    /// The key already carries the post's edit version, so a stale entry can't
    /// outlive an edit. Bounded because a long session visits many topics.
    @MainActor
    final class ParsedContentCache {
        static let shared = ParsedContentCache()

        private let cache = NSCache<NSString, Box>()

        /// NSCache needs a class type; `PostContent` is a struct.
        final class Box {
            let content: PostContent
            init(_ content: PostContent) { self.content = content }
        }

        private init() {
            cache.countLimit = 600
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.cache.removeAllObjects() }
            }
        }

        func content(forKey key: String) -> PostContent? {
            cache.object(forKey: key as NSString)?.content
        }

        func insert(_ content: PostContent, forKey key: String) {
            cache.setObject(Box(content), forKey: key as NSString)
        }
    }

    /// Parses every post body concurrently off the main actor and fills the
    /// cache. Doing this in one pass keeps `nestedComments` synchronous.
    private func parseContents(for posts: [TopicPost]) async {
        let pending = posts.filter { contentCache.content(forKey: Self.cacheKey($0)) == nil }
        guard !pending.isEmpty else { return }

        let parsed = await withTaskGroup(of: (String, PostContent).self) { group in
            for post in pending {
                let key = Self.cacheKey(post)
                let html = post.cooked
                group.addTask { (key, await PostHTMLParser.parse(html)) }
            }
            var results: [String: PostContent] = [:]
            for await (key, value) in group { results[key] = value }
            return results
        }
        for (key, value) in parsed { contentCache.insert(value, forKey: key) }
    }

    private func parsedContent(for post: TopicPost) -> PostContent {
        if let cached = contentCache.content(forKey: Self.cacheKey(post)) { return cached }
        // Fallback for posts that arrived outside `parseContents`.
        let parsed = PostHTMLParser.parseSync(post.cooked)
        contentCache.insert(parsed, forKey: Self.cacheKey(post))
        return parsed
    }

    func loadMoreComments(topicID: Int) async {
        guard self.topicID == topicID, nestedHasMore, !isLoadingMore else { return }
        await loadNested(reset: false)
    }

    /// DFS-flattens the server nested tree into rows, using each post's own
    /// `children` (server order — already sorted) instead of inferring nesting.
    private func buildNestedComments(from roots: [TopicPost]) -> [PostComment] {
        var result: [PostComment] = []

        func append(_ post: TopicPost, parent: TopicPost?, depth: Int, isLast: Bool, trails: [Bool], groupID: Int) {
            let kids = post.children ?? []
            result.append(
                PostComment(
                    id: post.id,
                    author: post.username,
                    time: DiscourseFormat.relative(post.createdAt),
                    content: parsedContent(for: post),
                    redEnvelopeClaim: post.redEnvelopeClaim,
                    votes: post.likeCount,
                    postNumber: post.postNumber ?? 0,
                    replyToPostNumber: post.replyToPostNumber,
                    parentAuthor: quotedParentAuthor(for: parent),
                    parentText: quotedParentText(for: parent),
                    avatarURL: post.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                    nestingDepth: min(depth, 4),
                    isLastSibling: isLast,
                    ancestorTrails: trails,
                    hasChildren: !kids.isEmpty,
                    groupID: groupID
                )
            )
            let nextTrails = trails + [!isLast]
            let last = kids.count - 1
            for (index, kid) in kids.enumerated() {
                append(kid, parent: post, depth: depth + 1, isLast: index == last, trails: nextTrails, groupID: groupID)
            }

            // Actionable when direct replies remain unloaded; the count shown
            // is the whole subtree (matching the web's "N 条回复").
            let directRemaining = (post.directReplyCount ?? 0) - kids.count
            let subtreeRemaining = (post.totalDescendantCount ?? post.directReplyCount ?? 0)
                - subtreeCount(kids)
            if directRemaining > 0, subtreeRemaining > 0, let parentNumber = post.postNumber {
                result.append(
                    PostComment(
                        id: -post.id,
                        author: "",
                        time: "",
                        content: .empty,
                        votes: 0,
                        nestingDepth: min(depth + 1, 4),
                        ancestorTrails: nextTrails,
                        groupID: groupID,
                        isLoadMore: true,
                        loadMoreParent: parentNumber,
                        loadMoreRemaining: subtreeRemaining
                    )
                )
            }
        }

        let lastRoot = roots.count - 1
        for (index, root) in roots.enumerated() {
            append(root, parent: nil, depth: 0, isLast: index == lastRoot, trails: [], groupID: root.postNumber ?? root.id)
        }
        return result
    }

    /// Total posts under these nodes, counted recursively.
    private func subtreeCount(_ posts: [TopicPost]) -> Int {
        posts.reduce(0) { $0 + 1 + subtreeCount($1.children ?? []) }
    }

    private func flatten(_ posts: [TopicPost]) -> [TopicPost] {
        var out: [TopicPost] = []
        func walk(_ post: TopicPost) {
            out.append(post)
            (post.children ?? []).forEach(walk)
        }
        posts.forEach(walk)
        return out
    }

    /// Sends a like for the topic's first post (no-op for guests).
    func like() async {
        guard DiscourseAuth.shared.isAuthenticated, let id = firstPostID else { return }
        try? await client.likePost(id: id)
    }

    /// Posts a reply and reloads the thread. Returns true on success.
    /// Posts a reply and reloads the thread. Returns the new reply's post number
    /// on success (so the reader can scroll to it), or nil on failure.
    func submitReply(_ raw: String, topicID: Int) async -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscourseAuth.shared.isAuthenticated, !trimmed.isEmpty else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let created = try await client.reply(topicID: topicID, raw: trimmed)
            loadedID = nil
            await load(topicID: topicID)
            return created.postNumber
        } catch {
            return nil
        }
    }

    private func nestedComments(from posts: [TopicPost]) -> [PostComment] {
        let replies = Array(posts.dropFirst())
        var postsByNumber: [Int: TopicPost] = [:]
        for post in posts {
            if let postNumber = post.postNumber {
                postsByNumber[postNumber] = post
            }
        }
        let replyNumbers = Set(replies.compactMap(\.postNumber))
        var rootReplies: [TopicPost] = []
        var childrenByParent: [Int: [TopicPost]] = [:]

        for post in replies {
            if let parentNumber = post.replyToPostNumber,
               parentNumber != 1,
               replyNumbers.contains(parentNumber) {
                childrenByParent[parentNumber, default: []].append(post)
            } else {
                rootReplies.append(post)
            }
        }

        // Top-level threads follow the chosen sort; replies within a thread
        // always stay chronological so a conversation reads top to bottom.
        rootReplies.sort(by: replySort.rootComparator)
        for parentNumber in childrenByParent.keys {
            childrenByParent[parentNumber]?.sort { ($0.postNumber ?? 0) < ($1.postNumber ?? 0) }
        }

        var result: [PostComment] = []
        var visited = Set<Int>()

        func append(_ post: TopicPost, depth: Int, isLastSibling: Bool, ancestorTrails: [Bool], groupID: Int) {
            guard !visited.contains(post.id) else { return }
            visited.insert(post.id)

            let parent = post.replyToPostNumber.flatMap { postsByNumber[$0] }
            let childPosts = post.postNumber.map { childrenByParent[$0] ?? [] } ?? []
            result.append(
                PostComment(
                    id: post.id,
                    author: post.username,
                    time: DiscourseFormat.relative(post.createdAt),
                    content: parsedContent(for: post),
                    redEnvelopeClaim: post.redEnvelopeClaim,
                    votes: post.likeCount,
                    postNumber: post.postNumber ?? 0,
                    replyToPostNumber: post.replyToPostNumber,
                    parentAuthor: quotedParentAuthor(for: parent),
                    parentText: quotedParentText(for: parent),
                    avatarURL: post.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                    nestingDepth: min(depth, 4),
                    isLastSibling: isLastSibling,
                    ancestorTrails: ancestorTrails,
                    hasChildren: !childPosts.isEmpty,
                    groupID: groupID
                )
            )

            guard !childPosts.isEmpty else { return }
            let nextTrails = ancestorTrails + [!isLastSibling]
            let lastChildIndex = childPosts.count - 1
            for (index, child) in childPosts.enumerated() {
                append(
                    child,
                    depth: depth + 1,
                    isLastSibling: index == lastChildIndex,
                    ancestorTrails: nextTrails,
                    groupID: groupID
                )
            }
        }

        // Each top-level reply and its descendants are one nest group, keyed by
        // the root reply's post number.
        let lastRootIndex = rootReplies.count - 1
        for (index, root) in rootReplies.enumerated() {
            append(
                root,
                depth: 0,
                isLastSibling: index == lastRootIndex,
                ancestorTrails: [],
                groupID: root.postNumber ?? root.id
            )
        }

        for post in replies where !visited.contains(post.id) {
            append(post, depth: 0, isLastSibling: true, ancestorTrails: [], groupID: post.postNumber ?? post.id)
        }

        return result
    }

    private var remainingPostIDs: [Int] {
        streamPostIDs.filter { !loadedPostIDs.contains($0) }
    }

    private func orderedPosts() -> [TopicPost] {
        guard !streamPostIDs.isEmpty else {
            return allPosts.sorted { ($0.postNumber ?? 0) < ($1.postNumber ?? 0) }
        }

        let postsByID = Dictionary(allPosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = streamPostIDs.compactMap { postsByID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(
            contentsOf: allPosts
                .filter { !orderedIDs.contains($0.id) }
                .sorted { ($0.postNumber ?? 0) < ($1.postNumber ?? 0) }
        )
        return ordered
    }

    private func quotedParentAuthor(for parent: TopicPost?) -> String? {
        guard let parent, parent.postNumber != 1 else { return nil }
        return parent.username
    }

    /// Stays plain text: the quote preview is a single truncated line, and
    /// truncating a parsed block tree correctly is a lot of work for no gain.
    private func quotedParentText(for parent: TopicPost?) -> String? {
        guard let parent, parent.postNumber != 1 else { return nil }
        let text = parsedContent(for: parent).excerpt(limit: 120)
        return text.isEmpty ? nil : text
    }
}
