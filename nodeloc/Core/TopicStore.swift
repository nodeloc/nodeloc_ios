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
        case .oldest: return AppString("最早回复")
        case .newest: return AppString("最新回复")
        case .mostLiked: return AppString("最多点赞")
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
        case .oldest: return AppString("按发布时间从早到晚")
        case .newest: return AppString("最新的回复在前")
        case .mostLiked: return AppString("点赞最多的在前")
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
    /// OP author's worn title and flair badge.
    var firstAuthorTitle: String?
    /// discourse-custom-badge styles for the 头衔 worn in this topic, keyed by
    /// the title text. Resolved here rather than per row: the catalog is an
    /// actor, and one lookup per visible reply would be an await inside every
    /// cell for a value that repeats across posts by the same group.
    private(set) var titleStyles: [String: TitleStyle] = [:]
    /// The OP's 小尾巴 from discourse-mobile, shown beside its timestamp.
    var firstPostSource: String?
    /// When the OP was *written*. The `Post` a list hands over carries the
    /// topic's bump time — right for a feed row, which sorts by activity, wrong
    /// for the author line of the first post.
    var firstPostTime: String?
    /// Bodies fetched back for replies the server blanked because their author
    /// is on this viewer's ignore list. Kept beside the posts rather than folded
    /// into them: `TopicPost.cooked` is a `let`, and rebuilding a 40-field DTO
    /// to patch one string is worse than a lookup at row-build time.
    private var revealedContent: [Int: PostContent] = [:]
    /// Replies whose reveal is in flight, so the row can show a spinner.
    private(set) var revealingPostIDs: Set<Int> = []
    /// Replies this topic has pinned. The nested endpoint reports the whole set
    /// rather than a flag per post, and already returns a pinned root first.
    private(set) var pinnedPostIDs: Set<Int> = []
    /// The viewer's permissions on the topic and the OP, straight from the
    /// server. Absent flags mean "no", which is how a node moderator's rights
    /// stay inside their node without the app knowing the boundary.
    private(set) var canEditTopic = false
    private(set) var canDeleteTopic = false
    private(set) var canCloseTopic = false
    private(set) var canPinTopic = false
    private(set) var canEditFirstPost = false
    private(set) var canDeleteFirstPost = false
    private(set) var isTopicClosed = false
    /// Discourse features a topic three different ways, and they are not
    /// interchangeable: a node pin tops one node's lists, a global pin tops
    /// every list, and a banner floats above every page. On top of that each
    /// reader may clear a pin for themselves. All four states live here.
    private(set) var isTopicPinned = false
    private(set) var isTopicPinnedGlobally = false
    private(set) var topicPinnedUntil: Date?
    /// The pin is in place but this reader dismissed it (`unpinned`).
    private(set) var isPinClearedForMe = false
    private(set) var isTopicBanner = false
    private(set) var canBannerTopic = false
    private(set) var topicCategoryID: Int?
    private(set) var topicTitle = ""
    /// The topic's slug, so links built for sharing or reposting are the
    /// canonical `/t/{slug}/{id}` rather than the id-only redirect.
    private(set) var topicSlug: String?
    var firstAuthorFlairURL: URL?
    /// Whether the current user has liked the OP.
    var firstPostLikedByMe = false
    /// The OP's reaction tally, for the summary beside its actions.
    private(set) var firstPostReactions: [PostReaction] = []
    /// discourse-vote on the OP. Nil score means voting doesn't apply here.
    private(set) var firstPostVoteScore: Int?
    private(set) var firstPostVoteDirection: VoteDirection = .none
    private(set) var firstPostCanVoteDown = false
    /// The OP's like count (kept here so the toggle can update it live).
    var firstPostLikeCount = 0
    /// Rewards the OP has received (for the 打赏 total + detail sheet).
    var firstPostRewards: [PostReward] = []
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
        // Only a *different* topic gets cleared. Reloading the one already on
        // screen — what posting a reply does — used to empty `content` and
        // `comments` first, which pulled the whole scroll content out from
        // under a reader who was scrolled into the thread: the offset survived
        // the collapse and the page came back blank. Refreshing in place keeps
        // what's on screen until there's something newer to replace it with.
        let isRefresh = self.topicID == topicID
        self.topicID = topicID
        isLoading = true
        if !isRefresh {
            content = .empty
            comments = []
            totalReplyCount = 0
            firstAuthor = nil
            firstAuthorTitle = nil
            titleStyles = [:]
            firstPostSource = nil
            firstPostTime = nil
            pinnedPostIDs = []
            revealedContent = [:]
            revealingPostIDs = []
            canEditTopic = false
            canDeleteTopic = false
            canCloseTopic = false
            canPinTopic = false
            canBannerTopic = false
            canEditFirstPost = false
            canDeleteFirstPost = false
            firstAuthorFlairURL = nil
            firstPostLikedByMe = false
            firstPostReactions = []
            firstPostVoteScore = nil
            firstPostVoteDirection = .none
            firstPostCanVoteDown = false
            firstPostLikeCount = 0
            firstPostRewards = []
            firstPostPolls = []
            myPollVotes = [:]
            lottery = nil
            redEnvelope = nil
            nestedRoots = []
        }
        do {
            let topic = try await client.topic(id: topicID)
            let posts = topic.postStream.posts
            firstPostID = posts.first?.id
            if let firstPost = posts.first {
                firstAuthor = UserProfileTarget(
                    // The OP always has one; only the nested view's deleted-reply
                    // stub omits it.
                    username: firstPost.username ?? "",
                    displayName: firstPost.name,
                    avatarURL: firstPost.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 120) }
                )
                firstPostPolls = firstPost.polls ?? []
                myPollVotes = firstPost.pollsVotes ?? [:]
                lottery = firstPost.lottery
                firstAuthorTitle = firstPost.userTitle
                firstPostSource = firstPost.mobileSource
                firstPostTime = DiscourseFormat.relative(firstPost.createdAt)
                canEditFirstPost = firstPost.canEdit ?? false
                canDeleteFirstPost = firstPost.canDelete ?? false
                firstAuthorFlairURL = Self.flairImageURL(firstPost.flairUrl)
                firstPostLikedByMe = firstPost.likedByMe
                firstPostReactions = firstPost.reactions ?? []
                firstPostVoteScore = firstPost.voteScore
                firstPostVoteDirection = Self.direction(for: firstPost)
                firstPostCanVoteDown = firstPost.canVoteDown ?? false
                firstPostLikeCount = firstPost.likeCount
                firstPostRewards = firstPost.rewards ?? []
            }
            redEnvelope = topic.redEnvelope
            totalReplyCount = max(0, (topic.postsCount ?? 1) - 1)
            // Localized when a translation exists; `title` is never rewritten.
            topicTitle = DiscourseFormat.displayTitle(
                title: topic.title,
                fancyTitle: topic.fancyTitle,
                isLocalized: topic.fancyTitleLocalized
            )
            topicSlug = topic.slug
            // `firstAuthorTitle` is already set above, and unlike `firstPost`
            // it's in scope here.
            await resolveTitleStyles(for: [firstAuthorTitle].compactMap { $0 })
            isTopicClosed = topic.closed ?? false
            // `pinned_at`, not `pinned`: the latter is already filtered by this
            // reader's own dismissal, so a moderator who cleared the pin for
            // themselves would be offered 置顶 on a topic that is pinned.
            isTopicPinned = topic.pinnedAt != nil
            isTopicPinnedGlobally = topic.pinnedGlobally ?? false
            topicPinnedUntil = DiscourseFormat.date(topic.pinnedUntil)
            isPinClearedForMe = topic.unpinned ?? false
            isTopicBanner = topic.archetype == "banner"
            topicCategoryID = topic.categoryId
            let details = topic.details
            canEditTopic = details?.canEdit ?? false
            canDeleteTopic = details?.canDelete ?? false
            canCloseTopic = details?.canCloseTopic ?? details?.canModerate ?? false
            canPinTopic = details?.canPinUnpinTopic ?? false
            canBannerTopic = details?.canBannerTopic ?? false

            // Parse the OP off the main actor before touching @Observable state.
            await parseContents(for: posts)
            // Only when there is one: a response without posts shouldn't blank
            // a body that's already rendered.
            if let firstPost = posts.first {
                content = parsedContent(for: firstPost)
            }
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
            if let pinned = response.pinnedPostIds { pinnedPostIDs = Set(pinned) }
            if reset { nestedRoots = roots } else { nestedRoots.append(contentsOf: roots) }
            nestedHasMore = response.hasMoreRoots?.value ?? false
            await parseContents(for: flatten(nestedRoots))
            comments = buildNestedComments(from: nestedRoots)
            await resolveTitleStyles(for: flatten(nestedRoots).compactMap(\.userTitle))
        } catch {
            // Deliberately keeps whatever is already on screen. Emptying the
            // rows here meant one failed refresh — a 429 right after posting is
            // the easy way to get one — replaced a perfectly good thread with a
            // blank page.
            if reset, nestedRoots.isEmpty { comments = [] }
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
                pluginErrorText = response.error ?? AppString("参与失败。")
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
        if case DiscourseError.badResponse(let status, _) = error {
            switch status {
            case 403: return AppString("没有权限执行该操作。")
            case 422: return AppString("操作被拒绝，可能条件不满足。")
            default: return AppString("操作失败（\(status)）。")
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Parsed content

    /// Keyed on the cooked HTML itself, not only the edit version.
    ///
    /// The version alone assumes the server renders one body per post, which
    /// discourse-permission breaks: a 回复可见 section is rendered for a viewer
    /// who has replied and withheld from one who hasn't, at the *same* version
    /// — replying changes nothing about the post, only about the reader. So a
    /// version-keyed entry kept handing back the locked parse even after the
    /// unlocked HTML had been fetched, and because this cache outlives the
    /// store, leaving the topic and coming back didn't clear it either.
    ///
    /// Hashing the body covers every such case at once — permissions, and
    /// anything else that renders per-viewer — rather than naming them.
    /// `hashValue` is seeded per process, which is fine: this cache is
    /// in-memory and dies with the process.
    private static func cacheKey(_ post: TopicPost) -> String {
        "\(post.id)-\(post.version ?? 0)-\(post.cooked.hashValue)"
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
                    author: post.username ?? "",
                    time: DiscourseFormat.relative(post.createdAt),
                    content: revealedContent[post.id] ?? parsedContent(for: post),
                    redEnvelopeClaim: post.redEnvelopeClaim,
                    votes: post.likeCount,
                    postNumber: post.postNumber ?? 0,
                    replyToPostNumber: post.replyToPostNumber,
                    parentAuthor: quotedParentAuthor(for: parent),
                    parentText: quotedParentText(for: parent),
                    avatarURL: post.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                    nestingDepth: min(depth, 8),
                    isLastSibling: isLast,
                    ancestorTrails: trails,
                    hasChildren: !kids.isEmpty,
                    groupID: groupID,
                    authorTitle: post.userTitle,
                    flairURL: Self.flairImageURL(post.flairUrl),
                    isLiked: post.likedByMe,
                    reactions: post.reactions ?? [],
                    voteScore: post.voteScore,
                    voteDirection: Self.direction(for: post),
                    canVoteDown: post.canVoteDown ?? false,
                    rewards: post.rewards ?? [],
                    mobileSource: post.mobileSource,
                    isPinned: pinnedPostIDs.contains(post.id),
                    isDeletedPlaceholder: post.deletedPostPlaceholder ?? false,
                    // Revealing replaces the placeholder with the real reply.
                    isIgnoredPlaceholder: (post.ignoredPostPlaceholder ?? false)
                        && revealedContent[post.id] == nil,
                    isRevealing: revealingPostIDs.contains(post.id),
                    canRecover: post.canRecover ?? false,
                    canEdit: post.canEdit ?? false,
                    canDelete: post.canDelete ?? false,
                    isMine: post.yours ?? false
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
                        nestingDepth: min(depth + 1, 8),
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

    /// Toggles the like on the topic's first post (like ↔ unlike), optimistically
    /// updating the count. No-op for guests.
    func toggleFirstPostLike() async {
        guard DiscourseAuth.shared.isAuthenticated, let id = firstPostID else { return }
        let wasLiked = firstPostLikedByMe
        firstPostLikedByMe.toggle()
        firstPostLikeCount += wasLiked ? -1 : 1
        do {
            if wasLiked { try await client.unlikePost(id: id) }
            else { try await client.likePost(id: id) }
        } catch {
            firstPostLikedByMe = wasLiked
            firstPostLikeCount += wasLiked ? 1 : -1
            ToastCenter.shared.showError(error)
        }
    }

    /// Posts a reply and reloads the thread. Returns true on success.
    /// Posts a reply and reloads the thread. Returns the new reply's post number
    /// on success (so the reader can scroll to it), or nil on failure.
    func submitReply(_ raw: String, topicID: Int, replyToPostNumber: Int? = nil) async -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscourseAuth.shared.isAuthenticated, !trimmed.isEmpty else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let created = try await client.reply(topicID: topicID, raw: trimmed, replyToPostNumber: replyToPostNumber)
            if let id = created.id {
                await insertPostedReply(
                    id: id,
                    topicID: topicID,
                    replyToPostNumber: replyToPostNumber
                )
            }
            await unlockReplyGatedContent(topicID: topicID)
            return created.postNumber
        } catch {
            ToastCenter.shared.showError(error)
            return nil
        }
    }

    /// Re-fetches the bodies that replying just unlocked.
    ///
    /// discourse-permission decides 回复可见 on the server, so posting a reply
    /// changes what the server *would* render without changing anything about
    /// the copy on screen — the section stayed locked until something asked for
    /// the body again.
    ///
    /// Only the posts that actually carry a reply lock are re-fetched: usually
    /// the OP alone, and on most topics none at all. That keeps
    /// `insertPostedReply`'s promise below — the row array isn't swapped out
    /// from under a reader who is scrolled into it — while still letting a
    /// reply's own gated section unlock, which rides the `revealedContent`
    /// override rather than needing the tree rebuilt.
    private func unlockReplyGatedContent(topicID: Int) async {
        var ids: [Int] = []
        if content.hasReplyLockedContent, let firstPostID {
            ids.append(firstPostID)
        }
        ids.append(contentsOf: comments.filter(\.content.hasReplyLockedContent).map(\.id))
        guard !ids.isEmpty else { return }

        guard let response = try? await client.topicPosts(topicID: topicID, postIDs: ids) else { return }
        let posts = response.postStream.posts
        // Re-parses rather than hitting the cache, because the unlocked HTML
        // hashes differently — see `cacheKey`.
        await parseContents(for: posts)

        for post in posts {
            if post.id == firstPostID {
                content = parsedContent(for: post)
            } else {
                revealedContent[post.id] = parsedContent(for: post)
            }
        }
        comments = buildNestedComments(from: nestedRoots)
    }

    /// Splices a just-posted reply into the thread already on screen, instead of
    /// re-fetching it.
    ///
    /// Re-fetching was the whole problem. Every earlier version of this — `load`
    /// from page 0, then all loaded pages — replaced the entire row array under
    /// a `LazyVStack` the reader was scrolled deep into. The rows come back in
    /// server sort order, so on a busy topic (or any `top` sort) plenty of them
    /// move; the offset that was valid before the swap points nowhere after it,
    /// and the page renders blank. It got worse the more replies a topic had,
    /// because that is when the offset is furthest from anything still present.
    ///
    /// This is what other clients do: the reply you just wrote is one row, so
    /// insert one row. Every existing row keeps its identity and position, which
    /// makes the change a single insertion for SwiftUI to diff and leaves the
    /// scroll offset meaning what it meant a moment ago.
    private func insertPostedReply(
        id: Int,
        topicID: Int,
        replyToPostNumber: Int?
    ) async {
        // The count is known without asking, and the red envelope isn't: a reply
        // claims one, so the banner's remaining count moves.
        totalReplyCount += 1
        if redEnvelope != nil, let topic = try? await client.topic(id: topicID) {
            redEnvelope = topic.redEnvelope
        }

        // Fetched rather than assembled: this is the server's own row, with the
        // cooked body, avatar and 小尾巴 already on it. One post, not a page.
        guard let response = try? await client.topicPosts(topicID: topicID, postIDs: [id]),
              let post = response.postStream.posts.first(where: { $0.id == id }) else { return }

        await parseContents(for: [post])

        let parentNumber = replyToPostNumber.flatMap { $0 > 1 ? $0 : nil }
        if let parentNumber, attach(post, under: parentNumber, in: &nestedRoots) {
            // Nested under the post it answers.
        } else if replySort == .newest {
            nestedRoots.insert(post, at: 0)
        } else {
            nestedRoots.append(post)
        }

        comments = buildNestedComments(from: nestedRoots)
    }

    /// Hangs a reply off its parent, wherever that parent sits in the tree.
    /// Returns whether it found one — a reply written from a visible row always
    /// has its parent loaded, but a caller shouldn't have to assume that.
    private func attach(
        _ post: TopicPost,
        under parentNumber: Int,
        in nodes: inout [TopicPost]
    ) -> Bool {
        for index in nodes.indices {
            if nodes[index].postNumber == parentNumber {
                var children = nodes[index].children ?? []
                children.append(post)
                nodes[index].children = children
                return true
            }
            var children = nodes[index].children ?? []
            if !children.isEmpty, attach(post, under: parentNumber, in: &children) {
                nodes[index].children = children
                return true
            }
        }
        return false
    }

    /// Where a post's vote stands, as the server reports it.
    ///
    /// Not inferred any more: since a vote became a reaction, a downvote is a
    /// reaction excluded from likes, so `likedByMe` is false for it and the old
    /// derivation read every downvote as no vote at all. The fallback only
    /// covers a payload with no `vote_direction`, where a like is still an
    /// upvote.
    private static func direction(for post: TopicPost) -> VoteDirection {
        post.voteDirection ?? (post.likedByMe ? .up : .none)
    }

    /// Casts or retracts a vote on any post in this topic, OP included.
    ///
    /// Applied locally first, then reconciled from the server's own numbers
    /// rather than by arithmetic: switching from down to up moves the score by
    /// two, and the plugin already knows that.
    func vote(_ direction: VoteDirection, postID: Int, reaction: String? = nil) async {
        guard let topicID else { return }
        let isFirstPost = postID == firstPostID

        // Optimistic.
        if isFirstPost {
            firstPostVoteScore = Self.applied(direction, from: firstPostVoteDirection, to: firstPostVoteScore)
            firstPostVoteDirection = direction
            firstPostLikedByMe = direction == .up
        } else if let index = comments.firstIndex(where: { $0.id == postID }) {
            comments[index].voteScore = Self.applied(
                direction,
                from: comments[index].voteDirection,
                to: comments[index].voteScore
            )
            comments[index].voteDirection = direction
            comments[index].isLiked = direction == .up
        }

        do {
            try await client.castVote(postID: postID, direction: direction, reaction: reaction)
            // Re-read the one post so the score is the server's.
            if isFirstPost {
                if let response = try? await client.topicPosts(topicID: topicID, postIDs: [postID]),
                   let post = response.postStream.posts.first {
                    firstPostVoteScore = post.voteScore
                    firstPostVoteDirection = Self.direction(for: post)
                    firstPostLikeCount = post.likeCount
                    // A vote is a reaction, so the summary moves with it.
                    firstPostReactions = post.reactions ?? []
                }
            } else {
                await replacePost(id: postID, topicID: topicID)
            }
        } catch {
            ToastCenter.shared.showError(error)
            // Put the row back the way the server last described it.
            if isFirstPost {
                if let response = try? await client.topicPosts(topicID: topicID, postIDs: [postID]),
                   let post = response.postStream.posts.first {
                    firstPostVoteScore = post.voteScore
                    firstPostVoteDirection = Self.direction(for: post)
                    firstPostLikedByMe = post.likedByMe
                }
            } else {
                await replacePost(id: postID, topicID: topicID)
            }
        }
    }

    private static func applied(_ target: VoteDirection, from current: VoteDirection, to score: Int?) -> Int? {
        guard let score else { return nil }
        func weight(_ direction: VoteDirection) -> Int {
            switch direction {
            case .up: return 1
            case .down: return -1
            case .none: return 0
            }
        }
        return score + weight(target) - weight(current)
    }

    /// The canonical URL for this topic.
    func url(forTopicID id: Int) -> URL {
        guard let topicSlug, !topicSlug.isEmpty else {
            return DiscourseConfig.baseURL.appending(path: "t/\(id)")
        }
        return DiscourseConfig.baseURL.appending(path: "t/\(topicSlug)/\(id)")
    }

    /// The design for one title, if the plugin has one.
    func titleStyle(for title: String?) -> TitleStyle? {
        guard let title else { return nil }
        return titleStyles[title.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Looks up the styles for titles this topic actually shows, skipping any
    /// already resolved. `TitleStyleCatalog` caches the whole set after its
    /// first load, so this is one await and no request on later topics.
    private func resolveTitleStyles(for titles: [String]) async {
        let pending = Set(
            titles
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && titleStyles[$0] == nil }
        )
        guard !pending.isEmpty else { return }

        var resolved = titleStyles
        for title in pending {
            if let style = await TitleStyleCatalog.shared.style(forTitle: title) {
                resolved[title] = style
            }
        }
        titleStyles = resolved
    }

    // MARK: Editing & moderation

    /// The markdown behind a post, for the editor to start from.
    func rawBody(postID: Int) async -> String? {
        (try? await client.postRaw(id: postID))?.raw
    }

    /// Saves an edited body. Refetches just that post so the rendered version
    /// on screen is the server's, not a local guess at how it cooks.
    func saveEdit(postID: Int, raw: String) async -> Bool {
        guard let topicID else { return false }
        do {
            try await client.updatePost(id: postID, raw: raw)
            if postID == firstPostID {
                if let response = try? await client.topicPosts(topicID: topicID, postIDs: [postID]),
                   let post = response.postStream.posts.first {
                    await parseContents(for: [post])
                    content = parsedContent(for: post)
                }
            } else {
                await replacePost(id: postID, topicID: topicID)
            }
            ToastCenter.shared.show(AppString("已保存修改"))
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// Removes a reply from the thread. Deleting the OP deletes the topic, so
    /// that is a separate action with its own confirmation.
    func deletePost(id: Int) async -> Bool {
        do {
            try await client.deletePost(id: id)
            // Dropped locally rather than refetched: the row is gone either
            // way, and a refetch would rebuild the whole list under the
            // reader's scroll position.
            remove(postID: id, from: &nestedRoots)
            comments = buildNestedComments(from: nestedRoots)
            totalReplyCount = max(0, totalReplyCount - 1)
            ToastCenter.shared.show(AppString("已删除"))
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// Undeletes a reply staff had deleted. Offered only where the server said
    /// `can_recover`, and the row is re-fetched afterwards so it stops being a
    /// placeholder — one post, spliced in place, so nobody's scroll moves.
    func recoverPost(id: Int) async {
        guard let topicID else { return }
        do {
            try await client.recoverPost(id: id)
            await replacePost(id: id, topicID: topicID)
            totalReplyCount += 1
            ToastCenter.shared.show(AppString("已恢复该回复"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Fetches back the body of a reply whose author this viewer ignores. The
    /// nested view sends `cooked: ""` for those; `/posts/{id}/cooked.json` is
    /// where the web's own reveal button gets it from.
    func revealIgnored(postID: Int) async {
        guard revealedContent[postID] == nil, !revealingPostIDs.contains(postID) else { return }
        revealingPostIDs.insert(postID)
        defer {
            revealingPostIDs.remove(postID)
            comments = buildNestedComments(from: nestedRoots)
        }
        do {
            let response = try await client.postCooked(id: postID)
            revealedContent[postID] = await PostHTMLParser.parse(response.cooked)
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    func deleteTopic() async -> Bool {
        guard let topicID else { return false }
        do {
            try await client.deleteTopic(id: topicID)
            ToastCenter.shared.show(AppString("主题已删除"))
            return true
        } catch {
            ToastCenter.shared.showError(error)
            return false
        }
    }

    /// 关闭 / 重新开放. Applied locally first so the menu's label flips at once.
    func toggleClosed() async {
        guard let topicID else { return }
        let target = !isTopicClosed
        isTopicClosed = target
        do {
            try await client.setTopicStatus(id: topicID, status: "closed", enabled: target)
            ToastCenter.shared.show(target ? AppString("主题已关闭") : AppString("主题已重新开放"))
        } catch {
            isTopicClosed = !target
            ToastCenter.shared.showError(error)
        }
    }

    /// Pins the topic, to its node or to every list.
    ///
    /// `until` is open-ended when omitted, matching the web modal's empty date
    /// field. A global pin is a different *status*, not a flag on the same one,
    /// because the server reads the status name to decide `pinned_globally`.
    func pinTopic(globally: Bool, until: Date?) async {
        guard let topicID else { return }
        let previous = (isTopicPinned, isTopicPinnedGlobally, topicPinnedUntil)
        isTopicPinned = true
        isTopicPinnedGlobally = globally
        topicPinnedUntil = until
        // Pinning afresh also revives it for a reader who had cleared the old
        // pin: `cleared_pinned_at` is compared against `pinned_at`, which just
        // moved to now.
        isPinClearedForMe = false
        do {
            try await client.setTopicStatus(
                id: topicID,
                status: globally ? "pinned_globally" : "pinned",
                enabled: true,
                until: until
            )
            ToastCenter.shared.show(globally ? AppString("已全站置顶") : AppString("已在节点内置顶"))
        } catch {
            (isTopicPinned, isTopicPinnedGlobally, topicPinnedUntil) = previous
            ToastCenter.shared.showError(error)
        }
    }

    /// Removes the pin for everyone. `update_pinned` clears `pinned_globally`
    /// along with `pinned_at`, so the plain "pinned" status undoes a global pin
    /// too — the same single call the web's unpin button makes.
    func unpinTopic() async {
        guard let topicID else { return }
        let previous = (isTopicPinned, isTopicPinnedGlobally, topicPinnedUntil)
        isTopicPinned = false
        isTopicPinnedGlobally = false
        topicPinnedUntil = nil
        do {
            try await client.setTopicStatus(id: topicID, status: "pinned", enabled: false)
            ToastCenter.shared.show(AppString("已取消置顶"))
        } catch {
            (isTopicPinned, isTopicPinnedGlobally, topicPinnedUntil) = previous
            ToastCenter.shared.showError(error)
        }
    }

    /// Hides or restores the pin for the current reader alone. Needs no
    /// permission beyond being able to see the topic.
    func setPinClearedForMe(_ cleared: Bool) async {
        guard let topicID else { return }
        isPinClearedForMe = cleared
        do {
            if cleared {
                try await client.clearTopicPin(id: topicID)
            } else {
                try await client.reTopicPin(id: topicID)
            }
            ToastCenter.shared.show(cleared ? AppString("已对我取消置顶") : AppString("已恢复置顶"))
        } catch {
            isPinClearedForMe = !cleared
            ToastCenter.shared.showError(error)
        }
    }

    /// 横幅: floats above every page until each reader dismisses it. Only one
    /// exists site-wide, so setting a new banner replaces the old one.
    func toggleBanner() async {
        guard let topicID else { return }
        let target = !isTopicBanner
        isTopicBanner = target
        do {
            if target {
                try await client.makeTopicBanner(id: topicID)
            } else {
                try await client.removeTopicBanner(id: topicID)
            }
            ToastCenter.shared.show(target ? AppString("已设为横幅主题") : AppString("已取消横幅"))
        } catch {
            isTopicBanner = !target
            ToastCenter.shared.showError(error)
        }
    }

    /// How full the featured slots are, for the 置顶 sheet's counts. Failure is
    /// silent: the counts are advisory, and the buttons work without them.
    func featureStats() async -> TopicFeatureStats? {
        try? await client.topicFeatureStats(categoryID: topicCategoryID)
    }

    /// Re-reads one reply and swaps it in place, keeping every other row's
    /// identity — the same reason posting splices instead of refetching.
    private func replacePost(id: Int, topicID: Int) async {
        guard let response = try? await client.topicPosts(topicID: topicID, postIDs: [id]),
              let fresh = response.postStream.posts.first(where: { $0.id == id }) else { return }
        await parseContents(for: [fresh])
        _ = replace(fresh, in: &nestedRoots)
        comments = buildNestedComments(from: nestedRoots)
    }

    private func replace(_ post: TopicPost, in nodes: inout [TopicPost]) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == post.id {
                var updated = post
                // Keep the children already loaded under it; the single-post
                // fetch doesn't carry them.
                updated.children = nodes[index].children
                nodes[index] = updated
                return true
            }
            var children = nodes[index].children ?? []
            if !children.isEmpty, replace(post, in: &children) {
                nodes[index].children = children
                return true
            }
        }
        return false
    }

    private func remove(postID: Int, from nodes: inout [TopicPost]) {
        nodes.removeAll { $0.id == postID }
        for index in nodes.indices {
            var children = nodes[index].children ?? []
            guard !children.isEmpty else { continue }
            remove(postID: postID, from: &children)
            nodes[index].children = children
        }
    }

    /// Pins or unpins a top-level reply. Staff only, and only for a root reply —
    /// the same two conditions the web menu applies before offering it.
    ///
    /// The server answers with the topic's whole pinned set, so this replaces
    /// rather than patches, then hoists the pinned root to the front the way the
    /// site does: a later fetch would have it first anyway.
    func togglePin(postID: Int) async {
        guard let topicID, DiscourseAuth.shared.isStaff else { return }
        guard nestedRoots.contains(where: { $0.id == postID }) else { return }

        do {
            let response = try await client.togglePinnedPost(topicID: topicID, postID: postID)
            pinnedPostIDs = Set(response.pinnedPostIds ?? [])
            if pinnedPostIDs.contains(postID),
               let index = nestedRoots.firstIndex(where: { $0.id == postID }), index > 0 {
                let pinned = nestedRoots.remove(at: index)
                nestedRoots.insert(pinned, at: 0)
            }
            comments = buildNestedComments(from: nestedRoots)
            ToastCenter.shared.show(pinnedPostIDs.contains(postID) ? AppString("已置顶该回复") : AppString("已取消置顶"))
        } catch {
            ToastCenter.shared.showError(error)
        }
    }

    /// Whether this reply can be pinned at all: a root reply, and the viewer is
    /// staff. Nested replies and the OP are never pinnable.
    func canPin(_ comment: PostComment) -> Bool {
        guard DiscourseAuth.shared.isStaff, !comment.isLoadMore else { return false }
        return nestedRoots.contains { $0.id == comment.id }
    }

    /// Toggles the like on a reply (like ↔ unlike), optimistically updating the
    /// row's count so the heart responds immediately.
    func toggleReplyLike(id: Int) async {
        guard DiscourseAuth.shared.isAuthenticated,
              let index = comments.firstIndex(where: { $0.id == id }) else { return }
        let wasLiked = comments[index].isLiked
        comments[index].isLiked.toggle()
        comments[index].votes += wasLiked ? -1 : 1
        do {
            if wasLiked { try await client.unlikePost(id: id) }
            else { try await client.likePost(id: id) }
        } catch {
            guard let now = comments.firstIndex(where: { $0.id == id }) else { return }
            comments[now].isLiked = wasLiked
            comments[now].votes += wasLiked ? 1 : -1
            ToastCenter.shared.showError(error)
        }
    }

    /// 打赏 — gives energy to a post via discourse-reward, then reloads so the
    /// new reward total shows.
    func giveReward(postID: Int, amount: Int, note: String?) async throws {
        try await client.giveReward(postID: postID, amount: amount, note: note)
        if let id = loadedID {
            loadedID = nil
            await load(topicID: id)
        }
    }

    /// 屏蔽作者 — through `BlockedUsersStore`, so the block also hides the
    /// author's rows in every list and tells the moderators about the post
    /// (guideline 1.2). Reloads afterwards so this reader sees it land here
    /// too: the author's replies come back as ignored placeholders instead of
    /// staying on screen until the topic is reopened.
    func blockAuthor(username: String, reportingPostID: Int?) async {
        await BlockedUsersStore.shared.blockAndConfirm(
            username: username,
            reportingPostID: reportingPostID
        )
        if let id = loadedID {
            loadedID = nil
            await load(topicID: id)
        }
    }

    /// 保存书签 — bookmarks a post.
    func bookmark(postID: Int) async throws {
        try await client.bookmark(postID: postID)
    }

    /// Repost — republishes this topic into another node via discourse-community.
    func repost(topicID: Int, categoryID: Int, title: String) async throws {
        try await client.repost(topicID: topicID, categoryID: categoryID, title: title)
    }

    /// Discourse's `flair_url` is either an image path/URL or a bare Font
    /// Awesome icon name (e.g. "gem"). Only the former is fetchable — feeding
    /// an icon name to the image loader produced -1002 "unsupported URL"
    /// requests for literally "gem".
    private static func flairImageURL(_ raw: String?) -> URL? {
        guard let raw, raw.hasPrefix("/") || raw.hasPrefix("http") else { return nil }
        return NodeSummaryFactory.resolvedURL(raw)
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
                    author: post.username ?? "",
                    time: DiscourseFormat.relative(post.createdAt),
                    content: parsedContent(for: post),
                    redEnvelopeClaim: post.redEnvelopeClaim,
                    votes: post.likeCount,
                    postNumber: post.postNumber ?? 0,
                    replyToPostNumber: post.replyToPostNumber,
                    parentAuthor: quotedParentAuthor(for: parent),
                    parentText: quotedParentText(for: parent),
                    avatarURL: post.avatarTemplate.flatMap { client.avatarURL(template: $0, size: 80) },
                    nestingDepth: min(depth, 8),
                    isLastSibling: isLastSibling,
                    ancestorTrails: ancestorTrails,
                    hasChildren: !childPosts.isEmpty,
                    groupID: groupID,
                    mobileSource: post.mobileSource,
                    isDeletedPlaceholder: post.deletedPostPlaceholder ?? false,
                    isIgnoredPlaceholder: post.ignoredPostPlaceholder ?? false
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
