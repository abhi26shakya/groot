import XCTest
@testable import GrootKit

final class TrashManagerAgentTests: XCTestCase {

    private var trashDir: URL!

    override func setUpWithError() throws {
        trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let trashDir { try? FileManager.default.removeItem(at: trashDir) }
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = trashDir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private struct StubBackupChecker: BackupChecking {
        let date: Date?
        func latestBackupDate() async -> Date? { date }
    }

    // MARK: Pure scanning

    func testScanTrashSumsTopLevelItemsIgnoringHidden() throws {
        _ = try write("a.txt", bytes: 100)
        _ = try write("b.txt", bytes: 200)
        _ = try write(".DS_Store", bytes: 999)

        let items = TrashManagerAgent.scanTrash(at: trashDir)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.reduce(0) { $0 + $1.sizeBytes }, 300)
    }

    func testScanTrashSumsFolderContentsRecursively() throws {
        let folder = trashDir.appendingPathComponent("OldProject", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 500).write(to: folder.appendingPathComponent("a.bin"))
        try Data(count: 500).write(to: folder.appendingPathComponent("b.bin"))

        let items = TrashManagerAgent.scanTrash(at: trashDir)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.sizeBytes, 1000)
    }

    // MARK: Backup-aware approval copy

    func testApprovalDetailWarnsWhenNoBackupExists() {
        let report = TrashReport(itemCount: 3, totalBytes: 1000, oldestItemDate: nil, latestBackupDate: nil)
        let detail = TrashManagerAgent.approvalDetail(for: report)
        XCTAssertTrue(detail.contains("No Time Machine backup"))
        XCTAssertTrue(detail.contains("cannot be undone"))
    }

    func testApprovalDetailWarnsWhenBackupIsStale() {
        let report = TrashReport(
            itemCount: 3, totalBytes: 1000, oldestItemDate: nil,
            latestBackupDate: Date().addingTimeInterval(-10 * 86_400))
        let detail = TrashManagerAgent.approvalDetail(for: report)
        XCTAssertTrue(detail.contains("days ago") || detail.contains("day(s) ago"))
    }

    func testApprovalDetailIsReassuringWhenBackupIsRecent() {
        let report = TrashReport(
            itemCount: 3, totalBytes: 1000, oldestItemDate: nil,
            latestBackupDate: Date().addingTimeInterval(-3600))
        let detail = TrashManagerAgent.approvalDetail(for: report)
        XCTAssertTrue(detail.contains("recent"))
    }

    // MARK: Pipeline

    func testApprovalPermanentlyDeletesTrashContents() async throws {
        let a = try write("a.txt", bytes: 100)
        let b = try write("b.txt", bytes: 200)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = TrashManagerAgent(
            trashDirectory: trashDir, fileService: fileService,
            backupChecker: StubBackupChecker(date: Date()),
            approvals: approvals, autonomy: .approval)
        await agent.attach(to: bus)
        await agent.start()

        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        let analyzing = Task { await agent.analyze() }
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(request.isDestructive)
        XCTAssertEqual(request.itemCount, 2)

        await approvals.approve(request.id)
        await analyzing.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        let history = try await fileService.history()
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.kind == .permanentDelete })
        XCTAssertTrue(history.allSatisfy { !$0.kind.isReversibleInApp })
        let emptied = await agent.emptied
        XCTAssertEqual(emptied, 2)
    }

    func testDeletionIsGatedEvenUnderAutopilot() async throws {
        let a = try write("a.txt", bytes: 100)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        // Autopilot would normally act immediately — but permanent deletion is
        // destructive, so ApprovalPolicy must still route this to the user.
        let agent = TrashManagerAgent(
            trashDirectory: trashDir, fileService: fileService,
            backupChecker: StubBackupChecker(date: Date()),
            approvals: approvals, autonomy: .autopilot)
        await agent.attach(to: bus)
        await agent.start()

        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        let analyzing = Task { await agent.analyze() }
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))

        await approvals.approve(request.id)
        await analyzing.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testPreviewModeChangesNothing() async throws {
        let a = try write("a.txt", bytes: 100)
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = TrashManagerAgent(
            trashDirectory: trashDir, fileService: fileService,
            backupChecker: StubBackupChecker(date: nil), autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.analyze()

        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testEmptyTrashAsksNothing() async throws {
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = TrashManagerAgent(
            trashDirectory: trashDir, fileService: fileService,
            backupChecker: StubBackupChecker(date: nil), autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.analyze()

        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }
}
