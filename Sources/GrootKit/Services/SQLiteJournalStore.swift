import Foundation
import SQLite3

/// Durable `JournalStore` backed by the system `libsqlite3` (ships with macOS —
/// no external dependency, builds offline). Because it's an actor, all statement
/// use is serialized, so a single connection with a shared handle is safe.
///
/// Drop-in for `InMemoryJournalStore`: `FileService` depends only on the
/// `JournalStore` protocol and is unchanged.
public actor SQLiteJournalStore: JournalStore {
    public enum StoreError: Error, Sendable {
        case open(String)
        case prepare(String)
        case step(String)
    }

    // nonisolated(unsafe) so `deinit` can close the handle. Access remains
    // serialized because every touch happens through actor-isolated methods.
    private nonisolated(unsafe) var db: OpaquePointer?
    private let path: String

    /// SQLite wants this destructor constant for transient (copied) bindings.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// - Parameter url: file URL for the database. Defaults to
    ///   `~/Library/Application Support/Groot/groot.db`.
    public init(url: URL? = nil) throws {
        let dbURL: URL
        if let url {
            dbURL = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Groot", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            dbURL = base.appendingPathComponent("groot.db")
        }
        self.path = dbURL.path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
        }
        self.db = handle
        try Self.bootstrap(handle)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Schema

    /// Static so it can run from the (nonisolated) initializer against the raw handle.
    private static func bootstrap(_ db: OpaquePointer) throws {
        try execRaw(db, "PRAGMA journal_mode=WAL;")
        try execRaw(db, """
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
        """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_journal_time ON undo_journal(timestamp DESC);")
        try execRaw(db, "PRAGMA user_version=1;")
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.prepare(message)
        }
    }

    // MARK: JournalStore

    public func record(_ entry: JournalEntry) async throws {
        try upsert(entry)
    }

    public func update(_ entry: JournalEntry) async throws {
        try upsert(entry)
    }

    public func entry(_ id: UUID) async throws -> JournalEntry? {
        let sql = "SELECT id, agent_id, kind, source_path, destination_path, timestamp, applied_at, reverted_at FROM undo_journal WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return row(stmt) }
        if rc == SQLITE_DONE { return nil }
        throw StoreError.step(lastError())
    }

    public func allEntries() async throws -> [JournalEntry] {
        let sql = "SELECT id, agent_id, kind, source_path, destination_path, timestamp, applied_at, reverted_at FROM undo_journal ORDER BY timestamp DESC;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var results: [JournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(row(stmt))
        }
        return results
    }

    // MARK: Upsert / row mapping

    private func upsert(_ entry: JournalEntry) throws {
        let sql = """
        INSERT INTO undo_journal (id, agent_id, kind, source_path, destination_path, timestamp, applied_at, reverted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            agent_id=excluded.agent_id,
            kind=excluded.kind,
            source_path=excluded.source_path,
            destination_path=excluded.destination_path,
            timestamp=excluded.timestamp,
            applied_at=excluded.applied_at,
            reverted_at=excluded.reverted_at;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.id.uuidString)
        bindText(stmt, 2, entry.agentID.raw)
        bindText(stmt, 3, entry.kind.rawValue)
        bindText(stmt, 4, entry.sourcePath)
        bindTextOrNull(stmt, 5, entry.destinationPath)
        sqlite3_bind_double(stmt, 6, entry.timestamp.timeIntervalSince1970)
        bindDoubleOrNull(stmt, 7, entry.appliedAt?.timeIntervalSince1970)
        bindDoubleOrNull(stmt, 8, entry.revertedAt?.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.step(lastError())
        }
    }

    private func row(_ stmt: OpaquePointer?) -> JournalEntry {
        let id = UUID(uuidString: text(stmt, 0) ?? "") ?? UUID()
        let agent = AgentID(text(stmt, 1) ?? "")
        let kind = FileOperationKind(rawValue: text(stmt, 2) ?? "") ?? .move
        let source = text(stmt, 3) ?? ""
        let dest = text(stmt, 4)
        let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let applied = doubleOrNil(stmt, 6).map { Date(timeIntervalSince1970: $0) }
        let reverted = doubleOrNil(stmt, 7).map { Date(timeIntervalSince1970: $0) }
        return JournalEntry(
            id: id, agentID: agent, kind: kind,
            sourcePath: source, destinationPath: dest,
            timestamp: ts, appliedAt: applied, revertedAt: reverted
        )
    }

    // MARK: Low-level helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(lastError())
        }
        return stmt
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindDoubleOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func doubleOrNil(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}
