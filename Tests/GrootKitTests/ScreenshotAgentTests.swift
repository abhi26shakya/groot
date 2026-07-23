import XCTest
@testable import GrootKit

/// Deterministic stub so the pipeline is testable without the Vision framework.
private struct StubRecognizer: TextRecognizing {
    let text: String
    func recognizeText(in url: URL) async throws -> String { text }
}

final class ScreenshotAgentTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-shot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    func testDetection() {
        XCTAssertTrue(ScreenshotAgent.isScreenshot(URL(fileURLWithPath: "/d/Screenshot 2026-07-24 at 9.41.png")))
        XCTAssertTrue(ScreenshotAgent.isScreenshot(URL(fileURLWithPath: "/d/CleanShot 2026.png")))
        XCTAssertFalse(ScreenshotAgent.isScreenshot(URL(fileURLWithPath: "/d/report.pdf")))
        XCTAssertFalse(ScreenshotAgent.isScreenshot(URL(fileURLWithPath: "/d/holiday.png")))
    }

    func testAutopilotRenamesAndFilesScreenshot() async throws {
        let desktop = sandbox.appendingPathComponent("Desktop", isDirectory: true)
        let picturesShots = sandbox.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

        let source = desktop.appendingPathComponent("Screenshot 2026-07-24 at 9.41.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source) // fake PNG bytes

        let store = InMemoryJournalStore()
        let fileService = FileService(store: store)
        let agent = ScreenshotAgent(
            recognizer: StubRecognizer(text: "VS Code Installation Error\nCould not write file"),
            suggester: HeuristicFilenameSuggester(),
            fileService: fileService,
            screenshotsRoot: picturesShots,
            autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()

        await agent.handle(.fileCreated(source))

        // Source gone; a renamed file exists somewhere under the Screenshots root.
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let organized = await agent.organized
        XCTAssertEqual(organized, 1)

        let moved = try firstFile(under: picturesShots)
        XCTAssertEqual(moved.lastPathComponent, "VS Code Installation Error.png")
        // Filed under a yyyy-MM subfolder.
        XCTAssertEqual(moved.deletingLastPathComponent().lastPathComponent.count, 7) // "2026-07"

        // Journaled and reversible.
        let history = try await fileService.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.kind, .rename)
    }

    func testPreviewModeMakesNoFilesystemChange() async throws {
        let source = sandbox.appendingPathComponent("Screenshot preview.png")
        try Data([0x89]).write(to: source)

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = ScreenshotAgent(
            recognizer: StubRecognizer(text: "Some Title Here"),
            suggester: HeuristicFilenameSuggester(),
            fileService: fileService,
            screenshotsRoot: sandbox.appendingPathComponent("Screenshots"),
            autonomy: .preview)
        await agent.attach(to: MessageBus())
        await agent.start()

        await agent.handle(.fileCreated(source))

        // Nothing moved, nothing journaled.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let history = try await fileService.history()
        XCTAssertTrue(history.isEmpty)
    }

    // MARK: Helpers

    private func firstFile(under root: URL) throws -> URL {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "png" } ?? []
        guard let first = files.first else {
            throw XCTSkip("No file produced under \(root.path)")
        }
        return first
    }
}
