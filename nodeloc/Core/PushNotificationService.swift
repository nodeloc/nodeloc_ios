//
//  PushNotificationService.swift
//  nodeloc
//
//  Message push, two ways, in order of preference:
//
//   1. **APNs.** The device registers, hands its token to the site
//      (`/mobile/push/register`), and the server pushes. Real delivery:
//      immediate, and it works with the app closed. `RemoteNotifications.swift`
//      receives the token; `SERVER_TASKS_PUSH.md` is the server's half.
//
//   2. **Polling, as a fallback.** A background refresh reads
//      notifications.json and posts what is new as local banners. This is what
//      the app shipped with, and it stays for the case that matters: the site
//      has not deployed the push endpoints yet, so registration 404s. It is
//      *off* whenever APNs is live, or every notification would arrive twice.
//
//  Needs three things set in Xcode (none can be added from code):
//   1. Signing & Capabilities → Background Modes → Background fetch *and*
//      Remote notifications.
//   2. Signing & Capabilities → + Capability → Push Notifications.
//   3. Info → BGTaskSchedulerPermittedIdentifiers containing `refreshTaskID`.
//  Without them the service degrades to no-ops instead of crashing
//  (BGTaskScheduler traps when registering an unlisted identifier).
//

import SwiftUI
import UIKit
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
        case .replies: return AppString("回复与提及")
        case .likes: return AppString("点赞")
        case .privateMessages: return AppString("私信")
        case .system: return AppString("徽章与系统通知")
        }
    }

    var detail: String {
        switch self {
        case .replies: return AppString("有人回复、引用或提及你")
        case .likes: return AppString("有人点赞你的帖子或回复")
        case .privateMessages: return AppString("收到新的私信")
        case .system: return AppString("徽章授予、群组消息等")
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
    /// The token the server was last told about, so a relaunch doesn't re-post
    /// an unchanged one and a changed one is noticed.
    private static let registeredTokenKey = "nodeloc.push.apns_token"

    private let client = DiscourseClient()
    let preferences = PushPreferences.shared

    /// Mirrors the system permission so the settings page can react to it.
    var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// A tapped banner's deep link, consumed by ContentView and routed through
    /// `LinkRouter` like any other URL.
    var routedURL: URL?

    /// This device's APNs token once iOS has issued one.
    private(set) var deviceToken: String?

    /// True once the site has accepted the token: real pushes are coming, so
    /// the polling fallback stands down.
    private(set) var isRemoteDeliveryLive = false

    /// Why APNs is unavailable, when it is. Kept rather than logged: the
    /// settings page tells the reader which of the two paths is running, and
    /// "no valid aps-environment" is a build-configuration mistake worth
    /// seeing rather than a silent fall back to polling.
    private(set) var remoteRegistrationError: String?

    private var registeredToken: String? {
        get { UserDefaults.standard.string(forKey: Self.registeredTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.registeredTokenKey) }
    }

    /// `development` for a debug build, `production` otherwise — APNs keeps
    /// separate token spaces, and a token from one is meaningless to the
    /// other. The server needs to know which gateway to use.
    private var apnsEnvironment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

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
            // Otherwise the banners stop only because iOS is asked not to show
            // them, while the server keeps sending.
            Task { await unregisterFromServer() }
            return false
        }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        preferences.isEnabled = granted
        if granted {
            registerWithAPNs()
            // Armed either way: until the site accepts a token there is
            // nothing else delivering, and `checkForNewNotifications` stands
            // itself down once there is.
            scheduleBackgroundRefresh()
        }
        return granted
    }

    // MARK: APNs

    /// Asks iOS for a device token. Safe to call repeatedly — iOS answers from
    /// its cache — so every path that could have changed the answer does.
    func registerWithAPNs() {
        guard preferences.isEnabled,
              authorizationStatus == .authorized || authorizationStatus == .provisional
        else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Re-attempts registration now that something that gates it may have
    /// changed — in practice, a session.
    ///
    /// Needed because the two events are racing on a cold start: iOS answers
    /// with a token about a second in, while the credential is still being
    /// restored, and `sendTokenIfNeeded` quietly gives up on a signed-out app.
    /// Without this the device stayed unregistered until the *next* time the
    /// app came to the foreground — which looked exactly like the server not
    /// having the endpoint.
    func syncRegistration() async {
        registerWithAPNs()
        await sendTokenIfNeeded()
    }

    /// The token arrived. Sends it to the site unless it has already been sent.
    func deviceTokenArrived(_ token: String) async {
        deviceToken = token
        remoteRegistrationError = nil
        await sendTokenIfNeeded()
    }

    func remoteRegistrationFailed(_ error: Error) {
        isRemoteDeliveryLive = false
        remoteRegistrationError = error.localizedDescription
    }

    /// Posts the token, and only then treats remote delivery as live.
    ///
    /// A 404 is the expected answer while the site has not deployed the
    /// endpoints, and it is not an error worth showing: the polling fallback
    /// covers it, which is the whole reason that code is still here.
    /// The token a registration POST is in flight for.
    private var registeringToken: String?

    private func sendTokenIfNeeded(force: Bool = false) async {
        guard let deviceToken, DiscourseAuth.shared.isAuthenticated else { return }
        guard force || deviceToken != registeredToken || !isRemoteDeliveryLive else { return }
        // The token and the restored credential race at launch, so this runs
        // two or three times at once; one POST is enough.
        guard registeringToken != deviceToken else { return }
        registeringToken = deviceToken
        defer { registeringToken = nil }
        do {
            try await client.registerPushDevice(token: deviceToken)
            registeredToken = deviceToken
            isRemoteDeliveryLive = true
            remoteRegistrationError = nil
        } catch {
            isRemoteDeliveryLive = false
            // A 404 means the endpoints aren't deployed, which is the state
            // the fallback exists for — not something to report.
            if case DiscourseError.badResponse(404, _, _) = error {
                remoteRegistrationError = nil
            } else {
                remoteRegistrationError = error.localizedDescription
            }
        }
    }

    /// Signing out, or turning push off: the site must stop pushing to this
    /// device. Best effort — a failure here is not something the reader can
    /// act on, and the server drops tokens APNs reports as gone anyway.
    func unregisterFromServer() async {
        guard let token = registeredToken else { return }
        registeredToken = nil
        isRemoteDeliveryLive = false
        try? await client.unregisterPushDevice(token: token)
    }

    /// A push arrived while the app was backgrounded or suspended.
    ///
    /// The payload is not turned into a banner here: an alert push is already
    /// shown by iOS, and a silent one is deliberately quiet. What it is for is
    /// keeping the counts honest — the inbox badge is what the reader sees on
    /// the tab, and it would otherwise be as stale as the last foreground.
    func remoteNotificationArrived(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // The watermark moves with the push, so the polling fallback — if it
        // ever runs again — doesn't banner what APNs has already delivered.
        if let id = (userInfo["notification_id"] as? Int)
            ?? Int(userInfo["notification_id"] as? String ?? "") {
            lastSeenID = max(lastSeenID, id)
        }
        // `reload`, because the inbox's unread counts are what the tab badge
        // reads and there is no narrower call for them.
        await MessageCenterStore.shared.reload()
        return .newData
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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
            registerWithAPNs()
            // Covers the two cases a token alone doesn't: the site deployed
            // the endpoint since the last try, and the reader signed in after
            // the token had already been issued.
            await sendTokenIfNeeded()
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
        // Nothing to do when the server is pushing: this would banner the same
        // notifications a second time.
        guard !isRemoteDeliveryLive else { return }
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
        let userInfo = response.notification.request.content.userInfo
        if let string = userInfo["url"] as? String, let url = URL(string: string) {
            routedURL = url
            return
        }
        // A remote push from the server: mark it read, then open the post it
        // names (or its site path).
        if let id = Self.int(userInfo["notification_id"]) {
            Task { _ = try? await client.markNotificationRead(id: id) }
        }
        routedURL = Self.remoteTarget(userInfo)
    }

    /// Where a server push points: the topic's floor when it names one,
    /// otherwise its site path.
    static func remoteTarget(_ userInfo: [AnyHashable: Any]) -> URL? {
        if let topicID = int(userInfo["topic_id"]) {
            var path = "t/topic/\(topicID)"
            if let number = int(userInfo["post_number"]), number > 1 { path += "/\(number)" }
            return DiscourseConfig.baseURL.appending(path: path)
        }
        if let path = userInfo["path"] as? String, !path.isEmpty {
            return URL(string: path, relativeTo: DiscourseConfig.baseURL)?.absoluteURL
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

}
