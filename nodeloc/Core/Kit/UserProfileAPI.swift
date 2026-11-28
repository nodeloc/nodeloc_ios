//
//  UserProfileAPI.swift
//  nodeloc
//
//  The extra reads someone else's profile needs on top of `user(_:)`: the
//  showcase with its 声望, their 能量, and the nodes they post in.
//

import Foundation

/// `GET /api/v1/users/{username}/achievements`, with the `reputation` that
/// `NLAchievementShowcase` drops. The server omits `reputation` when the person
/// turned off 显示等级与声望, so nil means "hidden", not zero.
nonisolated struct NLUserShowcase: Codable, Sendable {
    let showcase: [AchievementItem]
    let reputation: Int?
}

/// One row of `GET /api/v1/users/{username}/posts` — only the node it was
/// posted in is read here.
nonisolated struct NLUserPostNode: Codable, Sendable {
    let nodeSlug: String?
    let nodeName: String?
}

nonisolated struct NLUserPostNodes: Codable, Sendable {
    let posts: [NLUserPostNode]
}

/// A node someone posts in, and how many of their recent posts it holds.
nonisolated struct UserFrequentNode: Sendable, Hashable {
    let slug: String
    let name: String
    let count: Int
}

extension DiscourseClient {
    func userShowcase(username: String) async throws -> NLUserShowcase {
        let data = try await http.send("GET", "api/v1/users/\(Self.pathEscape(username))/achievements")
        return try NodelocJSON.decode(NLUserShowcase.self, from: data)
    }

    /// 常去节点 for another person. The backend has no per-user node list (joined
    /// nodes are private to the member; `/api/v1/me/nodes` is the reader's
    /// own), so this tallies the nodes of their latest 50 posts — the most the
    /// posts endpoint returns in one page — busiest first. Android works it
    /// out the same way, with the nodes they own put ahead (see the store).
    func userFrequentNodes(username: String) async throws -> [UserFrequentNode] {
        let data = try await http.send(
            "GET",
            "api/v1/users/\(Self.pathEscape(username))/posts",
            query: [URLQueryItem(name: "limit", value: "50")]
        )
        let posts = try NodelocJSON.decode(NLUserPostNodes.self, from: data).posts
        var counts: [String: (name: String, count: Int, first: Int)] = [:]
        for (index, post) in posts.enumerated() {
            guard let slug = post.nodeSlug, !slug.isEmpty else { continue }
            let key = slug.lowercased()
            let existing = counts[key]
            counts[key] = (
                existing?.name ?? (post.nodeName?.isEmpty == false ? post.nodeName! : slug),
                (existing?.count ?? 0) + 1,
                existing?.first ?? index
            )
        }
        // Ties go to the node posted in most recently.
        return counts
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.value.first < $1.value.first }
            .map { UserFrequentNode(slug: $0.key, name: $0.value.name, count: $0.value.count) }
    }

    /// Someone else's 能量, and their place on the all-time board when they
    /// are on its first page. `/api/v1/users/{u}` leaves the balance out and
    /// `/api/v1/points` only answers for the reader, so this does what Android
    /// does: the board (`GET /api/v1/points/leaderboard`, public) first, then
    /// the website's hover card (`GET /u/{u}/card`), which shows the balance to
    /// anyone. Nil when neither says.
    func userEnergy(username: String) async -> UserEnergy? {
        if let board = try? await leaderboard(period: .all, page: 1, limit: 100),
           let row = board.users.first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame }) {
            return UserEnergy(balance: row.value, rank: row.rank)
        }
        return await cardEnergy(username: username).map { UserEnergy(balance: $0, rank: nil) }
    }

    /// The `hc-energy` figure off the hover card, digits only (the separator
    /// follows the page's locale). Asked for as HTML: a JSON-only request to a
    /// website path is how the server spots the retired Discourse-era app and
    /// answers 410 (backend internal/web/oldapp.go).
    private func cardEnergy(username: String) async -> Int? {
        guard let data = try? await http.send(
            "GET",
            "u/\(Self.pathEscape(username))/card",
            headers: ["Accept": "text/html"]
        ), let html = String(data: data, encoding: .utf8),
              let marker = html.range(of: "class=\"hc-energy\"") else { return nil }
        let tail = html[marker.upperBound...]
        guard let open = tail.firstIndex(of: ">"),
              let close = tail[open...].firstIndex(of: "<") else { return nil }
        let raw = tail[tail.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let digits = raw.filter { ("0"..."9").contains($0) }
        guard let value = Int(digits) else { return nil }
        return raw.hasPrefix("-") || raw.hasPrefix("\u{2212}") ? -value : value
    }
}

/// Someone else's 能量: the balance, and the board rank when they are on it.
nonisolated struct UserEnergy: Codable, Sendable, Equatable {
    let balance: Int
    let rank: Int?
}
