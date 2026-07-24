import Foundation

/// Composable filter for querying the Undo journal. The Recovery Center is the
/// only consumer today, but this lives as a standalone value type (rather than
/// inline query parameters) so `InMemoryJournalStore` and `SQLiteJournalStore`
/// share one definition of what "matches" means.
public struct JournalFilter: Sendable, Equatable {
    /// Which subset of applied/reverted entries to include.
    public enum RevertState: Sendable, Equatable, CaseIterable {
        case any
        /// Already reverted (undone/restored).
        case revertedOnly
        /// Applied and not yet reverted.
        case appliedOnly
    }

    public var agentID: AgentID?
    /// Empty means "all kinds".
    public var kinds: Set<FileOperationKind>
    public var revertState: RevertState
    public var dateRange: ClosedRange<Date>?
    /// Case-insensitive substring match against the source or destination path.
    public var searchText: String?

    public init(
        agentID: AgentID? = nil,
        kinds: Set<FileOperationKind> = [],
        revertState: RevertState = .any,
        dateRange: ClosedRange<Date>? = nil,
        searchText: String? = nil
    ) {
        self.agentID = agentID
        self.kinds = kinds
        self.revertState = revertState
        self.dateRange = dateRange
        self.searchText = searchText
    }

    /// The pure predicate `InMemoryJournalStore` filters with directly, and
    /// that `SQLiteJournalStoreTests` checks the SQL translation against.
    public func matches(_ entry: JournalEntry) -> Bool {
        if let agentID, entry.agentID != agentID { return false }
        if !kinds.isEmpty, !kinds.contains(entry.kind) { return false }
        switch revertState {
        case .any: break
        case .revertedOnly: if entry.revertedAt == nil { return false }
        case .appliedOnly: if entry.revertedAt != nil { return false }
        }
        if let dateRange, !dateRange.contains(entry.timestamp) { return false }
        if let searchText, !searchText.isEmpty {
            let haystack = entry.sourcePath + " " + (entry.destinationPath ?? "")
            if !haystack.localizedCaseInsensitiveContains(searchText) { return false }
        }
        return true
    }
}
