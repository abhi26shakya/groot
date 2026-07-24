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
    private var health: [AgentID: AgentHealth] = [:]
    /// One inbox + one delivery task per agent — see `deliver(_:)`.
    private var inboxes: [AgentID: AsyncStream<BusEvent>.Continuation] = [:]
    private var deliveryTasks: [AgentID: Task<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    /// Agents that asked for time-based wake-ups. `.tick` goes only to these.
    private var tickSubscribers: Set<AgentID> = []
    private var scheduler: Scheduler?
    private let startedAt = Date()

    /// Matches `MessageBus`'s policy: a backed-up agent drops the oldest events
    /// rather than growing without bound. Drops are counted in `AgentHealth`.
    private static let inboxCapacity = 256

    public init(bus: MessageBus = MessageBus()) {
        self.bus = bus
    }

    // MARK: Registration

    /// Register an agent, attach it to the bus, and give it a private inbox.
    /// Does not start it.
    public func register(_ agent: any Agent) async {
        // Registering the same id twice must not orphan the first delivery task.
        if let existing = deliveryTasks[agent.id] {
            inboxes[agent.id]?.finish()
            existing.cancel()
        }

        agents[agent.id] = agent
        health[agent.id] = AgentHealth()
        if agent.tickCadence != .none {
            tickSubscribers.insert(agent.id)
        } else {
            tickSubscribers.remove(agent.id)
        }
        await agent.attach(to: bus)
        latestReports[agent.id] = AgentReport(agentID: agent.id, state: await agent.state)

        // Each agent consumes its own stream, so a slow agent (OCR, hashing,
        // or one suspended on an approval) can no longer stall delivery to the
        // others. A single consumer per inbox preserves per-agent ordering.
        let (stream, continuation) = AsyncStream<BusEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.inboxCapacity))
        inboxes[agent.id] = continuation
        deliveryTasks[agent.id] = Task { [weak agent] in
            for await event in stream {
                guard let agent else { break }
                await agent.handle(event)
            }
        }
    }

    /// Stop delivering to an agent and drop it from the registry.
    public func deregister(_ id: AgentID) {
        inboxes.removeValue(forKey: id)?.finish()
        deliveryTasks.removeValue(forKey: id)?.cancel()
        agents[id] = nil
        latestReports[id] = nil
        health[id] = nil
        tickSubscribers.remove(id)
    }

    // MARK: Clock

    /// Start publishing `.tick` from the runtime rather than from the UI.
    public func startClock(interval: TimeInterval = 1.0) async {
        if scheduler == nil { scheduler = Scheduler(bus: bus, interval: interval) }
        await scheduler?.start()
    }

    public func stopClock() async {
        await scheduler?.stop()
    }

    public func agent(_ id: AgentID) -> (any Agent)? { agents[id] }

    // MARK: Event pump

    /// Begin forwarding bus events to agents and collecting their reports.
    /// Idempotent — calling twice does nothing.
    public func startEventPump() async {
        guard pumpTask == nil else { return }
        // Subscribe BEFORE returning. Subscribing inside the task left a window
        // where an event published right after `startEventPump()` was dropped
        // because no subscription existed yet.
        let events = await bus.subscribe()
        pumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                await self.dispatch(event)
            }
        }
    }

    public func stopEventPump() {
        pumpTask?.cancel()
        pumpTask = nil
        for continuation in inboxes.values { continuation.finish() }
        for task in deliveryTasks.values { task.cancel() }
        inboxes.removeAll()
        deliveryTasks.removeAll()
    }

    /// Route one event: update our own aggregates, handle coordinator-level
    /// commands, then fan out to every agent.
    private func dispatch(_ event: BusEvent) async {
        switch event {
        case .agentReport(let report):
            latestReports[report.agentID] = report
            health[report.agentID] = report.health
        case .agentFailed(let id, let message):
            var current = health[id] ?? AgentHealth()
            current.recordError(message)
            health[id] = current
            if let report = latestReports[id] {
                latestReports[id] = AgentReport(
                    agentID: id, state: .error, currentTask: report.currentTask,
                    progress: report.progress, lastAction: report.lastAction,
                    health: current)
            }
        case .command(let intent):
            await handleCoordinatorIntent(intent)
        default:
            break
        }

        // Fan out to agents. `agentReport` is purely coordinator-facing, so we
        // don't echo it back. `operationJournaled` IS forwarded — the File
        // Monitoring Agent uses it as a loop guard against self-triggered events.
        //
        // Delivery is a non-blocking `yield` into each agent's own inbox, so
        // dispatch never waits on `handle(_:)`.
        switch event {
        case .agentReport:
            break
        default:
            // `.tick` goes only to agents that asked for it, so a clock running
            // at 1 Hz doesn't wake every agent in the system every second.
            var recipients = inboxes
            if case .tick = event {
                recipients = recipients.filter { tickSubscribers.contains($0.key) }
            }
            for (id, continuation) in recipients {
                if case .dropped = continuation.yield(event) {
                    var current = health[id] ?? AgentHealth()
                    current.recordDroppedEvent()
                    health[id] = current
                }
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
            latestReports[id] = AgentReport(agentID: id, state: await agent.state,
                                            health: health[id] ?? .healthy)
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
                lastAction: existing?.lastAction,
                health: health[id] ?? .healthy
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
                ?? AgentReport(agentID: agent.id, state: .idle,
                               health: health[agent.id] ?? .healthy)
            return AgentSummary(descriptor: agent.descriptor, report: report)
        }
        .sorted { $0.descriptor.name < $1.descriptor.name }
        return Snapshot(uptime: Date().timeIntervalSince(startedAt), agents: summaries)
    }
}
