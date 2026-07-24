import Foundation

/// Finds empty folders across a set of roots and offers to trash them.
///
/// "Empty" ignores hidden files (`.DS_Store` and friends) — a folder
/// containing only those is, for cleanup purposes, empty. Nested empty
/// folders are collapsed to their outermost empty ancestor before acting,
/// since trashing a folder removes its whole (empty) subtree; trashing an
/// already-covered inner folder afterward would just fail on a missing
/// source, so there's no reason to ask about it separately.
///
/// Command-driven, like `DuplicateDetectionAgent`/`LargeFileManagerAgent`: a
/// scan finds everything at once, publishes a report, and — if anything was
/// found — raises a single bulk `ApprovalRequest`. Trashing is destructive, so
/// `ApprovalPolicy` routes this to the user in every autonomy mode; the agent
/// never deletes without an explicit answer, and even then folders go to the
/// Trash (recoverable), never `rmdir`.
public actor EmptyFolderCleanupAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let roots: [URL]
    /// Paths we never consider, even if empty — other agents' output roots.
    private let excludedRoots: [URL]
    private let fileService: FileService
    private let approvals: ApprovalService?
    private var cleanedCount = 0

    public init(
        roots: [URL],
        excludedRoots: [URL] = [],
        fileService: FileService,
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "empty-folder-cleanup",
        name: String = "Empty Folders",
        colorHex: String = "#84CC16",
        symbol: String = "folder.badge.minus"
    ) {
        self.roots = roots.map(\.standardizedFileURL)
        self.excludedRoots = excludedRoots.map(\.standardizedFileURL)
        self.fileService = fileService
        self.approvals = approvals
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "idle")
    }

    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        if case .command(.scanEmptyFolders) = event { await scan() }
    }

    /// Scan all roots, find empty folders, publish a report, and (if any were
    /// found) ask for approval to trash all of them at once.
    public func scan() async {
        await core.report(task: "scanning for empty folders…", progress: nil, last: nil)
        let folders = Self.emptyFolders(under: roots, excluding: excludedRoots)
        let reportModel = EmptyFolderReport(paths: folders.map(\.path))
        await core.publish(.emptyFoldersFound(reportModel))

        guard !folders.isEmpty else {
            await core.report(task: "idle", last: "no empty folders found")
            return
        }

        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Delete \(folders.count) empty folder(s)",
            detail: "Moves them to the Trash — nothing inside is lost since they contain no files.",
            itemCount: folders.count,
            bytesAffected: 0,
            isDestructive: FileOperationKind.trash.isDestructive)

        await core.report(task: "idle", last: "found \(folders.count) empty folder(s)")

        // `.trash` is destructive, so `ApprovalPolicy` routes this to the user
        // even under `.autopilot`. The agent doesn't get a say.
        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await trashFolders(folders)
        case .previewOnly, .declined:
            await core.report(task: "idle", last: "kept all folders")
        }
    }

    private func trashFolders(_ folders: [URL]) async {
        var trashed = 0
        var skipped = 0
        for folder in folders {
            do {
                let entry = try await fileService.trash(folder, agentID: descriptor.id)
                await core.journaled(entry)
                trashed += 1
            } catch {
                // A folder that gained a file, or was already removed, since
                // the scan is expected, not fatal.
                skipped += 1
                GrootLog.fileops.notice(
                    "skipped empty folder \(folder.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        cleanedCount += trashed
        let summary = skipped == 0
            ? "trashed \(trashed) folder(s)"
            : "trashed \(trashed), skipped \(skipped) that changed since the scan"
        await core.report(task: "idle", last: summary)
    }

    // MARK: Pure scanning (unit-tested)

    /// Every folder under `roots` that is empty — recursively: a folder
    /// containing only other (recursively) empty folders counts as empty too
    /// — collapsed to the outermost such folder, since trashing it removes
    /// the whole subtree. Roots themselves and anything under `excluding` are
    /// never returned; a package/bundle (`.app`, `.bundle`, …) is treated as
    /// opaque content, never flagged and never descended into.
    public static func emptyFolders(
        under roots: [URL], excluding: [URL] = [], fileManager: FileManager = .default
    ) -> [URL] {
        let excludedPaths = excluding.map(\.standardizedFileURL.path)
        var result: [URL] = []
        for root in roots {
            collect(in: root.standardizedFileURL, excludedPaths: excludedPaths,
                    fileManager: fileManager, into: &result)
        }
        return result
    }

    /// Walk `folder`'s immediate children: flag a child as empty (without
    /// descending further) if it's recursively empty; otherwise recurse into
    /// it to find nested empty subfolders alongside its non-empty siblings.
    private static func collect(
        in folder: URL, excludedPaths: [String], fileManager: FileManager, into result: inout [URL]
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            let standardized = item.standardizedFileURL
            if excludedPaths.contains(where: { standardized.path == $0 || standardized.path.hasPrefix($0 + "/") }) {
                continue
            }
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true else { continue }

            if isEmptyRecursively(standardized, fileManager: fileManager) {
                result.append(standardized)
            } else {
                collect(in: standardized, excludedPaths: excludedPaths,
                        fileManager: fileManager, into: &result)
            }
        }
    }

    /// A directory is empty if it has no entries once hidden files
    /// (`.DS_Store` and similar) are ignored, or if every entry is itself a
    /// (recursively) empty, non-package directory.
    static func isEmptyRecursively(_ url: URL, fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        if contents.isEmpty { return true }
        for item in contents {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true,
                  isEmptyRecursively(item, fileManager: fileManager) else { return false }
        }
        return true
    }

    /// Exposed for tests/diagnostics.
    public var cleaned: Int { cleanedCount }
}
