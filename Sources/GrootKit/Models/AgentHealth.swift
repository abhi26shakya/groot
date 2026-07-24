import Foundation

/// Why an agent is unhealthy, and how badly. Referenced by `AgentState.error`,
/// which previously carried no cause at all — failures were stringified into an
/// agent's `lastAction` display text and lost.
public struct AgentHealth: Sendable, Hashable, Codable {
    /// Description of the most recent failure, if any.
    public var lastError: String?
    /// How many failures this agent has hit since it started.
    public var errorCount: Int
    /// Events the coordinator had to drop because this agent's inbox was full.
    /// A saturated agent must be visible, never silent.
    public var droppedEvents: Int
    /// When the agent last reported in — a stalled agent shows a stale value.
    public var lastHeartbeat: Date?

    public init(
        lastError: String? = nil,
        errorCount: Int = 0,
        droppedEvents: Int = 0,
        lastHeartbeat: Date? = nil
    ) {
        self.lastError = lastError
        self.errorCount = errorCount
        self.droppedEvents = droppedEvents
        self.lastHeartbeat = lastHeartbeat
    }

    /// Nothing has gone wrong.
    public static let healthy = AgentHealth()

    public var isHealthy: Bool { lastError == nil && droppedEvents == 0 }

    /// Record a failure, keeping the running count.
    public mutating func recordError(_ message: String) {
        lastError = message
        errorCount += 1
    }

    public mutating func recordDroppedEvent() {
        droppedEvents += 1
    }
}
