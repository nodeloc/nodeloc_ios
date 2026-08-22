//
//  TopicStore.swift
//  nodeloc
//
//  Loads a single topic's full body + replies for the post-detail overlay.
//

import Foundation
import UIKit

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
    private(set) var firstPostID: Int?
    private var loadedID: Int?
    private var allPosts: [TopicPost] = []
    private var streamPostIDs: [Int] = []
    private var loadedPostIDs: Set<Int> = []
    private let pageSize = 20
    /// Parsed bodies keyed by post id + edit version, so scrolling back through
    /// a long topic doesn't re-parse HTML that hasn't changed.
    private let contentCache = ParsedContentCache.shared

    var hasMoreComments: Bool {
        !remainingPostIDs.isEmpty
    }

    var remainingCommentCount: Int {
        remainingPostIDs.count
    }

    func load(topicID: Int) async {
        guard loadedID != topicID else { return }
        isLoading = true
        content = .empty
        comments = []
        totalReplyCount = 0
        firstAuthor = nil
        firstPostPolls = []
        myPollVotes = [:]
        lottery = nil
        redEnvelope = nil
        allPosts = []
        streamPostIDs = []
        loadedPostIDs = []
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
            allPosts = posts
            streamPostIDs = topic.postStream.stream ?? posts.map(\.id)
            loadedPostIDs = Set(posts.map(\.id))
            totalReplyCount = max(0, (topic.postsCount ?? streamPostIDs.count) - 1)

            // Parse off the main actor before touching any @Observable state.
            await parseContents(for: posts)
            content = posts.first.map { parsedContent(for: $0) } ?? .empty
            comments = nestedComments(from: orderedPosts())
            loadedID = topicID
        } catch {
            // Leave content/comments empty; the overlay falls back to the excerpt.
        }
        isLoading = false
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
        guard loadedID == topicID, !isLoadingMore else { return }
        let postIDs = Array(remainingPostIDs.prefix(pageSize))
        guard !postIDs.isEmpty else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await client.topicPosts(topicID: topicID, postIDs: postIDs)
            let newPosts = response.postStream.posts.filter { !loadedPostIDs.contains($0.id) }
            allPosts.append(contentsOf: newPosts)
            loadedPostIDs.formUnion(postIDs)
            // Parse before building the rows, otherwise `nestedComments` falls
            // back to the synchronous parser and stalls the main actor for the
            // whole page of replies.
            await parseContents(for: newPosts)
            comments = nestedComments(from: orderedPosts())
        } catch {
            // Keep the loaded comments visible; the user can retry from the load-more button.
        }
    }

    /// Sends a like for the topic's first post (no-op for guests).
    func like() async {
        guard DiscourseAuth.shared.isAuthenticated, let id = firstPostID else { return }
        try? await client.likePost(id: id)
    }

    /// Posts a reply and reloads the thread. Returns true on success.
    func submitReply(_ raw: String, topicID: Int) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscourseAuth.shared.isAuthenticated, !trimmed.isEmpty else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await client.reply(topicID: topicID, raw: trimmed)
            loadedID = nil
            await load(topicID: topicID)
            return true
        } catch {
            return false
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

        rootReplies.sort { ($0.postNumber ?? 0) < ($1.postNumber ?? 0) }
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
