import XCTest
@testable import GrootKit

final class MessageBusTests: XCTestCase {

    func testFanOutToMultipleSubscribers() async throws {
        let bus = MessageBus()
        let a = await bus.subscribe()
        let b = await bus.subscribe()

        let count = await bus.subscriberCount
        XCTAssertEqual(count, 2)

        // Collect first event from each subscriber concurrently, then publish.
        async let firstA = Self.firstEvent(from: a)
        async let firstB = Self.firstEvent(from: b)
        // Give the child tasks a moment to begin iterating before publishing.
        try await Task.sleep(nanoseconds: 50_000_000)
        await bus.publish(.tick(Date()))

        let (ra, rb) = await (firstA, firstB)
        XCTAssertTrue(Self.isTick(ra))
        XCTAssertTrue(Self.isTick(rb))
    }

    func testUnsubscribeOnTermination() async throws {
        let bus = MessageBus()
        do {
            let stream = await bus.subscribe()
            // Iterate once so the stream is live, then drop it.
            _ = stream
            let c1 = await bus.subscriberCount
            XCTAssertEqual(c1, 1)
        }
        // Termination is async; poll briefly.
        try await Task.sleep(nanoseconds: 100_000_000)
        let c2 = await bus.subscriberCount
        XCTAssertEqual(c2, 0)
    }

    // MARK: Helpers

    private static func firstEvent(from stream: AsyncStream<BusEvent>) async -> BusEvent? {
        for await event in stream { return event }
        return nil
    }

    private static func isTick(_ event: BusEvent?) -> Bool {
        if case .tick = event { return true }
        return false
    }
}
