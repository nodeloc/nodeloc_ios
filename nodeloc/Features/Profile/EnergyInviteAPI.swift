//
//  EnergyInviteAPI.swift
//  nodeloc
//
//  The endpoints behind 能量明细, 财富榜's side card and 邀请好友, in the
//  backend's own shapes (keys snake_case on the wire, camelCase here):
//
//  - `GET  /api/v1/points` — balance and the transfer rule.
//  - `GET  /api/v1/points/history?before=&limit=&direction=&group=&month=` —
//    one page of the ledger, newest first, with the related object resolved
//    and a serial number per entry.
//  - `GET  /api/v1/points/summary?month=YYYY-MM` — a month's income/expense.
//  - `POST /api/v1/points/transfers` `{to, amount, memo}` + `Idempotency-Key`.
//  - `GET  /api/v1/invites/me` — the invite page in one answer: personal code
//    (null when the reader's tier can't invite yet), rewards, counts,
//    milestones, friends.
//  - `POST /api/v1/invites/friends/{id}/remind` — 提醒验证 (no body, 204).
//  - `GET  /api/v1/invites` / `POST /api/v1/invites` (no body) — one-use
//    invite links, valid for a limited time.
//
//  Ledger days, months and check-in days are Beijing time on the server, so
//  the pages group and label by Asia/Shanghai as the web does.
//

import Foundation

// MARK: - Energy

/// `GET /api/v1/points`.
nonisolated struct NLPointsAccount: Codable, Sendable {
    nonisolated struct TransferRule: Codable, Sendable {
        let min: Int
        let max: Int
        let feePercent: Int
    }
    let balance: Int
    let transfer: TransferRule?
}

/// `GET /api/v1/points/history`, with every field the ledger page shows.
nonisolated struct NLLedgerPage: Codable, Sendable {
    nonisolated struct Entry: Codable, Sendable, Identifiable, Hashable {
        nonisolated struct Ref: Codable, Sendable, Hashable {
            /// topic, post, user, lottery, app, pay_order…
            let type: String?
            let label: String?
            /// A site path such as `/t/12#post-3`; nil when only the name shows.
            let url: String?
        }
        let id: Int
        let transactionId: Int?
        /// The serial number shown as 流水号.
        let no: String?
        let kind: String
        let amount: Int
        let balanceAfter: Int?
        let memo: String?
        let ref: Ref?
        let counterpart: String?
        /// For a check-in, which day of the streak it was.
        let streak: Int?
        let createdAt: String?
    }
    let entries: [Entry]
    let total: Int?
    let nextBefore: Int?
}

/// `GET /api/v1/points/summary`.
nonisolated struct NLPointsMonth: Codable, Sendable {
    let month: String?
    let income: Int
    /// Positive.
    let expense: Int
}

/// `POST /api/v1/points/transfers`.
nonisolated struct NLTransferResult: Codable, Sendable {
    let transactionId: Int?
    let amount: Int?
    let fee: Int?
    let balance: Int?
}

/// The ledger filters, as the web's /points page offers them.
nonisolated struct LedgerFilter: Equatable, Sendable {
    enum Direction: String, CaseIterable, Sendable { case all = "", income = "in", expense = "out" }

    var direction: Direction = .all
    /// A `KindGroups` key (checkin, tip, games, reward, spend) or `other`;
    /// empty for every kind.
    var group = ""
    /// `YYYY-MM`, empty for all time.
    var month = ""

    var isFiltered: Bool { direction != .all || !group.isEmpty || !month.isEmpty }
}

// MARK: - Invites

/// `GET /api/v1/invites/me`.
nonisolated struct NLInviteOverview: Codable, Sendable {
    nonisolated struct Rewards: Codable, Sendable {
        let inviter: Int
        let welcome: Int
        let level: Int
        let levelName: String
        let levelBonus: Int
        let second: Int
        let monthlyCap: Int
        let verifyDays: Int
    }
    nonisolated struct Friend: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        let username: String
        let name: String?
        let avatarUrl: String?
        let joinedAt: String?
        /// pending, expired, verified, leveled.
        let stage: String
        let levelName: String?
        let subInvites: Int?
        /// Everything this friend has brought in, second level included.
        let earned: Int?
        let second: Int?
        let pending: Int?
        let capped: Bool?
        let canRemind: Bool?
        let remindedAt: String?
        let expiresAt: String?

        var displayName: String { (name?.isEmpty == false ? name : nil) ?? username }
        var isEffective: Bool { stage == "verified" || stage == "leveled" }
    }
    nonisolated struct Milestone: Codable, Sendable, Hashable {
        let target: Int
        let badge: String?
        let reward: Int
        let reached: Bool
    }
    nonisolated struct Overview: Codable, Sendable {
        let rewards: Rewards
        let invited: Int
        let effective: Int
        let pendingCount: Int
        let earned: Int
        let earnedSecond: Int
        let pending: Int
        let milestones: [Milestone]
        let milestoneCount: Int
        let friends: [Friend]
    }
    let overview: Overview
    /// Null while the reader's tier can't invite people yet.
    let code: String?
}

/// One entry of `GET /api/v1/invites`.
nonisolated struct NLInviteCode: Codable, Sendable, Identifiable, Hashable {
    let code: String
    let nodeId: Int?
    let maxUses: Int?
    let useCount: Int?
    let expiresAt: String?
    let createdAt: String?
    let personal: Bool?
    let revoked: Bool?

    var id: String { code }
}

nonisolated struct NLInviteCodeList: Codable, Sendable {
    let invites: [NLInviteCode]
}

nonisolated struct NLInviteCodeCreated: Codable, Sendable {
    let invite: NLInviteCode
}

// MARK: - Client

extension DiscourseClient {
    func pointsAccount() async throws -> NLPointsAccount {
        let data = try await http.send("GET", "api/v1/points")
        return try NodelocJSON.decode(NLPointsAccount.self, from: data)
    }

    func ledger(filter: LedgerFilter, before: Int? = nil, limit: Int = 20) async throws -> NLLedgerPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if filter.direction != .all { query.append(URLQueryItem(name: "direction", value: filter.direction.rawValue)) }
        if !filter.group.isEmpty { query.append(URLQueryItem(name: "group", value: filter.group)) }
        if !filter.month.isEmpty { query.append(URLQueryItem(name: "month", value: filter.month)) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let data = try await http.send("GET", "api/v1/points/history", query: query)
        return try NodelocJSON.decode(NLLedgerPage.self, from: data)
    }

    /// Nil month is this month, Beijing time.
    func pointsMonth(_ month: String? = nil) async throws -> NLPointsMonth {
        let query = month.map { [URLQueryItem(name: "month", value: $0)] } ?? []
        let data = try await http.send("GET", "api/v1/points/summary", query: query)
        return try NodelocJSON.decode(NLPointsMonth.self, from: data)
    }

    /// 转赠. The key is made once per attempt by the caller so a retry of the
    /// same attempt can't send twice.
    func transferPoints(to username: String, amount: Int, memo: String, idempotencyKey: String) async throws -> NLTransferResult {
        let data = try await http.send(
            "POST", "api/v1/points/transfers",
            body: .json(["to": username, "amount": amount, "memo": memo]),
            headers: ["Idempotency-Key": idempotencyKey]
        )
        return try NodelocJSON.decode(NLTransferResult.self, from: data)
    }

    func inviteOverview() async throws -> NLInviteOverview {
        let data = try await http.send("GET", "api/v1/invites/me")
        return try NodelocJSON.decode(NLInviteOverview.self, from: data)
    }

    /// 提醒验证: resends the friend's verification mail; once a day per friend.
    func remindInvitedFriend(id: Int) async throws {
        _ = try await http.send("POST", "api/v1/invites/friends/\(id)/remind")
    }

    func inviteCodes() async throws -> [NLInviteCode] {
        let data = try await http.send("GET", "api/v1/invites")
        return try NodelocJSON.decode(NLInviteCodeList.self, from: data).invites
    }

    /// A one-use invite link. The server takes no body; the web sends `{}`.
    func createInviteCode() async throws -> NLInviteCode {
        let data = try await http.send("POST", "api/v1/invites", body: .json([:]))
        return try NodelocJSON.decode(NLInviteCodeCreated.self, from: data).invite
    }
}

// MARK: - Formatting

/// Beijing-time dates and grouped numbers, the way the web pages print them.
enum EnergyFormat {
    static let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    nonisolated static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// `+1,234` / `−1,234` (a real minus sign, as the design prints it).
    nonisolated static func signed(_ value: Int) -> String {
        (value >= 0 ? "+" : "−") + grouped(abs(value))
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    static let dayKey = formatter("yyyy-MM-dd")
    static let time = formatter("HH:mm")
    static let full = formatter("yyyy.MM.dd HH:mm")
    static let monthKey = formatter("yyyy-MM")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
