//
//  ModerationAPI.swift
//  nodeloc
//
//  Reporting a post, and handling one directly as someone who manages it
//  (docs/specs/mobile-api.md「投票、收藏、举报、转发」and「在帖子上直接处理」).
//

import Foundation

/// `GET /api/v1/posts/{id}/moderate`: what the handling dialog needs. 403
/// (`forbidden`, `protected`) means the reader can't handle this post and
/// reports it like anyone else.
nonisolated struct NLPostModerateOptions: Codable, Sendable {
    nonisolated struct Author: Codable, Sendable {
        let id: Int
        let username: String
    }
    /// `site` (site-wide penalties) or `node` (mute / ban inside the node).
    let scope: String
    let node: String?
    let firstPost: Bool?
    let hidden: Bool?
    let author: Author?
    let canPenalize: Bool?
    /// The longest penalty in days; 0 is unlimited (permanent allowed).
    let maxDays: Int?
    let reputationPenaltyMax: Int?
    let openReports: Int?

    var isNodeScope: Bool { scope == "node" }
}

/// `POST /api/v1/posts/{id}/moderate` → 200.
nonisolated struct NLPostModerateResult: Codable, Sendable {
    let scope: String?
    let postAction: String?
    let userAction: String?
    let itemId: Int?
    let reputationDeducted: Int?
    let closedItems: [Int]?
}

/// 409 `penalty_exists`: the same kind of penalty is already in force. The
/// request changed nothing; it is sent again with `on_conflict`.
nonisolated struct NLPenaltyConflict: Codable, Sendable {
    nonisolated struct Existing: Codable, Sendable {
        let id: Int?
        let kind: String?
        let reason: String?
        let createdAt: String?
        /// Nil is permanent.
        let endsAt: String?
        let createdBy: String?
        let count: Int?
    }
    let code: String?
    let message: String?
    let until: String?
    let permanent: Bool?
    let existing: Existing?

    /// Reads it from the error body the last request left behind.
    static func fromLastError() -> NLPenaltyConflict? {
        guard let data = DiscourseError.lastErrorBody,
              let envelope = try? NodelocJSON.decode(Envelope.self, from: data)
        else { return nil }
        return envelope.error
    }

    private nonisolated struct Envelope: Codable, Sendable {
        let error: NLPenaltyConflict
    }
}

/// What the handling dialog submits.
nonisolated struct PostModerateRequest: Sendable, Equatable {
    /// `delete`, `hide` or empty.
    var postAction = ""
    /// `silence`, `suspend` or empty (a node scope's mute / ban).
    var userAction = ""
    var days = 7
    var reputationPenalty = 0
    var reason = ""
    var note = ""
    /// `extend` or `replace`, after a 409 `penalty_exists`.
    var onConflict = ""

    var json: [String: Any] {
        var body: [String: Any] = [
            "reason": reason,
            "note": note,
            "post_action": postAction,
            "user_action": userAction,
        ]
        if !userAction.isEmpty { body["days"] = days }
        if reputationPenalty > 0 { body["reputation_penalty"] = reputationPenalty }
        if !onConflict.isEmpty { body["on_conflict"] = onConflict }
        return body
    }
}

extension DiscourseClient {
    /// The reasons a reader picks from when reporting, in the server's order
    /// with 「其他」 last.
    func reportReasons() async throws -> [NLReason] {
        let response: NLModerationReasons = try await get("api/v1/report-reasons")
        return response.reasons.filter { $0.report != false }
    }

    /// Reports a post (a topic is reported through its first post). 204.
    @discardableResult
    func reportPost(postID: Int, reason: String, note: String) async throws -> Data {
        try await send("POST", "api/v1/posts/\(postID)/reports", json: [
            "reason": reason,
            "note": String(note.prefix(500)),
        ])
    }

    /// 设为精华 / 取消精华. Staff only (`topics.curate`); 204.
    @discardableResult
    func setTopicFeatured(topicID: Int, featured: Bool) async throws -> Data {
        try await send("PUT", "api/v1/topics/\(topicID)/featured", json: ["featured": featured])
    }

    /// 移动到其他节点. Staff only (`topics.curate`). `reason` is one of
    /// `TopicMoveReason`; the note goes to the author with it. 204.
    @discardableResult
    func moveTopic(topicID: Int, toNode slug: String, reason: String, note: String) async throws -> Data {
        try await send("POST", "api/v1/topics/\(topicID)/move", json: [
            "node": slug,
            "reason": reason,
            "note": String(note.prefix(200)),
        ])
    }

    /// The handling dialog's options; 403 when the reader can't handle it.
    func postModerateOptions(postID: Int) async throws -> NLPostModerateOptions {
        try await get("api/v1/posts/\(postID)/moderate")
    }

    func moderatePost(postID: Int, request: PostModerateRequest) async throws -> NLPostModerateResult {
        let data = try await send("POST", "api/v1/posts/\(postID)/moderate", json: request.json)
        return try NodelocJSON.decode(NLPostModerateResult.self, from: data)
    }

    /// The first post of a topic, for reporting or handling a topic.
    func firstPostID(ofTopic topicID: Int) async throws -> Int {
        if let first = NodelocAdapterState.shared.firstPostID(topicID: topicID) { return first }
        let detail: NLTopicDetail = try await get("api/v1/topics/\(topicID)", query: [URLQueryItem(name: "limit", value: "1")])
        guard let first = detail.posts.first else { throw DiscourseError.badResponse(404, message: nil, code: "not_found") }
        return first.id
    }
}
