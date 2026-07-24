import Foundation

/// The single typed event vocabulary shared by every agent. Agents never call
/// each other directly — they publish and subscribe to `BusEvent`s, which keeps
/// the runtime decoupled and makes new agents purely additive.
public enum BusEvent: Sendable {
    // MARK: Filesystem signals (from the File Monitoring Agent)
    case fileCreated(URL)
    case fileModified(URL)
    case fileDeleted(URL)
    case fileRenamed(from: URL, to: URL)

    // MARK: User / coordinator signals
    case command(Intent)

    // MARK: Agent → coordinator signals
    case agentReport(AgentReport)
    /// An agent hit an error. Carries the cause, unlike `AgentState.error`.
    case agentFailed(AgentID, String)
    /// An agent recorded a journaled operation (for activity log / recovery UI).
    case operationJournaled(JournalEntry)
    /// An agent needs the user to approve a batch before proceeding.
    case approvalRequested(ApprovalRequest)
    /// The Duplicate Detection agent finished a scan.
    case duplicatesFound(DuplicateReport)
    /// The Storage Analyzer finished an analysis.
    case storageAnalyzed(StorageReport)
    /// The Large File Manager finished a scan.
    case largeFilesFound(LargeFileReport)
    /// The Empty Folder Cleanup agent finished a scan.
    case emptyFoldersFound(EmptyFolderReport)

    // MARK: Timing
    /// Periodic tick the coordinator broadcasts so agents can do time-based work
    /// (e.g. "archive files older than N days") without each owning a timer.
    case tick(Date)
}

/// A request for the user to approve a batch of operations. Raised whenever an
/// agent wants to perform destructive work, or any work while in `.approval` mode.
public struct ApprovalRequest: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let agentID: AgentID
    /// Short summary shown in the sheet, e.g. "Delete 26 duplicate files".
    public let summary: String
    /// Longer explanation, e.g. "Deleting them will recover 7.4 GB."
    public let detail: String?
    /// Number of items affected.
    public let itemCount: Int
    /// Bytes recovered/affected, for the "recover X GB" messaging.
    public let bytesAffected: UInt64
    public let isDestructive: Bool

    public init(
        id: UUID = UUID(),
        agentID: AgentID,
        summary: String,
        detail: String? = nil,
        itemCount: Int,
        bytesAffected: UInt64,
        isDestructive: Bool
    ) {
        self.id = id
        self.agentID = agentID
        self.summary = summary
        self.detail = detail
        self.itemCount = itemCount
        self.bytesAffected = bytesAffected
        self.isDestructive = isDestructive
    }
}
