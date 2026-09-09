//
//  EmojiPicker.swift
//  nodeloc
//
//  The site's emoji — standard and custom — for the chat composer.
//

import SwiftUI

/// The site's emoji, grouped as `GET /emojis.json` returns them.
///
/// One request per session for ~2000 entries. The images themselves are ordinary
/// remote images and go through the shared cache, so scrolling the grid warms
/// exactly the ones that get looked at.
@MainActor
@Observable
final class EmojiCatalog {
    static let shared = EmojiCatalog()

    struct Group: Identifiable {
        /// The key the endpoint used, e.g. `smileys_&_emotion` or a custom
        /// group's name.
        let key: String
        let title: String
        let emojis: [DiscourseEmoji]
        var id: String { key }
        /// Custom groups are the site's own uploads; there's no translation for
        /// their names and they belong at the front for a forum like this one.
        let isCustom: Bool
    }

    private(set) var groups: [Group] = []
    private var loadTask: Task<Void, Never>?

    /// The order Discourse's own picker uses. Anything not listed is a custom
    /// group.
    private static let standardOrder = [
        "smileys_&_emotion",
        "people_&_body",
        "animals_&_nature",
        "food_&_drink",
        "travel_&_places",
        "activities",
        "objects",
        "symbols",
        "flags",
    ]

    private init() {}

    func loadIfNeeded() async {
        guard groups.isEmpty else { return }
        if let loadTask { return await loadTask.value }
        let task = Task { await load() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// How long a stored catalogue is used before refetching.
    ///
    /// The site's emoji change when an admin uploads a set, which is rare — on
    /// the order of months. A week means at most one stale week for a new
    /// custom emoji, in exchange for never paying for this on a cold launch.
    /// Measured: `emojis.json` is 234 KB and ~1.5s on a warm connection, and
    /// before this it was refetched on *every* launch because the only cache
    /// was the in-process one above.
    private static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// One emoji by name, for turning a reaction's bare name back into an image.
    func emoji(named name: String) -> DiscourseEmoji? {
        for group in groups {
            if let hit = group.emojis.first(where: { $0.name == name }) { return hit }
        }
        return nil
    }

    /// Matches on the shortcode and on the aliases the endpoint supplies, so
    /// searching "smile" finds `slightly_smiling_face` the way the web does.
    func matches(_ term: String) -> [DiscourseEmoji] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [DiscourseEmoji] = []
        for group in groups {
            for emoji in group.emojis where !seen.contains(emoji.name) {
                let hit = emoji.name.contains(query)
                    || (emoji.searchAliases?.contains { $0.lowercased().contains(query) } ?? false)
                guard hit else { continue }
                seen.insert(emoji.name)
                results.append(emoji)
            }
        }
        // Prefix matches first: typing "cat" should offer 🐱 before 🎓.
        return results.sorted { lhs, rhs in
            let left = lhs.name.hasPrefix(query)
            let right = rhs.name.hasPrefix(query)
            if left != right { return left }
            return lhs.name.count < rhs.name.count
        }
    }

    private func load() async {
        await DiscourseLocale.shared.preload()

        // Disk first. A hit means the picker opens without a request at all;
        // the network is only consulted once the copy is a week old.
        if let cached = EmojiDiskCache.load(maxAge: Self.cacheLifetime) {
            apply(payload: cached)
            return
        }

        guard let payload = try? await DiscourseClient().emojis() else {
            // Expired but unreachable is still better than an empty picker —
            // emoji don't go stale in any way a reader would notice.
            if let stale = EmojiDiskCache.load(maxAge: .infinity) {
                apply(payload: stale)
            }
            return
        }
        EmojiDiskCache.store(payload)
        apply(payload: payload)
    }

    private func apply(payload: [String: [DiscourseEmoji]]) {

        let customKeys = payload.keys
            .filter { !Self.standardOrder.contains($0) }
            .sorted()

        // Custom first: on this site they're the ones people actually reach for.
        groups = (customKeys + Self.standardOrder).compactMap { key in
            guard let emojis = payload[key], !emojis.isEmpty else { return nil }
            let isCustom = !Self.standardOrder.contains(key)
            return Group(
                key: key,
                title: Self.title(for: key, isCustom: isCustom),
                emojis: emojis,
                isCustom: isCustom
            )
        }
    }

    /// Standard groups have translations (`js.emoji_picker.<key>`); a custom
    /// group's name is the admin's own and stays as it is.
    private static func title(for key: String, isCustom: Bool) -> String {
        if isCustom { return key }
        return DiscourseLocale.shared.string("emoji_picker.\(key)") ?? key
    }
}

/// Where a reaction's emoji image lives.
///
/// A reaction carries only the emoji's *name* (`heart`, or a custom `ac01`), so
/// the URL has to be reconstructed. The catalog knows the custom ones — their
/// images are uploads with hashed paths — and the standard set follows
/// Discourse's fixed path.
enum ChatEmojiURL {
    static func url(for emoji: String) -> URL? {
        let name = emoji.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if let custom = EmojiCatalog.shared.emoji(named: name)?.url {
            return nodelocSiteURL(custom)
        }
        return nodelocSiteURL("/images/emoji/twemoji/\(name).png")
    }
}

/// Grid of the site's emoji. Tapping one hands back its `:shortcode:`.
struct EmojiPickerSheet: View {
    let onPick: (DiscourseEmoji) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var catalog = EmojiCatalog.shared
    @State private var selectedGroup: String?
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                if !isSearching {
                    groupBar
                }

                if catalog.groups.isEmpty {
                    Spacer()
                    ProgressView().tint(Theme.accent)
                    Spacer()
                } else {
                    grid
                }
            }
            .background(Theme.bg)
            .navigationTitle("表情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(Theme.text)
                }
            }
        }
        .standardSheet([.medium, .large])
        .task {
            await catalog.loadIfNeeded()
            if selectedGroup == nil { selectedGroup = catalog.groups.first?.key }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted(0.45))
            TextField(
                DiscourseLocale.shared.string("emoji_picker.filter_placeholder") ?? AppString("搜索表情"),
                text: $searchText
            )
            .font(Theme.body(15))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            if isSearching {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted(0.35))
                }
                .buttonStyle(.pressableIcon)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.surface, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var groupBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(catalog.groups) { group in
                    let isSelected = selectedGroup == group.key
                    Button {
                        selectedGroup = group.key
                    } label: {
                        Text(group.title)
                            .font(Theme.body(13, weight: .semibold))
                            .foregroundStyle(isSelected ? Theme.bg : Theme.muted(0.6))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(visibleEmojis) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        EmojiImage(emoji: emoji)
                    }
                    .buttonStyle(.pressableIcon)
                    .accessibilityLabel(emoji.name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var visibleEmojis: [DiscourseEmoji] {
        if isSearching { return catalog.matches(searchText) }
        guard let selectedGroup else { return [] }
        return catalog.groups.first { $0.key == selectedGroup }?.emojis ?? []
    }
}

/// One emoji tile. Deliberately an image rather than a `Text` glyph: the custom
/// ones have no Unicode form at all, and the standard set is served as the same
/// PNGs the web renders, so the two match.
private struct EmojiImage: View {
    let emoji: DiscourseEmoji

    var body: some View {
        CachedRemoteImage(url: emoji.url.flatMap { nodelocSiteURL($0) }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
        }
        .frame(width: 32, height: 32)
        .padding(2)
    }
}

#Preview("表情") {
    // Loads from the live site through `EmojiCatalog`.
    EmojiPickerSheet { _ in }
}

/// The emoji catalogue on disk.
///
/// `emojis.json` is 234 KB and about 1.5s to fetch, and it describes the site's
/// configuration rather than anything a reader changes — so paying for it on
/// every cold launch was pure waste. Stored decoded-and-re-encoded rather than
/// as the raw body because the shape here is a plain dictionary with no server
/// quirks to preserve; there is nothing for a re-encode to lose.
///
/// Caches, not Application Support: this is genuinely reconstructible and
/// losing it costs one fetch.
enum EmojiDiskCache {
    private static var fileURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches.appending(path: "emoji-catalog.json")
    }

    static func load(maxAge: TimeInterval) -> [String: [DiscourseEmoji]]? {
        guard let url = fileURL,
              let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = attributes.contentModificationDate
        else { return nil }

        guard maxAge.isInfinite || Date().timeIntervalSince(modified) < maxAge else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: [DiscourseEmoji]].self, from: data)
    }

    static func store(_ payload: [String: [DiscourseEmoji]]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
