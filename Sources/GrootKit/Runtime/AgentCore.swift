import Foundation

/// The state and reporting plumbing every agent repeats.
///
/// Swift actors can't inherit, so agents *compose* this instead: they declare
/// `var core: AgentCore` and get `start/pause/resume/stop` plus reporting for
/// free. Before this, all six agents carried a byte-identical copy of those four
/// one-line lifecycle methods and a private `report(task:last:)`.
///
/// `report` is deliberately **non-mutating**: a `mutating` async method on a
/// stored property would be an overlapping-access error at every call site.
public struct AgentCore: Sendable {
    public let descriptor: AgentDescriptor
    public var state: AgentState
    public var health: AgentHealth
    /// The task string to show when the agent is running and otherwise idle.
    public var idleTask: String?
    private var bus: MessageBus?

    public init(
        descriptor: AgentDescriptor,
        state: AgentState = .idle,
        idleTask: String? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.health = .healthy
        self.idleTask = idleTask
    }

    public mutating func attach(to bus: MessageBus) {
        self.bus = bus
    }

    /// Publish a status update.
    public func report(task: String?, progress: Double? = nil, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id,
            state: state,
            currentTask: task,
            progress: progress,
            lastAction: last,
            health: health)))
    }

    /// Log a failure, publish it so `AgentManager` folds it into health, and
    /// show the user a readable message.
    public func fail(_ message: String, userFacing: String? = nil) async {
        await bus?.reportFailure(descriptor.id, message)
        await report(task: idleTask, last: userFacing ?? "failed")
    }

    /// Publish any other bus event (domain reports like `.duplicatesFound`).
    public func publish(_ event: BusEvent) async {
        await bus?.publish(event)
    }

    /// Publish an operation the agent journaled (the File Monitor's loop guard).
    public func journaled(_ entry: JournalEntry) async {
        await bus?.publish(.operationJournaled(entry))
    }

    public var isRunning: Bool { state == .running }
}

/// An `Agent` that stores its plumbing in an `AgentCore`, and so inherits the
/// standard lifecycle. Conforming agents only implement `handle(_:)` and their
/// own behaviour.
public protocol CoreAgent: Agent {
    var core: AgentCore { get set }
}

public extension CoreAgent {
    // `descriptor` is intentionally NOT defaulted here: it must stay
    // `nonisolated` so the UI can read it without awaiting, and a default
    // implementation would have to read the actor-isolated `core`. Agents keep
    // their own `nonisolated let descriptor` and pass a copy into the core.

    var state: AgentState { core.state }

    func attach(to bus: MessageBus) async {
        core.attach(to: bus)
    }

    // Lifecycle is idempotent and identical for every agent.
    func start() async {
        core.state = .running
        await core.report(task: core.idleTask, last: "started")
    }

    func pause() async {
        guard core.state == .running else { return }
        core.state = .paused
        await core.report(task: nil, last: "paused")
    }

    func resume() async {
        guard core.state == .paused else { return }
        core.state = .running
        await core.report(task: core.idleTask, last: "resumed")
    }

    func stop() async {
        core.state = .stopped
        await core.report(task: nil, last: "stopped")
    }
}
