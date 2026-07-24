import XCTest
@testable import GrootKit

final class SettingsStoreTests: XCTestCase {

    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-settings-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: dbURL.deletingLastPathComponent()
                    .appendingPathComponent(dbURL.lastPathComponent + suffix))
        }
    }

    /// The behaviour the app was missing: settings must outlive the process.
    func testAutonomyAndRootsSurviveAReopen() async throws {
        let roots = [URL(fileURLWithPath: "/Users/x/Desktop"),
                     URL(fileURLWithPath: "/Users/x/Projects")]
        do {
            let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
            await settings.setAutonomy(.autopilot, for: "screenshot")
            await settings.setWatchedRoots(roots)
            await settings.setCloudConsent(true)
        }

        let reopened = SettingsStore(database: try GrootDatabase(url: dbURL))
        let mode = await reopened.autonomy(for: "screenshot")
        XCTAssertEqual(mode, .autopilot)
        let savedRoots = await reopened.watchedRoots()
        XCTAssertEqual(savedRoots.map(\.path), roots.map(\.path))
        let consent = await reopened.cloudConsent()
        XCTAssertTrue(consent)
    }

    /// A fresh install must behave exactly like the old hardcoded defaults.
    func testDefaultsMatchPreviousHardcodedBehaviour() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))

        let mode = await settings.autonomy(for: "never-configured")
        XCTAssertEqual(mode, .approval)

        let roots = await settings.watchedRoots()
        XCTAssertEqual(roots.map(\.lastPathComponent), ["Desktop", "Downloads"])

        let enabled = await settings.isEnabled("never-configured")
        XCTAssertTrue(enabled)

        let bubbles = await settings.showBubbles()
        XCTAssertTrue(bubbles)
    }

    /// Local-first is the product promise: cloud use must never be assumed.
    func testCloudConsentDefaultsToFalse() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
        let consent = await settings.cloudConsent()
        XCTAssertFalse(consent)
        let ollama = await settings.ollamaEnabled()
        XCTAssertFalse(ollama, "the local LLM is optional too")
    }

    func testUpdatingAutonomyOverwritesRatherThanDuplicating() async throws {
        let db = try GrootDatabase(url: dbURL)
        let settings = SettingsStore(database: db)
        await settings.setAutonomy(.preview, for: "downloads-organizer")
        await settings.setAutonomy(.autopilot, for: "downloads-organizer")

        let mode = await settings.autonomy(for: "downloads-organizer")
        XCTAssertEqual(mode, .autopilot)
        let rows = try await db.query(
            "SELECT COUNT(*) FROM agent_state WHERE agent_id = 'downloads-organizer';")
        XCTAssertEqual(rows.first?.int(0), 1)
    }

    /// Enabling/disabling must not clobber a previously saved autonomy mode.
    func testTogglingEnabledPreservesAutonomy() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
        await settings.setAutonomy(.autopilot, for: "desktop-cleaner")
        await settings.setEnabled(false, for: "desktop-cleaner")

        let mode = await settings.autonomy(for: "desktop-cleaner")
        XCTAssertEqual(mode, .autopilot)
        let enabled = await settings.isEnabled("desktop-cleaner")
        XCTAssertFalse(enabled)
    }

    func testEmptyRootsFallsBackToDefaults() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
        await settings.setWatchedRoots([])
        let roots = await settings.watchedRoots()
        XCTAssertEqual(roots.map(\.lastPathComponent), ["Desktop", "Downloads"])
    }

    // MARK: Categorization settings

    func testCategorizationDefaults() async throws {
        let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
        let categories = await settings.customCategories()
        XCTAssertTrue(categories.isEmpty)
        let threshold = await settings.categorizationThreshold()
        XCTAssertEqual(threshold, 0.6, accuracy: 0.0001)
        let fallback = await settings.categorizationExtensionFallback()
        XCTAssertTrue(fallback)
    }

    func testCustomCategoriesAndThresholdSurviveAReopen() async throws {
        let categories = [CustomCategory(name: "Invoices"), CustomCategory(name: "Taxes")]
        do {
            let settings = SettingsStore(database: try GrootDatabase(url: dbURL))
            await settings.setCustomCategories(categories)
            await settings.setCategorizationThreshold(0.8)
            await settings.setCategorizationExtensionFallback(false)
        }

        let reopened = SettingsStore(database: try GrootDatabase(url: dbURL))
        let saved = await reopened.customCategories()
        XCTAssertEqual(saved.map(\.name), ["Invoices", "Taxes"])
        XCTAssertEqual(saved.map(\.id), categories.map(\.id))
        let threshold = await reopened.categorizationThreshold()
        XCTAssertEqual(threshold, 0.8, accuracy: 0.0001)
        let fallback = await reopened.categorizationExtensionFallback()
        XCTAssertFalse(fallback)
    }
}
