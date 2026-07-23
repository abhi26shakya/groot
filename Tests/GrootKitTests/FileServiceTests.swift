import XCTest
@testable import GrootKit

final class FileServiceTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrootTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    func testMoveJournalsAndUndoRestoresOriginal() async throws {
        let store = InMemoryJournalStore()
        let service = FileService(store: store)

        let source = sandbox.appendingPathComponent("report.pdf")
        let destDir = sandbox.appendingPathComponent("Finance", isDirectory: true)
        let destination = destDir.appendingPathComponent("report.pdf")
        try "invoice".data(using: .utf8)!.write(to: source)

        // Move: destination parent should be created, source gone, dest present.
        let entry = try await service.move(from: source, to: destination, agentID: "test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        // Journal recorded and marked applied.
        let recorded = try await store.entry(entry.id)
        XCTAssertNotNil(recorded?.appliedAt)
        XCTAssertNil(recorded?.revertedAt)

        // Undo: file returns to its original path, entry marked reverted.
        try await service.undo(entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let reverted = try await store.entry(entry.id)
        XCTAssertNotNil(reverted?.revertedAt)
    }

    func testMoveRefusesToClobberExistingDestination() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let source = sandbox.appendingPathComponent("a.txt")
        let destination = sandbox.appendingPathComponent("b.txt")
        try "a".data(using: .utf8)!.write(to: source)
        try "b".data(using: .utf8)!.write(to: destination)

        do {
            _ = try await service.move(from: source, to: destination, agentID: "test")
            XCTFail("Expected destinationExists error")
        } catch let error as FileService.FileServiceError {
            XCTAssertEqual(error, .destinationExists(destination.path))
        }
        // Both files untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDoubleUndoIsRejected() async throws {
        let service = FileService(store: InMemoryJournalStore())
        let source = sandbox.appendingPathComponent("x.txt")
        let destination = sandbox.appendingPathComponent("sub/x.txt")
        try "x".data(using: .utf8)!.write(to: source)

        let entry = try await service.move(from: source, to: destination, agentID: "test")
        try await service.undo(entry.id)
        do {
            try await service.undo(entry.id)
            XCTFail("Expected alreadyReverted error")
        } catch let error as FileService.FileServiceError {
            XCTAssertEqual(error, .alreadyReverted(entry.id))
        }
    }
}
