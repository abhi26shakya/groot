import XCTest
@testable import GrootKit

final class ApprovalServiceTests: XCTestCase {

    /// `static` so it isn't captured (sending `self`) by the `Task`s below —
    /// the Swift 6 gotcha already documented in CLAUDE.md.
    private static func makeRequest(destructive: Bool = false) -> ApprovalRequest {
        ApprovalRequest(
            agentID: "test",
            summary: destructive ? "Delete 3 duplicates" : "Move report.pdf to Documents",
            detail: nil,
            itemCount: destructive ? 3 : 1,
            bytesAffected: 1024,
            isDestructive: destructive)
    }

    // MARK: Policy routing (no waiting involved)

    func testPreviewModeReturnsPreviewOnlyWithoutPublishing() async throws {
        let bus = MessageBus()
        let service = ApprovalService(bus: bus)
        let events = await bus.subscribe()

        let outcome = await service.evaluate(Self.makeRequest(), autonomy: .preview)
        XCTAssertEqual(outcome, .previewOnly)
        let count = await service.pendingCount
        XCTAssertEqual(count, 0)

        // Nothing should have been published; prove it by publishing a sentinel
        // and asserting it arrives first.
        await bus.publish(.tick(Date()))
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .tick = first else {
            return XCTFail("expected no approvalRequested before the sentinel tick")
        }
    }

    func testAutopilotProceedsOnReversibleWorkWithoutAsking() async {
        let service = ApprovalService(bus: MessageBus())
        let outcome = await service.evaluate(Self.makeRequest(), autonomy: .autopilot)
        XCTAssertEqual(outcome, .proceed)
        let count = await service.pendingCount
        XCTAssertEqual(count, 0)
    }

    /// The invariant, exercised through the service rather than the pure policy.
    func testAutopilotStillAsksForDestructiveWork() async throws {
        let bus = MessageBus()
        let service = ApprovalService(bus: bus)
        let events = await bus.subscribe()

        let destructive = Self.makeRequest(destructive: true)
        let waiting = Task { await service.evaluate(destructive, autonomy: .autopilot) }

        var raised: ApprovalRequest?
        for await event in events {
            if case .approvalRequested(let request) = event { raised = request; break }
        }
        let request = try XCTUnwrap(raised, "destructive work in autopilot must raise an approval")

        await service.approve(request.id)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .proceed)
    }

    // MARK: Waiting and resolution

    func testApproveResumesWithProceed() async throws {
        let bus = MessageBus()
        let service = ApprovalService(bus: bus)
        let request = Self.makeRequest()

        let waiting = Task { await service.evaluate(request, autonomy: .approval) }
        try await waitUntilPending(service)

        await service.approve(request.id)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .proceed)
        let remaining = await service.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    func testRejectResumesWithDeclined() async throws {
        let service = ApprovalService(bus: MessageBus())
        let request = Self.makeRequest()

        let waiting = Task { await service.evaluate(request, autonomy: .approval) }
        try await waitUntilPending(service)

        await service.reject(request.id)
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .declined)
    }

    func testTimeoutDeclinesAutomatically() async throws {
        let service = ApprovalService(bus: MessageBus(), timeout: 0.15)
        let outcome = await service.evaluate(Self.makeRequest(), autonomy: .approval)
        XCTAssertEqual(outcome, .declined)
        let remaining = await service.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    /// A second resolve must be a harmless no-op. If the continuation were
    /// resumed twice the process would trap, so reaching the assertion at all is
    /// most of the point.
    func testDoubleResolveIsANoOpAndDoesNotTrap() async throws {
        let service = ApprovalService(bus: MessageBus())
        let request = Self.makeRequest()

        let waiting = Task { await service.evaluate(request, autonomy: .approval) }
        try await waitUntilPending(service)

        await service.approve(request.id)
        await service.approve(request.id)   // duplicate click
        await service.reject(request.id)    // contradictory late answer

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .proceed, "the first answer wins")
    }

    func testResolvingAnUnknownIdIsHarmless() async {
        let service = ApprovalService(bus: MessageBus())
        await service.approve(UUID())
        let count = await service.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testDeclineAllResumesEveryWaiter() async throws {
        let service = ApprovalService(bus: MessageBus())
        let first = Self.makeRequest()
        let second = Self.makeRequest(destructive: true)

        let waitingFirst = Task { await service.evaluate(first, autonomy: .approval) }
        let waitingSecond = Task { await service.evaluate(second, autonomy: .approval) }
        try await waitUntilPending(service, count: 2)

        await service.declineAll()

        let outcomes = [await waitingFirst.value, await waitingSecond.value]
        XCTAssertEqual(outcomes, [.declined, .declined])
        let remaining = await service.pendingCount
        XCTAssertEqual(remaining, 0, "no continuation may be left suspended")
    }

    func testCancellingTheWaiterLeavesNoPendingEntry() async throws {
        let service = ApprovalService(bus: MessageBus())
        let request = Self.makeRequest()
        let waiting = Task { await service.evaluate(request, autonomy: .approval) }
        try await waitUntilPending(service)

        waiting.cancel()
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .declined)

        try await waitUntilPending(service, count: 0)
        let remaining = await service.pendingCount
        XCTAssertEqual(remaining, 0, "a cancelled waiter must not leak a pending entry")
    }

    // MARK: Persistence

    func testPendingApprovalsFromAPreviousRunAreExpired() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-approval-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: dbURL.deletingLastPathComponent()
                        .appendingPathComponent(dbURL.lastPathComponent + suffix))
            }
        }

        let db = try GrootDatabase(url: dbURL)
        try await db.execute("""
        INSERT INTO pending_approvals
            (id, agent_id, summary, detail, item_count, bytes_affected, is_destructive, created_at)
        VALUES (?, 'dedup', 'leftover', NULL, 1, 0, 1, 0.0);
        """, [.text(UUID().uuidString)])

        let service = ApprovalService(bus: MessageBus(), database: db)
        let expired = await service.expireRestoredRequests()
        XCTAssertEqual(expired, 1)

        let rows = try await db.query("SELECT COUNT(*) FROM pending_approvals;")
        XCTAssertEqual(rows.first?.int(0), 0)
    }

    // MARK: Helper

    /// Poll until the service reports the expected number of waiting requests.
    /// Avoids racing the `Task` that calls `evaluate`.
    private func waitUntilPending(
        _ service: ApprovalService,
        count: Int = 1,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await service.pendingCount == count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(count) pending approval(s)")
    }
}
