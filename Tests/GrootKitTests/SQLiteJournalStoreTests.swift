import XCTest
@testable import GrootKit

final class SQLiteJournalStoreTests: XCTestCase {

    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: dbURL.deletingLastPathComponent()
                    .appendingPathComponent(dbURL.lastPathComponent + suffix))
        }
    }

    func testRecordFetchUpdateRoundTrip() async throws {
        let store = try SQLiteJournalStore(url: dbURL)
        var entry = JournalEntry(
            agentID: "screenshot",
            kind: .rename,
            sourcePath: "/tmp/Screenshot.png",
            destinationPath: "/tmp/Pictures/VSCode Error.png",
            appliedAt: Date()
        )
        try await store.record(entry)

        let fetched = try await store.entry(entry.id)
        XCTAssertEqual(fetched?.sourcePath, entry.sourcePath)
        XCTAssertEqual(fetched?.destinationPath, entry.destinationPath)
        XCTAssertEqual(fetched?.kind, .rename)
        XCTAssertEqual(fetched?.agentID, "screenshot")
        XCTAssertNotNil(fetched?.appliedAt)
        XCTAssertNil(fetched?.revertedAt)

        // Update marks reverted and persists.
        entry.revertedAt = Date()
        try await store.update(entry)
        let reverted = try await store.entry(entry.id)
        XCTAssertNotNil(reverted?.revertedAt)
    }

    func testAllEntriesNewestFirstAndPersistsAcrossReopen() async throws {
        do {
            let store = try SQLiteJournalStore(url: dbURL)
            let older = JournalEntry(agentID: "a", kind: .move, sourcePath: "/1",
                                     destinationPath: "/x/1", timestamp: Date(timeIntervalSince1970: 1000))
            let newer = JournalEntry(agentID: "a", kind: .move, sourcePath: "/2",
                                     destinationPath: "/x/2", timestamp: Date(timeIntervalSince1970: 2000))
            try await store.record(older)
            try await store.record(newer)
        }
        // Reopen a fresh store against the same file — data must survive.
        let reopened = try SQLiteJournalStore(url: dbURL)
        let all = try await reopened.allEntries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.sourcePath, "/2") // newest first
    }

    func testNullDestinationForTrash() async throws {
        let store = try SQLiteJournalStore(url: dbURL)
        let entry = JournalEntry(agentID: "dedup", kind: .trash,
                                 sourcePath: "/tmp/dup.pdf", destinationPath: nil, appliedAt: Date())
        try await store.record(entry)
        let fetched = try await store.entry(entry.id)
        XCTAssertNil(fetched?.destinationPath)
        XCTAssertEqual(fetched?.kind, .trash)
    }
}
