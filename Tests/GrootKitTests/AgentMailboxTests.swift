import XCTest
@testable import GrootKit

/// An agent that takes a long time in `handle(_:)` — an OCR pass, a hash sweep,
/// or one suspended waiting on an approval.
private actor SlowAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    var state: AgentState = .running
    var autonomy: AutonomyMode = .preview
    private let delay: UInt64
    private(set) var received = 0

    nonisolated var tickCadence: TickCadence { .every(1) }

    init(id: AgentID = "slow", delaySeconds: Double = 0.4) {
        self.descriptor = AgentDescriptor(id: id, name: "Slow", colorHex: "#000000", symbol: "tortoise")
        self.delay = UInt64(delaySeconds * 1_000_000_000)
    }

    func attach(to bus: MessageBus) async {}
    func start() async { state = .running }
    func pause() async { state = .paused }
    func resume() async { state = .running }
    func stop() async { state = .stopped }

    func handle(_ event: BusEvent) async {
        guard case .tick = event else { return }
        try? await Task.sleep(nanoseconds: delay)
        received += 1
    }

    var count: Int { received }
}

/// An agent that returns from `handle(_:)` immediately.
private actor FastAgent: Agent {
    nonisolated let descriptor: AgentDescriptor
    var state: AgentState = .running
    var autonomy: AutonomyMode = .preview
    private(set) var received = 0

    nonisolated var tickCadence: TickCadence { .every(1) }

    init(id: AgentID = "fast") {
        self.descriptor = AgentDescriptor(id: id, name: "Fast", colorHex: "#FFFFFF", symbol: "hare")
    }

    func attach(to bus: MessageBus) async {}
    func start() async { state = .running }
    func pause() async { state = .paused }
    func resume() async { state = .running }
    func stop() async { state = .stopped }

    func handle(_ event: BusEvent) async {
        guard case .tick = event else { return }
        received += 1
    }

    var count: Int { received }
}

final class AgentMailboxTests: XCTestCase {

    /// **The regression proof for per-agent mailboxes.** Under the old serial
    /// `for agent in agents.values { await agent.handle(event) }` dispatch, the
    /// fast agent could not get past the slow agent and this test would time out.
    func testSlowAgentDoesNotStallDeliveryToOtherAgents() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let slow = SlowAgent(delaySeconds: 0.4)
        let fast = FastAgent()

        await manager.register(slow)
        await manager.register(fast)
        await manager.startEventPump()

        let eventCount = 5
        for _ in 0..<eventCount {
            await bus.publish(.tick(Date()))
        }

        // The fast agent should drain everything well before the slow agent
        // finishes even two events (2 × 0.4s).
        let deadline = Date().addingTimeInterval(1.0)
        var fastCount = 0
        while Date() < deadline {
            fastCount = await fast.count
            if fastCount == eventCount { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(fastCount, eventCount,
                       "the fast agent must not wait on the slow agent's inbox")

        let slowCount = await slow.count
        XCTAssertLessThan(slowCount, eventCount,
                          "precondition: the slow agent should still be working")

        await manager.stopEventPump()
    }

    /// A single consumer per inbox means an agent still sees its own events in
    /// publication order.
    func testPerAgentOrderingIsPreserved() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let recorder = OrderRecorder()
        await manager.register(recorder)
        await manager.startEventPump()

        for index in 0..<20 {
            await bus.publish(.fileCreated(URL(fileURLWithPath: "/tmp/\(index)")))
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await recorder.paths.count == 20 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let paths = await recorder.paths
        XCTAssertEqual(paths, (0..<20).map { "/tmp/\($0)" })
        await manager.stopEventPump()
    }

    /// Re-registering the same id must replace the delivery task, not leave the
    /// old one running and double-delivering.
    func testReregisteringSameIdDoesNotDoubleDeliver() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let agent = FastAgent(id: "fast")

        await manager.register(agent)
        await manager.register(agent)   // same id again
        await manager.startEventPump()

        await bus.publish(.tick(Date()))

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if await agent.count > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // let any duplicate arrive

        let count = await agent.count
        XCTAssertEqual(count, 1, "one event must be delivered exactly once")
        await manager.stopEventPump()
    }

    func testDeregisteredAgentStopsReceivingEvents() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let agent = FastAgent(id: "fast")
        await manager.register(agent)
        await manager.startEventPump()
        await manager.deregister("fast")

        await bus.publish(.tick(Date()))
        try await Task.sleep(nanoseconds: 150_000_000)

        let count = await agent.count
        XCTAssertEqual(count, 0)
        await manager.stopEventPump()
    }
}

/// Records the order events arrive in.
private actor OrderRecorder: Agent {
    nonisolated let descriptor = AgentDescriptor(
        id: "recorder", name: "Recorder", colorHex: "#123456", symbol: "list.number")
    var state: AgentState = .running
    var autonomy: AutonomyMode = .preview
    private(set) var seen: [String] = []

    func attach(to bus: MessageBus) async {}
    func start() async {}
    func pause() async {}
    func resume() async {}
    func stop() async {}

    func handle(_ event: BusEvent) async {
        if case .fileCreated(let url) = event { seen.append(url.path) }
    }

    var paths: [String] { seen }
}
