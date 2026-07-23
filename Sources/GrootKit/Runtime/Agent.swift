import Foundation

/// The single extension point of the whole system. Every capability — screenshot
/// renaming, duplicate detection, a future email organizer — is an `Agent`.
///
/// Agents are actors, so their internal state is automatically isolated. They
/// communicate only through the `MessageBus`; the `AgentManager` drives their
/// lifecycle and forwards every `BusEvent` to `handle(_:)`.
public protocol Agent: Actor {
    /// Immutable identity/presentation, readable without awaiting the actor.
    nonisolated var descriptor: AgentDescriptor { get }

    /// Current lifecycle state.
    var state: AgentState { get }

    /// The autonomy mode this agent runs under. Defaults to the safest mode.
    var autonomy: AutonomyMode { get set }

    /// Called once when the agent is registered, before any events flow. Use to
    /// capture the bus handle so the agent can publish reports.
    func attach(to bus: MessageBus) async

    // MARK: Lifecycle (idempotent — safe to call in any state)
    func start() async
    func pause() async
    func resume() async
    func stop() async

    /// Fan-in: the coordinator forwards every bus event here. Agents filter for
    /// the events they care about and ignore the rest.
    func handle(_ event: BusEvent) async
}

public extension Agent {
    /// Convenience so `AgentManager` and the UI can read the id without awaiting.
    nonisolated var id: AgentID { descriptor.id }
}

/// An agent that raises `ApprovalRequest`s and can act on the user's decision.
/// The UI routes approve/reject to the right agent by `ApprovalRequest.agentID`
/// without needing to know the concrete agent type.
public protocol ApprovingAgent: Agent {
    /// Carry out the proposal behind this request id.
    func approve(_ requestID: UUID) async
    /// Discard the proposal, leaving files untouched.
    func reject(_ requestID: UUID) async
}
