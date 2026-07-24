import Foundation
import os

/// Structured logging for the runtime.
///
/// Agents used to swallow failures into a display string
/// (`report(last: "failed: \(error)")`), so a real error was indistinguishable
/// from normal activity and vanished on the next report. Failures now go to the
/// system log *and* onto the bus as `.agentFailed`, which `AgentManager` folds
/// into `AgentHealth`.
public enum GrootLog {
    private static let subsystem = "com.groot.app"

    /// Coordinator, bus, lifecycle.
    public static let runtime = Logger(subsystem: subsystem, category: "runtime")
    /// Per-agent activity.
    public static let agent = Logger(subsystem: subsystem, category: "agent")
    /// Anything that touches the filesystem.
    public static let fileops = Logger(subsystem: subsystem, category: "fileops")
    /// OCR, local/cloud models.
    public static let ai = Logger(subsystem: subsystem, category: "ai")
    /// SQLite: migrations, queries.
    public static let db = Logger(subsystem: subsystem, category: "db")
    /// The safety gate.
    public static let approvals = Logger(subsystem: subsystem, category: "approvals")
}

public extension MessageBus {
    /// Log a failure and publish it so the coordinator can record it in
    /// `AgentHealth` and the dashboard can surface it.
    func reportFailure(_ agentID: AgentID, _ message: String) async {
        GrootLog.agent.error("[\(agentID.raw, privacy: .public)] \(message, privacy: .public)")
        await publish(.agentFailed(agentID, message))
    }
}
