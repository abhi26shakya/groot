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

    public func entries(matching filter: JournalFilter) async throws -> [JournalEntry] {
        var clauses: [String] = []
        var bindings: [SQLValue] = []

        if let agentID = filter.agentID {
            clauses.append("agent_id = ?")
            bindings.append(.text(agentID.raw))
        }
        if !filter.kinds.isEmpty {
            let placeholders = filter.kinds.map { _ in "?" }.joined(separator: ", ")
            clauses.append("kind IN (\(placeholders))")
            bindings.append(contentsOf: filter.kinds.map { .text($0.rawValue) })
        }
        switch filter.revertState {
        case .any: break
        case .revertedOnly: clauses.append("reverted_at IS NOT NULL")
        case .appliedOnly: clauses.append("reverted_at IS NULL")
        }
        if let range = filter.dateRange {
            clauses.append("timestamp >= ? AND timestamp <= ?")
            bindings.append(.date(range.lowerBound))
            bindings.append(.date(range.upperBound))
        }
        if let search = filter.searchText, !search.isEmpty {
            clauses.append("(source_path LIKE ? ESCAPE '\\' OR destination_path LIKE ? ESCAPE '\\')")
            let pattern = "%\(Self.escapeLike(search))%"
            bindings.append(.text(pattern))
            bindings.append(.text(pattern))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let rows = try await db.query(
            "SELECT \(Self.columns) FROM undo_journal \(whereSQL) ORDER BY timestamp DESC;",
            bindings)
        return rows.map(Self.decode)
    }

    public func deleteEntries(olderThan date: Date, revertedOnly: Bool) async throws {
        if revertedOnly {
            try await db.execute(
                "DELETE FROM undo_journal WHERE timestamp < ? AND reverted_at IS NOT NULL;",
                [.date(date)])
        } else {
            try await db.execute(
                "DELETE FROM undo_journal WHERE timestamp < ?;",
                [.date(date)])
        }
    }

    public func deleteAll() async throws {
        try await db.execute("DELETE FROM undo_journal;")
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

    /// Escape SQLite `LIKE` metacharacters so user search text is matched
    /// literally rather than as a wildcard pattern.
    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
