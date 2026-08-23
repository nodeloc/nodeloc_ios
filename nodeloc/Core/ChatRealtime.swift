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
        guard !positions.isEmpty else { return }
        do {
            let data = try await client.messageBusPoll(clientID: clientID, positions: positions)
            // JSONSerialization rather than Codable: event payloads are
            // heterogeneous per channel and we only need the envelope.
            guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            var fired: Set<String> = []
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
