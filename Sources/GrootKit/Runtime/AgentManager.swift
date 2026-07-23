import Foundation

/// The central coordinator. Owns the agent registry, drives lifecycle, pumps
/// bus events to every agent, and aggregates the latest report per agent so the
/// dashboard and floating bubbles have a single source of truth.
public actor AgentManager {
    /// Immutable, so callers (UI, tests) can publish onto the bus without awaiting
    /// the coordinator actor.
    public nonisolated let bus: MessageBus

    private var agents: [AgentID: any Agent] = [:]
    private var latestReports: [AgentID: AgentReport] = [:]
    private var pumpTask: Task<Void, Never>?
    private let startedAt = Date()

    public init(bus: MessageBus = MessageBus()) {
        self.bus = bus
    }

    // MARK: Registration

    /// Register an agent and attach it to the bus. Does not start it.
    public func register(_ agent: any Agent) async {
        agents[agent.id] = agent
        await agent.attach(to: bus)
        latestReports[agent.id] = AgentReport(agentID: agent.id, state: await agent.state)
    }

    public func agent(_ id: AgentID) -> (any Agent)? { agents[id] }

    // MARK: Event pump

    /// Begin forwarding bus events to agents and collecting their reports.
    /// Idempotent — calling twice does nothing.
    public func startEventPump() {
        guard pumpTask == nil else { return }
        let stream = bus // capture; subscribe inside the task
        pumpTask = Task { [weak self] in
            let events = await stream.subscribe()
            for await event in events {
                guard let self else { break }
                await self.dispatch(event)
            }
        }
    }

    public func stopEventPump() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    /// Route one event: update our own aggregates, handle coordinator-level
    /// commands, then fan out to every agent.
    private func dispatch(_ event: BusEvent) async {
        switch event {
        case .agentReport(let report):
            latestReports[report.agentID] = report
        case .command(let intent):
            await handleCoordinatorIntent(intent)
        default:
            break
        }

        // Fan out to agents. `agentReport` is purely coordinator-facing, so we
        // don't echo it back. `operationJournaled` IS forwarded — the File
        // Monitoring Agent uses it as a loop guard against self-triggered events.
        switch event {
        case .agentReport:
            break
        default:
            for agent in agents.values {
                await agent.handle(event)
            }
        }
    }

    /// Coordinator-level interpretation of lifecycle intents. Agent-specific
    /// intents (organizeDesktop, etc.) are left for the relevant agent's `handle`.
    private func handleCoordinatorIntent(_ intent: Intent) async {
        switch intent {
        case .pauseAll:
            await pauseAll()
        case .resumeAll:
            await resumeAll()
        case .setState(let id, let cmd):
            guard let agent = agents[id] else { return }
            switch cmd {
            case .start:  await agent.start()
            case .pause:  await agent.pause()
            case .resume: await agent.resume()
            case .stop:   await agent.stop()
            }
            latestReports[id] = AgentReport(agentID: id, state: await agent.state)
        default:
            break
        }
    }

    // MARK: Lifecycle (bulk)

    public func startAll() async {
        for agent in agents.values { await agent.start() }
        await refreshReports()
    }

    public func pauseAll() async {
        for agent in agents.values { await agent.pause() }
        await refreshReports()
    }

    public func resumeAll() async {
        for agent in agents.values { await agent.resume() }
        await refreshReports()
    }

    public func stopAll() async {
        for agent in agents.values { await agent.stop() }
        await refreshReports()
    }

    private func refreshReports() async {
        for (id, agent) in agents {
            let existing = latestReports[id]
            latestReports[id] = AgentReport(
                agentID: id,
                state: await agent.state,
                currentTask: existing?.currentTask,
                lastAction: existing?.lastAction
            )
        }
    }

    // MARK: Snapshots for the UI

    /// A read-only view of the whole system, safe to hand to the MainActor UI.
    public struct Snapshot: Sendable {
        public let uptime: TimeInterval
        public let agents: [AgentSummary]
        public var runningCount: Int { agents.filter { $0.report.state == .running }.count }
    }

    public struct AgentSummary: Sendable, Identifiable {
        public let descriptor: AgentDescriptor
        public let report: AgentReport
        public var id: AgentID { descriptor.id }
    }

    public func snapshot() -> Snapshot {
        let summaries = agents.values.map { agent -> AgentSummary in
            let report = latestReports[agent.id]
                ?? AgentReport(agentID: agent.id, state: .idle)
            return AgentSummary(descriptor: agent.descriptor, report: report)
        }
        .sorted { $0.descriptor.name < $1.descriptor.name }
        return Snapshot(uptime: Date().timeIntervalSince(startedAt), agents: summaries)
    }
}
