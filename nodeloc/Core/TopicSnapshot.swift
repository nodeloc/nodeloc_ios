//
//  TopicSnapshot.swift
//  nodeloc
//
//  Topics kept on disk so opening one — or swiping to the next — draws the post
//  immediately instead of a skeleton.
//
//  Raw JSON, for the reason `ProfileSnapshot` gives at length: the bytes are
//  what the server sent, so `TopicResponse` stays the only decoding path. A
//  re-encoded model would be a second one, free to drift, and failing silently
//  when it does.
//
//  Caches, not Documents — reconstructible from the network by definition.
//

import Foundation

enum TopicSnapshot {
    /// Beyond this a snapshot is only used to avoid the blank frame; the
    /// refresh that follows is what the reader actually reads. Nothing is
    /// deleted at this age — see `prune`, which is about size, not staleness.
    static let freshEnough: TimeInterval = 60 * 60 * 24 * 3

    /// How many topics to keep. Roughly a long evening's reading; a topic
    /// payload with its post stream is tens of kilobytes, so this is a couple
    /// of megabytes at worst.
    private static let capacity = 60

    private static func directory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = caches.appending(path: "topic-snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileURL(id: Int) -> URL? {
        directory()?.appending(path: "\(id).json")
    }

    /// Replies live in a second file, keyed by sort as well: the server does
    /// the sorting, so "top" and "new" are different answers and caching one
    /// as the other would show the reader a list they didn't ask for.
    private static func repliesURL(id: Int, sort: String) -> URL? {
        directory()?.appending(path: "\(id)-replies-\(sort).json")
    }

    static func saveReplies(_ data: Data, id: Int, sort: String) {
        guard let url = repliesURL(id: id, sort: sort) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadReplies(id: Int, sort: String) -> Data? {
        guard let url = repliesURL(id: id, sort: sort) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func save(_ data: Data, id: Int) {
        guard let url = fileURL(id: id) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The stored payload, and how old it is.
    ///
    /// The age comes back with it rather than being checked here: a stale
    /// snapshot is still worth drawing while the fresh one loads, so it is the
    /// caller's business whether to refresh, not this type's whether to answer.
    static func load(id: Int) -> (data: Data, age: TimeInterval)? {
        guard let url = fileURL(id: id),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        return (data, Date().timeIntervalSince(modified))
    }

    static func contains(id: Int) -> Bool {
        guard let url = fileURL(id: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Drops the oldest files past `capacity`. Called after a save, off the
    /// main actor, so a long reading session doesn't grow without bound.
    static func prune() {
        guard let directory = directory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ),
              urls.count > capacity
        else { return }

        let byAge = urls.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        for url in byAge.dropFirst(capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sign-out: the next reader of this device must not find the last one's
    /// topics, some of which may have been private messages.
    static func clearAll() {
        guard let directory = directory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Fetches the topic the reader is *about* to swipe to.
///
/// An actor so the in-flight set is safe to touch from anywhere, and so a
/// prefetch never runs twice for the same topic — swiping back and forth over
/// the same two posts would otherwise refetch both every time.
actor TopicPrefetcher {
    static let shared = TopicPrefetcher()

    private var inFlight: Set<Int> = []
    private let client = DiscourseClient()

    /// Warms `TopicSnapshot` for `id`. Cheap to call repeatedly: a topic that
    /// already has a fresh snapshot, or a fetch already running, is skipped.
    ///
    /// Deliberately silent about failures. This is speculative work for a
    /// screen nobody has asked for yet; if it fails, opening the topic does
    /// exactly what it did before.
    func prefetch(id: Int, sort: String) async {
        guard id > 0, !inFlight.contains(id) else { return }
        if let snapshot = TopicSnapshot.load(id: id), snapshot.age < TopicSnapshot.freshEnough {
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        guard let raw = try? await client.topicWithRaw(id: id).raw else { return }
        TopicSnapshot.save(raw, id: id)
        // The reply list as well, in the sort the reader is using — a post
        // whose body appears instantly and whose replies then take a second
        // still reads as loading.
        if let replies = try? await client.nestedTopicWithRaw(id: id, sort: sort).raw {
            TopicSnapshot.saveReplies(replies, id: id, sort: sort)
        }
        TopicSnapshot.prune()
    }
}
