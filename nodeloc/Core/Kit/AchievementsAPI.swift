//
//  AchievementsAPI.swift
//  nodeloc
//
//  Achievements and weekly tasks, as the backend returns them:
//
//  - `GET /api/v1/achievements` — the signed-in reader's full catalogue, each
//    entry with its unlock state and progress, plus `total` / `unlocked_count`.
//  - `GET /api/v1/users/{username}/achievements` — anyone's public showcase
//    (at most three they picked), without unlock state.
//  - `GET /api/v1/me/tasks` — this week's tasks and the weekly reputation cap.
//
//  The profile summary the app used to read badges from is empty on this
//  backend, which is why 成就 never showed.
//

import SwiftUI

/// One achievement. Fields beyond `key` are optional: the public showcase
/// carries only the descriptive ones.
nonisolated struct AchievementItem: Codable, Sendable, Identifiable, Hashable {
    let key: String
    let category: String?
    /// 1 铜级, 2 银级, 3 金级, 4 稀有级.
    let tier: Int?
    let tierName: String?
    /// A short name from the web's icon set: pen, bolt, book, chat, flag,
    /// flame, heart, node, star, up, user.
    let icon: String?
    let name: String?
    let description: String?
    /// How to unlock it, in the reader's language.
    let how: String?
    let reputation: Int?
    let target: Int?
    let repeatable: Bool?
    let current: Int?
    /// How many times a repeatable one has been earned.
    let times: Int?
    let unlocked: Bool?
    let unlockedAt: String?
    let lastAt: String?
    /// Retired or switched off; not shown as something still to earn.
    let off: Bool?
    let closed: Bool?
    /// Only an admin hands it out (shown as 管理员发放 while locked).
    let manual: Bool?
    /// On the reader's 主页展示 (one of at most `maxShowcase`).
    let pinned: Bool?
    /// Share of members holding it, 0…1.
    let holderShare: Double?

    var id: String { key }
    var title: String { name ?? key }
    var isUnlocked: Bool { unlocked ?? true }

    /// 0…1 toward `target`.
    var fraction: Double {
        guard let target, target > 0 else { return isUnlocked ? 1 : 0 }
        return min(max(Double(current ?? 0) / Double(target), 0), 1)
    }

    /// Unlocked in the last three days.
    var isNew: Bool {
        guard let date = DiscourseFormat.date(lastAt ?? unlockedAt) else { return false }
        return Date().timeIntervalSince(date) < 3 * 24 * 3600
    }

    var symbolName: String {
        switch icon {
        case "pen": return "pencil"
        case "bolt": return "bolt.fill"
        case "book": return "book.fill"
        case "chat": return "bubble.left.fill"
        case "flag": return "flag.fill"
        case "flame": return "flame.fill"
        case "heart": return "heart.fill"
        case "node": return "square.grid.2x2.fill"
        case "star": return "star.fill"
        case "up": return "arrow.up"
        case "user": return "person.fill"
        default: return "rosette"
        }
    }
}

/// `GET /api/v1/achievements`.
nonisolated struct NLAchievementList: Codable, Sendable {
    let achievements: [AchievementItem]
    /// Keys on 主页展示, in the order they show.
    let showcase: [String]?
    let maxShowcase: Int?
    let total: Int?
    let unlockedCount: Int?
    let reputationEarned: Int?
}

/// `GET /api/v1/me/reputation/ledger` — newest first; `next` is the cursor
/// for the page after this one.
nonisolated struct NLReputationLedger: Codable, Sendable {
    nonisolated struct Item: Codable, Sendable, Identifiable, Hashable {
        let id: Int
        /// `like`, `accept`, `featured`, `achievement`, `task` or `moderation`.
        let source: String
        let amount: Int
        /// `settled`, or `pending` (greyed, not counted yet).
        let status: String?
        /// A clawback of an earlier entry.
        let revoke: Bool?
        /// Why: a task's or achievement's key, a penalty's reason, …
        let memo: String?
        /// The topic it's about, when the reader can see it; an achievement's name.
        let title: String?
        let url: String?
        let createdAt: String?
    }
    let items: [Item]
    let next: String?
}

/// `GET /api/v1/users/{username}/achievements`.
nonisolated struct NLAchievementShowcase: Codable, Sendable {
    let showcase: [AchievementItem]
}

/// `GET /api/v1/me/tasks`.
nonisolated struct NLTaskList: Codable, Sendable {
    nonisolated struct Task: Codable, Sendable, Identifiable, Hashable {
        let key: String
        /// `daily` or `weekly`.
        let period: String?
        let title: String?
        let progress: Int?
        let target: Int?
        let done: Bool?
        let energy: Int?
        let reputation: Int?
        /// The call to action and the web path it leads to.
        let cta: String?
        let href: String?
        let compose: Bool?

        var id: String { key }
    }
    let tasks: [Task]
    let weekReputation: Int?
    let weekCap: Int?
    let reputationEligible: Bool?
}

extension DiscourseClient {
    func achievementList() async throws -> NLAchievementList {
        let data = try await http.send("GET", "api/v1/achievements")
        return try NodelocJSON.decode(NLAchievementList.self, from: data)
    }

    func achievementShowcase(username: String) async throws -> [AchievementItem] {
        let escaped = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let data = try await http.send("GET", "api/v1/users/\(escaped)/achievements")
        return try NodelocJSON.decode(NLAchievementShowcase.self, from: data).showcase
    }

    func weeklyTasks() async throws -> NLTaskList {
        let data = try await http.send("GET", "api/v1/me/tasks")
        return try NodelocJSON.decode(NLTaskList.self, from: data)
    }

    /// `PUT` / `DELETE /api/v1/achievements/{key}/pin`, no body, 204. Pinning
    /// needs the achievement unlocked (403 `locked`) and a free slot (409
    /// `showcase_full`); unpinning one that isn't pinned is a no-op.
    func setAchievementPinned(key: String, pinned: Bool) async throws {
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        _ = try await http.send(pinned ? "PUT" : "DELETE", "api/v1/achievements/\(escaped)/pin")
    }

    /// `GET /api/v1/me/reputation/ledger?before=&limit=` (limit 1…100).
    func reputationLedger(before: String? = nil, limit: Int = 20) async throws -> NLReputationLedger {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before, !before.isEmpty { query.append(URLQueryItem(name: "before", value: before)) }
        let data = try await http.send("GET", "api/v1/me/reputation/ledger", query: query)
        return try NodelocJSON.decode(NLReputationLedger.self, from: data)
    }
}

// MARK: - Medal

/// An achievement's icon on a disc graded bronze / silver / gold / rare.
/// Greyed out while still locked.
struct AchievementMedal: View {
    let item: AchievementItem
    var size: CGFloat = 52
    var locked = false

    var body: some View {
        let style = Self.style(for: item.tier)
        // The design's disc: a 145° gradient, a white inner ring, a hairline
        // outer ring in the grade's darker colour. Locked is flat grey.
        ZStack {
            if locked {
                Circle().fill(Theme.chip)
            } else {
                Circle().fill(
                    LinearGradient(colors: [style.top, style.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            Circle().strokeBorder(Color.white.opacity(locked ? 0.35 : 0.7), lineWidth: 2)
            Image(systemName: item.symbolName)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(locked ? Theme.textFaint : style.icon)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(locked ? Theme.hairline : style.bottom, lineWidth: 1).padding(-0.5))
    }

    /// 1 铜级, 2 银级, 3 金级, 4 稀有级 — the design's medal colours.
    static func style(for tier: Int?) -> (top: Color, bottom: Color, icon: Color) {
        switch tier {
        case 2: return (Color(hex: 0xF4F7F8), Color(hex: 0xC5D0D6), Color(hex: 0x2A3C42))
        case 3: return (Color(hex: 0xFFF4CF), Color(hex: 0xEBC65A), Color(hex: 0x6B4700))
        case 4: return (Color(hex: 0x1B3A2F), Color(hex: 0x0B1F18), Color(hex: 0x5CC79A))
        default: return (Color(hex: 0xF6E3D2), Color(hex: 0xD9A679), Color(hex: 0x7A3A10))
        }
    }
}
