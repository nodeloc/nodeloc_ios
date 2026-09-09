//
//  VideoFeedStore.swift
//  nodeloc
//
//  Supplies "one more video" for the full-screen player's upward swipe.
//

import Foundation

/// A pool of other people's videos, for the player to page into.
///
/// Source is discourse-anyvideo's own `/anyvideo/videos/suggestions`, which is
/// built for exactly this: it joins its transcoded videos to first posts of
/// visible, regular topics, takes the 60 most recently bumped, and samples ten
/// at random. Walking `latest` for `topic_video_url` — the obvious alternative —
/// finds almost nothing, because a transcoded upload doesn't set that field:
/// 300 topics scanned turned up one video, while this endpoint answers with ten
/// straight away.
///
/// It returns topic metadata only, so each pick costs a second request for the
/// topic itself. That is also what supplies the chrome — author, likes, reply
/// count, and the first post's id so a like can go to the server.
@MainActor
@Observable
final class VideoFeedStore {
    static let shared = VideoFeedStore()

    struct Item: Identifiable {
        let post: Post
        let video: PostVideo
        var id: Int { post.id }
    }

    private let client = DiscourseClient()
    /// Suggested topic ids not yet turned into items.
    private var queue: [Int] = []
    /// Already handed out (or found to hold no playable video), so a session
    /// doesn't loop the same clip.
    private var seenTopicIDs: Set<Int> = []
    /// Shared so two swipes in a row await one request rather than racing.
    private var fetchTask: Task<Void, Never>?

    private init() {}

    /// The next video to show. `excluded` is what's already in the pager.
    func next(excluding excluded: Set<Int>) async -> Item? {
        // Two rounds: the queue can run dry, or every id in it can turn out to
        // be excluded, and either way one refill is worth trying.
        for _ in 0..<2 {
            if let item = await takeNext(excluding: excluded) { return item }
            await refill(excluding: excluded)
        }
        return nil
    }

    private func takeNext(excluding excluded: Set<Int>) async -> Item? {
        while !queue.isEmpty {
            let topicID = queue.removeFirst()
            guard !excluded.contains(topicID), !seenTopicIDs.contains(topicID) else { continue }
            seenTopicIDs.insert(topicID)
            if let item = await item(forTopicID: topicID) { return item }
            // No playable video in the first post after all (the upload could
            // have been removed since the join ran); try the next id.
        }
        return nil
    }

    private func refill(excluding excluded: Set<Int>) async {
        if let fetchTask { return await fetchTask.value }
        let task = Task { [excluded] in await fetchSuggestions(excluding: excluded) }
        fetchTask = task
        await task.value
        fetchTask = nil
    }

    private func fetchSuggestions(excluding excluded: Set<Int>) async {
        // The plugin can drop one topic server-side; the rest are filtered when
        // taken. Passing the video on screen is the useful one.
        let response = try? await client.videoSuggestions(excludingTopicID: excluded.first)
        let ids = (response?.topics ?? [])
            .map(\.id)
            .filter { !seenTopicIDs.contains($0) && !excluded.contains($0) }
        guard !ids.isEmpty else { return }
        queue.append(contentsOf: ids.filter { !queue.contains($0) })
    }

    /// Turns a suggested topic into something the player can show: the video out
    /// of its first post's cooked HTML, plus the chrome around it.
    private func item(forTopicID topicID: Int) async -> Item? {
        guard let topic = try? await client.topic(id: topicID),
              let firstPost = topic.postStream.posts.first
        else { return nil }

        let content = await PostHTMLParser.parse(firstPost.cooked)
        guard let video = content.videos.first else { return nil }

        var node: SidebarNodeSummary?
        if let categoryID = topic.categoryId {
            node = await NodeCatalog.shared.node(id: categoryID)
        }
        let post = Post(
            id: topic.id,
            node: node.map { "n/\($0.slug)" } ?? "n/nodeloc",
            avatarLetter: String((firstPost.username ?? "N").prefix(1)).uppercased(),
            variant: topic.id % 2,
            time: DiscourseFormat.relative(firstPost.createdAt),
            title: topic.title,
            excerpt: "",
            baseVotes: firstPost.likeCount,
            // discourse-vote, so a recommendation gets the same up/score/down
            // control as the topic it came from rather than a bare like.
            voteScore: firstPost.voteScore,
            voteDirection: firstPost.voteDirection ?? .none,
            canVoteDown: firstPost.canVoteDown ?? false,
            opPostID: firstPost.id,
            comments: max(0, (topic.postsCount ?? 1) - 1),
            hasImage: false,
            avatarURL: firstPost.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 120) },
            authorUsername: firstPost.username,
            authorName: firstPost.name,
            videoURL: PostInlineRenderer.resolvedLink(video.src)
        )
        return Item(post: post, video: video)
    }
}
