//
//  TopicStore.swift
//  nodeloc
//
//  Loads a single topic's full body + replies for the post-detail overlay.
//

import Foundation

@MainActor
@Observable
final class TopicStore {
    private let client = DiscourseClient()

    var body = ""
    var comments: [PostComment] = []
    var isLoading = false
    var isLoadingMore = false
    var isSubmitting = false
    var totalReplyCount = 0
    var firstAuthor: UserProfileTarget?
    private(set) var firstPostID: Int?
    private var loadedID: Int?
    private var allPosts: [TopicPost] = []
    private var streamPostIDs: [Int] = []
    private var loadedPostIDs: Set<Int> = []
    private let pageSize = 20

    var hasMoreComments: Bool {
        !remainingPostIDs.isEmpty
    }

    var remainingCommentCount: Int {
        remainingPostIDs.count
    }

    func load(topicID: Int) async {
        guard loadedID != topicID else { return }
        isLoading = true
        body = ""
        comments = []
        totalReplyCount = 0
        firstAuthor = nil
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
            }
            body = DiscourseFormat.plainText(posts.first?.cooked)
            allPosts = posts
            streamPostIDs = topic.postStream.stream ?? posts.map(\.id)
            loadedPostIDs = Set(posts.map(\.id))
            totalReplyCount = max(0, (topic.postsCount ?? streamPostIDs.count) - 1)
            comments = nestedComments(from: orderedPosts())
            loadedID = topicID
        } catch {
            // Leave body/comments empty; the overlay falls back to the list excerpt.
        }
        isLoading = false
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

        func append(_ post: TopicPost, depth: Int, isLastSibling: Bool, ancestorTrails: [Bool]) {
            guard !visited.contains(post.id) else { return }
            visited.insert(post.id)

            let parent = post.replyToPostNumber.flatMap { postsByNumber[$0] }
            let childPosts = post.postNumber.map { childrenByParent[$0] ?? [] } ?? []
            result.append(
                PostComment(
                    id: post.id,
                    author: post.username,
                    time: DiscourseFormat.relative(post.createdAt),
                    text: DiscourseFormat.plainText(post.cooked),
                    votes: post.likeCount,
                    postNumber: post.postNumber ?? 0,
                    replyToPostNumber: post.replyToPostNumber,
                    parentAuthor: quotedParentAuthor(for: parent),
                    parentText: quotedParentText(for: parent),
                    avatarURL: post.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                    nestingDepth: min(depth, 4),
                    isLastSibling: isLastSibling,
                    ancestorTrails: ancestorTrails,
                    hasChildren: !childPosts.isEmpty
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
                    ancestorTrails: nextTrails
                )
            }
        }

        let lastRootIndex = rootReplies.count - 1
        for (index, root) in rootReplies.enumerated() {
            append(root, depth: 0, isLastSibling: index == lastRootIndex, ancestorTrails: [])
        }

        for post in replies where !visited.contains(post.id) {
            append(post, depth: 0, isLastSibling: true, ancestorTrails: [])
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

    private func quotedParentText(for parent: TopicPost?) -> String? {
        guard let parent, parent.postNumber != 1 else { return nil }
        let text = DiscourseFormat.plainText(parent.cooked)
        guard !text.isEmpty else { return nil }
        let preview = String(text.prefix(120))
        return preview == text ? text : "\(preview)..."
    }
}
