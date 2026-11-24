//
//  NodelocReports.swift
//  nodeloc
//
//  Report reasons and a few fixed labels the backend leaves to clients.
//

import Foundation

@MainActor
enum NodelocReports {
    /// The report reasons the backend accepts, in the `FlagType` shape the
    /// report sheet reads. Ids follow Discourse's where one exists (off-topic
    /// 3, spam 8, "something else" 7) so code that names those keeps working.
    static var flagTypes: [[String: Any]] {
        [
            flag(id: 8, key: "spam", name: AppString("垃圾广告"), description: AppString("广告、推广或重复刷屏的内容")),
            flag(id: 4, key: "harassment", name: AppString("人身攻击"), description: AppString("辱骂、骚扰或针对他人的攻击")),
            flag(id: 3, key: "off_topic", name: AppString("偏离主题"), description: AppString("与所在节点或主题无关")),
            flag(id: 12, key: "copyright", name: AppString("侵犯版权"), description: AppString("未经授权转载或盗用他人作品")),
            flag(id: 10, key: "illegal", name: AppString("违法内容"), description: AppString("违反法律法规的内容"), requireMessage: true),
            flag(id: 7, key: "notify_moderators", name: AppString("其他问题"), description: AppString("说明一下需要版主关注的原因"), requireMessage: true),
        ]
    }

    private static func flag(id: Int, key: String, name: String, description: String, requireMessage: Bool = false) -> [String: Any] {
        [
            "id": id,
            "name_key": key,
            "name": name,
            "description": description,
            "short_description": description,
            "is_flag": true,
            "require_message": requireMessage,
            "enabled": true,
            "applies_to": ["Post", "Topic"],
        ]
    }

    static func reason(forFlagType id: Int) -> String {
        switch id {
        case 8: return "spam"
        case 4: return "harassment"
        case 3: return "off_topic"
        case 12: return "copyright"
        case 10: return "illegal"
        default: return "other"
        }
    }

    /// A readable name for a points ledger entry without a memo.
    static func pointsKindLabel(_ kind: String) -> String {
        switch kind {
        case "checkin": return AppString("签到")
        case "tip": return AppString("打赏")
        case "tip_revoke": return AppString("撤回打赏")
        case "transfer": return AppString("转账")
        case "featured_reward": return AppString("精华奖励")
        case "app_spend", "pay": return AppString("应用消费")
        default:
            if kind.hasPrefix("red_envelope") { return AppString("红包") }
            if kind.hasPrefix("lottery") { return AppString("抽奖") }
            return kind
        }
    }
}

/// What the server's sign-in list said it supports, read by the sign-in
/// screens (the native Apple button only shows when the server has it).
@MainActor
enum NodelocAuthCapabilities {
    /// Remembered across launches: the provider list is cached with the rest
    /// of the site data and not re-asked every time.
    static var appleNative: Bool {
        get { UserDefaults.standard.bool(forKey: "nodeloc.auth.apple_native") }
        set { UserDefaults.standard.set(newValue, forKey: "nodeloc.auth.apple_native") }
    }
    static var providerURLs: [String: String] = [:]
}

/// Endpoints of the native sign-in flows, in one place because they are the
/// part of the contract most likely to be renamed.
nonisolated enum NodelocAuthPaths {
    static let login = "api/v1/auth/login"
    static let passkeyBegin = "api/v1/auth/passkey/begin"
    static let passkeyFinish = "api/v1/auth/passkey"
    static let register = "api/v1/auth/register"
    static let registerEmailCode = "api/v1/auth/register/email-code"
    static let logout = "api/v1/auth/logout"
    static let providers = "api/v1/auth/providers"
    /// Social sign-in: the provider round trip runs in the system browser
    /// sheet and ends at `nodeloc://auth?code=…`; the code is exchanged here.
    static func socialStart(provider: String) -> String { "auth/\(provider)" }
    static let socialExchange = "api/v1/auth/app/exchange"
    static let appleExchange = "api/v1/auth/apple/native"
}
