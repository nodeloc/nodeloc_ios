//
//  PackageShims.swift
//  NodelocKit
//
//  Stand-ins for the few app types the shared core refers to but which live
//  in SwiftUI/UIKit files the package cannot compile. Each mirrors exactly the
//  members the core uses; the app build checks the real ones, so a drift here
//  shows up as a compile error on the Mac, not as different behaviour.
//
//  Never add this file to the app target.
//

import Foundation

nonisolated func AppString(_ value: String) -> String { value }

nonisolated enum AppLanguage: String, Sendable {
    case simplifiedChinese = "zh-Hans"

    static var resolved: AppLanguage { .simplifiedChinese }
    var acceptLanguageHeader: String { "zh-CN,zh;q=0.9" }
    static var accountChoice: String?
}

/// `CurrentUser.userOption`; the adapter never fills it.
struct UserPreferences: Decodable {}

struct PostMedia: Identifiable, Hashable {
    let url: URL
    let width: Int?
    let height: Int?
    var variants: [ImageVariant] = []
    var id: URL { url }
}

struct ImageVariant: Hashable {
    let width: Int
    let url: URL
}

enum HomeFeed: Int, CaseIterable, Identifiable {
    case best = 0
    case latest = 1
    case hot = 2
    case top = 3
    var id: Int { rawValue }
}

extension String {
    func breakingLongTokens(every maxRun: Int = 18) -> String { self }
}

struct AppleSignInCredential: Sendable {
    let identityToken: String
    let nonce: String
    let authorizationCode: String?
    let email: String?
    let fullName: String?
}

nonisolated struct LotteryLevel: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var prize: String
    var quantity: Int

    init(id: UUID = UUID(), name: String = "", prize: String = "", quantity: Int = 1) {
        self.id = id
        self.name = name
        self.prize = prize
        self.quantity = quantity
    }

    var isComplete: Bool { !name.isEmpty && !prize.isEmpty && quantity > 0 }
}

nonisolated struct LotteryDraft: Sendable, Equatable {
    var title = ""
    var minParticipants = 5
    var maxParticipants = ""
    var maxTicketsPerUser = 10
    var minTrustLevel = 1
    var drawAt: Date?
    var levels: [LotteryLevel] = [LotteryLevel()]

    var completeLevels: [LotteryLevel] { levels.filter(\.isComplete) }

    var parsedMaxParticipants: Int? {
        let trimmed = maxParticipants.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Int(trimmed), value > 0 else { return nil }
        return value
    }
}
