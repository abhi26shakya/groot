import Foundation

/// What an agent should do with a proposed operation.
public enum ActionDecision: Sendable, Equatable {
    /// Act now — reversible work the user has already authorized via autopilot.
    case proceed
    /// Report the proposal but touch nothing (preview mode).
    case propose
    /// Raise an `ApprovalRequest` and wait for the user's answer.
    case askUser
}

/// **The safety model of the entire app, in one pure function.**
///
/// Before this existed, every agent hand-rolled the same
/// `switch autonomy { … }` block, which meant the rule "destructive operations
/// always require approval" was documented but enforced nowhere — an agent that
/// forgot the switch silently bypassed it. Now agents ask this, and it is
/// exhaustively unit-tested.
///
/// | | `.preview` | `.approval` | `.autopilot` |
/// |---|---|---|---|
/// | reversible | `.propose` | `.askUser` | `.proceed` |
/// | **destructive** | `.propose` | `.askUser` | **`.askUser`** |
public enum ApprovalPolicy {

    /// - Parameters:
    ///   - isDestructive: derived from `FileOperationKind.isDestructive` — never
    ///     asserted by the calling agent.
    ///   - autonomy: the agent's current mode.
    public static func decide(isDestructive: Bool, autonomy: AutonomyMode) -> ActionDecision {
        switch autonomy {
        case .preview:
            // Preview never touches the filesystem, destructive or not.
            return .propose
        case .approval:
            return .askUser
        case .autopilot:
            // THE INVARIANT: autopilot covers reversible work only. Destructive
            // operations always come back to the user, whatever the mode says.
            return isDestructive ? .askUser : .proceed
        }
    }

    /// Convenience overload so agents pass the operation kind directly and can't
    /// get the destructive classification wrong.
    public static func decide(kind: FileOperationKind, autonomy: AutonomyMode) -> ActionDecision {
        decide(isDestructive: kind.isDestructive, autonomy: autonomy)
    }
}
