import Foundation

/// The one and only path through which agents mutate the filesystem. Every
/// operation is journaled *before* it runs, which is what makes Undo, the
/// Recovery Center, and activity logs possible for free.
///
/// Deletes never call `unlink` — they move items to the Trash, so nothing is
/// truly destroyed until the user empties Trash (itself a gated, destructive op).
public actor FileService {
    public enum FileServiceError: Error, Sendable, Equatable {
        case sourceMissing(String)
        case destinationExists(String)
        case notReversible(UUID)
        case alreadyReverted(UUID)
    }

    private let store: JournalStore
    private let fileManager: FileManager

    public init(store: JournalStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    // MARK: Move / rename (reversible)

    /// Move (or rename) `source` to `destination`, journaling first. Creates the
    /// destination's parent directory if needed. Refuses to clobber an existing
    /// file — callers must resolve name collisions upstream.
    @discardableResult
    public func move(
        from source: URL,
        to destination: URL,
        agentID: AgentID,
        kind: FileOperationKind = .move
    ) async throws -> JournalEntry {
        guard fileManager.fileExists(atPath: source.path) else {
            throw FileServiceError.sourceMissing(source.path)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileServiceError.destinationExists(destination.path)
        }

        // Record intent BEFORE acting, so a crash mid-op is still recoverable.
        var entry = JournalEntry(
            agentID: agentID,
            kind: kind,
            sourcePath: source.path,
            destinationPath: destination.path
        )
        try await store.record(entry)

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: source, to: destination)

        entry.appliedAt = Date()
        try await store.update(entry)
        return entry
    }

    // MARK: Delete (recoverable via Trash)

    /// Move an item to the Trash. Journaled as a destructive op. The resulting
    /// Trash URL (unknowable beforehand — the OS may rename on collision) is
    /// captured and stored as `destinationPath`, which is what makes trashed
    /// items restorable from the Recovery Center via `restore(_:)`.
    @discardableResult
    public func trash(_ url: URL, agentID: AgentID) async throws -> JournalEntry {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileServiceError.sourceMissing(url.path)
        }

        var entry = JournalEntry(
            agentID: agentID,
            kind: .trash,
            sourcePath: url.path,
            destinationPath: nil
        )
        try await store.record(entry)

        var resultingItemURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingItemURL)

        entry.destinationPath = (resultingItemURL as URL?)?.path
        entry.appliedAt = Date()
        try await store.update(entry)
        return entry
    }

    // MARK: Undo / Restore

    /// Reverse a previously applied, reversible operation — a move/rename back
    /// to its origin, or (since trash records its resulting Trash URL as
    /// `destinationPath`) a trashed item back from `~/.Trash`. Both are the
    /// same mechanics: move `destinationPath` back to `sourcePath`.
    @discardableResult
    public func undo(_ entryID: UUID) async throws -> JournalEntry {
        guard var entry = try await store.entry(entryID) else {
            throw FileServiceError.notReversible(entryID)
        }
        guard entry.revertedAt == nil else {
            throw FileServiceError.alreadyReverted(entryID)
        }
        guard entry.kind.isReversibleInApp, let destination = entry.destinationPath else {
            throw FileServiceError.notReversible(entryID)
        }

        let destURL = URL(fileURLWithPath: destination)
        let originURL = URL(fileURLWithPath: entry.sourcePath)

        guard fileManager.fileExists(atPath: destURL.path) else {
            throw FileServiceError.sourceMissing(destURL.path)
        }
        guard !fileManager.fileExists(atPath: originURL.path) else {
            throw FileServiceError.destinationExists(originURL.path)
        }

        try fileManager.createDirectory(
            at: originURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: destURL, to: originURL)

        entry.revertedAt = Date()
        try await store.update(entry)
        return entry
    }

    /// Semantically-named wrapper over `undo(_:)` for trashed rows — the
    /// Recovery Center's "Restore" action reads more naturally against this
    /// name than "undo a trash", even though the mechanics are identical.
    @discardableResult
    public func restore(_ entryID: UUID) async throws -> JournalEntry {
        try await undo(entryID)
    }

    // MARK: Read-through for the Recovery Center

    public func history() async throws -> [JournalEntry] {
        try await store.allEntries()
    }

    /// Filtered/searched history for the Recovery Center.
    public func history(matching filter: JournalFilter) async throws -> [JournalEntry] {
        try await store.entries(matching: filter)
    }

    // MARK: Retention (journal rows only — never touches a file on disk)

    public func clearHistory(olderThan date: Date, revertedOnly: Bool) async throws {
        try await store.deleteEntries(olderThan: date, revertedOnly: revertedOnly)
    }

    public func clearAllHistory() async throws {
        try await store.deleteAll()
    }
}
