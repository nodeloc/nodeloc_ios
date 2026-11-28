//
//  AppLocale.swift
//  nodeloc
//
//  Which language the interface speaks, and where that decision comes from.
//
//  Two sources, in order:
//    1. The account's own Discourse locale, once signed in and once the user
//       has actually chosen one on the forum. Someone who reads nodeloc.com in
//       Vietnamese expects the app to match.
//    2. The device's preferred languages, negotiated against what the app
//       ships. This is what a signed-out or never-configured user gets.
//
//  Switching is live: `Text` resolves its `LocalizedStringKey` against
//  `EnvironmentValues.locale` at render time, so overriding that at the root
//  re-localizes the whole tree without relaunching. (Measured: the same
//  `Text("Cancel")` renders 120pt wide under `en` and 76pt under `zh-Hans`.)
//  Code that builds strings outside a view can't read the environment, so it
//  goes through `AppString` instead, which forces the matching `.lproj`.
//

import Foundation
import SwiftUI

// MARK: - The languages the app speaks

/// The languages the app is built to speak. Raw values are the `.lproj` names,
/// which is also what `Localizable.xcstrings` keys its localizations by.
///
/// Listing a language here does not ship it — `available` does, by looking at
/// which translations made it into the bundle. Arabic and Persian are written
/// down because the plumbing (including `isRightToLeft`) is already in place,
/// but they stay unshipped until the RTL layout work is done; until then they
/// simply never appear in `available`.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case vietnamese = "vi"
    case indonesian = "id"
    case russian = "ru"
    case ukrainian = "uk"
    case arabic = "ar"
    case persian = "fa"

    var id: String { rawValue }

    /// The language's name in that language, which is how a language picker
    /// should always label itself.
    var endonym: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .vietnamese: return "Tiếng Việt"
        case .indonesian: return "Bahasa Indonesia"
        case .russian: return "Русский"
        case .ukrainian: return "Українська"
        case .arabic: return "العربية"
        case .persian: return "فارسی"
        }
    }

    /// Discourse's code for the same language. It uses underscored POSIX-ish
    /// names rather than BCP-47, and only some of them carry a region.
    var discourseCode: String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh_CN"
        case .traditionalChinese: return "zh_TW"
        case .japanese: return "ja"
        case .vietnamese: return "vi"
        case .indonesian: return "id"
        case .russian: return "ru"
        case .ukrainian: return "uk"
        case .arabic: return "ar"
        case .persian: return "fa_IR"
        }
    }

    /// `Accept-Language` value, which is what drives Discourse's *content*
    /// localization — the server swaps `fancy_title`, excerpts and cooked posts
    /// for their translations and flags it with `fancy_title_localized` /
    /// `is_localized`. Verified against the live site: one topic returns its
    /// title in English for `en` and in Japanese for `ja`.
    ///
    /// Built from `discourseCode` with hyphens rather than from `rawValue`: the
    /// header wants BCP-47 (`zh-CN`), while `rawValue` carries script subtags
    /// (`zh-Hans`) that Discourse's locale list doesn't use. A regioned tag also
    /// offers its bare language as a fallback, so `fa-IR` still matches a site
    /// that only lists `fa`.
    var acceptLanguageHeader: String {
        let tag = discourseCode.replacingOccurrences(of: "_", with: "-")
        guard let base = tag.split(separator: "-").first, String(base) != tag else { return tag }
        return "\(tag),\(base);q=0.9"
    }

    var isRightToLeft: Bool {
        self == .arabic || self == .persian
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var layoutDirection: LayoutDirection {
        isRightToLeft ? .rightToLeft : .leftToRight
    }

    /// The `.lproj` for this language, for lookups that can't read the
    /// SwiftUI environment. Falls back to the main bundle, which yields the
    /// source string rather than crashing if a language ever ships unbuilt.
    var bundle: Bundle { Self.bundles[self] ?? .main }

    /// Built once, immutably. A lazily-filled `var` cache would be a data race
    /// here: `AppString` is called from nonisolated code (validation in
    /// `ComposerFeatures`, `ImageEditModel`, `VideoExporter`), so two threads
    /// could mutate the dictionary at once. `static let` is initialized exactly
    /// once and never written again.
    private static let bundles: [AppLanguage: Bundle] = {
        var map: [AppLanguage: Bundle] = [:]
        for language in allCases {
            if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                map[language] = bundle
            }
        }
        return map
    }()

    // MARK: Matching

    /// Maps any language tag — BCP-47 from the system, or Discourse's
    /// underscored form — onto a language the app ships. `nil` when the app
    /// doesn't speak it.
    static func matching(tag rawTag: String) -> AppLanguage? {
        let tag = rawTag.replacingOccurrences(of: "_", with: "-")
        guard !tag.isEmpty else { return nil }
        let locale = Locale(identifier: tag)
        guard let code = locale.language.languageCode?.identifier else { return nil }

        switch code {
        case "zh":
            // "zh-Hans"/"zh-Hant" say it outright; "zh-TW" and Discourse's
            // "zh_TW" only imply it through the region.
            if let script = locale.language.script?.identifier {
                return script == "Hant" ? .traditionalChinese : .simplifiedChinese
            }
            let region = locale.region?.identifier ?? ""
            return ["TW", "HK", "MO"].contains(region) ? .traditionalChinese : .simplifiedChinese
        // Indonesian's ISO 639-1 code was renamed; some systems still say "in".
        case "in":
            return .indonesian
        default:
            return AppLanguage(rawValue: code)
        }
    }

    /// The languages whose translations are actually in the built app.
    ///
    /// The enum lists everything the app is *planned* to speak; this lists what
    /// it can speak today. Selecting a language with no `.lproj` would be worse
    /// than not offering it — `Text` would fall through to the source key,
    /// showing Chinese to someone who asked for Japanese — so every path that
    /// picks a language filters through here. Shipping a new translation is
    /// then just a matter of filling it in; this picks it up on its own.
    /// What the bundle ships never changes while the app runs.
    static let available: [AppLanguage] = {
        let shipped = Set(Bundle.main.localizations)
        return allCases.filter { shipped.contains($0.rawValue) }
    }()

    var isAvailable: Bool { Self.available.contains(self) }

    /// The best of the device's preferred languages that the app can speak.
    /// Read once: iOS relaunches the app when the device language changes,
    /// and `AppString` asks for this on every call — it showed up while
    /// scrolling, re-parsing every preferred-language tag each time.
    static let systemPreferred: AppLanguage = computeSystemPreferred()

    private static func computeSystemPreferred() -> AppLanguage {
        let shipped = available
        for tag in Locale.preferredLanguages {
            if let match = matching(tag: tag), shipped.contains(match) { return match }
        }
        return shipped.contains(.english) ? .english : (shipped.first ?? .english)
    }
}

// MARK: - Resolution

nonisolated extension AppLanguage {
    private static let accountKey = "app.language.account"

    /// The language the interface should be in right now.
    ///
    /// Read from `UserDefaults` rather than from the store so that code off the
    /// main actor — and the very first draw, before any network call returns —
    /// can still resolve it.
    static var resolved: AppLanguage {
        if let stored = UserDefaults.standard.string(forKey: accountKey),
           let language = AppLanguage(rawValue: stored),
           language.isAvailable {
            return language
        }
        return systemPreferred
    }

    /// The account's choice, or `nil` when it is following the device.
    static var accountChoice: AppLanguage? {
        get {
            UserDefaults.standard.string(forKey: accountKey).flatMap(AppLanguage.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: accountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: accountKey)
            }
        }
    }
}

/// Localizes outside a view, where `EnvironmentValues.locale` isn't reachable.
///
/// `Text` handles itself; this is for strings that go into toasts, alerts built
/// from model code, and anything else assembled before it reaches SwiftUI.
nonisolated func AppString(_ value: String.LocalizationValue) -> String {
    observeAppLanguage()
    let language = AppLanguage.resolved
    return String(localized: value, bundle: language.bundle, locale: language.locale)
}

/// Reads the store's language so a view body that calls `AppString` redraws
/// when the language changes.
///
/// `AppLanguage.resolved` comes from `UserDefaults`, which SwiftUI can't
/// observe: a view whose text came from `AppString` (rather than a `Text`
/// key, which follows the environment's locale) kept the old language until
/// something else happened to redraw it — most of the app, after a switch.
/// Touching the observable store inside the body registers the dependency.
/// Off the main thread there is no body to register, so it's skipped.
nonisolated private func observeAppLanguage() {
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated { _ = AppLocaleStore.shared.language }
}

/// For a Chinese source string that means two different things: the key
/// tells them apart in the catalog, and `value` is what shows where the
/// catalog has no entry (Chinese, the source text).
nonisolated func AppString(key: StaticString, default value: String.LocalizationValue) -> String {
    observeAppLanguage()
    let language = AppLanguage.resolved
    return String(localized: key, defaultValue: value, bundle: language.bundle, locale: language.locale)
}

// MARK: - The languages the server speaks

/// The languages nodeloc's server speaks — `internal/locale/locale.go`,
/// `all`, in its order. No endpoint lists them (`POST /api/v1/locale` only
/// validates against this table), so they are written down here.
///
/// The app's own text exists only for the languages in `AppLanguage.available`
/// (English and 简体中文 today). Choosing another server language asks the
/// server for it — notices, notifications, translated posts, node names — and
/// shows the app's own words in the closest language it has.
nonisolated struct ServerLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [ServerLanguage] = [
        .init(code: "zh-CN", name: "简体中文"), .init(code: "zh-TW", name: "繁體中文"),
        .init(code: "en", name: "English"), .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"), .init(code: "ru", name: "Русский"),
        .init(code: "es", name: "Español"), .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"), .init(code: "pt", name: "Português"),
        .init(code: "it", name: "Italiano"), .init(code: "tr", name: "Türkçe"),
        .init(code: "vi", name: "Tiếng Việt"), .init(code: "id", name: "Bahasa Indonesia"),
        .init(code: "th", name: "ไทย"), .init(code: "ar", name: "العربية"),
    ]

    /// The closest language the app has its own strings for.
    var appLanguage: AppLanguage {
        if let match = AppLanguage.matching(tag: code), match.isAvailable { return match }
        if code.hasPrefix("zh"), AppLanguage.simplifiedChinese.isAvailable { return .simplifiedChinese }
        return AppLanguage.english.isAvailable ? .english : AppLanguage.systemPreferred
    }

    /// Whether the app itself has strings in this very language.
    var appHasStrings: Bool { appLanguage.discourseCode.replacingOccurrences(of: "_", with: "-") == code }

    var acceptLanguage: String {
        code.contains("-") ? "\(code),\(code.prefix(2));q=0.9" : code
    }

    private static let key = "app.language.server"

    /// The account's language as this device last sent or adopted it — what
    /// `user.locale` should say when nothing changed elsewhere.
    static var lastSynced: String? {
        get { UserDefaults.standard.string(forKey: "app.language.synced") }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: "app.language.synced") }
            else { UserDefaults.standard.removeObject(forKey: "app.language.synced") }
        }
    }
    /// Read once per change, not per request.
    nonisolated(unsafe) private static var cached: ServerLanguage?? = nil

    /// The chosen language, nil when following the system.
    static var choice: ServerLanguage? {
        get {
            if let cached { return cached }
            let stored = UserDefaults.standard.string(forKey: key).flatMap { code in all.first { $0.code == code } }
            cached = .some(stored)
            return stored
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.code, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            cached = .some(newValue)
        }
    }
}

extension Notification.Name {
    /// The reading language changed: server texts on screen are stale.
    static let nodelocLanguageDidChange = Notification.Name("nodelocLanguageDidChange")
}

// MARK: - Store

/// Publishes the resolved language so the view tree redraws when it changes.
@MainActor
@Observable
final class AppLocaleStore {
    static let shared = AppLocaleStore()

    private(set) var language: AppLanguage

    private init() {
        language = AppLanguage.resolved
    }

    var locale: Locale { language.locale }
    var layoutDirection: LayoutDirection { language.layoutDirection }

    /// Adopts the locale the account has set on the forum.
    ///
    /// An empty `locale` means the user never chose one and Discourse is
    /// serving them the site default — that isn't a preference, so the device's
    /// language keeps winning. Only an explicit choice overrides it.
    func adopt(discourseLocale: String?) {
        adoptAccountLocale(discourseLocale)
    }

    /// The language saved on the account (`user.locale`, mobile-api.md
    /// 2026-11-28: `GET /api/v1/me` and every sign-in answer).
    ///
    /// Precedence:
    /// 1. Empty or missing says nothing — the choice on this device stays.
    ///    (Treating "empty" as "follow the system" is what wiped the choice
    ///    at every launch before the field existed.)
    /// 2. The same code this device last sent (or last adopted): already in
    ///    agreement, nothing to do — a 跟随系统 chosen here stands too.
    /// 3. A different code: it was changed on the web or another phone, and
    ///    the account wins — applied here, server text and app text alike.
    /// Guests never get here; their choice is local only.
    func adoptAccountLocale(_ raw: String?) {
        let code = (raw ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard !code.isEmpty else { return }
        if code.caseInsensitiveCompare(ServerLanguage.lastSynced ?? "") == .orderedSame { return }
        let language = ServerLanguage.all.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
            ?? ServerLanguage.all.first { $0.code.prefix(2).lowercased() == code.prefix(2).lowercased() }
        guard let language else { return }
        ServerLanguage.lastSynced = code
        guard ServerLanguage.choice?.code != language.code else { return }
        ServerLanguage.choice = language
        AppLanguage.accountChoice = language.appLanguage
        refresh()
        syncSystemLanguage()
        NotificationCenter.default.post(name: .nodelocLanguageDidChange, object: nil)
    }

    /// Sets the language from inside the app and writes it back to the forum,
    /// so the two stay in agreement.
    func choose(_ language: AppLanguage) {
        AppLanguage.accountChoice = language
        refresh()
        guard let username = DiscourseAuth.shared.username else { return }
        Task {
            try? await DiscourseClient().updateProfile(
                username: username,
                items: [("locale", language.discourseCode)]
            )
        }
    }

    /// 设置 › 界面 › 语言: a server language, or nil to follow the system.
    /// The app's own words switch at once (to the closest language it has);
    /// the server is told (`POST /api/v1/locale`, which also keeps it for a
    /// signed-in account); a refusal puts everything back and returns the
    /// server's words.
    func chooseServerLanguage(_ language: ServerLanguage?) async -> String? {
        let previous = ServerLanguage.choice
        let previousApp = AppLanguage.accountChoice
        ServerLanguage.choice = language
        AppLanguage.accountChoice = language?.appLanguage
        refresh()
        if let language {
            do {
                try await DiscourseClient().http.send("POST", "api/v1/locale", body: .json(["locale": language.code]))
                // What the account holds now, so the next launch's `user.locale`
                // reads as "in agreement" rather than "changed elsewhere".
                ServerLanguage.lastSynced = language.code
            } catch {
                ServerLanguage.choice = previous
                AppLanguage.accountChoice = previousApp
                refresh()
                return ServerFieldErrors.last()["locale"]
                    ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        syncSystemLanguage()
        NotificationCenter.default.post(name: .nodelocLanguageDidChange, object: nil)
        return nil
    }

    /// The system's own pieces — share sheet, photo picker, Copy / Paste,
    /// date pickers, permission prompts — follow the app bundle's language,
    /// which iOS reads from `AppleLanguages` at launch. Writing the choice
    /// there makes them match the app's words from the next launch on (iOS
    /// can't switch them in a running app). Following the system removes it,
    /// which also clears a per-app language set in iOS 设置 › nodeloc.
    private func syncSystemLanguage() {
        if let choice = AppLanguage.accountChoice {
            UserDefaults.standard.set([choice.rawValue], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Back to following the device.
    func clearAccountChoice() {
        AppLanguage.accountChoice = nil
        refresh()
    }

    /// Reads the signed-in account's locale. `user_option` doesn't carry it —
    /// it lives on the user record, and Discourse only serializes it to its
    /// owner (`UserSerializer.private_attributes :locale`).
    func syncFromAccount() async {
        guard DiscourseAuth.shared.isAuthenticated else { return }
        struct Me: Decodable {
            struct User: Decodable { let locale: String? }
            let user: User?
        }
        guard let me: Me = try? await DiscourseClient().get("api/v1/me") else { return }
        adoptAccountLocale(me.user?.locale)
    }

    private func refresh() {
        let next = AppLanguage.resolved
        guard next != language else { return }
        language = next
        // Cached payloads hold *server-rendered* text — topic titles, excerpts,
        // profile fields — which Discourse translates per request. They are keyed
        // by id, not by language, so without this a switch left node pages and
        // profiles in the old language for the rest of their 3–5 minute TTL.
        NodeDetailStore.cache.removeAll()
        PublicProfileStore.cache.removeAll()
    }
}

