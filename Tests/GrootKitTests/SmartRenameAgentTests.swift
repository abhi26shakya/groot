import XCTest
@testable import GrootKit

final class SmartRenameAgentTests: XCTestCase {

    private var watched: URL!
    private var organized: URL!
    private var screenshots: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-rename-\(UUID().uuidString)", isDirectory: true)
        watched = base.appendingPathComponent("Desktop", isDirectory: true)
        organized = base.appendingPathComponent("Organized", isDirectory: true)
        screenshots = base.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let base = watched.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    private struct StubRecognizer: TextRecognizing {
        func recognizeText(in url: URL) async throws -> String { "" }
    }

    private struct StubSuggester: FilenameSuggester {
        let name: String
        func suggest(ocrText: String, original: URL) async -> String { name }
    }

    private func extractor() -> ContentExtractor {
        ContentExtractor(recognizer: StubRecognizer())
    }

    private func write(_ name: String, _ contents: String = "some content", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? watched).appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func makeAgent(
        namer: FilenameSuggester,
        fileService: FileService,
        approvals: ApprovalService? = nil,
        allowedExtensions: Set<String>? = nil,
        autonomy: AutonomyMode = .autopilot
    ) -> SmartRenameAgent {
        SmartRenameAgent(
            watchedRoots: [watched],
            excludedRoots: [organized, screenshots],
            fileService: fileService,
            extractor: extractor(),
            namer: namer,
            allowedExtensions: allowedExtensions,
            approvals: approvals,
            autonomy: autonomy)
    }

    // MARK: Guard tests (pure, no I/O side effects beyond fixture setup)

    func testAcceptsPlainFilesDirectlyInWatchedRoot() throws {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("IMG_4821.pdf")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("Untitled.txt")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("notes.swift")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("Holiday.png")))
    }

    func testRejectsDotfilesAndPartialDownloads() {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent(".hidden.txt")))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("big.crdownload")))
    }

    func testRejectsNestedAndExcludedRoots() {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("sub/deep.txt")))
        XCTAssertFalse(agent.shouldRename(organized.appendingPathComponent("Finance/x.txt")))
        XCTAssertFalse(agent.shouldRename(screenshots.appendingPathComponent("2026-07/x.png")))
    }

    func testRejectsScreenshotsMutualExclusion() {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertFalse(agent.shouldRename(
            watched.appendingPathComponent("Screenshot 2026-07-24 at 9.41.png")))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("CleanShot 2026.png")))
    }

    func testRejectsUnsupportedExtensions() {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("archive.zip")))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("Installer.dmg")))
    }

    func testRejectsExtensionsOutsideAllowList() {
        let agent = makeAgent(
            namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()),
            allowedExtensions: ["txt"])
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("Untitled.txt")))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("Untitled.pdf")))
    }

    func testAlreadyNamedFilesAreLeftAlone() {
        let agent = makeAgent(namer: StubSuggester(name: "x"), fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertFalse(agent.shouldRename(watched.appendingPathComponent("Quarterly Budget Review.pdf")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("IMG_4821.pdf")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("Untitled.txt")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("document.pdf")))
        XCTAssertTrue(agent.shouldRename(watched.appendingPathComponent("42.txt")))
    }

    // MARK: Pipeline

    func testConfidentSuggestionRenamesInPlace() async throws {
        let txt = try write("IMG_4821.txt", "Quarterly Budget Review for Acme Corp")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(namer: StubSuggester(name: "Quarterly Budget Review"), fileService: fileService)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertFalse(FileManager.default.fileExists(atPath: txt.path))
        let dest = watched.appendingPathComponent("Quarterly Budget Review.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let count = await agent.renamed
        XCTAssertEqual(count, 1)
        let history = try await fileService.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.kind, .rename)
    }

    func testNoSignalLeavesFileUntouched() async throws {
        let txt = try write("IMG_4821.txt", "x")
        let fileService = FileService(store: InMemoryJournalStore())
        // Suggester returns the original base name unchanged ("no real signal").
        let agent = makeAgent(namer: StubSuggester(name: "IMG_4821"), fileService: fileService)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testEmptySuggestionLeavesFileUntouched() async throws {
        let txt = try write("IMG_4821.txt", "x")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(namer: StubSuggester(name: ""), fileService: fileService)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testCollisionAppendsSuffix() async throws {
        let txt = try write("IMG_4821.txt", "Meeting Notes")
        _ = try write("Meeting Notes.txt", "already exists")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(namer: StubSuggester(name: "Meeting Notes"), fileService: fileService)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        let dest = watched.appendingPathComponent("Meeting Notes 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRenameRepublishesFileCreatedForDownstreamAgents() async throws {
        let txt = try write("IMG_4821.txt", "Quarterly Budget Review for Acme Corp")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(namer: StubSuggester(name: "Quarterly Budget Review"), fileService: fileService)
        let bus = MessageBus()
        await agent.attach(to: bus)
        await agent.start()

        let collector = EventCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .fileCreated(let url) = event { await collector.add(url) }
            }
        }
        await agent.handle(.fileCreated(txt))
        try await Task.sleep(nanoseconds: 100_000_000)
        sub.cancel()

        let seen = await collector.value
        let dest = watched.appendingPathComponent("Quarterly Budget Review.txt")
        XCTAssertTrue(seen.contains(dest))
    }

    // MARK: Autonomy matrix

    func testPreviewModeMovesNothing() async throws {
        let txt = try write("IMG_4821.txt", "Quarterly Budget Review for Acme Corp")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(
            namer: StubSuggester(name: "Quarterly Budget Review"), fileService: fileService, autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testApprovalModeWaitsThenRenamesOnApprove() async throws {
        let txt = try write("IMG_4821.txt", "Quarterly Budget Review for Acme Corp")
        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = makeAgent(
            namer: StubSuggester(name: "Quarterly Budget Review"),
            fileService: fileService, approvals: approvals, autonomy: .approval)
        await agent.attach(to: bus)
        await agent.start()

        let collector = RequestCollector()
        let sub = Task {
            for await event in await bus.subscribe() {
                if case .approvalRequested(let req) = event { await collector.set(req) }
            }
        }
        let handling = Task { await agent.handle(.fileCreated(txt)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        sub.cancel()

        let captured = await collector.value
        let request = try XCTUnwrap(captured)
        XCTAssertFalse(request.isDestructive)
        XCTAssertTrue(request.summary.contains("Quarterly Budget Review"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))

        await approvals.approve(request.id)
        await handling.value
        let dest = watched.appendingPathComponent("Quarterly Budget Review.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: Cross-agent race safety

    func testRaceWithCategorizationAgentIsSafe() async throws {
        let txt = try write("IMG_4821.txt", "Quarterly Budget Review for Acme Corp")
        let fileService = FileService(store: InMemoryJournalStore())

        let renamer = makeAgent(namer: StubSuggester(name: "Quarterly Budget Review"), fileService: fileService)
        let categorizer = CategorizationAgent(
            watchedRoots: [watched],
            organizedRoot: organized,
            fileService: fileService,
            provider: HeuristicProvider(),
            extractor: extractor(),
            extensionFallback: true,
            autonomy: .autopilot)

        await renamer.attach(to: MessageBus())
        await renamer.start()
        await categorizer.attach(to: MessageBus())
        await categorizer.start()

        async let renameHandled: Void = renamer.handle(.fileCreated(txt))
        async let categorizeHandled: Void = categorizer.handle(.fileCreated(txt))
        _ = await (renameHandled, categorizeHandled)

        let originalStillThere = FileManager.default.fileExists(atPath: txt.path)
        let renamedInPlace = FileManager.default.fileExists(
            atPath: watched.appendingPathComponent("Quarterly Budget Review.txt").path)
        let categorizedAway = FileManager.default.fileExists(
            atPath: organized.appendingPathComponent("Documents/IMG_4821.txt").path)

        // Exactly one outcome happened; the file was never lost or duplicated.
        let outcomes = [originalStillThere, renamedInPlace, categorizedAway].filter { $0 }
        XCTAssertEqual(outcomes.count, 1)
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }

    private actor EventCollector {
        private(set) var value: [URL] = []
        func add(_ url: URL) { value.append(url) }
    }
}
