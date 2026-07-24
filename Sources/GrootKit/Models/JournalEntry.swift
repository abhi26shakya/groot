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
    /// Whether the operation can be reversed from within Groot (Undo /
    /// Recovery Center) rather than only from the Finder. Distinct from
    /// `isDestructive`: trash is destructive (always needs approval) yet still
    /// reversible in-app, since the item just moves to `~/.Trash` — recorded as
    /// this entry's `destinationPath` — until the user empties Trash.
    var isReversibleInApp: Bool {
        switch self {
        // Exhaustive (rather than `true`) so a future fourth kind forces an
        // explicit decision here instead of silently inheriting one.
        case .move, .rename, .trash: return true
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
    /// Location after the operation. For trash, this is the resulting Trash URL
    /// reported by `FileManager.trashItem`, filled in once the OS has performed
    /// the move (unknowable beforehand, since the OS may rename on collision).
    public var destinationPath: String?
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

/// A journal entry's current standing for display and action-gating in the
/// Dashboard's activity list and the Recovery Center. Both surfaces derive
/// this the same way — see `JournalEntry.recoveryStatus(fileManager:)` —
/// rather than each hand-rolling its own "is this restorable" predicate.
public enum RecoveryStatus: Sendable, Equatable {
    case applied
    case reverted
    /// Reversible in principle, but not right now: the destination is
    /// missing (Trash emptied, file moved externally since) or
    /// `destinationPath` was never recorded (a legacy trash row from before
    /// trash became reversible).
    case unavailable
}

public extension JournalEntry {
    /// Whether — and why — this entry can currently be restored. The only
    /// OS-dependent part is the existence check, so `fileManager` is
    /// injected for testability, mirroring `FileService`'s own pattern.
    func recoveryStatus(fileManager: FileManager = .default) -> RecoveryStatus {
        if revertedAt != nil { return .reverted }
        guard kind.isReversibleInApp, let destination = destinationPath else { return .unavailable }
        return fileManager.fileExists(atPath: destination) ? .applied : .unavailable
    }

    /// Convenience for call sites that only need a yes/no.
    func isCurrentlyRestorable(fileManager: FileManager = .default) -> Bool {
        recoveryStatus(fileManager: fileManager) == .applied
    }
}
