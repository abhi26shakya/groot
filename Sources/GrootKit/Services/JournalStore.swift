import Foundation

/// Persistence boundary for the Undo journal. Kept as a protocol so Phase 0 can
/// run against an in-memory store (offline, test-friendly) while production
/// swaps in a GRDB/SQLite implementation without touching `FileService`.
public protocol JournalStore: Sendable {
    /// Record an entry (typically before the operation runs). Returns nothing;
    /// the caller already holds the entry.
    func record(_ entry: JournalEntry) async throws

    /// Update an existing entry in place (e.g. to set `appliedAt`/`revertedAt`).
    func update(_ entry: JournalEntry) async throws

    /// Fetch a single entry by id.
    func entry(_ id: UUID) async throws -> JournalEntry?

    /// All entries, newest first — powers the Recovery Center / activity log.
    func allEntries() async throws -> [JournalEntry]

    /// Filtered/searched view for the Recovery Center.
    func entries(matching filter: JournalFilter) async throws -> [JournalEntry]

    /// Retention: remove entries older than `date`. When `revertedOnly` is
    /// true, only already-reverted rows are removed — rows for unreverted
    /// operations are kept regardless of age. Deletes journal rows only; never
    /// touches a file on disk.
    func deleteEntries(olderThan date: Date, revertedOnly: Bool) async throws

    /// Clear the entire journal. Rows only; never touches a file on disk.
    func deleteAll() async throws
}

/// Simple in-memory journal for Phase 0 and unit tests.
public actor InMemoryJournalStore: JournalStore {
    private var entries: [UUID: JournalEntry] = [:]

    public init() {}

    public func record(_ entry: JournalEntry) async throws {
        entries[entry.id] = entry
    }

    public func update(_ entry: JournalEntry) async throws {
        entries[entry.id] = entry
    }

    public func entry(_ id: UUID) async throws -> JournalEntry? {
        entries[id]
    }

    public func allEntries() async throws -> [JournalEntry] {
        entries.values.sorted { $0.timestamp > $1.timestamp }
    }

    public func entries(matching filter: JournalFilter) async throws -> [JournalEntry] {
        entries.values.filter(filter.matches).sorted { $0.timestamp > $1.timestamp }
    }

    public func deleteEntries(olderThan date: Date, revertedOnly: Bool) async throws {
        entries = entries.filter { _, entry in
            guard entry.timestamp < date else { return true } // keep: not old enough
            if revertedOnly { return entry.revertedAt == nil } // keep: not yet reverted
            return false // delete
        }
    }

    public func deleteAll() async throws {
        entries.removeAll()
    }
}
