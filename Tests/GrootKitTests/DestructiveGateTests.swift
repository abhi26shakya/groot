import XCTest
@testable import GrootKit

/// The regression suite for the rule that motivated Phase 07: **destructive work
/// never runs unattended, whatever autonomy mode the user picked.**
///
/// Before `ApprovalService`, an agent in `.autopilot` reached its own
/// `switch autonomy` block and went straight to `perform`. These tests drive the
/// real agent against a real temp directory and assert the filesystem is
/// untouched until a human answers.
final class DestructiveGateTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// **The invariant, end to end.** Autopilot + duplicate deletion must raise
    /// an approval and change nothing on disk until it is answered.
    func testAutopilotDuplicateDeletionRaisesApprovalAndTouchesNothing() async throws {
        let original = try write("keep.txt", "identical")
        let duplicate = try write("dupe.txt", "identical")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: original.path)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = DuplicateDetectionAgent(
            roots: [sandbox],
            fileService: fileService,
            approvals: approvals,
            autonomy: .autopilot)   // the mode that used to bypass the prompt
        await agent.attach(to: bus)
        await agent.start()

        let scanning = Task { await agent.scan() }

        // Wait for the gate to register a pending request.
        try await waitUntil { await approvals.pendingCount == 1 }

        // Nothing may have happened yet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path),
                      "autopilot must not trash a duplicate before the user answers")
        let historyBefore = try await fileService.history()
        XCTAssertTrue(historyBefore.isEmpty, "nothing may be journaled before approval")

        let raised = await approvals.pending.first
        let request = try XCTUnwrap(raised)
        XCTAssertTrue(request.isDestructive)

        await approvals.approve(request.id)
        await scanning.value

        // Only after approval does the duplicate go (to the Trash, not unlinked).
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        let historyAfter = try await fileService.history()
        XCTAssertEqual(historyAfter.first?.kind, .trash)
    }

    /// Declining leaves every file in place.
    func testDecliningDestructiveWorkLeavesFilesUntouched() async throws {
        let original = try write("a.txt", "same")
        let duplicate = try write("b.txt", "same")

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = DuplicateDetectionAgent(
            roots: [sandbox], fileService: fileService, approvals: approvals, autonomy: .autopilot)
        await agent.attach(to: bus)
        await agent.start()

        let scanning = Task { await agent.scan() }
        try await waitUntil { await approvals.pendingCount == 1 }

        let raised = await approvals.pending.first
        let request = try XCTUnwrap(raised)
        await approvals.reject(request.id)
        await scanning.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    /// With no gate wired up there is no one to ask, so destructive work in
    /// autopilot must be declined — never silently performed.
    func testWithoutAGateDestructiveAutopilotWorkIsDeclinedNotPerformed() async throws {
        let original = try write("x.txt", "dup")
        let duplicate = try write("y.txt", "dup")

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = DuplicateDetectionAgent(
            roots: [sandbox], fileService: fileService, approvals: nil, autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()

        await agent.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    /// Reversible work is unaffected by the gate: autopilot still acts at once.
    func testReversibleWorkStillProceedsUnderAutopilot() async throws {
        let downloads = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("invoice.pdf")
        try Data([0x25, 0x50]).write(to: file)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = DownloadsOrganizerAgent(
            root: downloads, fileService: fileService, approvals: approvals, autonomy: .autopilot)
        await agent.attach(to: bus)
        await agent.start()

        await agent.handle(.fileCreated(file))

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "a reversible move should not wait for approval in autopilot")
        let history = try await fileService.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.kind, .move)
        let pending = await approvals.pendingCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: Helper

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
