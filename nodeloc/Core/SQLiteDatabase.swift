//
//  SQLiteDatabase.swift
//  nodeloc
//
//  A minimal SQLite layer, for the one thing in this app that is genuinely a
//  database problem: chat history.
//
//  Why SQLite and not the alternatives:
//
//  * **GRDB** would mean a Swift package, which means editing
//    `project.pbxproj` — an operation that crashes Xcode here, so it can only
//    be done by hand in the UI. Not worth that friction for the few hundred
//    lines below.
//  * **SwiftData** would add a second decoding path: `@Model` types alongside
//    the `Codable` ones the API already returns. This codebase has lost real
//    time to decode fragility twice (a wrong type in `site.json` emptying
//    every post's node, Rails enums breaking `current_user`), and `Codable` is
//    all-or-nothing. One path is worth protecting.
//  * SQLite ships with the OS, needs no package, and `import SQLite3` links
//    against the SDK's own module.
//
//  Two decisions that shape everything here:
//
//  1. **The rows are a cache of the server, so there are no migrations.** Bump
//     `Schema.version` and the database is deleted and rebuilt from the
//     network. That removes the largest long-term cost of introducing a
//     database at all — nobody has to write or test an upgrade path for data
//     that can be refetched.
//
//  2. **Messages keep the server's own JSON in a column.** Queryable columns
//     exist only for what the app needs to sort, page and join on; the body is
//     decoded by the same models a live response goes through. Same principle
//     as `ProfileSnapshot`.
//
//  Concurrency: this type is not itself thread-safe. It is owned by the
//  `ChatStorage` actor, which serializes every call. SQLite would allow more
//  with WAL and a connection pool, but chat writes are small and infrequent,
//  and a single serialized connection cannot deadlock or interleave a
//  half-written transaction.
//

import Foundation
import SQLite3

/// A value crossing the SQLite boundary.
enum SQLValue: Sendable, Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    var intValue: Int? {
        switch self {
        case .int(let value): Int(value)
        case .double(let value): Int(value)
        case .text(let value): Int(value)
        default: nil
        }
    }

    var stringValue: String? {
        switch self {
        case .text(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        default: nil
        }
    }

    var dataValue: Data? {
        switch self {
        case .blob(let value): value
        case .text(let value): value.data(using: .utf8)
        default: nil
        }
    }

    var boolValue: Bool {
        (intValue ?? 0) != 0
    }
}

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "SQLite could not open the database: \(message)"
        case .prepare(let message, let sql): "SQLite could not prepare \(sql): \(message)"
        case .step(let message, let sql): "SQLite failed running \(sql): \(message)"
        }
    }
}

/// Not an actor, deliberately.
///
/// Its only owner is the `ChatStorage` actor, which already serializes every
/// call, so a second boundary here would buy nothing and cost a great deal:
/// `transaction` takes a synchronous closure, and an actor would force every
/// statement inside it to be awaited — which is precisely what a transaction
/// must not allow, since each `await` is a suspension point where other work
/// could slip between BEGIN and COMMIT.
///
/// Non-`Sendable` on purpose: the compiler then refuses to let it escape the
/// actor that holds it.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let url: URL

    /// - Parameter url: the database file. Its directory is created if needed.
    init(url: URL) {
        self.url = url
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Opens the connection, creating the file and its directory.
    ///
    /// Separate from `init` so the failure is reportable: callers open
    /// explicitly and decide what an unusable cache means for them.
    func open() throws {
        guard handle == nil else { return }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(connection)
            throw SQLiteError.open(message)
        }
        handle = connection

        // WAL so a read never blocks behind a write, and NORMAL because losing
        // the last few messages to a power cut is recoverable — they are still
        // on the server.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Deletes the file and reopens it empty.
    ///
    /// This is the migration strategy: every row here can be refetched, so a
    /// schema change costs one download rather than an upgrade path.
    func reset() throws {
        close()
        // The siblings too: WAL and shared-memory files outlive the main one,
        // and reopening onto a stale -wal would restore the rows just deleted.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        try open()
    }

    /// Runs one or more statements with no parameters and no results.
    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError.open("not open") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    /// Runs one parameterised statement that returns nothing.
    @discardableResult
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        guard let handle else { throw SQLiteError.open("not open") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and materialises the rows.
    ///
    /// Materialised rather than streamed because callers hand the result
    /// straight to the UI, and holding a statement open across an `await`
    /// inside an actor buys nothing.
    func rows(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[String: SQLValue]] {
        guard handle != nil else { throw SQLiteError.open("not open") }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(index))))
        }

        var output: [[String: SQLValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for index in 0..<columnCount {
                row[names[index]] = value(of: statement, at: Int32(index))
            }
            output.append(row)
        }
        return output
    }

    /// Everything in `body` commits together, or not at all.
    ///
    /// Used for the batch of messages one fetch produces: a half-inserted page
    /// would leave a gap that the paging queries would read as "history ends
    /// here".
    func transaction<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body(self)
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: Statements

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw SQLiteError.open("not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw SQLiteError.prepare(message, sql: sql)
        }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .int(let value):
                sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                // `SQLITE_TRANSIENT` so SQLite copies the bytes; the Swift
                // string's buffer does not outlive this call.
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .blob(let value):
                if value.isEmpty {
                    sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    _ = value.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                    }
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func value(of statement: OpaquePointer?, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: cString))
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, index) else { return .null }
            let count = Int(sqlite3_column_bytes(statement, index))
            return .blob(Data(bytes: pointer, count: count))
        default:
            return .null
        }
    }
}

/// `SQLITE_TRANSIENT` isn't exposed to Swift, so it has to be rebuilt: it is
/// the sentinel destructor pointer -1, telling SQLite to copy the bound bytes.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
