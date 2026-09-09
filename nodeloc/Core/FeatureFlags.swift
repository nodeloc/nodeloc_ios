//
//  FeatureFlags.swift
//  nodeloc
//
//  Server-controlled switches for the two features App Review is most likely
//  to argue about: the HTML5 mini apps (guideline 4.7) and user-run 抽奖
//  (guideline 5.3).
//
//  The point is to be able to turn either one off from the server without
//  shipping a binary. A rejection on one feature otherwise blocks the whole
//  release and restarts the review queue.
//
//  Two deliberate choices:
//
//  * Defaults are *on*. The endpoint may not exist yet, and a missing config
//    must not take working features away.
//  * The last answer is persisted. Once the server has said "off", a launch
//    with no network keeps it off — otherwise a flaky connection would quietly
//    re-enable exactly the thing that got the app rejected.
//

import Foundation

@MainActor
@Observable
final class FeatureFlags {
    static let shared = FeatureFlags()

    /// Running HTML5 mini apps in a web view. Off leaves the directory and each
    /// app's discussion reachable — only the 开始游戏 launch disappears, which is
    /// the part guideline 4.7 governs.
    private(set) var miniAppsEnabled: Bool

    /// Creating and entering 抽奖. Red envelopes are separate: claiming one
    /// costs nothing, so they aren't a contest.
    private(set) var lotteryEnabled: Bool

    /// Whether the profile page may use `/mobile/profile.json` instead of
    /// fanning out to five endpoints.
    ///
    /// Defaults **off**, which is the opposite of the two above and deliberate:
    /// those guard features that already exist and must not disappear when the
    /// config is unreachable, while this one guards an endpoint that may not be
    /// deployed. Off simply means the profile page loads the way it always has.
    private(set) var profileAggregateEnabled: Bool

    private enum Key {
        static let miniApps = "app.flags.miniApps"
        static let lottery = "app.flags.lottery"
        static let profileAggregate = "app.flags.profileAggregate"
    }

    private init() {
        let defaults = UserDefaults.standard
        miniAppsEnabled = defaults.object(forKey: Key.miniApps) as? Bool ?? true
        lotteryEnabled = defaults.object(forKey: Key.lottery) as? Bool ?? true
        profileAggregateEnabled = defaults.object(forKey: Key.profileAggregate) as? Bool ?? false
    }

    /// Reads the switches from the companion plugin. Failure is silent and
    /// leaves the last known values in place.
    func refresh() async {
        guard let config = try? await DiscourseClient().featureFlags() else { return }
        apply(config)
    }

    private func apply(_ config: FeatureFlagConfig) {
        let defaults = UserDefaults.standard
        if let value = config.miniAppsEnabled {
            miniAppsEnabled = value
            defaults.set(value, forKey: Key.miniApps)
        }
        if let value = config.lotteryEnabled {
            lotteryEnabled = value
            defaults.set(value, forKey: Key.lottery)
        }
        if let value = config.profileAggregateEnabled {
            profileAggregateEnabled = value
            defaults.set(value, forKey: Key.profileAggregate)
        }
    }
}

// MARK: - Mini-app gating (guideline 4.7)

/// The consent and age checks guideline 4.7 requires before a mini app runs.
///
/// 4.7.3 wants consent "in each instance" that data or permissions are shared,
/// so approval is recorded per app rather than once for the section. 4.7.5
/// wants access limited by verified or declared age; the forum doesn't carry a
/// birthdate, so the age is declared here and kept on the device.
@MainActor
enum MiniAppGate {
    /// Must match the app's App Store age rating. Raising the rating without
    /// raising this would let under-age users into software the rating covers.
    static let minimumAge = 17

    private static let ageKey = "app.miniapp.declaredBirthYear"
    private static func consentKey(_ slug: String) -> String { "app.miniapp.consent.\(slug)" }

    /// Nil until the reader has declared an age.
    static var declaredBirthYear: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: ageKey)
            return value > 0 ? value : nil
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: ageKey)
                return
            }
            UserDefaults.standard.set(newValue, forKey: ageKey)
        }
    }

    /// Declared and old enough. Unknown counts as *not* satisfied, so the
    /// prompt appears rather than being skipped.
    static var isAgeSatisfied: Bool {
        guard let year = declaredBirthYear else { return false }
        let thisYear = Calendar.current.component(.year, from: Date())
        return thisYear - year >= minimumAge
    }

    /// Declared, but under the app's rating — a distinct case from "not asked",
    /// because it needs an explanation rather than another prompt.
    static var isUnderAge: Bool {
        declaredBirthYear != nil && !isAgeSatisfied
    }

    static func hasConsented(to slug: String) -> Bool {
        UserDefaults.standard.bool(forKey: consentKey(slug))
    }

    static func recordConsent(for slug: String) {
        UserDefaults.standard.set(true, forKey: consentKey(slug))
    }
}
