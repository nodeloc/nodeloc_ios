//
//  ChatRealtime.swift
//  nodeloc
//
//  Live updates from the backend's event stream
//  (`GET /api/v1/notifications/stream`, server-sent events), behind the same
//  `MessageBusClient` interface the stores used with Discourse's MessageBus,
//  so the chat list, the open conversation and the topic reader didn't change.
//
//  - One stream per app (`NodelocRealtime`), shared by every subscriber: the
//    server allows only a few per account.
//  - Events carry no content — "conversation 12 has a new message" — so a
//    subscriber is told *that* something changed and refetches, which is the
//    path the stores already had for payloads they couldn't use.
//  - Topics have no stream events; a topic subscription polls the cheap
//    live-replies counter instead and announces new posts by id.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Server-sent events

nonisolated struct SSEEvent: Equatable, Sendable {
    var event: String
    var data: String
}

/// Incremental `text/event-stream` parser (WHATWG rules: `event:` / `data:`
/// fields, blank line dispatches, `:` lines are comments, CR/LF/CRLF all end a
/// line). Bytes may arrive split anywhere, including inside a UTF-8 sequence.
nonisolated struct SSEParser {
    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []

    init() {}

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let range = nextLineBreak() {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            let line = String(decoding: lineData, as: UTF8.self)
            if let event = process(line) { events.append(event) }
        }
        return events
    }

    private func nextLineBreak() -> Range<Data.Index>? {
        guard let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return nil }
        if buffer[index] == 0x0D {
            let next = buffer.index(after: index)
            // A CR at the very end may be the first half of a CRLF still in
            // flight; wait for the next chunk.
            if next == buffer.endIndex { return nil }
            if buffer[next] == 0x0A { return index..<buffer.index(after: next) }
        }
        return index..<buffer.index(after: index)
    }

    private mutating func process(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { eventName = ""; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return SSEEvent(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}

/// The `chat` event's payload.
nonisolated struct NLStreamChatEvent: Codable, Sendable, Equatable {
    let type: String
    let conversation: Int?
    let kind: String?
    let message: Int?
    let sender: Int?
    let senderName: String?
    let joined: Bool?
    let left: Int?
    let kicked: Bool?
    let system: Bool?
    let muted: Bool?
    let mentioned: Bool?
}

/// Delivers one HTTP response body as it streams in.
nonisolated final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var parser = SSEParser()
    private var status: Int?
    private let onEvent: @Sendable (SSEEvent) -> Void
    private let onOpen: @Sendable (Int) -> Void
    private let onClose: @Sendable (Error?, Int?) -> Void

    init(
        onOpen: @escaping @Sendable (Int) -> Void,
        onEvent: @escaping @Sendable (SSEEvent) -> Void,
        onClose: @escaping @Sendable (Error?, Int?) -> Void
    ) {
        self.onOpen = onOpen
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        status = code
        onOpen(code)
        completionHandler(code == 200 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for event in parser.feed(data) { onEvent(event) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onClose(error, status)
        session.finishTasksAndInvalidate()
    }
}

// MARK: - The shared stream

@MainActor
final class NodelocRealtime {
    static let shared = NodelocRealtime()

    typealias Handler = (SSEEvent) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var task: URLSessionDataTask?
    private var reconnectTask: Task<Void, Never>?
    private var failures = 0
    private(set) var isConnected = false
    /// The latest notification unread count the stream reported.
    private(set) var unreadNotifications: Int?

    var client = DiscourseClient()

    /// What is waiting in the review queue, and per node for someone who
    /// manages one. Nil until the stream says — a reader with neither review
    /// permission nor a node to manage never gets this event at all, which is
    /// different from a queue that happens to be empty.
    ///
    /// Which nodes a reader manages is read once when the stream connects, so
    /// being made a moderator mid-session shows up on the next reconnect.
    private(set) var pendingReview: Int?
    private(set) var pendingReviewByNode: [String: Int] = [:]

    /// Posted with the unread count whenever the stream reports one.
    static let unreadDidChange = Notification.Name("NodelocUnreadNotificationsDidChange")
    static let pendingReviewDidChange = Notification.Name("NodelocPendingReviewDidChange")

    func addHandler(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        connectIfNeeded()
        return id
    }

    func removeHandler(_ id: UUID) {
        handlers[id] = nil
        if handlers.isEmpty { disconnect() }
    }

    func connectIfNeeded() {
        guard task == nil, reconnectTask == nil, !handlers.isEmpty, client.auth.isAuthenticated else { return }
        guard let request = try? client.http.makeRequest(
            "GET", "api/v1/notifications/stream",
            headers: ["Accept": "text/event-stream", "Cache-Control": "no-cache"]
        ) else { return }

        let delegate = SSEStreamDelegate(
            onOpen: { status in
                Task { @MainActor in NodelocRealtime.shared.opened(status: status) }
            },
            onEvent: { event in
                Task { @MainActor in NodelocRealtime.shared.dispatch(event) }
            },
            onClose: { error, status in
                Task { @MainActor in NodelocRealtime.shared.closed(error: error, status: status) }
            }
        )
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        // The server pings every 25 s; silence well past that means the
        // connection is gone.
        configuration.timeoutIntervalForRequest = 70
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel()
        task = nil
        isConnected = false
    }

    private func opened(status: Int) {
        isConnected = status == 200
        if status == 200 {
            if failures > 0 {
                // Whatever happened while the stream was down is only learned
                // by asking.
                dispatch(SSEEvent(event: "chat", data: #"{"type":"resync"}"#))
            }
            failures = 0
        }
    }

    private func dispatch(_ event: SSEEvent) {
        if event.event == "unread",
           let data = event.data.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let unread = object["unread"] as? Int {
            unreadNotifications = unread
            NotificationCenter.default.post(name: Self.unreadDidChange, object: nil, userInfo: ["unread": unread])
        }
        // How much is waiting in the review queue. Only sent to someone with
        // review permission or who manages a node, so absence is the normal
        // case and leaves `pendingReview` nil rather than 0. For a reader who
        // only manages nodes `pending` is already the sum of `nodes`.
        if event.event == "review",
           let data = event.data.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pendingReview = object["pending"] as? Int
            pendingReviewByNode = object["nodes"] as? [String: Int] ?? [:]
            NotificationCenter.default.post(
                name: Self.pendingReviewDidChange, object: nil,
                userInfo: ["pending": pendingReview ?? 0]
            )
        }
        for handler in handlers.values { handler(event) }
    }

    private func closed(error: Error?, status: Int?) {
        task = nil
        isConnected = false
        guard !handlers.isEmpty, client.auth.isAuthenticated else { return }
        if (error as? URLError)?.code == .cancelled, status == nil || status == 200 {
            // Cancelled by `disconnect`, or the server's 30-minute close.
            if reconnectTask != nil { return }
        }
        if status == 401 { return }
        // Exponential with jitter, so clients that lost the network together
        // don't come back in lockstep.
        failures = min(failures + 1, 6)
        let backoff = status == 200 ? 1 : min(pow(2, Double(failures)), 60)
        let wait = backoff + Double.random(in: 0...(backoff * 0.3))
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NodelocRealtime.shared.reconnectTask = nil
            NodelocRealtime.shared.connectIfNeeded()
        }
    }
}

// MARK: - MessageBus-compatible subscriptions

struct MessageBusEvent {
    let channel: String
    let payload: Data?
}

/// Subscriptions in Discourse's channel vocabulary, served from the event
/// stream:
///
/// - `/chat/{id}/new-messages` and `/chat/{id}`: fire on any change to that
///   conversation (and on a resync) with no payload, which makes the stores
///   refetch — the backend's events carry no message bodies.
/// - `/topic/{id}`: polls for replies and fires `{"type":"created","id":…}`
///   per new post, the shape `TopicStore` reads.
@MainActor
final class MessageBusClient {
    private var handlerID: UUID?
    private var channels: [String] = []
    private var handler: ((MessageBusEvent) -> Void)?
    private var pollTask: Task<Void, Never>?
    var client = DiscourseClient()

    /// How often a topic subscription asks whether there are new replies.
    var topicPollInterval: Double = 20

    func subscribe(channels: [String], onEvent: @escaping (MessageBusEvent) -> Void) {
        stop()
        self.channels = channels
        handler = onEvent
        if channels.contains(where: { $0.hasPrefix("/chat/") }) {
            handlerID = NodelocRealtime.shared.addHandler { [weak self] event in
                self?.route(event)
            }
        }
        let topics = channels.compactMap { channel -> Int? in
            guard channel.hasPrefix("/topic/") else { return nil }
            return Int(channel.dropFirst("/topic/".count))
        }
        if !topics.isEmpty {
            pollTask = Task { [weak self] in
                await self?.pollTopics(topics)
            }
        }
    }

    func stop() {
        if let handlerID { NodelocRealtime.shared.removeHandler(handlerID) }
        handlerID = nil
        pollTask?.cancel()
        pollTask = nil
        handler = nil
        channels = []
    }

    var isRunning: Bool { handler != nil }

    private func route(_ event: SSEEvent) {
        guard event.event == "chat",
              let data = event.data.data(using: .utf8),
              let chat = try? NodelocJSON.decode(NLStreamChatEvent.self, from: data)
        else { return }
        for channel in Self.channels(for: chat, among: channels) {
            handler?(MessageBusEvent(channel: channel, payload: nil))
        }
    }

    /// Which subscribed channels an event concerns.
    static func channels(for event: NLStreamChatEvent, among subscribed: [String]) -> [String] {
        if event.type == "resync" { return subscribed.filter { $0.hasPrefix("/chat/") } }
        guard let conversation = event.conversation else { return [] }
        let listWide: Set<String> = ["updated", "archived", "dissolved", "member", "muted"]
        return subscribed.filter { channel in
            // A direct message opened before it existed is subscribed under
            // its stand-in id.
            let parts = channel.split(separator: "/")
            let subscribedID = parts.count >= 2 ? Int(parts[1]) : nil
            let resolved = subscribedID.flatMap { NodelocAdapterState.shared.serverConversationID($0) }
            let matches = resolved == conversation
            return (matches && (channel.hasSuffix("/new-messages") || parts.count == 2))
                || (listWide.contains(event.type) && channel.hasSuffix("/new-messages"))
        }
    }

    private func pollTopics(_ topics: [Int]) async {
        var highest: [Int: Int] = [:]
        while !Task.isCancelled {
            for topicID in topics {
                await pollTopic(topicID, highest: &highest)
            }
            try? await Task.sleep(nanoseconds: UInt64(topicPollInterval * 1_000_000_000))
        }
    }

    func pollTopic(_ topicID: Int, highest: inout [Int: Int]) async {
        let since = highest[topicID] ?? 0
        guard let data = try? await client.http.send(
            "GET", "api/v1/live/topics/\(topicID)/replies",
            query: [URLQueryItem(name: "since", value: String(since))]
        ),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let newest = object["highest"] as? Int
        else { return }
        guard let known = highest[topicID] else {
            // The first answer is the baseline, not news.
            highest[topicID] = newest
            return
        }
        guard newest > known else { return }
        highest[topicID] = newest
        guard let detail = try? await client.http.send("GET", "api/v1/topics/\(topicID)", query: [
            URLQueryItem(name: "after", value: String(known)), URLQueryItem(name: "limit", value: "50"),
        ]), let page = try? NodelocJSON.decode(NLTopicDetail.self, from: detail) else { return }
        NodelocAdapterState.shared.store(posts: page.posts, topicID: topicID)
        for post in page.posts where post.postNumber > known {
            let payload = try? JSONSerialization.data(withJSONObject: ["type": "created", "id": post.id])
            handler?(MessageBusEvent(channel: "/topic/\(topicID)", payload: payload))
        }
    }
}
