import XCTest
@testable import GrootKit

/// Phase 06 — Recovery Center & Undo History. Covers the two things that make
/// the Recovery Center possible: trash becoming restorable (`FileService`) and
/// filtered/paginated querying of the journal (`JournalStore`).
final class RecoveryTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    @discardableResult
    private func write(_ name: String, _ contents: String = "x") throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: FileService.trash / restore

    func testTrashRecordsResultingTrashURLAsDestination() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let file = try write("dupe.txt")

        let entry = try await service.trash(file, agentID: "test")

        XCTAssertEqual(entry.kind, .trash)
        XCTAssertNotNil(entry.destinationPath, "trash must capture the resulting Trash URL")
        XCTAssertTrue(entry.kind.isReversibleInApp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.destinationPath!),
                      "the resulting URL should be the file's real location in Trash")

        // Clean up: real Trash file, not the (already-removed) sandbox copy.
        try? FileManager.default.removeItem(atPath: entry.destinationPath!)
    }

    func testRestoreMovesTrashedItemBackToOriginAndMarksReverted() async throws {
        let store = InMemoryJournalStore()
        let service = FileService(store: store)
        let file = try write("recoverable.txt")

        let trashed = try await service.trash(file, agentID: "test")
        XCTAssertNil(trashed.revertedAt)

        let restored = try await service.restore(trashed.id)

        XCTAssertNotNil(restored.revertedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "restore should move the file back to its original path")
        let persisted = try await store.entry(trashed.id)
        XCTAssertNotNil(persisted?.revertedAt)
    }

    func testRestoreRejectsWhenOriginIsOccupied() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let file = try write("occupied.txt")

        let trashed = try await service.trash(file, agentID: "test")
        // Someone/something re-created a file at the original path in the meantime.
        try write("occupied.txt", "new content")

        do {
            _ = try await service.restore(trashed.id)
            XCTFail("expected destinationExists error")
        } catch let error as FileService.FileServiceError {
            XCTAssertEqual(error, .destinationExists(file.path))
        }

        try? FileManager.default.removeItem(atPath: trashed.destinationPath!)
    }

    func testRestoreFailsWhenTrashedFileIsMissing() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let file = try write("gone.txt")

        let trashed = try await service.trash(file, agentID: "test")
        // Simulate the user having emptied the Trash since.
        try FileManager.default.removeItem(atPath: trashed.destinationPath!)

        do {
            _ = try await service.restore(trashed.id)
            XCTFail("expected sourceMissing error")
        } catch let error as FileService.FileServiceError {
            XCTAssertEqual(error, .sourceMissing(trashed.destinationPath!))
        }
    }

    func testLegacyTrashRowWithNilDestinationIsNotRestorable() async throws {
        let store = InMemoryJournalStore()
        let service = FileService(store: store)
        let legacy = JournalEntry(
            agentID: "dedup", kind: .trash, sourcePath: "/tmp/legacy.txt",
            destinationPath: nil, appliedAt: Date())
        try await store.record(legacy)

        do {
            _ = try await service.restore(legacy.id)
            XCTFail("expected notReversible error")
        } catch let error as FileService.FileServiceError {
            XCTAssertEqual(error, .notReversible(legacy.id))
        }
    }

    func testBatchRestoreOverMixedSelectionReportsPerItemOutcomes() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let restorable = try await service.trash(try write("a.txt"), agentID: "test")
        let missing = try await service.trash(try write("b.txt"), agentID: "test")
        try FileManager.default.removeItem(atPath: missing.destinationPath!) // now unrestorable

        var restoredCount = 0
        var skipped: [UUID] = []
        for entry in [restorable, missing] {
            do {
                _ = try await service.restore(entry.id)
                restoredCount += 1
            } catch {
                skipped.append(entry.id)
            }
        }

        XCTAssertEqual(restoredCount, 1)
        XCTAssertEqual(skipped, [missing.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("a.txt").path))
    }

    // MARK: Retention is filesystem-inert

    func testClearAllHistoryRemovesJournalRowsButNeverTouchesFiles() async throws {
        let store = InMemoryJournalStore()
        let service = FileService(store: store)
        let file = try write("kept-on-disk.txt")
        _ = try await service.move(
            from: file, to: sandbox.appendingPathComponent("moved.txt"), agentID: "test")

        try await service.clearAllHistory()

        let remaining = try await service.history()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("moved.txt").path),
            "clearing history must never delete or move a real file")
    }

    func testClearHistoryOlderThanRevertedOnlyKeepsUnrevertedRows() async throws {
        let store = InMemoryJournalStore()
        let old = JournalEntry(agentID: "a", kind: .move, sourcePath: "/1", destinationPath: "/x/1",
                                timestamp: Date(timeIntervalSince1970: 1000), revertedAt: Date(timeIntervalSince1970: 1500))
        let oldUnreverted = JournalEntry(agentID: "a", kind: .move, sourcePath: "/2", destinationPath: "/x/2",
                                          timestamp: Date(timeIntervalSince1970: 1000))
        try await store.record(old)
        try await store.record(oldUnreverted)

        try await store.deleteEntries(olderThan: Date(timeIntervalSince1970: 2000), revertedOnly: true)

        let remaining = try await store.allEntries()
        XCTAssertEqual(remaining.map(\.id), [oldUnreverted.id])
    }

    // MARK: JournalEntry.recoveryStatus — the shared predicate both the
    // Dashboard's activity list and the Recovery Center render from.

    func testRecoveryStatusAppliedRevertedAndUnavailable() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let file = try write("status.txt")

        let trashed = try await service.trash(file, agentID: "test")
        XCTAssertEqual(trashed.recoveryStatus(), .applied)
        XCTAssertTrue(trashed.isCurrentlyRestorable())

        let restored = try await service.restore(trashed.id)
        XCTAssertEqual(restored.recoveryStatus(), .reverted)
        XCTAssertFalse(restored.isCurrentlyRestorable())

        let missing = try await service.trash(try write("gone.txt"), agentID: "test")
        try FileManager.default.removeItem(atPath: missing.destinationPath!)
        XCTAssertEqual(missing.recoveryStatus(), .unavailable)
        XCTAssertFalse(missing.isCurrentlyRestorable())

        let legacy = JournalEntry(agentID: "dedup", kind: .trash,
                                   sourcePath: "/tmp/legacy.txt", destinationPath: nil)
        XCTAssertEqual(legacy.recoveryStatus(), .unavailable)
    }

    // MARK: JournalFilter — InMemoryJournalStore

    func testInMemoryEntriesMatchingFiltersByAgentKindRevertStateAndSearch() async throws {
        let store = InMemoryJournalStore()
        let moveA = JournalEntry(agentID: "screenshot", kind: .move,
                                  sourcePath: "/tmp/a.png", destinationPath: "/tmp/out/a.png")
        var trashB = JournalEntry(agentID: "duplicate-detector", kind: .trash,
                                   sourcePath: "/tmp/b.pdf", destinationPath: "/.Trash/b.pdf")
        trashB.revertedAt = Date()
        let renameC = JournalEntry(agentID: "screenshot", kind: .rename,
                                    sourcePath: "/tmp/Screenshot.png", destinationPath: "/tmp/out/Invoice.png")
        try await store.record(moveA)
        try await store.record(trashB)
        try await store.record(renameC)

        let byAgent = try await store.entries(matching: JournalFilter(agentID: "screenshot"))
        XCTAssertEqual(Set(byAgent.map(\.id)), [moveA.id, renameC.id])

        let byKind = try await store.entries(matching: JournalFilter(kinds: [.trash]))
        XCTAssertEqual(byKind.map(\.id), [trashB.id])

        let reverted = try await store.entries(matching: JournalFilter(revertState: .revertedOnly))
        XCTAssertEqual(reverted.map(\.id), [trashB.id])

        let applied = try await store.entries(matching: JournalFilter(revertState: .appliedOnly))
        XCTAssertEqual(Set(applied.map(\.id)), [moveA.id, renameC.id])

        let searched = try await store.entries(matching: JournalFilter(searchText: "invoice"))
        XCTAssertEqual(searched.map(\.id), [renameC.id])

        let combined = try await store.entries(
            matching: JournalFilter(agentID: "screenshot", kinds: [.rename], searchText: "invoice"))
        XCTAssertEqual(combined.map(\.id), [renameC.id])
    }

    // MARK: JournalFilter — SQLiteJournalStore (same predicate, SQL translation)

    func testSQLiteEntriesMatchingProducesSameResultsAsInMemory() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-recovery-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: dbURL.deletingLastPathComponent()
                        .appendingPathComponent(dbURL.lastPathComponent + suffix))
            }
        }
        let store = try SQLiteJournalStore(url: dbURL)

        let moveA = JournalEntry(agentID: "screenshot", kind: .move,
                                  sourcePath: "/tmp/a.png", destinationPath: "/tmp/out/a.png")
        var trashB = JournalEntry(agentID: "duplicate-detector", kind: .trash,
                                   sourcePath: "/tmp/b.pdf", destinationPath: "/.Trash/b.pdf")
        trashB.revertedAt = Date()
        let renameC = JournalEntry(agentID: "screenshot", kind: .rename,
                                    sourcePath: "/tmp/Screenshot.png", destinationPath: "/tmp/out/Invoice.png")
        try await store.record(moveA)
        try await store.record(trashB)
        try await store.record(renameC)

        let byAgent = try await store.entries(matching: JournalFilter(agentID: "screenshot"))
        XCTAssertEqual(Set(byAgent.map(\.id)), [moveA.id, renameC.id])

        let byKind = try await store.entries(matching: JournalFilter(kinds: [.trash]))
        XCTAssertEqual(byKind.map(\.id), [trashB.id])

        let reverted = try await store.entries(matching: JournalFilter(revertState: .revertedOnly))
        XCTAssertEqual(reverted.map(\.id), [trashB.id])

        let searched = try await store.entries(matching: JournalFilter(searchText: "invoice"))
        XCTAssertEqual(searched.map(\.id), [renameC.id])

        // A search string containing SQL LIKE metacharacters must be treated literally.
        let literalSearch = try await store.entries(matching: JournalFilter(searchText: "100%"))
        XCTAssertTrue(literalSearch.isEmpty)
    }

    func testSQLiteDeleteEntriesAndDeleteAll() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-recovery-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: dbURL.deletingLastPathComponent()
                        .appendingPathComponent(dbURL.lastPathComponent + suffix))
            }
        }
        let store = try SQLiteJournalStore(url: dbURL)
        var old = JournalEntry(agentID: "a", kind: .move, sourcePath: "/1", destinationPath: "/x/1",
                                timestamp: Date(timeIntervalSince1970: 1000))
        old.revertedAt = Date(timeIntervalSince1970: 1500)
        let recent = JournalEntry(agentID: "a", kind: .move, sourcePath: "/2", destinationPath: "/x/2",
                                   timestamp: Date())
        try await store.record(old)
        try await store.record(recent)

        try await store.deleteEntries(olderThan: Date(timeIntervalSince1970: 2000), revertedOnly: true)
        let afterFirstDelete = try await store.allEntries()
        XCTAssertEqual(afterFirstDelete.map(\.id), [recent.id])

        try await store.deleteAll()
        let afterDeleteAll = try await store.allEntries()
        XCTAssertTrue(afterDeleteAll.isEmpty)
    }
}
