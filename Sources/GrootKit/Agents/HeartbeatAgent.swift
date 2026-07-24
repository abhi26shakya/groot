import Foundation

/// A minimal reference agent used to validate the runtime end-to-end. It does no
/// filesystem work — it simply transitions through the lifecycle and publishes a
/// report on every `.tick`, which is exactly what the dashboard and bubbles need
/// to render a live, moving agent.
///
/// **This is also the reference for `CoreAgent`:** it stores its plumbing in an
/// `AgentCore` and therefore implements no lifecycle methods at all. New agents
/// should be modeled on this — declare `descriptor` and `core`, opt into a tick
/// cadence if you need one, and implement only `handle(_:)`.
public actor HeartbeatAgent: CoreAgent {
    /// Stays `nonisolated` so the UI/coordinator can read identity without awaiting.
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private var beats: Int = 0

    public init(
        id: AgentID = "heartbeat",
        name: String = "Heartbeat",
        colorHex: String = "#5E9EFF",
        symbol: String = "waveform.path.ecg",
        autonomy: AutonomyMode = .preview
    ) {
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "listening")
        self.autonomy = autonomy
    }

    /// Beats on the runtime clock, so it must opt into ticks.
    public nonisolated var tickCadence: TickCadence { .every(1.0) }

    // `attach`, `start`, `pause`, `resume`, `stop` and `state` all come from the
    // `CoreAgent` extension — that used to be ~25 lines of identical code here.

    // MARK: Events

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        if case .tick(let date) = event {
            beats += 1
            await core.report(task: "beat #\(beats)", last: "beat at \(date)")
        }
    }

    /// Exposed for tests/diagnostics.
    public var beatCount: Int { beats }
}
