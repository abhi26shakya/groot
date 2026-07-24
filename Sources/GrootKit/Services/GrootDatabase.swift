import Foundation
import SQLite3

/// A `Sendable` SQLite value. Statement handles (`OpaquePointer`) can never leave
/// the database actor, so every query crosses the isolation boundary as values.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public var stringValue: String? { if case .text(let v) = self { return v }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .integer(let v): return Int(v)
        case .real(let v): return Int(v)
        default: return nil
        }
    }
    public var boolValue: Bool? { intValue.map { $0 != 0 } }
}

/// One row of a result set, addressed by column index.
public struct SQLRow: Sendable {
    public let values: [SQLValue]

    public subscript(index: Int) -> SQLValue {
        index >= 0 && index < values.count ? values[index] : .null
    }

    public func string(_ index: Int) -> String? { self[index].stringValue }
    public func double(_ index: Int) -> Double? { self[index].doubleValue }
    public func int(_ index: Int) -> Int? { self[index].intValue }
    public func bool(_ index: Int) -> Bool? { self[index].boolValue }
    public func date(_ index: Int) -> Date? { self[index].doubleValue.map(Date.init(timeIntervalSince1970:)) }
}

/// A statement plus its bindings, so batches can cross isolation as values.
public struct SQLStatement: Sendable {
    public let sql: String
    public let bindings: [SQLValue]

    public init(_ sql: String, _ bindings: [SQLValue] = []) {
        self.sql = sql
        self.bindings = bindings
    }
}

/// A single forward-only schema change. Applied in a transaction and stamped
/// into `PRAGMA user_version`, so an upgrade is all-or-nothing per step.
///
/// **Migrations are append-only and must never `DROP` or rewrite user data** —
/// people already have a `groot.db` on disk.
public struct Migration: Sendable {
    public let version: Int
    public let sql: String

    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

/// The single SQLite connection for the whole app: owns the handle, applies
/// migrations on open, and exposes a small value-based query API that every
/// store (`SQLiteJournalStore`, `SettingsStore`, …) is a thin façade over.
///
/// Because it's an actor, statement use is serialized and one connection is safe.
public actor GrootDatabase {
    public enum DatabaseError: Error, Sendable, Equatable {
        case open(String)
        case prepare(String)
        case step(String)
        case migration(version: Int, message: String)
    }

    // nonisolated(unsafe) so `deinit` can close the handle. Every other touch
    // happens through actor-isolated methods, so access stays serialized.
    private nonisolated(unsafe) var db: OpaquePointer?
    public nonisolated let path: String

    /// SQLite wants this destructor constant for transient (copied) bindings.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Default location: `~/Library/Application Support/Groot/groot.db`.
    public static func defaultURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Groot", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("groot.db")
    }

    public init(url: URL? = nil) throws {
        let dbURL = try url ?? Self.defaultURL()
        self.path = dbURL.path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(handle)))
        }
        self.db = handle
        // Runs against the raw handle: an actor's init can't call isolated methods.
        try Self.exec(handle, "PRAGMA journal_mode=WAL;")
        try Self.exec(handle, "PRAGMA foreign_keys=ON;")
        try Self.migrate(handle)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Schema

    /// Ordered, append-only. v1 reproduces the original `undo_journal` schema
    /// verbatim so databases created before migrations existed match exactly and
    /// upgrade in place rather than being rebuilt.
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE IF NOT EXISTS undo_journal (
            id               TEXT PRIMARY KEY,
            agent_id         TEXT NOT NULL,
            kind             TEXT NOT NULL,
            source_path      TEXT NOT NULL,
            destination_path TEXT,
            timestamp        REAL NOT NULL,
            applied_at       REAL,
            reverted_at      REAL
        );
        CREATE INDEX IF NOT EXISTS idx_journal_time ON undo_journal(timestamp DESC);
        """),

        Migration(version: 2, sql: """
        CREATE TABLE IF NOT EXISTS agent_state (
            agent_id   TEXT PRIMARY KEY,
            autonomy   TEXT NOT NULL,
            enabled    INTEGER NOT NULL DEFAULT 1,
            last_state TEXT
        );
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS activity_log (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id TEXT,
            level    TEXT NOT NULL,
            message  TEXT NOT NULL,
            ts       REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_activity_time ON activity_log(ts DESC);
        CREATE TABLE IF NOT EXISTS pending_approvals (
            id             TEXT PRIMARY KEY,
            agent_id       TEXT NOT NULL,
            summary        TEXT NOT NULL,
            detail         TEXT,
            item_count     INTEGER NOT NULL,
            bytes_affected INTEGER NOT NULL,
            is_destructive INTEGER NOT NULL,
            created_at     REAL NOT NULL
        );
        """),

        // Created empty on purpose: Phases 03–04 fill these in, and having the
        // tables already present means those phases carry no migration risk.
        Migration(version: 3, sql: """
        CREATE TABLE IF NOT EXISTS rules (
            id         TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            priority   INTEGER NOT NULL DEFAULT 0,
            enabled    INTEGER NOT NULL DEFAULT 1,
            definition TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS catalog (
            path        TEXT PRIMARY KEY,
            size_bytes  INTEGER NOT NULL,
            category    TEXT,
            content_hash TEXT,
            indexed_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_catalog_hash ON catalog(content_hash);
        CREATE TABLE IF NOT EXISTS learning (
            id         TEXT PRIMARY KEY,
            agent_id   TEXT NOT NULL,
            signal     TEXT NOT NULL,
            payload    TEXT NOT NULL,
            ts         REAL NOT NULL
        );
        """)
    ]

    /// Apply every migration newer than the stored `user_version`, one
    /// transaction each. A crash mid-upgrade leaves the schema and the version
    /// stamp consistent at the last fully applied step.
    private static func migrate(_ db: OpaquePointer) throws {
        let current = try readUserVersion(db)
        for migration in migrations.sorted(by: { $0.version < $1.version })
        where migration.version > current {
            do {
                try exec(db, "BEGIN;")
                try exec(db, migration.sql)
                // Not bindable — it's our own Int literal, so interpolation is safe.
                try exec(db, "PRAGMA user_version=\(migration.version);")
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                let message = (error as? DatabaseError).map { "\($0)" } ?? "\(error)"
                throw DatabaseError.migration(version: migration.version, message: message)
            }
        }
    }

    private static func readUserVersion(_ db: OpaquePointer) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// The schema version this connection is at. Exposed for tests/diagnostics.
    public var schemaVersion: Int {
        get throws {
            guard let db else { return 0 }
            return try Self.readUserVersion(db)
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.prepare(message)
        }
    }

    // MARK: Query API (values in, values out — nothing unsendable escapes)

    /// Run a statement that returns no rows.
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.step(lastError())
        }
    }

    /// Run a statement and materialize every row.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError.step(lastError()) }
            var values: [SQLValue] = []
            values.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                values.append(value(stmt, Int32(column)))
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    /// Run several statements as one atomic unit, rolling back if any fails.
    ///
    /// Deliberately takes a list of values rather than a closure: under Swift 6
    /// complete concurrency a non-`Sendable` closure can't cross into the actor,
    /// and every caller here just needs a batch of writes.
    public func transaction(_ statements: [SQLStatement]) throws {
        try execute("BEGIN;")
        do {
            for statement in statements {
                try execute(statement.sql, statement.bindings)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: Low-level helpers

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(lastError())
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null:
                sqlite3_bind_null(stmt, index)
            case .integer(let v):
                sqlite3_bind_int64(stmt, index, v)
            case .real(let v):
                sqlite3_bind_double(stmt, index, v)
            case .text(let v):
                sqlite3_bind_text(stmt, index, v, -1, Self.SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    private func value(_ stmt: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        default:
            guard let c = sqlite3_column_text(stmt, index) else { return .null }
            return .text(String(cString: c))
        }
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }
}

// MARK: - Binding conveniences

public extension SQLValue {
    static func text(orNull value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func real(orNull value: Double?) -> SQLValue { value.map { .real($0) } ?? .null }
    static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSince1970) }
    static func date(orNull value: Date?) -> SQLValue { value.map { .real($0.timeIntervalSince1970) } ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
}
