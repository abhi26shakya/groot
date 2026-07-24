import Foundation

/// How often an agent wants time-based wake-ups.
public enum TickCadence: Sendable, Equatable {
    /// The agent does no time-based work — don't wake it at all.
    case none
    /// Wake at most this often.
    case every(TimeInterval)

    var interval: TimeInterval? {
        if case .every(let seconds) = self { return max(seconds, 0.1) }
        return nil
    }
}

/// Owns the runtime clock.
///
/// The 1 Hz `.tick` used to be published by the UI (`AppModel`), which meant the
/// view model drove the runtime and every agent was woken every second whether
/// it wanted to be or not. The coordinator owns it now, and agents opt in via
/// `Agent.tickCadence`.
public actor Scheduler {
    private let bus: MessageBus
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    /// - Parameter interval: how often to publish `.tick`. The coarsest cadence
    ///   any agent asks for should divide this cleanly; 1 s stays the default so
    ///   existing throttles (e.g. `DesktopCleanerAgent.minInterval`) behave the same.
    public init(bus: MessageBus, interval: TimeInterval = 1.0) {
        self.bus = bus
        self.interval = max(interval, 0.1)
    }

    /// Idempotent — calling twice does not start a second clock.
    public func start() {
        guard task == nil else { return }
        let bus = self.bus
        let interval = self.interval
        task = Task {
            while !Task.isCancelled {
                await bus.publish(.tick(Date()))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public var isRunning: Bool { task != nil }

    deinit {
        task?.cancel()
    }
}

public extension Agent {
    /// Default: `.none`. Most agents are purely event-driven, and waking them
    /// for nothing is wasted work. Agents that do time-based sweeps
    /// (`DesktopCleanerAgent`) override this.
    nonisolated var tickCadence: TickCadence { .none }
}
