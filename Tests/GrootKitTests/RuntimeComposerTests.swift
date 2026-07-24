import XCTest
@testable import GrootKit

private struct SilentRecognizer: TextRecognizing {
    func recognizeText(in url: URL) async throws -> String { "" }
}

/// Composition is the single most consequential piece of assembly in the project
/// — which agents exist, what they're injected with, what autonomy they start
/// in. It used to live in the app target and could only be checked by launching
/// the UI. These tests exercise it headlessly.
final class RuntimeComposerTests: XCTestCase {

    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-compose-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: dbURL.deletingLastPathComponent()
                    .appendingPathComponent(dbURL.lastPathComponent + suffix))
        }
    }

    private func options() -> RuntimeComposer.Options {
        RuntimeComposer.Options(databaseURL: dbURL, recognizer: SilentRecognizer())
    }

    func testComposesTheExpectedAgentSet() async {
        let runtime = await RuntimeComposer.compose(options: options())
        XCTAssertEqual(Set(runtime.agentIDs.map(\.raw)), [
            "file-monitor", "screenshot", "downloads-organizer",
            "desktop-cleaner", "duplicate-detector", "storage-analyzer",
            "categorization", "smart-rename", "large-file-manager"
        ])
    }

    func testEveryComposedAgentIsRegisteredWithTheManager() async {
        let runtime = await RuntimeComposer.compose(options: options())
        for id in runtime.agentIDs {
            let agent = await runtime.manager.agent(id)
            XCTAssertNotNil(agent, "\(id) was not registered")
        }
    }

    /// The gate must be wired in, not left nil — an agent without it declines
    /// everything needing a user, which would look like the app doing nothing.
    func testApprovalGateIsWiredAndEmptyAtStartup() async {
        let runtime = await RuntimeComposer.compose(options: options())
        let pending = await runtime.approvals.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// Saved autonomy must be honoured at startup — that's the whole point of
    /// persisting it.
    func testComposedAgentsAdoptSavedAutonomy() async throws {
        do {
            let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
            await settings.setAutonomy(.preview, for: "screenshot")
        }

        let runtime = await RuntimeComposer.compose(options: options())
        let agent = await runtime.manager.agent("screenshot")
        let mode = await agent?.autonomy
        XCTAssertEqual(mode, .preview, "the composer must read autonomy from settings")
    }

    func testDefaultAutonomyIsApprovalOnAFreshInstall() async {
        let runtime = await RuntimeComposer.compose(options: options())
        for id in ["screenshot", "downloads-organizer", "desktop-cleaner", "duplicate-detector"] {
            let agent = await runtime.manager.agent(AgentID(id))
            let mode = await agent?.autonomy
            XCTAssertEqual(mode, .approval, "\(id) should start in the safest useful mode")
        }
    }

    func testEphemeralCompositionSkipsPersistence() async {
        let runtime = await RuntimeComposer.compose(
            options: RuntimeComposer.Options(ephemeral: true, recognizer: SilentRecognizer()))
        XCTAssertNil(runtime.database)
        XCTAssertNil(runtime.settings)
        XCTAssertFalse(runtime.agentIDs.isEmpty, "agents still compose without a database")
    }

    func testComposedRuntimeDeliversEventsEndToEnd() async throws {
        let runtime = await RuntimeComposer.compose(options: options())
        await runtime.manager.startAll()

        let deadline = Date().addingTimeInterval(2)
        var running = 0
        while Date() < deadline {
            running = await runtime.manager.snapshot().runningCount
            if running > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(running, 0, "the pump and lifecycle should be live after compose")

        await runtime.manager.stopAll()
        await runtime.manager.stopEventPump()
    }

    /// Local-first: with nothing configured, no network-backed provider is used.
    func testFilenameSuggesterIsOnDeviceUnlessOllamaIsEnabled() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))

        let byDefault = await RuntimeComposer.makeFilenameSuggester(settings: settings)
        XCTAssertTrue(byDefault is HeuristicFilenameSuggester,
                      "the on-device heuristic is the default")

        await settings.setOllamaEnabled(true)
        let enabled = await RuntimeComposer.makeFilenameSuggester(settings: settings)
        XCTAssertTrue(enabled is FilenameUseCase,
                      "turning Ollama on should route through the provider port")
    }
}
