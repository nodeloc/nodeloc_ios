//
//  PushNotificationService.swift
//  nodeloc
//
//  Message push, done client-side: a background refresh polls
//  notifications.json and posts what's new as local notification banners.
//  There is no APNs relay — Discourse only pushes to the official app's
//  server — so delivery rides on BGAppRefreshTask, which iOS schedules
//  opportunistically for regularly-used apps.
//
//  Needs two things set in Xcode (they can't be added from code):
//   1. Signing & Capabilities → Background Modes → Background fetch.
//   2. Info → BGTaskSchedulerPermittedIdentifiers containing `refreshTaskID`.
//  Without them the service degrades to no-ops instead of crashing
//  (BGTaskScheduler traps when registering an unlisted identifier).
//

import SwiftUI
import BackgroundTasks
import UserNotifications

// MARK: - What the user allows

/// The notification families a user can allow or silence in settings, bucketed
/// the same way the inbox groups its rows (`NotificationKind`).
enum PushCategory: String, CaseIterable, Identifiable {
    case replies
    case likes
    case privateMessages
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replies: return "回复与提及"
        case .likes: return "点赞"
        case .privateMessages: return "私信"
        case .system: return "徽章与系统通知"
        }
    }

    var detail: String {
        switch self {
        case .replies: return "有人回复、引用或提及你"
        case .likes: return "有人点赞你的帖子或回复"
        case .privateMessages: return "收到新的私信"
        case .system: return "徽章授予、群组消息等"
        }
    }

    static func category(for kind: NotificationKind) -> PushCategory {
        switch kind {
        case .comment: return .replies
        case .like: return .likes
        case .message: return .privateMessages
        case .success, .star, .system: return .system
        }
    }
}

/// Which pushes this device shows. Local-only settings — they gate what this
/// device banners, not what the server records — so UserDefaults rather than
/// the account's user_options.
@MainActor
@Observable
final class PushPreferences {
    static let shared = PushPreferences()

    private static let enabledKey = "nodeloc.push.enabled"
    private static func key(for category: PushCategory) -> String {
        "nodeloc.push.allow.\(category.rawValue)"
    }

    /// Master switch; off until the user opts in.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var allowed: [PushCategory: Bool]

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        var loaded: [PushCategory: Bool] = [:]
        for category in PushCategory.allCases {
            // Every kind defaults to on; enabling push means everything until
            // the user narrows it.
            loaded[category] = UserDefaults.standard
                .object(forKey: Self.key(for: category)) as? Bool ?? true
        }
        allowed = loaded
    }

    func allows(_ category: PushCategory) -> Bool { allowed[category] ?? true }

    func setAllows(_ allow: Bool, for category: PushCategory) {
        allowed[category] = allow
        UserDefaults.standard.set(allow, forKey: Self.key(for: category))
    }
}

// MARK: - Service

@MainActor
@Observable
final class PushNotificationService: NSObject {
    static let shared = PushNotificationService()

    /// Must be listed in the Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskID = "com.nodeloc.notification-refresh"

    private static let lastSeenKey = "nodeloc.push.last_seen_id"

    private let client = DiscourseClient()
    let preferences = PushPreferences.shared

    /// Mirrors the system permission so the settings page can react to it.
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// A tapped banner's deep link, consumed by ContentView and routed through
    /// `LinkRouter` like any other URL.
    var routedURL: URL?

    /// Whether the background-task identifier is present in the Info.plist —
    /// the one part of setup that can't be done from code.
    var backgroundRefreshConfigured: Bool {
        let ids = Bundle.main
            .object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return ids?.contains(Self.refreshTaskID) == true
    }

    /// Newest notification id already handled, so a poll only banners what
    /// arrived after it. 0 means "never polled": that first pass only sets the
    /// baseline, so enabling push doesn't dump the whole unread backlog.
    private var lastSeenID: Int {
        get { UserDefaults.standard.integer(forKey: Self.lastSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSeenKey) }
    }

    private override init() {
        super.init()
    }

    // MARK: Lifecycle

    /// Call once from the App's init — BGTaskScheduler requires registration
    /// before the app finishes launching.
    func configure() {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundTask()
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Flips the master switch. Enabling asks for system permission when it's
    /// still undetermined; returns whether push ended up on.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            preferences.isEnabled = false
            return false
        }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        preferences.isEnabled = granted
        if granted { scheduleBackgroundRefresh() }
        return granted
    }

    /// The app is frontmost again: the in-app badge supersedes anything
    /// delivered, so clear the banners and the icon badge.
    func appDidBecomeActive() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        Task {
            try? await center.setBadgeCount(0)
            // The user may have changed the permission in system settings.
            await refreshAuthorizationStatus()
        }
    }

    // MARK: Background refresh

    private func registerBackgroundTask() {
        guard backgroundRefreshConfigured else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                let service = PushNotificationService.shared
                // Re-arm first so the chain survives even if this pass fails.
                service.scheduleBackgroundRefresh()
                await service.checkForNewNotifications()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    /// Asks iOS for the next poll; call when the app enters the background.
    /// Submitting again just replaces the pending request.
    func scheduleBackgroundRefresh() {
        guard backgroundRefreshConfigured, preferences.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Polling

    /// Fetches notifications and banners the new, allowed ones.
    func checkForNewNotifications() async {
        guard preferences.isEnabled,
              DiscourseAuth.shared.isAuthenticated,
              authorizationStatus == .authorized || authorizationStatus == .provisional,
              let response = try? await client.notifications() else { return }

        let watermark = lastSeenID
        // Advance past everything fetched — silenced kinds included — so
        // nothing banners twice or piles up for a later pass.
        if let newest = response.notifications.map(\.id).max(), newest > watermark {
            lastSeenID = newest
        }
        // First pass only establishes the baseline (see lastSeenID).
        guard watermark > 0 else { return }

        // Oldest first so banners stack in arrival order; capped so a long
        // gap doesn't dump a wall of banners.
        let fresh = response.notifications
            .filter { !$0.read && $0.id > watermark }
            .filter { preferences.allows(category(of: $0)) }
            .sorted { $0.id < $1.id }
            .suffix(5)

        let center = UNUserNotificationCenter.current()
        for notification in fresh {
            let kind = NotificationFormatter.kind(forType: notification.notificationType)
            let content = UNMutableNotificationContent()
            content.title = NotificationFormatter.displayName(for: notification, kind: kind)
            content.body = NotificationFormatter.text(for: notification, kind: kind)
            content.sound = .default
            // Group banners by family, like the settings toggles.
            content.threadIdentifier = PushCategory.category(for: kind).rawValue
            if let url = NotificationRouting.url(for: notification) {
                content.userInfo = ["url": url.absoluteString]
            }
            try? await center.add(
                UNNotificationRequest(
                    identifier: "discourse-notification-\(notification.id)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    private func category(of notification: DiscourseNotification) -> PushCategory {
        PushCategory.category(
            for: NotificationFormatter.kind(forType: notification.notificationType)
        )
    }
}

// MARK: - Banner presentation & taps

extension PushNotificationService: UNUserNotificationCenterDelegate {
    /// Nothing while the app is frontmost — the message tab's badge already
    /// shows it, and a banner over the very screen it points to is noise.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// A banner was tapped: surface its deep link for ContentView to route,
    /// same as a link tapped inside a post.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        routedURL = url
    }
}
