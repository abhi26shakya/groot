import XCTest
@testable import GrootKit

/// Counts ticks and declares whether it wants them.
private actor TickCounter: Agent {
    nonisolated let descriptor: AgentDescriptor
    nonisolated let cadence: TickCadence
    var state: AgentState = .running
    var autonomy: AutonomyMode = .preview
    private(set) var ticks = 0

    init(id: AgentID, cadence: TickCadence) {
        self.descriptor = AgentDescriptor(id: id, name: id.raw, colorHex: "#000000", symbol: "clock")
        self.cadence = cadence
    }

    nonisolated var tickCadence: TickCadence { cadence }

    func attach(to bus: MessageBus) async {}
    func start() async {}
    func pause() async {}
    func resume() async {}
    func stop() async {}

    func handle(_ event: BusEvent) async {
        if case .tick = event { ticks += 1 }
    }

    var count: Int { ticks }
}

final class SchedulerTests: XCTestCase {

    func testSchedulerPublishesTicksOnItsOwn() async throws {
        let bus = MessageBus()
        let scheduler = Scheduler(bus: bus, interval: 0.1)
        let events = await bus.subscribe()
        await scheduler.start()

        var seen = 0
        for await event in events {
            if case .tick = event { seen += 1 }
            if seen >= 2 { break }
        }
        await scheduler.stop()
        XCTAssertGreaterThanOrEqual(seen, 2)
    }

    func testStartIsIdempotent() async {
        let scheduler = Scheduler(bus: MessageBus(), interval: 0.1)
        await scheduler.start()
        await scheduler.start()
        let running = await scheduler.isRunning
        XCTAssertTrue(running)
        await scheduler.stop()
        let stopped = await scheduler.isRunning
        XCTAssertFalse(stopped)
    }

    /// The point of cadences: an agent that does no time-based work should not
    /// be woken every second just because the clock is running.
    func testTicksOnlyReachAgentsThatAskedForThem() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let subscriber = TickCounter(id: "wants-ticks", cadence: .every(1))
        let bystander = TickCounter(id: "event-driven", cadence: .none)

        await manager.register(subscriber)
        await manager.register(bystander)
        await manager.startEventPump()

        for _ in 0..<3 { await bus.publish(.tick(Date())) }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if await subscriber.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let subscribed = await subscriber.count
        let ignored = await bystander.count
        XCTAssertEqual(subscribed, 3)
        XCTAssertEqual(ignored, 0, "an event-driven agent must not be woken by the clock")

        await manager.stopEventPump()
    }

    /// Non-tick events still reach every agent regardless of cadence.
    func testNonTickEventsStillReachEveryAgent() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let bystander = TickCounter(id: "event-driven", cadence: .none)
        await manager.register(bystander)
        await manager.startEventPump()

        // A non-tick event must be delivered — it just isn't counted as a tick.
        await bus.publish(.fileCreated(URL(fileURLWithPath: "/tmp/x")))
        await bus.publish(.tick(Date()))
        try await Task.sleep(nanoseconds: 150_000_000)

        let ticks = await bystander.count
        XCTAssertEqual(ticks, 0)
        await manager.stopEventPump()
    }

    func testManagerOwnedClockDrivesSubscribers() async throws {
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let subscriber = TickCounter(id: "wants-ticks", cadence: .every(0.1))
        await manager.register(subscriber)
        await manager.startEventPump()
        await manager.startClock(interval: 0.1)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await subscriber.count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let count = await subscriber.count
        XCTAssertGreaterThanOrEqual(count, 2, "the runtime should drive its own clock")

        await manager.stopClock()
        await manager.stopEventPump()
    }
}
