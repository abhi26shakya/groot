import XCTest
@testable import GrootKit

final class EmptyFolderCleanupAgentTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-emptyfolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func makeDir(_ relativePath: String) throws -> URL {
        let url = sandbox.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relativePath: String, _ contents: String = "x") throws -> URL {
        let url = sandbox.appendingPathComponent(relativePath)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: Pure scanning

    func testFindsEmptyFolderAndSkipsNonEmptyOne() throws {
        _ = try makeDir("Empty")
        let nonEmpty = try makeDir("HasFile")
        _ = try write("HasFile/note.txt")

        let found = EmptyFolderCleanupAgent.emptyFolders(under: [sandbox])
        XCTAssertEqual(found.map(\.lastPathComponent), ["Empty"])
        XCTAssertFalse(found.contains(where: { $0.path == nonEmpty.path }))
    }

    func testFolderWithOnlyHiddenFilesCountsAsEmpty() throws {
        _ = try makeDir("AlmostEmpty")
        _ = try write("AlmostEmpty/.DS_Store")

        let found = EmptyFolderCleanupAgent.emptyFolders(under: [sandbox])
        XCTAssertEqual(found.map(\.lastPathComponent), ["AlmostEmpty"])
    }

    func testNestedEmptyFoldersCollapseToOutermostAncestor() throws {
        _ = try makeDir("Outer/Middle/Inner")

        let found = EmptyFolderCleanupAgent.emptyFolders(under: [sandbox])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "Outer")
    }

    func testExcludedRootsAreNeverConsidered() throws {
        let excluded = try makeDir("Organized")
        _ = try makeDir("Organized/EmptySub")
        _ = try makeDir("Regular")

        let found = EmptyFolderCleanupAgent.emptyFolders(under: [sandbox], excluding: [excluded])
        XCTAssertEqual(found.map(\.lastPathComponent), ["Regular"])
    }

    func testWatchedRootItselfIsNeverFlaggedEvenWhenEmpty() throws {
        // sandbox has no contents at all — the root itself must never appear.
        let found = EmptyFolderCleanupAgent.emptyFolders(under: [sandbox])
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: Pipeline

    func testApprovalTrashesEmptyFoldersButKeepsNonEmptyOnes() async throws {
        _ = try makeDir("Empty")
        let nonEmpty = try makeDir("HasFile")
        _ = try write("HasFile/note.txt")

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = EmptyFolderCleanupAgent(
            roots: [sandbox], fileService: fileService, approvals: approvals, autonomy: .approval)
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
        XCTAssertEqual(request.itemCount, 1)

        await approvals.approve(request.id)
        await scanning.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Empty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonEmpty.path))
        let history = try await fileService.history()
        XCTAssertEqual(history.first?.kind, .trash)
        let cleaned = await agent.cleaned
        XCTAssertEqual(cleaned, 1)
    }

    func testTrashIsGatedEvenUnderAutopilot() async throws {
        _ = try makeDir("Empty")
        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = EmptyFolderCleanupAgent(
            roots: [sandbox], fileService: fileService, approvals: approvals, autonomy: .autopilot)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Empty").path))

        await approvals.approve(request.id)
        await scanning.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Empty").path))
    }

    func testPreviewModeChangesNothing() async throws {
        _ = try makeDir("Empty")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = EmptyFolderCleanupAgent(roots: [sandbox], fileService: fileService, autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("Empty").path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testNoEmptyFoldersAsksNothing() async throws {
        let nonEmpty = try makeDir("HasFile")
        _ = try write("HasFile/note.txt")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = EmptyFolderCleanupAgent(roots: [sandbox], fileService: fileService, autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: nonEmpty.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }
}
