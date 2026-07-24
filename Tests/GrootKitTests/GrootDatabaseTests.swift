import XCTest
import SQLite3
@testable import GrootKit

final class GrootDatabaseTests: XCTestCase {

    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-db-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: dbURL.deletingLastPathComponent()
                    .appendingPathComponent(dbURL.lastPathComponent + suffix))
        }
    }

    // MARK: Migrations

    func testFreshDatabaseMigratesToLatestVersion() async throws {
        let db = try GrootDatabase(url: dbURL)
        let latest = GrootDatabase.migrations.map(\.version).max() ?? 0
        let version = try await db.schemaVersion
        XCTAssertEqual(version, latest)
        XCTAssertEqual(version, 3, "Phase 07 ships schema v3")
    }

    func testAllExpectedTablesExist() async throws {
        let db = try GrootDatabase(url: dbURL)
        let rows = try await db.query("SELECT name FROM sqlite_master WHERE type='table';")
        let tables = Set(rows.compactMap { $0.string(0) })
        for expected in ["undo_journal", "agent_state", "settings", "activity_log",
                         "pending_approvals", "rules", "catalog", "learning"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    /// The migration that actually matters: users already have a v1 `groot.db`
    /// on disk written by the pre-migration `SQLiteJournalStore`. It must upgrade
    /// in place with its history intact — never rebuilt, never dropped.
    func testExistingV1DatabaseUpgradesInPlaceWithRowsIntact() async throws {
        try writeLegacyV1Database(at: dbURL, journalRowID: "row-1")

        let db = try GrootDatabase(url: dbURL)
        let version = try await db.schemaVersion
        XCTAssertEqual(version, 3)

        let rows = try await db.query("SELECT id, source_path FROM undo_journal;")
        XCTAssertEqual(rows.count, 1, "pre-existing journal row must survive the upgrade")
        XCTAssertEqual(rows.first?.string(0), "row-1")
        XCTAssertEqual(rows.first?.string(1), "/tmp/legacy.png")
    }

    /// A v1 database opened through the journal store still reads back through
    /// the public API after migrating.
    func testLegacyRowReadableThroughJournalStoreAfterMigration() async throws {
        let id = UUID()
        try writeLegacyV1Database(at: dbURL, journalRowID: id.uuidString)

        let store = try SQLiteJournalStore(url: dbURL)
        let entry = try await store.entry(id)
        XCTAssertEqual(entry?.sourcePath, "/tmp/legacy.png")
        XCTAssertEqual(entry?.kind, .rename)
    }

    func testMigrationIsIdempotentAcrossReopens() async throws {
        _ = try GrootDatabase(url: dbURL)
        let reopened = try GrootDatabase(url: dbURL)
        let version = try await reopened.schemaVersion
        XCTAssertEqual(version, 3)
    }

    // MARK: Query API

    func testExecuteAndQueryRoundTripAllValueKinds() async throws {
        let db = try GrootDatabase(url: dbURL)
        try await db.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?);",
            [.text("roots"), .text("/Users/x/Desktop")])
        let rows = try await db.query("SELECT value FROM settings WHERE key = ?;", [.text("roots")])
        XCTAssertEqual(rows.first?.string(0), "/Users/x/Desktop")

        try await db.execute(
            "INSERT INTO activity_log (agent_id, level, message, ts) VALUES (?, ?, ?, ?);",
            [.null, .text("info"), .text("hello"), .date(Date(timeIntervalSince1970: 5000))])
        let log = try await db.query("SELECT agent_id, level, ts FROM activity_log;")
        XCTAssertEqual(log.first?[0], .null)
        XCTAssertEqual(log.first?.string(1), "info")
        XCTAssertEqual(log.first?.date(2)?.timeIntervalSince1970, 5000)
    }

    func testTransactionCommitsAllStatements() async throws {
        let db = try GrootDatabase(url: dbURL)
        try await db.transaction([
            SQLStatement("INSERT INTO settings (key, value) VALUES (?, ?);", [.text("a"), .text("1")]),
            SQLStatement("INSERT INTO settings (key, value) VALUES (?, ?);", [.text("b"), .text("2")])
        ])
        let rows = try await db.query("SELECT COUNT(*) FROM settings;")
        XCTAssertEqual(rows.first?.int(0), 2)
    }

    func testTransactionRollsBackWhenAStatementFails() async throws {
        let db = try GrootDatabase(url: dbURL)
        do {
            try await db.transaction([
                SQLStatement("INSERT INTO settings (key, value) VALUES (?, ?);", [.text("a"), .text("1")]),
                SQLStatement("INSERT INTO no_such_table (x) VALUES (1);")
            ])
            XCTFail("expected the failing statement to propagate")
        } catch {
            // expected
        }

        let rows = try await db.query("SELECT COUNT(*) FROM settings;")
        XCTAssertEqual(rows.first?.int(0), 0, "the earlier insert must be rolled back")
    }

    // MARK: Helper

    /// Write a database in exactly the shape the pre-Phase-07 `SQLiteJournalStore`
    /// produced: `undo_journal` only, stamped `user_version = 1`.
    private func writeLegacyV1Database(at url: URL, journalRowID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(handle) }

        let sql = """
        PRAGMA journal_mode=WAL;
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
        INSERT INTO undo_journal (id, agent_id, kind, source_path, destination_path, timestamp)
        VALUES ('\(journalRowID)', 'screenshot', 'rename', '/tmp/legacy.png', '/tmp/out.png', 1000.0);
        PRAGMA user_version=1;
        """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
