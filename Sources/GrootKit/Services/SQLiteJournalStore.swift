import Foundation

/// Durable `JournalStore` backed by the shared `GrootDatabase` connection.
///
/// This is a thin façade: all connection handling, migrations, and statement
/// plumbing live in `GrootDatabase`. Drop-in for `InMemoryJournalStore` —
/// `FileService` depends only on the `JournalStore` protocol and is unchanged.
public actor SQLiteJournalStore: JournalStore {
    private let db: GrootDatabase

    private static let columns =
        "id, agent_id, kind, source_path, destination_path, timestamp, applied_at, reverted_at"

    /// Use the shared database connection.
    public init(database: GrootDatabase) {
        self.db = database
    }

    /// Convenience for callers that just want the default on-disk database
    /// (`~/Library/Application Support/Groot/groot.db`).
    ///
    /// Prefer `init(database:)` in the app so every store shares one connection.
    public init(url: URL? = nil) throws {
        self.db = try GrootDatabase(url: url)
    }

    /// The connection behind this store, so other façades can share it.
    public var database: GrootDatabase { db }

    // MARK: JournalStore

    public func record(_ entry: JournalEntry) async throws {
        try await upsert(entry)
    }

    public func update(_ entry: JournalEntry) async throws {
        try await upsert(entry)
    }

    public func entry(_ id: UUID) async throws -> JournalEntry? {
        let rows = try await db.query(
            "SELECT \(Self.columns) FROM undo_journal WHERE id = ?;",
            [.text(id.uuidString)])
        return rows.first.map(Self.decode)
    }

    public func allEntries() async throws -> [JournalEntry] {
        let rows = try await db.query(
            "SELECT \(Self.columns) FROM undo_journal ORDER BY timestamp DESC;")
        return rows.map(Self.decode)
    }

    // MARK: Mapping

    private func upsert(_ entry: JournalEntry) async throws {
        try await db.execute("""
        INSERT INTO undo_journal (\(Self.columns))
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            agent_id=excluded.agent_id,
            kind=excluded.kind,
            source_path=excluded.source_path,
            destination_path=excluded.destination_path,
            timestamp=excluded.timestamp,
            applied_at=excluded.applied_at,
            reverted_at=excluded.reverted_at;
        """, [
            .text(entry.id.uuidString),
            .text(entry.agentID.raw),
            .text(entry.kind.rawValue),
            .text(entry.sourcePath),
            .text(orNull: entry.destinationPath),
            .date(entry.timestamp),
            .date(orNull: entry.appliedAt),
            .date(orNull: entry.revertedAt)
        ])
    }

    private static func decode(_ row: SQLRow) -> JournalEntry {
        JournalEntry(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            agentID: AgentID(row.string(1) ?? ""),
            kind: FileOperationKind(rawValue: row.string(2) ?? "") ?? .move,
            sourcePath: row.string(3) ?? "",
            destinationPath: row.string(4),
            timestamp: row.date(5) ?? Date(),
            appliedAt: row.date(6),
            revertedAt: row.date(7)
        )
    }
}
