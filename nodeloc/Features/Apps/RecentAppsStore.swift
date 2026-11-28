//
//  RecentAppsStore.swift
//  nodeloc
//
//  The mini games and apps opened lately, for the sidebar's 最近玩过. Kept on
//  the device (the backend has no "recently used apps" endpoint), per account
//  — guests have their own list — most recent first, at most a handful.
//  Recorded when a game's web view actually opens, which every way of
//  starting one goes through (the directory's 开始, the app page, links).
//

import Foundation

struct RecentApp: Codable, Hashable, Identifiable {
    let slug: String
    let name: String
    let logoUrl: String?
    var id: String { slug }
}

@MainActor
@Observable
final class RecentAppsStore {
    static let shared = RecentAppsStore()
    private static let keep = 8

    private(set) var items: [RecentApp] = []
    private var loadedKey: String?

    private var key: String {
        "recent.apps.v1.\(DiscourseAuth.shared.username?.lowercased() ?? "guest")"
    }

    /// Switches to the current account's list when the account changed.
    func prepare() {
        guard loadedKey != key else { return }
        loadedKey = key
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([RecentApp].self, from: data) {
            items = saved
        } else {
            items = []
        }
    }

    func record(_ app: DirectoryApp) {
        prepare()
        var next = items.filter { $0.slug != app.slug }
        next.insert(RecentApp(slug: app.slug, name: app.name, logoUrl: app.logoUrl), at: 0)
        items = Array(next.prefix(Self.keep))
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
