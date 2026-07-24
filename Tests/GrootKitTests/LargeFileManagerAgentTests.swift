import XCTest
@testable import GrootKit

final class LargeFileManagerAgentTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-largefiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    // MARK: Pure filtering

    func testLargeFilesFiltersByThresholdAndSortsDescending() {
        let small = FileEntry(path: "/x/note.txt", sizeBytes: 100, modified: Date())
        let big = FileEntry(path: "/x/movie.mov", sizeBytes: 2_000_000_000, modified: Date())
        let biggest = FileEntry(path: "/x/backup.zip", sizeBytes: 8_000_000_000, modified: Date())

        let large = LargeFileManagerAgent.largeFiles(
            [small, big, biggest], thresholdBytes: 500 * 1024 * 1024)

        XCTAssertEqual(large.map(\.path), ["/x/backup.zip", "/x/movie.mov"])
    }

    func testLargeFilesExcludesOwnArchiveOutput() {
        let alreadyArchived = FileEntry(
            path: "/x/Large Files/2026-07/old.zip", sizeBytes: 1_000_000_000, modified: Date())
        let fresh = FileEntry(path: "/x/new.zip", sizeBytes: 1_000_000_000, modified: Date())

        let large = LargeFileManagerAgent.largeFiles(
            [alreadyArchived, fresh], thresholdBytes: 500 * 1024 * 1024)

        XCTAssertEqual(large.map(\.path), ["/x/new.zip"])
    }

    // MARK: Archive (default, reversible) pipeline

    func testApprovalArchivesLargeFilesIntoDatedFolder() async throws {
        let big = try write("huge.bin", bytes: 2000)
        _ = try write("small.txt", bytes: 10)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = LargeFileManagerAgent(
            roots: [sandbox], fileService: fileService, approvals: approvals,
            thresholdBytes: 1000, action: .archive, autonomy: .approval)
        await agent.attach(to: bus)
        await agent.start()

        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        let scanning = Task { await agent.scan() }
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertFalse(request.isDestructive) // archive is a reversible move
        XCTAssertEqual(request.itemCount, 1)

        await approvals.approve(request.id)
        await scanning.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
        let monthFolder = sandbox
            .appendingPathComponent("Large Files", isDirectory: true)
            .appendingPathComponent(currentMonthString(), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: monthFolder.appendingPathComponent("huge.bin").path))
        let history = try await fileService.history()
        XCTAssertEqual(history.first?.kind, .move)
        let acted = await agent.acted
        XCTAssertEqual(acted, 1)
    }

    // MARK: Trash (opt-in, destructive) pipeline

    func testTrashActionIsAlwaysGatedEvenUnderAutopilot() async throws {
        let big = try write("huge.bin", bytes: 2000)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        // Autopilot would normally act immediately — but trash is destructive,
        // so ApprovalPolicy must still route this to the user.
        let agent = LargeFileManagerAgent(
            roots: [sandbox], fileService: fileService, approvals: approvals,
            thresholdBytes: 1000, action: .trash, autonomy: .autopilot)
        await agent.attach(to: bus)
        await agent.start()

        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        let scanning = Task { await agent.scan() }
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(request.isDestructive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))

        await approvals.approve(request.id)
        await scanning.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
        let history = try await fileService.history()
        XCTAssertEqual(history.first?.kind, .trash)
    }

    func testPreviewModeChangesNothing() async throws {
        let big = try write("huge.bin", bytes: 2000)

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = LargeFileManagerAgent(
            roots: [sandbox], fileService: fileService,
            thresholdBytes: 1000, action: .archive, autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testNoLargeFilesReportsEmptyAndAsksNothing() async throws {
        _ = try write("small.txt", bytes: 10)
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = LargeFileManagerAgent(
            roots: [sandbox], fileService: fileService, thresholdBytes: 1000, autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.scan()

        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    private func currentMonthString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }
}
