import Foundation

/// The kind of mutating filesystem operation an agent performed. Drives Undo
/// and the Recovery Center.
public enum FileOperationKind: String, Sendable, Codable {
    case move       // reversible: move source back to origin
    case rename     // reversible: same as move, kept distinct for readable logs
    case trash      // recoverable: item sits in ~/.Trash until trash is emptied
}

/// Whether an operation can be undone in-app, and whether it destroys data.
public extension FileOperationKind {
    /// Reversible operations may run under `.autopilot` without a prompt.
    var isReversibleInApp: Bool {
        switch self {
        case .move, .rename: return true
        case .trash: return false // recoverable from Trash, but not by us re-linking
        }
    }

    /// Destructive operations always require approval regardless of autonomy mode.
    var isDestructive: Bool {
        switch self {
        case .move, .rename: return false
        case .trash: return true
        }
    }
}

/// A durable record written *before* a mutating operation runs. This is the
/// backbone of every safety feature: Undo, Recovery Center, and activity logs
/// all read from the journal.
public struct JournalEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let agentID: AgentID
    public let kind: FileOperationKind
    /// Location before the operation.
    public let sourcePath: String
    /// Location after the operation (nil for trash — the OS owns the trashed URL).
    public let destinationPath: String?
    public let timestamp: Date
    /// Set once the operation is confirmed applied; nil means "recorded, not yet applied".
    public var appliedAt: Date?
    /// Set once the entry has been reverted, so we never double-undo.
    public var revertedAt: Date?

    public init(
        id: UUID = UUID(),
        agentID: AgentID,
        kind: FileOperationKind,
        sourcePath: String,
        destinationPath: String?,
        timestamp: Date = Date(),
        appliedAt: Date? = nil,
        revertedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.kind = kind
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.timestamp = timestamp
        self.appliedAt = appliedAt
        self.revertedAt = revertedAt
    }
}
