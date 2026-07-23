import XCTest
@testable import GrootKit

final class AnalysisAgentsTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: Duplicate detection

    func testGroupsIdenticalFilesAndComputesRecoverable() async throws {
        _ = try write("a.txt", "hello world")           // dup group A
        _ = try write("b.txt", "hello world")           // dup of a
        _ = try write("c.txt", "hello world")           // dup of a
        _ = try write("unique.txt", "different content") // singleton

        let files = FileScanner().scan(roots: [sandbox])
        let groups = DuplicateDetectionAgent.groupDuplicates(files)

        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.paths.count, 3)
        XCTAssertEqual(group.duplicates.count, 2) // 3 identical → 2 removable
        // "hello world" == 11 bytes, 2 duplicates recoverable.
        XCTAssertEqual(group.recoverableBytes, 22)
    }

    func testApprovalTrashesDuplicatesButKeepsOriginal() async throws {
        let a = try write("keep.txt", "same")
        let b = try write("dupe.txt", "same")
        // Make `keep.txt` older so it's chosen as the original.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: a.path)

        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let agent = DuplicateDetectionAgent(roots: [sandbox], fileService: fileService, autonomy: .approval)
        await agent.attach(to: bus)
        await agent.start()

        // Capture the approval request the scan raises.
        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        await agent.scan()
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertTrue(request.isDestructive)
        XCTAssertEqual(request.itemCount, 1)

        await agent.approve(request.id)
        // Original kept; duplicate removed from its original location (trashed).
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        let history = try await fileService.history()
        XCTAssertEqual(history.first?.kind, .trash)
    }

    // MARK: Storage analyzer

    func testBuildReportRanksLargestAndFlagsInstallers() throws {
        let big = FileEntry(path: "/x/Xcode.dmg", sizeBytes: 8_000_000_000, modified: Date())
        let small = FileEntry(path: "/x/note.txt", sizeBytes: 100, modified: Date())
        let mid = FileEntry(path: "/x/movie.mov", sizeBytes: 2_000_000_000, modified: Date())

        let report = StorageAnalyzerAgent.buildReport(
            [small, big, mid], largeFileThreshold: 500 * 1024 * 1024)

        XCTAssertEqual(report.largestFiles.first?.path, "/x/Xcode.dmg")
        XCTAssertEqual(report.totalScannedBytes, 10_000_000_100)
        // An installer insight should be present and mention the .dmg size.
        XCTAssertTrue(report.insights.contains { $0.title == "Old installers" })
        // Two files exceed 500 MB → a large-files insight.
        XCTAssertTrue(report.insights.contains { $0.title.contains("large file") })
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }
}
