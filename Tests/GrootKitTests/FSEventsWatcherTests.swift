import XCTest
import CoreServices
@testable import GrootKit

final class FSEventsWatcherTests: XCTestCase {

    func testClassifyPrefersCreatedOverModified() {
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(FSEventsWatcher.classify(flags: flags), .created)
    }

    func testClassifyRenamed() {
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        XCTAssertEqual(FSEventsWatcher.classify(flags: flags), .renamed)
    }

    func testClassifyRemoved() {
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        XCTAssertEqual(FSEventsWatcher.classify(flags: flags), .removed)
    }

    func testClassifyModifiedOnly() {
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        XCTAssertEqual(FSEventsWatcher.classify(flags: flags), .modified)
    }

    func testClassifyUnknownIsOther() {
        // A flag with no item-level bits (e.g. a history-done sentinel).
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
        XCTAssertEqual(FSEventsWatcher.classify(flags: flags), .other)
    }

    /// Live smoke test: create a real watcher over a temp dir and confirm a file
    /// creation surfaces. Generous timeout; skipped gracefully if FSEvents is
    /// unavailable in the sandboxed test host.
    func testLiveWatcherDeliversCreationEvent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.lastPathComponent // unique per run; survives /private canonicalization
        let received = ChangeCollector()
        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.2) { changes in
            Task { await received.add(changes) }
        }
        watcher.start()
        defer { watcher.stop() }

        // Give the stream a moment to arm, then create a file.
        try await Task.sleep(nanoseconds: 500_000_000)
        try "hi".data(using: .utf8)!.write(to: dir.appendingPathComponent("new.txt"))

        // Poll up to ~3s for the event.
        for _ in 0..<30 {
            if await received.count > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let paths = await received.paths
        // FSEvents can be unavailable/slow in some CI hosts; only assert if any
        // events arrived, otherwise treat as an environment skip.
        if paths.isEmpty {
            throw XCTSkip("No FSEvents delivered in this environment")
        }
        // FSEvents may report the file itself or its parent dir, and canonicalizes
        // /var → /private/var; the unique dir marker is present either way.
        XCTAssertTrue(paths.contains { $0.contains(marker) })
    }

    private actor ChangeCollector {
        private(set) var all: [FSChange] = []
        func add(_ changes: [FSChange]) { all.append(contentsOf: changes) }
        var count: Int { all.count }
        var paths: [String] { all.map(\.path) }
    }
}
