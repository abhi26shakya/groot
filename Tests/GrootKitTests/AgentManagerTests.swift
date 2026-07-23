import XCTest
@testable import GrootKit

final class AgentManagerTests: XCTestCase {

    func testRegisterAndSnapshot() async throws {
        let manager = AgentManager()
        let agent = HeartbeatAgent()
        await manager.register(agent)

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.agents.first?.report.state, .idle)
        XCTAssertEqual(snapshot.runningCount, 0)
    }

    func testLifecycleTransitions() async throws {
        let manager = AgentManager()
        let agent = HeartbeatAgent()
        await manager.register(agent)

        await manager.startAll()
        var state = await agent.state
        XCTAssertEqual(state, .running)

        await manager.pauseAll()
        state = await agent.state
        XCTAssertEqual(state, .paused)

        await manager.resumeAll()
        state = await agent.state
        XCTAssertEqual(state, .running)

        await manager.stopAll()
        state = await agent.state
        XCTAssertEqual(state, .stopped)
    }

    func testEventPumpDeliversTicksAndAggregatesReports() async throws {
        let manager = AgentManager()
        let agent = HeartbeatAgent()
        await manager.register(agent)
        await manager.startAll()
        await manager.startEventPump()

        // Let the pump's subscription come up before publishing.
        try await Task.sleep(nanoseconds: 100_000_000)

        let bus = manager.bus
        await bus.publish(.tick(Date()))

        // Allow the tick to be handled and the resulting report to be aggregated.
        try await Task.sleep(nanoseconds: 150_000_000)

        let beats = await agent.beatCount
        XCTAssertGreaterThanOrEqual(beats, 1)

        let snapshot = await manager.snapshot()
        let summary = snapshot.agents.first
        XCTAssertEqual(summary?.report.state, .running)
        XCTAssertNotNil(summary?.report.currentTask)

        await manager.stopEventPump()
    }

    func testSetStateIntentRoutedThroughBus() async throws {
        let manager = AgentManager()
        let agent = HeartbeatAgent()
        await manager.register(agent)
        await manager.startEventPump()
        try await Task.sleep(nanoseconds: 100_000_000)

        await manager.bus.publish(.command(.setState(agent.id, .start)))
        try await Task.sleep(nanoseconds: 150_000_000)
        var state = await agent.state
        XCTAssertEqual(state, .running)

        await manager.bus.publish(.command(.pauseAll))
        try await Task.sleep(nanoseconds: 150_000_000)
        state = await agent.state
        XCTAssertEqual(state, .paused)

        await manager.stopEventPump()
    }
}
