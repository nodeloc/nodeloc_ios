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
    static var available: [AppLanguage] {
        let shipped = Set(Bundle.main.localizations)
        return allCases.filter { shipped.contains($0.rawValue) }
    }

    var isAvailable: Bool { Self.available.contains(self) }

    /// The best of the device's preferred languages that the app can speak.
    static var systemPreferred: AppLanguage {
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
    let language = AppLanguage.resolved
    return String(localized: value, bundle: language.bundle, locale: language.locale)
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
        let trimmed = discourseLocale?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty,
              let match = AppLanguage.matching(tag: trimmed),
              match.isAvailable
        else {
            AppLanguage.accountChoice = nil
            refresh()
            return
        }
        AppLanguage.accountChoice = match
        refresh()
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

    /// Back to following the device.
    func clearAccountChoice() {
        AppLanguage.accountChoice = nil
        refresh()
    }

    /// Reads the signed-in account's locale. `user_option` doesn't carry it —
    /// it lives on the user record, and Discourse only serializes it to its
    /// owner (`UserSerializer.private_attributes :locale`).
    func syncFromAccount() async {
        guard let username = DiscourseAuth.shared.username else { return }
        guard let profile = try? await DiscourseClient().user(username).user else { return }
        adopt(discourseLocale: profile.locale)
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

