import Foundation

/// A point-in-time health/progress snapshot an agent publishes onto the bus.
/// The coordinator aggregates these for the dashboard and drives bubble animation.
public struct AgentReport: Sendable, Hashable, Codable {
    public let agentID: AgentID
    public let state: AgentState
    /// Human-readable description of what the agent is doing right now.
    public let currentTask: String?
    /// Fractional progress of the current task, 0...1, or nil when indeterminate.
    public let progress: Double?
    /// Last action the agent completed, shown when a bubble expands.
    public let lastAction: String?
    /// Approximate CPU load attributed to this agent, 0...1.
    public let cpu: Double
    /// Approximate resident memory attributed to this agent, in bytes.
    public let memoryBytes: UInt64
    public let timestamp: Date

    public init(
        agentID: AgentID,
        state: AgentState,
        currentTask: String? = nil,
        progress: Double? = nil,
        lastAction: String? = nil,
        cpu: Double = 0,
        memoryBytes: UInt64 = 0,
        timestamp: Date = Date()
    ) {
        self.agentID = agentID
        self.state = state
        self.currentTask = currentTask
        self.progress = progress.map { min(max($0, 0), 1) }
        self.lastAction = lastAction
        self.cpu = min(max(cpu, 0), 1)
        self.memoryBytes = memoryBytes
        self.timestamp = timestamp
    }
}
