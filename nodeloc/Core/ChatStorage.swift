//
//  ChatStorage.swift
//  nodeloc
//
//  Chat history and the send queue, on disk.
//
//  Replaces `ChatDiskCache`, which held one page of raw JSON per channel in
//  Caches. That was enough to open a conversation instantly and nothing more:
//  no history above the newest page, no record of a message that failed to
//  send, and the system could reclaim all of it.
//
//  Three things shape the schema:
//
//  1. **Messages are stored as the server's own JSON, one row each.** Reading
//     a page wraps those rows back into a `{"messages":[…]}` envelope and runs
//     `ChatMessageMapper` — the same mapper a live response goes through. So
//     there is exactly one place that understands a chat message, and paging
//     from disk cannot drift from paging from the network.
//
//  2. **The outbox is durable.** A message you typed is your data; losing it
//     to a dropped connection is not acceptable, and until now it was — the
//     draft was cleared before the request was even attempted.
//
//  3. **No migrations.** Everything except the outbox is a cache of the
//     server, so a schema change deletes the file and refetches. The outbox is
//     the one table that holds unsynced user data, so `Schema.version` bumps
//     must preserve it — hence `resetKeepingOutbox`.
//
//  Lives in Application Support, not Caches: history the reader scrolls back
//  through, and a queue of unsent messages, must not be reclaimed under disk
//  pressure. Excluded from backup all the same — it is reconstructible, and
//  chat content in an iCloud backup is not a decision to make silently.
//

import Foundation

actor ChatStorage {
    static let shared = ChatStorage()

    private enum Schema {
        /// Bump to rebuild. The outbox survives; everything else refetches.
        static let version = 1
    }

    private let database: SQLiteDatabase
    private var isReady = false

    private init() {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "nodeloc", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // The directory, not the file: the -wal and -shm siblings need the same
        // treatment and this is the one place that covers them.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)

        database = SQLiteDatabase(url: url.appending(path: "chat.sqlite"))
    }

    // MARK: Lifecycle

    /// Opens and prepares the database. Safe to call repeatedly.
    ///
    /// Failure is reported by throwing, but every caller in the app treats it
    /// as "no cache available" and carries on against the network — chat must
    /// not become unusable because a cache file is unwritable.
    func prepare() throws {
        guard !isReady else { return }
        try database.open()
        try createTables()

        let stored = try storedSchemaVersion()
        if stored != Schema.version {
            try rebuildKeepingOutbox()
        }
        isReady = true
    }

    private func createTables() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS message (
                id         INTEGER PRIMARY KEY,
                channel_id INTEGER NOT NULL,
                thread_id  INTEGER,
                created_at TEXT,
                payload    TEXT NOT NULL
            );

            -- Every read is "this channel, newest first, optionally older than
            -- an id", so the index carries the sort as well as the filter.
            CREATE INDEX IF NOT EXISTS message_channel_id
                ON message(channel_id, id DESC);
            CREATE INDEX IF NOT EXISTS message_thread_id
                ON message(thread_id, id DESC);

            CREATE TABLE IF NOT EXISTS outbox (
                local_id       TEXT PRIMARY KEY,
                channel_id     INTEGER NOT NULL,
                thread_id      INTEGER,
                body           TEXT NOT NULL,
                in_reply_to_id INTEGER,
                upload_ids     TEXT,
                created_at     REAL NOT NULL,
                attempts       INTEGER NOT NULL DEFAULT 0,
                last_error     TEXT
            );

            CREATE INDEX IF NOT EXISTS outbox_channel
                ON outbox(channel_id, created_at);
        """)
    }

    private func storedSchemaVersion() throws -> Int {
        let rows = try database.rows("SELECT value FROM meta WHERE key = 'schema_version';")
        return rows.first?["value"]?.intValue ?? 0
    }

    /// The migration strategy: drop the cached rows, keep the unsent ones.
    private func rebuildKeepingOutbox() throws {
        let queued = try database.rows("SELECT * FROM outbox;")

        try database.reset()
        try createTables()

        for row in queued {
            try database.run(
                """
                INSERT OR REPLACE INTO outbox
                    (local_id, channel_id, thread_id, body, in_reply_to_id,
                     upload_ids, created_at, attempts, last_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(row["local_id"]?.stringValue ?? UUID().uuidString),
                    .int(Int64(row["channel_id"]?.intValue ?? 0)),
                    row["thread_id"]?.intValue.map { .int(Int64($0)) } ?? .null,
                    .text(row["body"]?.stringValue ?? ""),
                    row["in_reply_to_id"]?.intValue.map { .int(Int64($0)) } ?? .null,
                    row["upload_ids"].map { SQLValue.text($0.stringValue ?? "[]") } ?? .text("[]"),
                    .double(Double(row["created_at"]?.stringValue ?? "") ?? Date().timeIntervalSince1970),
                    .int(Int64(row["attempts"]?.intValue ?? 0)),
                    row["last_error"].map { SQLValue.text($0.stringValue ?? "") } ?? .null,
                ]
            )
        }

        try database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);",
            [.text(String(Schema.version))]
        )
    }

    /// Everything, for sign-out. The outbox goes too: unsent messages belong to
    /// the account that wrote them.
    func clearAll() throws {
        guard isReady else { return }
        try database.execute("DELETE FROM message; DELETE FROM outbox;")
    }

    // MARK: Messages

    /// A page of stored messages, as a synthetic response body.
    ///
    /// Returns the same shape the network returns, so the caller decodes it
    /// with `ChatMessageMapper` and neither side needs to know where it came
    /// from. Nil when there is nothing stored, which callers read as "go to
    /// the network".
    ///
    /// - Parameter before: exclusive upper bound — the oldest id already on
    ///   screen — for scrolling further back. Nil asks for the newest page.
    func page(channelID: Int, threadID: Int? = nil, before: Int? = nil, limit: Int = 50) throws -> Data? {
        guard isReady else { return nil }

        var sql = "SELECT payload FROM message WHERE channel_id = ?"
        var parameters: [SQLValue] = [.int(Int64(channelID))]

        if let threadID {
            sql += " AND thread_id = ?"
            parameters.append(.int(Int64(threadID)))
        } else {
            // A channel page shows the channel's own messages; thread replies
            // are read through `threadID` instead of appearing twice.
            sql += " AND thread_id IS NULL"
        }
        if let before {
            sql += " AND id < ?"
            parameters.append(.int(Int64(before)))
        }
        // Newest first for the LIMIT to bite at the right end, then reversed
        // below so the caller always receives chronological order.
        sql += " ORDER BY id DESC LIMIT ?;"
        parameters.append(.int(Int64(limit)))

        let rows = try database.rows(sql, parameters)
        guard !rows.isEmpty else { return nil }

        let payloads = rows.reversed().compactMap { $0["payload"]?.stringValue }
        return Self.envelope(messagePayloads: payloads)
    }

    /// The newest stored id, for deciding whether a fetched page continues the
    /// stored history or starts a new one.
    func newestMessageID(channelID: Int) throws -> Int? {
        guard isReady else { return nil }
        let rows = try database.rows(
            "SELECT MAX(id) AS newest FROM message WHERE channel_id = ?;",
            [.int(Int64(channelID))]
        )
        return rows.first?["newest"]?.intValue
    }

    /// Stores a page of messages.
    ///
    /// `isContiguous` is the caller's answer to "does this page touch what is
    /// already stored?" When false the channel's rows are dropped first,
    /// because a gap is worse than a short history: paging up through one would
    /// silently skip whatever arrived while the app was closed, and nothing on
    /// screen would say so.
    func store(
        messages: [StoredMessage],
        channelID: Int,
        isContiguous: Bool
    ) throws {
        guard isReady, !messages.isEmpty else { return }

        try database.transaction { db in
            if !isContiguous {
                try db.run("DELETE FROM message WHERE channel_id = ?;", [.int(Int64(channelID))])
            }
            for message in messages {
                try db.run(
                    """
                    INSERT OR REPLACE INTO message (id, channel_id, thread_id, created_at, payload)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    [
                        .int(Int64(message.id)),
                        .int(Int64(channelID)),
                        message.threadID.map { .int(Int64($0)) } ?? .null,
                        message.createdAt.map { .text($0) } ?? .null,
                        .text(message.payload),
                    ]
                )
            }
        }
    }

    /// Drops one message, for a deletion arriving over the bus.
    func delete(messageID: Int) throws {
        guard isReady else { return }
        try database.run("DELETE FROM message WHERE id = ?;", [.int(Int64(messageID))])
    }

    /// Keeps a channel's stored history bounded.
    ///
    /// Called after a fetch rather than on a timer: the point is to stop one
    /// very busy channel growing without limit, not to expire history by age.
    func trim(channelID: Int, keeping limit: Int = 500) throws {
        guard isReady else { return }
        try database.run(
            """
            DELETE FROM message
            WHERE channel_id = ?
              AND id NOT IN (
                SELECT id FROM message WHERE channel_id = ? ORDER BY id DESC LIMIT ?
              );
            """,
            [.int(Int64(channelID)), .int(Int64(channelID)), .int(Int64(limit))]
        )
    }

    // MARK: Outbox

    /// Records a message before it is sent, so a failure can't lose it.
    func enqueue(_ item: OutboxItem) throws {
        guard isReady else { return }
        let uploads = (try? JSONEncoder().encode(item.uploadIDs)).flatMap { String(data: $0, encoding: .utf8) }
        try database.run(
            """
            INSERT OR REPLACE INTO outbox
                (local_id, channel_id, thread_id, body, in_reply_to_id, upload_ids, created_at, attempts, last_error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(item.localID.uuidString),
                .int(Int64(item.channelID)),
                item.threadID.map { .int(Int64($0)) } ?? .null,
                .text(item.body),
                item.inReplyToID.map { .int(Int64($0)) } ?? .null,
                .text(uploads ?? "[]"),
                .double(item.createdAt.timeIntervalSince1970),
                .int(Int64(item.attempts)),
                item.lastError.map { .text($0) } ?? .null,
            ]
        )
    }

    /// Everything still unsent, oldest first — the order it must be retried in,
    /// or messages would arrive shuffled.
    func queued(channelID: Int? = nil) throws -> [OutboxItem] {
        guard isReady else { return [] }
        var sql = "SELECT * FROM outbox"
        var parameters: [SQLValue] = []
        if let channelID {
            sql += " WHERE channel_id = ?"
            parameters.append(.int(Int64(channelID)))
        }
        sql += " ORDER BY created_at ASC;"
        return try database.rows(sql, parameters).compactMap(OutboxItem.init(row:))
    }

    func markAttempt(localID: UUID, error: String?) throws {
        guard isReady else { return }
        try database.run(
            "UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE local_id = ?;",
            [error.map { .text($0) } ?? .null, .text(localID.uuidString)]
        )
    }

    /// Removes a queued message, on success or on the reader discarding it.
    func dequeue(localID: UUID) throws {
        guard isReady else { return }
        try database.run("DELETE FROM outbox WHERE local_id = ?;", [.text(localID.uuidString)])
    }

    // MARK: Envelope

    /// Wraps stored per-message JSON back into the response shape.
    ///
    /// String assembly rather than re-encoding a parsed object: the payloads
    /// are already valid JSON and this keeps them byte-identical to what the
    /// server sent, which is the whole reason they are stored as JSON.
    private static func envelope(messagePayloads: [String]) -> Data? {
        let joined = messagePayloads.joined(separator: ",")
        return "{\"messages\":[\(joined)]}".data(using: .utf8)
    }
}

/// One message on its way into storage.
struct StoredMessage: Sendable {
    let id: Int
    let threadID: Int?
    let createdAt: String?
    /// The server's own JSON for this message.
    let payload: String
}

/// A message written but not yet acknowledged by the server.
struct OutboxItem: Sendable, Identifiable, Equatable {
    /// Stable across retries and app launches, and what the optimistic bubble
    /// on screen is keyed on.
    let localID: UUID
    let channelID: Int
    let threadID: Int?
    let body: String
    let inReplyToID: Int?
    let uploadIDs: [Int]
    let createdAt: Date
    var attempts: Int = 0
    var lastError: String?

    var id: UUID { localID }

    /// Shown as failed rather than sending once the server has refused it more
    /// than twice — at that point retrying silently is just hiding it.
    var hasFailed: Bool { attempts >= 3 }

    init(
        localID: UUID = UUID(),
        channelID: Int,
        threadID: Int? = nil,
        body: String,
        inReplyToID: Int? = nil,
        uploadIDs: [Int] = [],
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.localID = localID
        self.channelID = channelID
        self.threadID = threadID
        self.body = body
        self.inReplyToID = inReplyToID
        self.uploadIDs = uploadIDs
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }

    init?(row: [String: SQLValue]) {
        guard let idString = row["local_id"]?.stringValue,
              let localID = UUID(uuidString: idString),
              let channelID = row["channel_id"]?.intValue,
              let body = row["body"]?.stringValue
        else { return nil }

        let uploads: [Int]
        if let json = row["upload_ids"]?.dataValue,
           let decoded = try? JSONDecoder().decode([Int].self, from: json) {
            uploads = decoded
        } else {
            uploads = []
        }

        let created: Date
        switch row["created_at"] {
        case .double(let seconds): created = Date(timeIntervalSince1970: seconds)
        case .int(let seconds): created = Date(timeIntervalSince1970: Double(seconds))
        default: created = Date()
        }

        self.init(
            localID: localID,
            channelID: channelID,
            threadID: row["thread_id"]?.intValue,
            body: body,
            inReplyToID: row["in_reply_to_id"]?.intValue,
            uploadIDs: uploads,
            createdAt: created,
            attempts: row["attempts"]?.intValue ?? 0,
            lastError: row["last_error"]?.stringValue
        )
    }
}
