import Foundation

/// Stable identifier for an agent. String-backed so it survives persistence and
/// keeps logs/journal rows readable.
public struct AgentID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.raw = value
    }

    public var description: String { raw }
}

/// The lifecycle state an agent can be in. Reported to the dashboard and bubbles.
public enum AgentState: String, Sendable, Codable, CaseIterable {
    case idle       // registered, not doing work, ready
    case running    // actively processing
    case paused     // temporarily suspended by the user/coordinator
    case stopped    // shut down; will not process until started again
    case error      // last operation failed; see `AgentHealth`
}

/// How aggressively an agent is allowed to act on its own. The safety spine of the app.
public enum AutonomyMode: String, Sendable, Codable, CaseIterable {
    /// Proposes actions only. Never touches the filesystem.
    case preview
    /// Acts, but only after the user confirms each batch.
    case approval
    /// Acts automatically on reversible operations. Destructive ops still prompt.
    case autopilot
}

/// Static presentation metadata for an agent. Immutable, so it can be read
/// without actor isolation (`nonisolated`) by the UI and coordinator.
public struct AgentDescriptor: Sendable, Hashable, Codable {
    public let id: AgentID
    public let name: String
    /// Hex color used for the agent's floating bubble (e.g. "#5E9EFF").
    public let colorHex: String
    /// SF Symbol name for the agent's icon.
    public let symbol: String

    public init(id: AgentID, name: String, colorHex: String, symbol: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
    }
}
