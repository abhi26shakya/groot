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

    /// How often this agent wants `.tick`. Declared as a protocol requirement
    /// (not just an extension default) so it dispatches dynamically through
    /// `any Agent` — an extension-only member would statically bind to the
    /// default and silently ignore every agent's override.
    nonisolated var tickCadence: TickCadence { get }

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

    /// Change the agent's autonomy from outside the actor. An isolated property
    /// can't be assigned across an `await`, so the UI goes through this.
    ///
    /// Raising autonomy never weakens safety: `ApprovalPolicy` still refuses to
    /// let any mode perform destructive work unattended.
    func setAutonomy(_ mode: AutonomyMode) async {
        autonomy = mode
    }
}

// `ApprovingAgent` used to live here, requiring every agent to keep its own
// `pending` dictionary and re-implement the autonomy switch. Approvals now go
// through `ApprovalService`, which owns the pending requests and applies
// `ApprovalPolicy` in one place — so the UI resolves decisions against the
// service and never needs to know a concrete agent type.
