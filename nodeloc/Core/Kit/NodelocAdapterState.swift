//
//  NodelocAdapterState.swift
//  nodeloc
//
//  What the adapter has to remember between calls because the screens were
//  written against Discourse's addressing and the new backend addresses things
//  differently:
//
//  - nodes are addressed by slug, the screens hold category *ids*;
//  - lists page by cursor, the screens ask for page N;
//  - a post is fetched with its topic, the screens ask for posts by id;
//  - a direct message is read by username, the screens hold a channel id;
//  - chat users have no id on the wire, the screens key them by id.
//
//  Everything here is a cache of server answers. Losing it costs a refetch,
//  never correctness, and `reset()` drops it on sign-out.
//

import Foundation

@MainActor
final class NodelocAdapterState {
    static let shared = NodelocAdapterState()

    // MARK: Nodes

    private(set) var nodesByID: [Int: NLNode] = [:]
    private(set) var nodesBySlug: [String: NLNode] = [:]
    private(set) var nodeOrder: [Int] = []
    private var nodesFetchedAt: Date?
    var nodesFresh: Bool {
        guard let nodesFetchedAt else { return false }
        return Date().timeIntervalSince(nodesFetchedAt) < 300
    }

    func store(nodes: [NLNode]) {
        nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        nodesBySlug = Dictionary(nodes.map { ($0.slug, $0) }, uniquingKeysWith: { _, last in last })
        nodeOrder = nodes.map(\.id)
        nodesFetchedAt = Date()
    }

    /// Folds a single node (from a detail call) into the directory.
    func merge(node: NLNode) {
        if nodesByID[node.id] == nil { nodeOrder.append(node.id) }
        nodesByID[node.id] = node
        nodesBySlug[node.slug] = node
    }

    func invalidateNodes() { nodesFetchedAt = nil }

    var allNodes: [NLNode] { nodeOrder.compactMap { nodesByID[$0] } }

    /// A stable id for a slug the directory doesn't know (a node the reader
    /// can't list, or one created after the last fetch). Negative so it never
    /// collides with a real one.
    func nodeID(forSlug slug: String) -> Int {
        if let node = nodesBySlug[slug] { return node.id }
        let id = -Int(StableHash.fnv1a("node:" + slug) % 1_000_000_000) - 1
        syntheticNodeSlugs[id] = slug
        return id
    }

    func nodeSlug(forID id: Int) -> String? {
        nodesByID[id]?.slug ?? syntheticNodeSlugs[id]
    }

    private var syntheticNodeSlugs: [Int: String] = [:]

    // MARK: Paging

    /// Cursor for page N of a list, keyed by the list's identity.
    private var cursors: [String: [Int: String]] = [:]

    func cursor(list: String, page: Int) -> String? {
        cursors[list]?[page]
    }

    func setCursor(_ cursor: String?, list: String, page: Int) {
        guard let cursor else { return }
        cursors[list, default: [:]][page] = cursor
    }

    // MARK: Users

    private var userIDs: [String: Int] = [:]
    private var usernamesByID: [Int: String] = [:]
    private var avatars: [String: String] = [:]

    /// The id a username is known by: its real id when any response carried
    /// it, else a stable negative stand-in.
    func userID(for username: String) -> Int {
        let key = username.lowercased()
        if let id = userIDs[key] { return id }
        let id = -Int(StableHash.fnv1a("user:" + key) % 1_000_000_000) - 1
        userIDs[key] = id
        usernamesByID[id] = username
        return id
    }

    func remember(username: String, id: Int?, avatar: String? = nil) {
        let key = username.lowercased()
        if let id, id > 0 {
            if let previous = userIDs[key], previous != id { usernamesByID[previous] = nil }
            userIDs[key] = id
            usernamesByID[id] = username
        } else if userIDs[key] == nil {
            _ = userID(for: username)
        }
        if let avatar, !avatar.isEmpty { avatars[key] = avatar }
    }

    func username(forID id: Int) -> String? { usernamesByID[id] }
    func avatar(for username: String) -> String? { avatars[username.lowercased()] }

    // MARK: Topics and posts

    private var posts: [Int: NLPost] = [:]
    private var postTopic: [Int: Int] = [:]
    private var topicFirstPost: [Int: Int] = [:]
    private var topicPostIDs: [Int: [Int]] = [:]
    private var topicNodes: [Int: String] = [:]

    func store(posts newPosts: [NLPost], topicID: Int) {
        for post in newPosts {
            posts[post.id] = post
            postTopic[post.id] = topicID
            if post.postNumber == 1 { topicFirstPost[topicID] = post.id }
            remember(username: post.author, id: post.authorId, avatar: post.authorAvatar)
            if !(topicPostIDs[topicID]?.contains(post.id) ?? false) {
                topicPostIDs[topicID, default: []].append(post.id)
            }
        }
    }

    func post(_ id: Int) -> NLPost? { posts[id] }
    func topicID(forPost id: Int) -> Int? { postTopic[id] }
    func firstPostID(topicID: Int) -> Int? { topicFirstPost[topicID] }
    func setNode(slug: String, topicID: Int) { topicNodes[topicID] = slug }
    func nodeSlug(topicID: Int) -> String? { topicNodes[topicID] }

    func post(topicID: Int, number: Int) -> NLPost? {
        topicPostIDs[topicID]?.compactMap { posts[$0] }.first { $0.postNumber == number }
    }

    /// Mirrors a vote or bookmark onto the cached copy so the next mapping of
    /// that post reflects it.
    func update(post id: Int, _ change: (inout PostOverrides) -> Void) {
        var overrides = postOverrides[id] ?? PostOverrides()
        change(&overrides)
        postOverrides[id] = overrides
    }

    func overrides(for id: Int) -> PostOverrides? { postOverrides[id] }

    private var postOverrides: [Int: PostOverrides] = [:]

    struct PostOverrides {
        var upvotes: Int?
        var downvotes: Int?
        var viewerVote: Int?
        var bookmarked: Bool?
    }

    // MARK: Chat

    enum ConversationKind: String { case direct, channel, group }

    struct Conversation {
        let id: Int
        let kind: ConversationKind
        /// The other person, for a direct message.
        let username: String?
        let name: String
    }

    private(set) var conversations: [Int: Conversation] = [:]
    /// Direct messages not started yet have no id on the server. They get a
    /// negative stand-in until the first message creates the real one.
    private var pendingDirects: [Int: String] = [:]

    func store(conversation: Conversation) {
        conversations[conversation.id] = conversation
    }

    /// The server's id for a conversation the screens may still hold by its
    /// stand-in id (a direct message opened before its first message).
    func serverConversationID(_ id: Int) -> Int? {
        if id > 0 { return id }
        guard let username = pendingDirects[id] else { return nil }
        return directConversation(with: username)?.id
    }

    func directConversation(with username: String) -> Conversation? {
        conversations.values.first { $0.kind == .direct && $0.username?.lowercased() == username.lowercased() }
    }

    func pendingDirectID(for username: String) -> Int {
        if let existing = pendingDirects.first(where: { $0.value.lowercased() == username.lowercased() }) {
            return existing.key
        }
        let id = -Int(StableHash.fnv1a("dm:" + username.lowercased()) % 1_000_000_000) - 1
        pendingDirects[id] = username
        return id
    }

    func pendingDirectUsername(_ id: Int) -> String? { pendingDirects[id] }

    /// The conversation's newest message id, so read markers and live
    /// catch-up have somewhere to start.
    var newestMessageID: [Int: Int] = [:]

    // MARK: Uploads

    private var uploads: [Int: NLUpload] = [:]
    func store(upload: NLUpload) { uploads[upload.id] = upload }
    func upload(_ id: Int) -> NLUpload? { uploads[id] }
    func uploadID(forURL url: String) -> Int? {
        uploads.values.first { $0.url == url || url.hasSuffix($0.url) }?.id
    }

    /// Topics in which the reader may moderate, from each topic's permissions.
    var topicModerators: Set<Int> = []

    // MARK: Me

    var me: NLUser?
    var myAvatar: String?

    func reset() {
        nodesByID = [:]
        nodesBySlug = [:]
        nodeOrder = []
        nodesFetchedAt = nil
        cursors = [:]
        posts = [:]
        postTopic = [:]
        topicFirstPost = [:]
        topicPostIDs = [:]
        topicNodes = [:]
        postOverrides = [:]
        conversations = [:]
        pendingDirects = [:]
        newestMessageID = [:]
        uploads = [:]
        topicModerators = []
        me = nil
        myAvatar = nil
    }
}

/// FNV-1a: stable across launches and platforms, unlike `hashValue`.
nonisolated enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }
}
