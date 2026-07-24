import XCTest
@testable import GrootKit

final class CategorizationAgentTests: XCTestCase {

    private var watched: URL!
    private var organized: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-cat-\(UUID().uuidString)", isDirectory: true)
        watched = base.appendingPathComponent("Downloads", isDirectory: true)
        organized = base.appendingPathComponent("Organized", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        let base = watched.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    // A provider that replays canned responses (mirrors AIProviderTests).
    private struct ScriptedProvider: AIProvider {
        let reply: String
        var capabilities: Set<AICapability> { [.text] }
        var isLocal: Bool { true }
        func complete(_ request: AIRequest) async throws -> String { reply }
    }

    private struct StubRecognizer: TextRecognizing {
        func recognizeText(in url: URL) async throws -> String { "" }
    }

    private func extractor() -> ContentExtractor {
        ContentExtractor(recognizer: StubRecognizer())
    }

    private func write(_ name: String, _ contents: String = "some content") throws -> URL {
        let url = watched.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func makeAgent(
        provider: any AIProvider,
        fileService: FileService,
        approvals: ApprovalService? = nil,
        extensionFallback: Bool = true,
        autonomy: AutonomyMode = .autopilot
    ) -> CategorizationAgent {
        CategorizationAgent(
            watchedRoots: [watched],
            organizedRoot: organized,
            fileService: fileService,
            provider: provider,
            extractor: extractor(),
            extensionFallback: extensionFallback,
            approvals: approvals,
            autonomy: autonomy)
    }

    // MARK: Confident decision → move

    func testConfidentDecisionMovesToCategoryFolder() async throws {
        let txt = try write("invoice.txt", "Total due $420 — Acme Corp invoice")

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(
            provider: ScriptedProvider(reply: #"{"category":"Finance","confidence":0.92}"#),
            fileService: fileService)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertFalse(FileManager.default.fileExists(atPath: txt.path))
        let dest = organized.appendingPathComponent("Finance/invoice.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let count = await agent.categorized
        XCTAssertEqual(count, 1)
        let history = try await fileService.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.kind, .move)
    }

    // MARK: nil decision (heuristic provider returns "") → fallback / skip

    func testUndecidedWithFallbackMovesByExtension() async throws {
        let txt = try write("mystery.txt", "x")   // too little signal
        let fileService = FileService(store: InMemoryJournalStore())
        // HeuristicProvider returns "" → CategorizerUseCase → nil.
        let agent = makeAgent(
            provider: HeuristicProvider(), fileService: fileService, extensionFallback: true)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        // Filed under the extension bucket ("Documents").
        let dest = organized.appendingPathComponent("Documents/mystery.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let count = await agent.categorized
        XCTAssertEqual(count, 1)
    }

    func testUndecidedWithoutFallbackDoesNothing() async throws {
        let txt = try write("mystery.txt", "x")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(
            provider: HeuristicProvider(), fileService: fileService, extensionFallback: false)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    // MARK: Skip rules

    func testSkipRules() async {
        let agent = makeAgent(provider: HeuristicProvider(),
                              fileService: FileService(store: InMemoryJournalStore()))
        // Dotfile.
        XCTAssertFalse(agent.shouldCategorize(watched.appendingPathComponent(".hidden.txt")))
        // Partial download.
        XCTAssertFalse(agent.shouldCategorize(watched.appendingPathComponent("big.crdownload")))
        // Unclaimed bucket (installer) is left to the Downloads Organizer.
        XCTAssertFalse(agent.shouldCategorize(watched.appendingPathComponent("Xcode.dmg")))
        // Not directly inside a watched root.
        XCTAssertFalse(agent.shouldCategorize(
            watched.appendingPathComponent("sub/deep.txt")))
        // Under the organized root (own output).
        XCTAssertFalse(agent.shouldCategorize(
            organized.appendingPathComponent("Finance/x.txt")))
    }

    func testClaimedDocumentIsAccepted() async throws {
        // A real document directly in the watched root passes the guard.
        let txt = try write("claim.txt")
        let agent = makeAgent(provider: HeuristicProvider(),
                              fileService: FileService(store: InMemoryJournalStore()))
        XCTAssertTrue(agent.shouldCategorize(txt))
    }

    // MARK: Autonomy matrix

    func testPreviewModeMovesNothing() async throws {
        let txt = try write("preview.txt", "Contract terms and legal clauses herein")
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = makeAgent(
            provider: ScriptedProvider(reply: #"{"category":"Legal","confidence":0.9}"#),
            fileService: fileService, autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()
        await agent.handle(.fileCreated(txt))

        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testApprovalModeWaitsThenMovesOnApprove() async throws {
        let txt = try write("approve.txt", "Resume and cover letter for the role")
        let fileService = FileService(store: InMemoryJournalStore())
        let bus = MessageBus()
        let approvals = ApprovalService(bus: bus)
        let agent = makeAgent(
            provider: ScriptedProvider(reply: #"{"category":"Career","confidence":0.88}"#),
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
        XCTAssertFalse(request.isDestructive)   // a move is reversible
        XCTAssertTrue(request.summary.contains("Career"))
        // Not moved until approved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))

        await approvals.approve(request.id)
        await handling.value
        let dest = organized.appendingPathComponent("Career/approve.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    private actor RequestCollector {
        private(set) var value: ApprovalRequest?
        func set(_ r: ApprovalRequest) { if value == nil { value = r } }
    }
}
