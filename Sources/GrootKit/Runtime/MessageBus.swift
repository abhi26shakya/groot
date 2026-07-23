import Foundation

/// A broadcast, in-process event bus. Every subscriber receives every published
/// event via its own `AsyncStream`, so agents and the UI can each consume the
/// stream at their own pace without blocking publishers.
///
/// This is intentionally simple (no persistence, no backpressure policy beyond
/// `.bufferingNewest`). It is the one place all cross-agent communication flows
/// through, which is what keeps individual agents decoupled.
public actor MessageBus {
    private var continuations: [UUID: AsyncStream<BusEvent>.Continuation] = [:]

    public init() {}

    /// Subscribe to the bus. The returned stream terminates when the caller
    /// stops iterating (its `onTermination` handler unregisters it).
    public func subscribe() -> AsyncStream<BusEvent> {
        let id = UUID()
        let stream = AsyncStream<BusEvent>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
        return stream
    }

    /// Publish an event to all current subscribers.
    public func publish(_ event: BusEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Number of live subscribers — used by tests and diagnostics.
    public var subscriberCount: Int { continuations.count }

    private func unsubscribe(_ id: UUID) {
        continuations[id] = nil
    }
}
