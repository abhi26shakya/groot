import XCTest
@testable import GrootKit

final class OrganizerAgentsTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    // MARK: FileCategory

    func testCategoryMapping() {
        XCTAssertEqual(FileCategory.forExtension("ZIP"), .archives)
        XCTAssertEqual(FileCategory.forExtension(".dmg"), .installers)
        XCTAssertEqual(FileCategory.forExtension("pdf"), .documents)
        XCTAssertEqual(FileCategory.forExtension("heic"), .pictures)
        XCTAssertEqual(FileCategory.forExtension("mov"), .media)
        XCTAssertEqual(FileCategory.forExtension("swift"), .code)
        XCTAssertEqual(FileCategory.forExtension("xyz"), .other)
    }

    // MARK: Downloads Organizer

    func testDownloadsOrganizerFilesByCategoryInAutopilot() async throws {
        let downloads = sandbox! // treat sandbox as the Downloads root
        let dmg = downloads.appendingPathComponent("Xcode.dmg")
        try Data([0x1]).write(to: dmg)

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = DownloadsOrganizerAgent(root: downloads, fileService: fileService, autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()

        await agent.handle(.fileCreated(dmg))

        let moved = downloads.appendingPathComponent("Installers/Xcode.dmg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg.path))
        let count = await agent.organized
        XCTAssertEqual(count, 1)
    }

    func testDownloadsOrganizerIgnoresAlreadySortedAndPartialFiles() async {
        let downloads = sandbox!
        let fileService = FileService(store: InMemoryJournalStore())
        let agent = DownloadsOrganizerAgent(root: downloads, fileService: fileService, autonomy: .autopilot)

        // File already inside a category subfolder → ignored (prevents re-sorting).
        let sorted = downloads.appendingPathComponent("Installers/App.dmg")
        XCTAssertFalse(agent.shouldOrganize(sorted))
        // Partial download → ignored.
        let partial = downloads.appendingPathComponent("big.zip.crdownload")
        XCTAssertFalse(agent.shouldOrganize(partial))
        // A regular top-level file → organized.
        let ok = downloads.appendingPathComponent("photo.png")
        XCTAssertTrue(agent.shouldOrganize(ok))
    }

    // MARK: Desktop Cleaner

    func testDesktopCleanerArchivesStaleFilesOnly() async throws {
        let desktop = sandbox!
        let old = desktop.appendingPathComponent("old-notes.txt")
        let fresh = desktop.appendingPathComponent("today.txt")
        try Data([0x1]).write(to: old)
        try Data([0x1]).write(to: fresh)
        // Backdate `old` by 30 days.
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: thirtyDaysAgo], ofItemAtPath: old.path)

        let fileService = FileService(store: InMemoryJournalStore())
        let agent = DesktopCleanerAgent(root: desktop, fileService: fileService,
                                        archiveAfterDays: 14, autonomy: .autopilot)
        await agent.attach(to: MessageBus())
        await agent.start()

        // staleFiles should pick only the old one.
        let stale = agent.staleFiles()
        XCTAssertEqual(stale.map(\.lastPathComponent), ["old-notes.txt"])

        await agent.handle(.command(.organizeDesktop))
        let archivedCount = await agent.archived
        XCTAssertEqual(archivedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path)) // fresh untouched
    }
}
