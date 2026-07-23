import Foundation

/// A user command routed by the coordinator to one or more agents. Produced by
/// UI buttons, the menu bar, or (Phase 3) the voice assistant's NL parser.
///
/// Kept deliberately coarse for Phase 0; specific agents interpret the payload.
public enum Intent: Sendable, Hashable, Codable {
    case organizeDesktop
    case organizeDownloads
    case moveTodaysScreenshots
    case scanDuplicates
    case analyzeStorage
    case pauseAll
    case resumeAll
    /// Lifecycle command targeting a single agent.
    case setState(AgentID, LifecycleCommand)
    /// Escape hatch for commands not yet modeled (e.g. raw voice text pending parse).
    case freeform(String)

    public enum LifecycleCommand: String, Sendable, Hashable, Codable {
        case start, pause, resume, stop
    }
}
