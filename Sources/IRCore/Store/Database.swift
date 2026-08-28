import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The index database.
///
/// It holds no secrets and no documents — only pointers and metadata. That is
/// deliberate: the files are the truth (F7.1) and this file is a cache that can
/// be thrown away and rebuilt by re-scanning the library folder (F7.2). Keeping
/// that property means never storing anything here that exists nowhere else.
public actor Database {
    /// The connection is opened once and closed once, and every statement runs
    /// under this actor. `nonisolated(unsafe)` is what lets `deinit` — which is
    /// not actor-isolated — close it.
    private nonisolated(unsafe) var handle: OpaquePointer?
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw IRError.storage("could not open \(url.path)")
        }
        self.handle = db

        // WAL plus a busy timeout is what keeps the database intact when the
        // app is force-quit mid-collection, which the specification requires
        // ("no corrupted state after an abrupt stop").
        try Database.exec(db, "PRAGMA journal_mode = WAL")
        try Database.exec(db, "PRAGMA foreign_keys = ON")
        try Database.exec(db, "PRAGMA busy_timeout = 5000")
        try Database.exec(db, "PRAGMA synchronous = NORMAL")
    }

    /// In-memory database, for tests.
    public static func inMemory() throws -> Database {
        try Database(url: URL(fileURLWithPath: ":memory:"))
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Primitives

    public func execute(_ sql: String) throws {
        guard let handle else { throw IRError.storage("database is closed") }
        try Database.exec(handle, sql)
    }

    /// Statement execution that does not touch actor state, so `init` — which
    /// runs before isolation is established — can use it too.
    private nonisolated static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw IRError.storage("\(message) — while running: \(sql.prefix(200))")
        }
    }

    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw IRError.storage(lastErrorMessage() + " — while running: \(sql.prefix(200))")
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [Row] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(statement, Int32(i))))
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw IRError.storage(lastErrorMessage() + " — while running: \(sql.prefix(200))")
            }
            var values: [String: SQLValue] = [:]
            for i in 0..<columnCount {
                values[names[i]] = readColumn(statement, Int32(i))
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// Runs `body` inside a transaction, rolling back if it throws. Used
    /// wherever a document's row and its file must agree.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer? {
        guard let handle else { throw IRError.storage("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IRError.storage(lastErrorMessage() + " — while preparing: \(sql.prefix(200))")
        }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, position)
            case .integer(let n):
                sqlite3_bind_int64(statement, position, Int64(n))
            case .real(let d):
                sqlite3_bind_double(statement, position, d)
            case .text(let s):
                sqlite3_bind_text(statement, position, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        }
        return statement
    }

    private func readColumn(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(Int(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:   return .real(sqlite3_column_double(statement, index))
        case SQLITE_NULL:    return .null
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, index) else { return .null }
            return .blob(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index))))
        default:
            guard let cString = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: cString))
        }
    }

    private func lastErrorMessage() -> String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "unknown SQLite error" }
        return String(cString: message)
    }
}

// MARK: - Values and rows

public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int?) { self = value.map { .integer($0) } ?? .null }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: UUID?) { self = value.map { .text($0.uuidString) } ?? .null }
    /// Dates are stored as ISO-8601 text: readable with any SQLite browser,
    /// which matters for a database the user is invited to inspect.
    public init(_ value: Date?) {
        self = value.map { .text(ISO8601DateFormatter.database.string(from: $0)) } ?? .null
    }
    public init<T: Encodable>(json value: T?) {
        guard let value, let data = try? JSONEncoder().encode(value) else { self = .null; return }
        self = .text(String(decoding: data, as: UTF8.self))
    }
}

public struct Row: Sendable {
    public let values: [String: SQLValue]

    public func string(_ column: String) -> String? {
        if case .text(let s)? = values[column] { return s }
        return nil
    }
    public func int(_ column: String) -> Int? {
        switch values[column] {
        case .integer(let n)?: return n
        case .real(let d)?: return Int(d)
        default: return nil
        }
    }
    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let d)?: return d
        case .integer(let n)?: return Double(n)
        default: return nil
        }
    }
    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
    public func uuid(_ column: String) -> UUID? { string(column).flatMap(UUID.init(uuidString:)) }
    public func date(_ column: String) -> Date? {
        string(column).flatMap { ISO8601DateFormatter.database.date(from: $0) }
    }
    public func data(_ column: String) -> Data? {
        if case .blob(let d)? = values[column] { return d }
        return nil
    }
    public func json<T: Decodable>(_ column: String, as type: T.Type) -> T? {
        guard let raw = string(column), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension ISO8601DateFormatter {
    /// Apple's date formatters are documented as safe to read from several
    /// threads once configured; this one is configured once and never mutated.
    nonisolated(unsafe) static let database: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
