import Foundation

/// A minimal reference agent used to validate the runtime end-to-end. It does no
/// filesystem work — it simply transitions through the lifecycle and publishes a
/// report on every `.tick`, which is exactly what the dashboard and bubbles need
/// to render a live, moving agent.
///
/// New real agents can be modeled after this: capture the bus in `attach`,
/// guard work behind `state == .running`, and publish `AgentReport`s.
public actor HeartbeatAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private var bus: MessageBus?
    private var beats: Int = 0

    public init(
        id: AgentID = "heartbeat",
        name: String = "Heartbeat",
        colorHex: String = "#5E9EFF",
        symbol: String = "waveform.path.ecg",
        autonomy: AutonomyMode = .preview
    ) {
        self.descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.autonomy = autonomy
    }

    public func attach(to bus: MessageBus) async {
        self.bus = bus
    }

    // MARK: Lifecycle

    public func start() async {
        state = .running
        await report(task: "listening", last: "started")
    }

    public func pause() async {
        guard state == .running else { return }
        state = .paused
        await report(task: nil, last: "paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        state = .running
        await report(task: "listening", last: "resumed")
    }

    public func stop() async {
        state = .stopped
        await report(task: nil, last: "stopped")
    }

    // MARK: Events

    public func handle(_ event: BusEvent) async {
        guard state == .running else { return }
        if case .tick(let date) = event {
            beats += 1
            await report(task: "beat #\(beats)", last: "beat at \(date)")
        }
    }

    /// Exposed for tests/diagnostics.
    public var beatCount: Int { beats }

    private func report(task: String?, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id,
            state: state,
            currentTask: task,
            lastAction: last
        )))
    }
}
