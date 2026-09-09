//
//  ChatRealtime.swift
//  nodeloc
//
//  The two pieces that make chat feel like a messenger:
//
//  - MessageBusClient: a minimal client for Discourse's MessageBus long-poll
//    endpoint — the same transport the web client uses for live chat. Events
//    are treated purely as "this channel changed" signals; the store refetches
//    through its existing mappers, which keeps this client tiny.
//
//  - ChatDiskCache: per-channel snapshots of the raw messages JSON, so a
//    conversation opens instantly from disk and the network fetch only
//    reconciles. Lives in Caches (purgeable); no database by design.
//

import Foundation

@MainActor
final class MessageBusClient {
    private let client = DiscourseClient()
    private let clientID = UUID().uuidString
    private var positions: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var handler: ((String) -> Void)?

    /// Subscribes to a set of bus channels, replacing any previous set.
    /// `onEvent` fires with the channel name whenever it publishes.
    func subscribe(channels: [String], onEvent: @escaping (String) -> Void) {
        stop()
        positions = Dictionary(uniqueKeysWithValues: channels.map { ($0, -1) })
        handler = onEvent
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    private func pollOnce() async {
        // Nothing to poll: yield with a sleep rather than returning, or the
        // caller's `while` becomes a hot loop on the main actor with no await
        // in it to let anything else run.
        guard !positions.isEmpty else {
            try? await Task.sleep(for: .seconds(1))
            return
        }
        do {
            let data = try await client.messageBusPoll(clientID: clientID, positions: positions)
            var fired: Set<String> = []
            let events = Self.events(in: data)
            for event in events {
                guard let channel = event["channel"] as? String else { continue }
                if channel == "/__status" {
                    // The server reports each channel's current position, so
                    // -1 subscriptions start from "now".
                    if let statuses = event["data"] as? [String: Int] {
                        for (name, id) in statuses where positions[name] != nil {
                            positions[name] = id
                        }
                    }
                    continue
                }
                guard positions[channel] != nil,
                      let id = event["message_id"] as? Int else { continue }
                positions[channel] = id
                fired.insert(channel)
            }
            for channel in fired {
                handler?(channel)
            }
        } catch {
            // Transient network trouble: back off briefly before re-polling,
            // or a dead connection would spin this loop hot.
            try? await Task.sleep(for: .seconds(4))
        }
    }

    /// The envelopes in one poll's body.
    ///
    /// `JSONSerialization` rather than `Codable`: payloads are heterogeneous per
    /// channel and only the envelope matters here.
    ///
    /// Split on the pipe first, because MessageBus has two framings for the same
    /// endpoint — one array, or several arrays separated by `\r\n|\r\n`. The
    /// request asks for the former; parsing both means a proxy that strips the
    /// header, or a server that ignores it, degrades to working rather than to
    /// silence. A single array has no separator, so it comes through this
    /// unchanged.
    private static func events(in data: Data) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "|")
            .compactMap { chunk -> [[String: Any]]? in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let chunkData = trimmed.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: chunkData) as? [[String: Any]]
            }
            .flatMap { $0 }
    }
}

actor ChatDiskCache {
    static let shared = ChatDiskCache()

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ChatMessages", directoryHint: .isDirectory)
    }

    func load(channelID: Int) -> Data? {
        try? Data(contentsOf: fileURL(channelID))
    }

    func store(_ data: Data, channelID: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(channelID), options: .atomic)
    }

    private func fileURL(_ channelID: Int) -> URL {
        directory.appending(path: "channel-\(channelID).json")
    }
}
