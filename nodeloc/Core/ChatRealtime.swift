//
//  ChatRealtime.swift
//  nodeloc
//
//  The two pieces that make chat feel like a messenger:
//
//  - MessageBusClient: a minimal client for Discourse's MessageBus long-poll
//    endpoint — the same transport the web client uses for live chat. The
//    payload is handed on intact, because for the common event — someone sent
//    a message — it already *contains* that message, and refetching a page to
//    learn what the server just told us is a round trip per message.
//
//  Per-channel snapshots used to live here too. They were replaced by
//  `ChatStorage`, which keeps message history and the send queue in SQLite —
//  a snapshot of the newest page could open a conversation instantly and
//  nothing else: no scrolling back, and nothing to hold a message that failed
//  to send.
//

import Foundation

/// One MessageBus publication.
struct MessageBusEvent {
    let channel: String
    /// The event's own `data`, still JSON.
    ///
    /// Passed as bytes rather than a parsed dictionary so the consumer can
    /// decode it with the very models a REST response goes through — the
    /// message inside a chat event is the same shape `/chat/:id/messages`
    /// returns, and having one decoder for both is what keeps the live path
    /// and the fetched path from drifting.
    let payload: Data?
}

@MainActor
final class MessageBusClient {
    private let client = DiscourseClient()
    private let clientID = UUID().uuidString
    private var positions: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var handler: ((MessageBusEvent) -> Void)?
    /// Consecutive failures, for backing off.
    private var failures = 0

    /// Subscribes to a set of bus channels, replacing any previous set.
    /// `onEvent` fires with the channel name and its payload whenever one
    /// publishes.
    func subscribe(channels: [String], onEvent: @escaping (MessageBusEvent) -> Void) {
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
        failures = 0
    }

    /// Whether a subscription is currently running, so a caller resuming from
    /// the background can tell "reconnect" from "already connected".
    var isRunning: Bool { pollTask != nil }

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
            var fired: [MessageBusEvent] = []
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

                // The payload, not just the fact that something happened.
                let payload = event["data"].flatMap { data -> Data? in
                    try? JSONSerialization.data(withJSONObject: data)
                }
                fired.append(MessageBusEvent(channel: channel, payload: payload))
            }
            failures = 0
            for event in fired {
                handler?(event)
            }
        } catch {
            // Exponential, with jitter. A flat delay meant a device that is
            // simply offline retried at a fixed rate forever — on the phone's
            // battery and the server's connection budget — and every client
            // that lost the network at the same moment came back in lockstep.
            failures = min(failures + 1, 6)
            let backoff = min(pow(2, Double(failures)), 60)
            let jitter = Double.random(in: 0...(backoff * 0.3))
            try? await Task.sleep(for: .seconds(backoff + jitter))
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

