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
        case .auto: return AppString("自动")
        case .light: return AppString("浅色")
        case .dark: return AppString("深色")
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
        case .smallest: return AppString("最小")
        case .smaller: return AppString("更小")
        case .normal: return AppString("正常")
        case .larger: return AppString("更大")
        case .largest: return AppString("最大")
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
        case .always: return AppString("始终")
        case .onlyWhenAway: return AppString("只在离开时")
        case .never: return AppString("从不")
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
        case .always: return AppString("始终")
        case .unlessEmailed: return AppString("除非之前发送过")
        case .never: return AppString("从不")
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
        case .always: return AppString("始终")
        case .firstTimeAndDaily: return AppString("每日帖子第一次被赞")
        case .firstTime: return AppString("帖子第一次被赞")
        case .never: return AppString("从不")
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
        case .none: return AppString("已禁用")
        case .all: return AppString("已启用")
        case .chatOnly: return AppString("仅为聊天启用")
        }
    }
}

enum TitleCountMode: Int, CaseIterable, Identifiable {
    case notifications = 0
    case contextual = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .notifications: return AppString("新通知")
        case .contextual: return AppString("新页面内容")
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
        case .rich: return AppString("富文本")
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

    /// `UserOption#send_shortcut` is a Rails enum: it travels as its name, not
    /// the integer, both when read and when written.
    var wireName: String {
        switch self {
        case .enter: return "enter"
        case .metaEnter: return "meta_enter"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "enter": self = .enter
        case "meta_enter": self = .metaEnter
        default: return nil
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
        case .noneSelected: return AppString("未选择")
        case .ics: return "ICS"
        case .google: return AppString("Google 日历")
        }
    }

    /// `UserOption#default_calendar` is a Rails enum: it travels as its name,
    /// not the integer, both when read and when written.
    var wireName: String {
        switch self {
        case .noneSelected: return "none_selected"
        case .ics: return "ics"
        case .google: return "google"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "none_selected": self = .noneSelected
        case "ics": self = .ics
        case "google": self = .google
        default: return nil
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
        case .latest: return AppString("最新")
        case .categories: return AppString("类别")
        case .unread: return AppString("未读")
        case .new: return AppString("新")
        case .top: return AppString("热门")
        case .bookmarks: return AppString("书签")
        case .unseen: return AppString("未浏览")
        case .hot: return AppString("热")
        }
    }
}

/// Which list the home tab shows.
///
/// Deliberately *not* `homepage_id`. The default is the community feed at
/// `/best.json` (the discourse-community plugin — it answers with
/// `filter: community_feed`), and the site's `homepage_choices` has no value
/// for it, so this choice has nowhere to live on the server. It is therefore
/// local: seeded once from `homepage_id` so someone who set a homepage on the
/// website starts where they expect, and never written back — the website's own
/// default homepage stays theirs.
///
/// The cases are only the lists that both come back shaped like a topic list
/// and work while signed out. `categories` and `bookmarks` are neither, which
/// is why the app's list is shorter than the site's.
enum HomeFeed: Int, CaseIterable, Identifiable {
    case best = 0
    case latest = 1
    case hot = 2
    case top = 3

    var id: Int { rawValue }

    var path: String {
        switch self {
        case .best: return "best.json"
        case .latest: return "latest.json"
        case .hot: return "hot.json"
        case .top: return "top.json"
        }
    }

    /// `best` picks a fresh random ordering on every seedless request and
    /// discloses the seed it used only in `more_topics_url`. Without carrying
    /// that seed forward, asking for page 2 reshuffles the whole feed and
    /// silently skips topics — so this marks the feeds whose pagination needs
    /// it.
    var isSeeded: Bool { self == .best }

    var label: String {
        switch self {
        // The plugin's own name for the feed; `HomepageChoice` has no
        // equivalent to borrow.
        case .best: return AppString("精选")
        // The other three are the same lists the website offers, so they keep
        // `HomepageChoice`'s wording.
        case .latest: return AppString("最新")
        case .hot: return AppString("热")
        case .top: return AppString("热门")
        }
    }

    /// The nearest app feed to a website homepage choice, used only to pick a
    /// starting value. Everything the home list can't render becomes `best`.
    init(seededFrom choice: HomepageChoice?) {
        switch choice {
        case .latest: self = .latest
        case .hot: self = .hot
        case .top: self = .top
        default: self = .best
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
        case .watchTopic: return AppString("关注话题")
        case .trackTopic: return AppString("跟踪话题")
        case .doNothing: return AppString("不进行操作")
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
        case .notViewed: return AppString("我还没看过")
        case .lastHere: return AppString("在我上次访问后创建")
        case .afterOneDay: return AppString("在过去一天内创建")
        case .afterTwoDays: return AppString("在过去 2 天内创建")
        case .afterOneWeek: return AppString("在过去一周内创建")
        case .afterTwoWeeks: return AppString("在过去 2 周内创建")
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
        case .never: return AppString("从不")
        case .immediately: return AppString("立即")
        case .after30Seconds: return AppString("30 秒后")
        case .after1Minute: return AppString("1 分钟后")
        case .after2Minutes: return AppString("2 分钟后")
        case .after3Minutes: return AppString("3 分钟后")
        case .after4Minutes: return AppString("4 分钟后")
        case .after5Minutes: return AppString("5 分钟后")
        case .after10Minutes: return AppString("10 分钟后")
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
    /// A Rails enum name ("none_selected"/"ics"/"google"), not an integer.
    var defaultCalendar: String?
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
    /// A Rails enum name ("enter"/"meta_enter"), not an integer.
    var sendShortcut: String?
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
        static let homeFeed = "prefHomeFeed"
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

    /// Local, unlike the rest of this type — see `HomeFeed`. Nil means nobody
    /// has chosen yet, which is what lets `homepage_id` seed it exactly once
    /// without overwriting a later choice.
    private var storedHomeFeed: HomeFeed?

    /// Which list the home tab loads.
    var homeFeed: HomeFeed { storedHomeFeed ?? .best }

    private var loaded = false

    private init() {
        let defaults = UserDefaults.standard
        let storedMode = defaults.object(forKey: Key.colorMode) as? Int
        let storedSize = defaults.object(forKey: Key.textSize) as? Int

        colorMode = storedMode.flatMap(InterfaceColorMode.init(rawValue:)) ?? .auto
        let size = storedSize.flatMap(TextSize.init(rawValue:)) ?? .normal
        textSize = size
        textScale = size.scale
        storedHomeFeed = (defaults.object(forKey: Key.homeFeed) as? Int)
            .flatMap(HomeFeed.init(rawValue:))
    }

    func setHomeFeed(_ feed: HomeFeed) {
        storedHomeFeed = feed
        UserDefaults.standard.set(feed.rawValue, forKey: Key.homeFeed)
    }

    var homeFeedBinding: Binding<HomeFeed> {
        Binding(get: { self.homeFeed }, set: { self.setHomeFeed($0) })
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

        seedHomeFeed(from: option)
    }

    /// Takes the website's default homepage as the *initial* app feed, once.
    ///
    /// Only when nothing is stored: after that the local choice stands, so
    /// this can't undo a selection, and picking a feed in the app never
    /// touches `homepage_id`.
    private func seedHomeFeed(from option: UserPreferences) {
        guard storedHomeFeed == nil else { return }
        let choice = option.homepageId.flatMap(HomepageChoice.init(rawValue:))
        setHomeFeed(HomeFeed(seededFrom: choice))
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

// MARK: - Bindings

extension UserPreferencesStore {
    /// A binding for a boolean option that writes through to the server.
    func toggle(
        _ keyPath: WritableKeyPath<UserPreferences, Bool?>,
        _ wireKey: String,
        default fallback: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { self.preferences[keyPath: keyPath] ?? fallback },
            set: { newValue in
                Task {
                    await self.save(
                        { $0[keyPath: keyPath] = newValue },
                        items: [(wireKey, newValue ? "true" : "false")]
                    )
                }
            }
        )
    }

    /// A binding for an integer-backed enum option.
    func choice<Option: RawRepresentable>(
        _ keyPath: WritableKeyPath<UserPreferences, Int?>,
        _ wireKey: String,
        default fallback: Option
    ) -> Binding<Option> where Option.RawValue == Int {
        Binding(
            get: {
                self.preferences[keyPath: keyPath]
                    .flatMap(Option.init(rawValue:)) ?? fallback
            },
            set: { newValue in
                Task {
                    await self.save(
                        { $0[keyPath: keyPath] = newValue.rawValue },
                        items: [(wireKey, String(newValue.rawValue))]
                    )
                }
            }
        )
    }

    /// A binding for a Rails-enum option whose value travels as its name
    /// ("ics", "meta_enter") rather than an integer. The enum keeps its `Int`
    /// raw value for the UI; only the wire form differs.
    func nameChoice<Option>(
        _ keyPath: WritableKeyPath<UserPreferences, String?>,
        _ wireKey: String,
        default fallback: Option,
        name: @escaping (Option) -> String,
        from: @escaping (String) -> Option?
    ) -> Binding<Option> {
        Binding(
            get: {
                self.preferences[keyPath: keyPath].flatMap(from) ?? fallback
            },
            set: { newValue in
                let wire = name(newValue)
                Task {
                    await self.save(
                        { $0[keyPath: keyPath] = wire },
                        items: [(wireKey, wire)]
                    )
                }
            }
        )
    }

    /// Colour mode and text size need their own bindings: both also drive the
    /// local mirror, and text size travels as a name rather than an integer.
    var colorModeBinding: Binding<InterfaceColorMode> {
        Binding(
            get: { self.colorMode },
            set: { newValue in
                Task {
                    await self.save(
                        { $0.interfaceColorMode = newValue.rawValue },
                        items: [("interface_color_mode", String(newValue.rawValue))]
                    )
                }
            }
        )
    }

    var textSizeBinding: Binding<TextSize> {
        Binding(
            get: { self.textSize },
            set: { newValue in
                Task {
                    await self.save(
                        { $0.textSize = newValue.wireName },
                        items: [("text_size", newValue.wireName)]
                    )
                }
            }
        )
    }

    var titleCountModeBinding: Binding<TitleCountMode> {
        Binding(
            get: { self.preferences.resolvedTitleCountMode },
            set: { newValue in
                Task {
                    await self.save(
                        { $0.titleCountMode = newValue.wireName },
                        items: [("title_count_mode", newValue.wireName)]
                    )
                }
            }
        )
    }

    /// Timezone is a free string (an IANA identifier).
    var timezoneBinding: Binding<String> {
        Binding(
            get: { self.preferences.timezone ?? TimeZone.current.identifier },
            set: { newValue in
                Task {
                    await self.save(
                        { $0.timezone = newValue },
                        items: [("timezone", newValue)]
                    )
                }
            }
        )
    }
}
