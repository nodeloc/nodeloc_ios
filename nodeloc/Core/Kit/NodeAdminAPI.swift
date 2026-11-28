//
//  NodeAdminAPI.swift
//  nodeloc
//
//  What the node management hub and its pages read: the manage summary,
//  members by role and the node's active penalties. Matched to the backend's
//  node/manage_handlers.go (`manage`, `listMembers`, `listRestrictions`) and
//  node/handlers.go (`updateDetails`).
//

import Foundation

/// `GET /api/v1/nodes/{slug}/manage` — owner, moderators and site staff only.
nonisolated struct NLNodeManage: Codable, Sendable {
    nonisolated struct Node: Codable, Sendable {
        let id: Int
        let slug: String
        let name: String
        let description: String?
        let ownerId: Int?
        let color: String?
        let iconText: String?
        let logoUrl: String?
        let memberCount: Int?
        let topicCount: Int?
        let postCount: Int?
        let pinnedCount: Int?
        /// `public`, `members`, … — who can read.
        let visibility: String?
        let topicPolicy: String?
        let replyPolicy: String?
        let slowModeSeconds: Int?
        let createdAt: String?
    }
    nonisolated struct Moderator: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let username: String
        let owner: Bool?
    }
    nonisolated struct Rule: Codable, Sendable, Hashable {
        let title: String
        let description: String?
    }
    /// `owner`, `moderator`, or empty for staff who are neither.
    let role: String?
    let canEdit: Bool?
    let isStaff: Bool?
    let isAdmin: Bool?
    let node: Node
    let rules: [Rule]?
    let moderators: [Moderator]?
}

/// `GET /api/v1/nodes/{slug}/members?role=` — one page.
nonisolated struct NLNodeMembers: Codable, Sendable {
    nonisolated struct Member: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let username: String
        let name: String?
        let avatar: String?
        /// `owner`, `moderator` or `member`.
        let role: String?
        let joinedAt: String?
    }
    let members: [Member]
    let nextOffset: Int?
}

/// `GET /api/v1/nodes/{slug}/restrictions` — who is silenced or banned in the
/// node right now.
nonisolated struct NLNodeRestrictions: Codable, Sendable {
    nonisolated struct Restriction: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        /// `silence` (禁言) or `ban` (封禁).
        let kind: String
        let reason: String?
        let expiresAt: String?
        let createdAt: String?
        let userId: Int
        let username: String
        let createdBy: String?
    }
    let restrictions: [Restriction]
}

extension DiscourseClient {
    func nodeManage(slug: String) async throws -> NLNodeManage {
        try await get("api/v1/nodes/\(Self.pathEscape(slug))/manage")
    }

    func nodeMembers(slug: String, role: String? = nil, query: String? = nil, offset: Int = 0) async throws -> NLNodeMembers {
        var items = [URLQueryItem(name: "offset", value: String(offset))]
        if let role { items.append(URLQueryItem(name: "role", value: role)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await get("api/v1/nodes/\(Self.pathEscape(slug))/members", query: items)
    }

    func nodeRestrictions(slug: String) async throws -> [NLNodeRestrictions.Restriction] {
        let answer: NLNodeRestrictions = try await get("api/v1/nodes/\(Self.pathEscape(slug))/restrictions")
        return answer.restrictions
    }

    /// 解除: lifts one user's penalty in the node.
    func liftNodeRestriction(slug: String, userID: Int) async throws {
        try await send("DELETE", "api/v1/nodes/\(Self.pathEscape(slug))/restrictions/\(userID)")
    }

    /// 基本信息: the node's name and description.
    func updateNodeDetails(slug: String, name: String, description: String) async throws {
        try await send("PUT", "api/v1/nodes/\(Self.pathEscape(slug))/details", json: ["name": name, "description": description])
    }
}

extension DiscourseClient {
    /// The node's pinned topics as the server lists them, with when each
    /// pin started and ends.
    func nodePinList(slug: String) async throws -> [NLNodePins.Pin] {
        let pins: NLNodePins = try await get("api/v1/nodes/\(Self.pathEscape(slug))/pins")
        return pins.topics
    }
}

extension DiscourseClient {
    /// The pinned carousel, plus a signature of what is pinned: each pin's
    /// topic id, when it was pinned, its title and its excerpt, in order.
    /// The pins endpoint has no edited-at time, so the title and the
    /// first-post excerpt stand in for "edited"; reply counts, last-reply
    /// times and votes are left out so ordinary activity doesn't count as a
    /// change.
    func nodePinsWithSignature(slug: String) async throws -> (LatestResponse, String) {
        let pins: NLNodePins = try await get("api/v1/nodes/\(Self.pathEscape(slug))/pins")
        let shaped: LatestResponse = try Self.shaped(DiscourseShape.pinnedCarousel(pins.topics, nodeSlug: slug))
        let signature = pins.topics
            .map { "\($0.id)|\($0.pinnedAt ?? "")|\($0.title)|\($0.excerpt ?? "")" }
            .joined(separator: "\n")
        return (shaped, signature)
    }
}
