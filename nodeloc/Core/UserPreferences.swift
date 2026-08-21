//
//  UserPreferences.swift
//  nodeloc
//
//  The account's Discourse preferences: the enums, the wire model, and the
//  store that reads and writes them.
//
//  Raw values here are Discourse's own integers (app/models/user_option.rb).
//  They are part of the wire format, so renumbering any of them silently
//  changes what the server stores.
//

import SwiftUI

// MARK: - Enums

/// `interface_color_mode`. Constants from `UserOption::AUTO_MODE` and friends.
enum InterfaceColorMode: Int, CaseIterable, Identifiable {
    case auto = 1
    case light = 2
    case dark = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `nil` follows the system, which is what "auto" means.
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// `text_size`. Note `normal` is 0, not the middle of the range — sorting by
/// raw value would put it first rather than in the centre.
enum TextSize: Int, CaseIterable, Identifiable {
    case smallest = 4
    case smaller = 3
    case normal = 0
    case larger = 1
    case largest = 2

    var id: Int { rawValue }

    /// Smallest to largest, which is not raw-value order.
    static let ordered: [TextSize] = [.smallest, .smaller, .normal, .larger, .largest]

    var label: String {
        switch self {
        case .smallest: return "最小"
        case .smaller: return "更小"
        case .normal: return "正常"
        case .larger: return "更大"
        case .largest: return "最大"
        }
    }

    /// Multiplier applied to every font in `Theme`. Matches the web's steps on
    /// its 15px base; verified that 11pt stays at 10pt and 32pt reaches 36pt.
    var scale: CGFloat {
        switch self {
        case .smallest: return 0.875
        case .smaller: return 0.9375
        case .normal: return 1.0
        case .larger: return 1.0625
        case .largest: return 1.125
        }
    }
}

/// `email_level` and `email_messages_level` share this.
enum EmailLevel: Int, CaseIterable, Identifiable {
    case always = 0
    case onlyWhenAway = 1
    case never = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .always: return "始终"
        case .onlyWhenAway: return "只在离开时"
        case .never: return "从不"
        }
    }
}

enum PreviousRepliesLevel: Int, CaseIterable, Identifiable {
    case always = 0
    case unlessEmailed = 1
    case never = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .always: return "始终"
        case .unlessEmailed: return "除非之前发送过"
        case .never: return "从不"
        }
    }
}

enum LikeNotificationFrequency: Int, CaseIterable, Identifiable {
    case always = 0
    case firstTimeAndDaily = 1
    case firstTime = 2
    case never = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .always: return "始终"
        case .firstTimeAndDaily: return "每日帖子第一次被赞"
        case .firstTime: return "帖子第一次被赞"
        case .never: return "从不"
        }
    }
}

enum PushNotificationLevel: Int, CaseIterable, Identifiable {
    case none = 0
    case all = 1
    case chatOnly = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "已禁用"
        case .all: return "已启用"
        case .chatOnly: return "仅为聊天启用"
        }
    }
}

enum TitleCountMode: Int, CaseIterable, Identifiable {
    case notifications = 0
    case contextual = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .notifications: return "新通知"
        case .contextual: return "新页面内容"
        }
    }
}

enum CompositionMode: Int, CaseIterable, Identifiable {
    case markdown = 0
    case rich = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .rich: return "富文本"
        }
    }
}

enum SendShortcut: Int, CaseIterable, Identifiable {
    case enter = 0
    case metaEnter = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .enter: return "Enter"
        case .metaEnter: return "⌘ + Enter"
        }
    }
}

enum DefaultCalendar: Int, CaseIterable, Identifiable {
    case noneSelected = 0
    case ics = 1
    case google = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .noneSelected: return "未选择"
        case .ics: return "ICS"
        case .google: return "Google 日历"
        }
    }
}

/// `homepage_id`, from `UserOption::HOMEPAGES`.
enum HomepageChoice: Int, CaseIterable, Identifiable {
    case latest = 1
    case categories = 2
    case unread = 3
    case new = 4
    case top = 5
    case bookmarks = 6
    case unseen = 7
    case hot = 8

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .latest: return "最新"
        case .categories: return "类别"
        case .unread: return "未读"
        case .new: return "新"
        case .top: return "热门"
        case .bookmarks: return "书签"
        case .unseen: return "未浏览"
        case .hot: return "热"
        }
    }
}

/// `notification_level_when_replying`, reusing Discourse's notification levels.
enum ReplyNotificationLevel: Int, CaseIterable, Identifiable {
    case doNothing = 0
    case trackTopic = 2
    case watchTopic = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .watchTopic: return "关注话题"
        case .trackTopic: return "跟踪话题"
        case .doNothing: return "不进行操作"
        }
    }
}

/// `new_topic_duration_minutes`, from `NewTopicDurationSiteSetting`.
enum NewTopicDuration: Int, CaseIterable, Identifiable {
    case notViewed = -1
    case lastHere = -2
    case afterOneDay = 1440
    case afterTwoDays = 2880
    case afterOneWeek = 10080
    case afterTwoWeeks = 20160

    var id: Int { rawValue }

    static let ordered: [NewTopicDuration] = [
        .notViewed, .lastHere, .afterOneDay, .afterTwoDays, .afterOneWeek, .afterTwoWeeks,
    ]

    var label: String {
        switch self {
        case .notViewed: return "我还没看过"
        case .lastHere: return "在我上次访问后创建"
        case .afterOneDay: return "在过去一天内创建"
        case .afterTwoDays: return "在过去 2 天内创建"
        case .afterOneWeek: return "在过去一周内创建"
        case .afterTwoWeeks: return "在过去 2 周内创建"
        }
    }
}

/// `auto_track_topics_after_msecs`, from `AutoTrackDurationSiteSetting`.
enum AutoTrackDuration: Int, CaseIterable, Identifiable {
    case never = -1
    case immediately = 0
    case after30Seconds = 30000
    case after1Minute = 60000
    case after2Minutes = 120000
    case after3Minutes = 180000
    case after4Minutes = 240000
    case after5Minutes = 300000
    case after10Minutes = 600000

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never: return "从不"
        case .immediately: return "立即"
        case .after30Seconds: return "30 秒后"
        case .after1Minute: return "1 分钟后"
        case .after2Minutes: return "2 分钟后"
        case .after3Minutes: return "3 分钟后"
        case .after4Minutes: return "4 分钟后"
        case .after5Minutes: return "5 分钟后"
        case .after10Minutes: return "10 分钟后"
        }
    }
}

// MARK: - Wire model

/// `user_option` as the server sends it. Every field is optional: Discourse
/// serializes a different subset depending on who is asking, and a missing key
/// must not fail the whole decode.
struct UserPreferences: Codable, Equatable {
    // Interface
    var interfaceColorMode: Int?
    var textSize: String?
    var homepageId: Int?
    var automaticallyTranslate: Bool?
    var understoodLanguages: [String]?
    var colorSchemeId: Int?
    var darkSchemeId: Int?
    var themeIds: [Int]?

    // Notifications
    var pushNotificationLevel: Int?
    var likeNotificationFrequency: Int?
    var notifyOnLinkedPosts: Bool?
    var enableUpcomingChangeAvailableNotifications: Bool?

    // Email
    var emailLevel: Int?
    var emailMessagesLevel: Int?
    var emailDigests: Bool?
    var digestAfterMinutes: Int?
    var emailPreviousReplies: Int?
    var emailInReplyTo: Bool?
    var includeTl0InDigests: Bool?
    var mailingListMode: Bool?
    var mailingListModeFrequency: Int?

    // Tracking
    var newTopicDurationMinutes: Int?
    var autoTrackTopicsAfterMsecs: Int?
    var notificationLevelWhenReplying: Int?
    var topicsUnreadWhenClosed: Bool?
    var watchedPrecedenceOverMuted: Bool?
    var automaticallyUnpinTopics: Bool?

    // Privacy
    var hideProfile: Bool?
    var hidePresence: Bool?
    var allowPrivateMessages: Bool?
    var enableAllowedPmUsers: Bool?

    // Other
    var timezone: String?
    var defaultCalendar: Int?
    var bookmarkAutoDeletePreference: Int?
    var skipNewUserTips: Bool?
    var compositionMode: Int?
    var seenPopups: [Int]?

    // Web-only: these save to the account but have no effect in this app.
    var externalLinksInNewTab: Bool?
    var dynamicFavicon: Bool?
    var enableQuoting: Bool?
    var enableSmartLists: Bool?
    var enableMarkdownMonospaceFont: Bool?
    /// A name, not an integer: `UserOption#title_count_mode` reads through
    /// `Enum#[]`, which maps the stored key back to its symbol.
    var titleCountMode: String?
    var sendShortcut: Int?
    var sidebarLinkToFilteredList: Bool?
    var sidebarShowCountOfNewItems: Bool?

    /// Added by discourse-community, not core: "compact" / "expand" / "card".
    var communityViewMode: String?

    /// `text_size` arrives as a name ("normal"), not the integer, so it is
    /// mapped through the enum's label rather than its raw value.
    var resolvedTextSize: TextSize {
        switch textSize {
        case "smallest": return .smallest
        case "smaller": return .smaller
        case "larger": return .larger
        case "largest": return .largest
        default: return .normal
        }
    }

    var resolvedColorMode: InterfaceColorMode {
        interfaceColorMode.flatMap(InterfaceColorMode.init(rawValue:)) ?? .auto
    }

    /// Also name-based on the wire, like `text_size`.
    var resolvedTitleCountMode: TitleCountMode {
        titleCountMode == "contextual" ? .contextual : .notifications
    }
}

extension TitleCountMode {
    var wireName: String {
        switch self {
        case .notifications: return "notifications"
        case .contextual: return "contextual"
        }
    }
}

/// The wire name for a `TextSize`, for sending back.
extension TextSize {
    var wireName: String {
        switch self {
        case .smallest: return "smallest"
        case .smaller: return "smaller"
        case .normal: return "normal"
        case .larger: return "larger"
        case .largest: return "largest"
        }
    }
}

// MARK: - Store

/// Reads and writes the account's preferences.
///
/// Two of them — colour mode and text size — decide how the whole app draws, so
/// they are mirrored into `UserDefaults` and read back synchronously at launch.
/// Waiting for the network would show one frame in the wrong theme and size.
@MainActor
@Observable
final class UserPreferencesStore {
    static let shared = UserPreferencesStore()

    private enum Key {
        static let colorMode = "prefInterfaceColorMode"
        static let textSize = "prefTextSize"
    }

    private let client = DiscourseClient()

    private(set) var preferences = UserPreferences()
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorText: String?

    /// Mirrored locally so the first frame is already correct.
    private(set) var colorMode: InterfaceColorMode
    private(set) var textSize: TextSize

    /// Read by `Theme.body`/`Theme.heading` on every font construction, so it
    /// must stay a cheap stored-property read rather than a lookup.
    private(set) var textScale: CGFloat

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        let storedMode = defaults.object(forKey: Key.colorMode) as? Int
        let storedSize = defaults.object(forKey: Key.textSize) as? Int

        colorMode = storedMode.flatMap(InterfaceColorMode.init(rawValue:)) ?? .auto
        let size = storedSize.flatMap(TextSize.init(rawValue:)) ?? .normal
        textSize = size
        textScale = size.scale
    }

    // MARK: Loading

    /// Pulls `user_option` from the signed-in session. Preferences are only
    /// serialized for their owner, so this is meaningless while signed out.
    func load(force: Bool = false) async {
        guard DiscourseAuth.shared.isAuthenticated else { return }
        guard force || !loaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let response = try? await client.currentUser() else { return }
        loaded = true
        apply(response.currentUser.userOption)
    }

    /// Adopts a payload the app already fetched, so opening settings doesn't
    /// refetch what the launch path just read.
    func apply(_ option: UserPreferences?) {
        guard let option else { return }
        preferences = option
        adoptDisplayPreferences(from: option)
    }

    /// Mirrors the two display-affecting values so the next launch can draw
    /// correctly before any network call returns.
    private func adoptDisplayPreferences(from option: UserPreferences) {
        colorMode = option.resolvedColorMode
        UserDefaults.standard.set(colorMode.rawValue, forKey: Key.colorMode)

        textSize = option.resolvedTextSize
        textScale = textSize.scale
        UserDefaults.standard.set(textSize.rawValue, forKey: Key.textSize)
    }

    // MARK: Saving

    /// Applies a change locally, then sends it. On failure the previous value is
    /// restored so the row never shows a setting the server rejected.
    func save(_ mutate: (inout UserPreferences) -> Void, items: [(String, String)]) async {
        guard let username = DiscourseAuth.shared.username else { return }

        let snapshot = preferences
        var updated = preferences
        mutate(&updated)
        preferences = updated
        adoptDisplayPreferences(from: updated)

        isSaving = true
        defer { isSaving = false }

        do {
            try await client.updatePreferences(username: username, items: items)
        } catch {
            preferences = snapshot
            adoptDisplayPreferences(from: snapshot)
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Convenience for a single scalar field.
    func save<Value>(
        _ keyPath: WritableKeyPath<UserPreferences, Value?>,
        _ value: Value,
        wireKey: String,
        wireValue: String
    ) async {
        await save({ $0[keyPath: keyPath] = value }, items: [(wireKey, wireValue)])
    }
}
