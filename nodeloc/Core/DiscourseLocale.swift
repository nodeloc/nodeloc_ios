//
//  DiscourseLocale.swift
//  nodeloc
//
//  The site's own client translations, so names the server doesn't localise for
//  us don't end up hardcoded in English.
//

import Foundation

/// Reads Discourse's client translation bundle.
///
/// Some labels have no localised form in the API: a profile's 用户组 chips are
/// derived from `trust_level` / `admin` / `moderator`, which are a number and two
/// booleans. The web turns those into words with its own translations, and this
/// fetches the same file — `/extra-locales/<hash>/<locale>/main.js`, where the
/// hash is only a cache-buster (a bogus one answers 200 all the same, checked
/// against the live site).
///
/// Two files, and the second one matters here: `main.js` carries the stock
/// translations, `overrides.js` carries what the admin rewrote in 自定义 → 文本.
/// nodeloc renames every trust level there — 青铜会员 / 白银会员 / 黄金会员 /
/// 钻石会员 / 王者会员 — so reading only `main.js` would show Discourse's own
/// 新用户 / 基本用户 / 成员 …, which is not what this site calls its levels.
///
/// Their shapes differ: `main.js` is a tree under `js`, while `overrides.js` is
/// flat with `js.`-prefixed dotted keys.
@MainActor
final class DiscourseLocale {
    static let shared = DiscourseLocale()

    /// Flattened `js.…` keys, e.g. `trust_levels.names.basic`. Only the leaves
    /// are kept, so the 680KB download doesn't stay in memory.
    private var strings: [String: String] = [:]
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Fetches the bundle once per session. Callers that need a string
    /// synchronously (a view model building labels) await this first.
    func preload() async {
        guard strings.isEmpty else { return }
        if let loadTask { return await loadTask.value }
        let task = Task { await load() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// A translation, or nil when the bundle hasn't loaded or has no such key.
    /// Callers keep an English fallback for exactly that case.
    func string(_ key: String) -> String? {
        strings[key]
    }

    /// `%{name}`-style interpolation, the format Discourse's strings use.
    func string(_ key: String, _ replacements: [String: String]) -> String? {
        guard var value = strings[key] else { return nil }
        for (name, replacement) in replacements {
            value = value.replacingOccurrences(of: "%{\(name)}", with: replacement)
        }
        return value
    }

    private func load() async {
        var resolved: [String: String] = [:]
        // Stock translations first, then the admin's rewrites over the top.
        if let payload = await bundle(named: "main.js", marker: "localeData.translations = "),
           let js = payload["js"] as? [String: Any] {
            Self.flatten(js, prefix: "", into: &resolved)
        }
        if let payload = await bundle(named: "overrides.js", marker: "localeData.overrides = ") {
            for (key, value) in payload {
                // Flat, dotted, and prefixed by the bundle they belong to. Only
                // the client's own (`js.`) are of any use here; the rest are
                // `admin_js.` and server-side keys.
                guard let text = value as? String, key.hasPrefix("js.") else { continue }
                resolved[String(key.dropFirst(3))] = text
            }
        }
        strings = resolved
    }

    /// One locale file, unwrapped to the object for this locale.
    private func bundle(named name: String, marker: String) async -> [String: Any]? {
        // The hash is a cache-buster, but the route constrains it to 40 hex
        // characters — "0" answers with the 404 page, forty zeros with the
        // bundle.
        guard let url = URL(
            string: "extra-locales/\(String(repeating: "0", count: 40))/\(Self.localeCode)/\(name)",
            relativeTo: DiscourseConfig.baseURL
        )?.absoluteURL else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let script = String(data: data, encoding: .utf8),
              // Brace-matched rather than cut at the first `;`: translations
              // contain semicolons (HTML entities, for one), and stopping at one
              // truncates the JSON into something that won't parse.
              let start = script.range(of: marker),
              let json = Self.firstJSONObject(in: script, from: start.upperBound),
              let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }

        // One locale per file, keyed by name — and the key isn't always the code
        // that was asked for (`en` answers with `en_US`).
        return payload[Self.localeCode] as? [String: Any]
            ?? payload.values.first as? [String: Any]
    }

    /// The balanced `{…}` starting at or after `index`, ignoring braces inside
    /// string literals.
    private static func firstJSONObject(in script: String, from index: String.Index) -> Substring? {
        guard let open = script[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = open
        while cursor < script.endIndex {
            let character = script[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return script[open...cursor]
                    }
                }
            }
            cursor = script.index(after: cursor)
        }
        return nil
    }

    private static func flatten(_ node: [String: Any], prefix: String, into result: inout [String: String]) {
        for (key, value) in node {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let text = value as? String {
                result[path] = text
            } else if let child = value as? [String: Any] {
                flatten(child, prefix: path, into: &result)
            }
        }
    }

    /// Discourse's code for whichever language the interface is currently in,
    /// so server-provided words (trust levels, group names) match the rest of
    /// the UI rather than the device.
    private static var localeCode: String {
        AppLanguage.resolved.discourseCode
    }
}

/// The words a profile's 用户组 chips use.
///
/// Trust levels come straight from `js.trust_levels.names.*`, the same keys the
/// web reads. Staff have no `default_names` in the client bundle — those live
/// server-side under `groups.default_names.*` — so the two words are taken from
/// the strings the site does ship for them.
enum DiscourseRoleNames {
    static func trustLevel(_ level: Int) -> String {
        let key = trustLevelKey(level)
        return DiscourseLocale.shared.string("trust_levels.names.\(key)")
            ?? fallbackTrustLevel(level)
    }

    /// `js.admin_title` is top level, not under `js.user`.
    static var admin: String {
        DiscourseLocale.shared.string("admin_title")
            ?? DiscourseLocale.shared.string("user.invited.invite_roles.staff_role_admin")
            ?? "ADMIN"
    }

    /// The singular noun. `about.moderators` is the plural section heading
    /// ("Moderators" / 版主 — right in Chinese, wrong in English), while the
    /// invite-role label is the site's own singular of the same word.
    static var moderator: String {
        DiscourseLocale.shared.string("user.invited.invite_roles.staff_role_moderator")
            ?? DiscourseLocale.shared.string("about.moderators")
            ?? "MOD"
    }

    /// Shown when someone has no staff role and no trust level to name.
    static var member: String {
        DiscourseLocale.shared.string("trust_levels.names.member") ?? "MEMBER"
    }

    private static func trustLevelKey(_ level: Int) -> String {
        switch level {
        case 0: return "newuser"
        case 1: return "basic"
        case 2: return "member"
        case 3: return "regular"
        case 4: return "leader"
        default: return "member"
        }
    }

    private static func fallbackTrustLevel(_ level: Int) -> String {
        switch level {
        case 0: return "NEW"
        case 1: return "BASIC"
        case 2: return "MEMBER"
        case 3: return "REGULAR"
        case 4: return "LEADER"
        default: return "TL\(level)"
        }
    }
}
