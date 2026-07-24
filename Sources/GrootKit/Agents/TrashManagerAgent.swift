import Foundation

/// Analyzes the system Trash (`~/.Trash`) — how much space emptying it would
/// recover, how stale its oldest item is, and whether a recent backup exists —
/// then offers to empty it. Permanent deletion is irreversible, so
/// `ApprovalPolicy` routes this to the user in **every** autonomy mode; the
/// agent never empties the Trash without an explicit answer, and the backup
/// status is surfaced prominently in that request so the decision is informed.
///
/// Command-driven, like `DuplicateDetectionAgent`/`LargeFileManagerAgent`/
/// `EmptyFolderCleanupAgent`: `analyze()` finds everything at once, publishes
/// a report, and — if the Trash isn't empty — raises a single bulk
/// `ApprovalRequest` rather than one per item.
public actor TrashManagerAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let trashDirectory: URL
    private let fileService: FileService
    private let approvals: ApprovalService?
    private let backupChecker: BackupChecking
    private var emptiedCount = 0

    public init(
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true),
        fileService: FileService,
        backupChecker: BackupChecking = TimeMachineBackupChecker(),
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "trash-manager",
        name: String = "Trash",
        colorHex: String = "#64748B",
        symbol: String = "trash.circle"
    ) {
        self.trashDirectory = trashDirectory
        self.fileService = fileService
        self.backupChecker = backupChecker
        self.approvals = approvals
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "idle")
    }

    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        if case .command(.analyzeTrash) = event { await analyze() }
    }

    /// Scan the Trash, check backup status, publish a report, and (if the
    /// Trash isn't empty) ask for approval to empty it.
    public func analyze() async {
        await core.report(task: "checking Trash…", progress: nil, last: nil)
        let items = Self.scanTrash(at: trashDirectory)
        let backupDate = await backupChecker.latestBackupDate()
        let reportModel = TrashReport(
            itemCount: items.count,
            totalBytes: items.reduce(UInt64(0)) { $0 + $1.sizeBytes },
            oldestItemDate: items.map(\.modified).min(),
            latestBackupDate: backupDate)
        await core.publish(.trashAnalyzed(reportModel))

        guard !items.isEmpty else {
            await core.report(task: "idle", last: "Trash is empty")
            return
        }

        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Empty Trash (\(items.count) item(s))",
            detail: Self.approvalDetail(for: reportModel),
            itemCount: items.count,
            bytesAffected: reportModel.totalBytes,
            isDestructive: FileOperationKind.permanentDelete.isDestructive)

        await core.report(
            task: "idle",
            last: "\(items.count) item(s) in Trash · \(ByteFormat.string(reportModel.totalBytes)) recoverable")

        // Permanent deletion is destructive, so `ApprovalPolicy` routes this
        // to the user even under `.autopilot`. The agent doesn't get a say.
        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await empty(items)
        case .previewOnly, .declined:
            await core.report(task: "idle", last: "kept Trash contents")
        }
    }

    private func empty(_ items: [FileEntry]) async {
        var emptied = 0
        var skipped = 0
        for item in items {
            do {
                let entry = try await fileService.permanentlyDelete(
                    URL(fileURLWithPath: item.path), agentID: descriptor.id)
                await core.journaled(entry)
                emptied += 1
            } catch {
                // An item removed or changed since the scan is expected, not
                // fatal — but still worth logging rather than swallowing.
                skipped += 1
                GrootLog.fileops.notice(
                    "skipped trash item \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        emptiedCount += emptied
        let summary = skipped == 0
            ? "emptied \(emptied) item(s)"
            : "emptied \(emptied), skipped \(skipped) that changed since the scan"
        await core.report(task: "idle", last: summary)
    }

    // MARK: Pure helpers (unit-tested)

    /// Top-level items directly inside the Trash, each with its full
    /// (recursive, for folders) size. Hidden entries (`.DS_Store`, the
    /// per-volume Trash marker files) are ignored, matching the intent of
    /// "what would actually be reclaimed."
    public static func scanTrash(at directory: URL, fileManager: FileManager = .default) -> [FileEntry] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> FileEntry? in
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            ) else { return nil }
            let size: UInt64 = values.isDirectory == true
                ? directorySize(url, fileManager: fileManager)
                : UInt64(values.fileSize ?? 0)
            return FileEntry(
                path: url.path, sizeBytes: size,
                modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// The approval copy: always states the deletion is permanent, then calls
    /// out backup status so the decision is informed, not just gated.
    static func approvalDetail(for report: TrashReport) -> String {
        var detail = "Permanently deletes \(report.itemCount) item(s), recovering "
            + "\(ByteFormat.string(report.totalBytes)). This cannot be undone."
        switch report.latestBackupDate {
        case nil:
            detail += " No Time Machine backup was found — consider backing up first."
        case .some(let date) where report.backupIsStale:
            let days = Int(report.scannedAt.timeIntervalSince(date) / 86_400)
            detail += " Your last backup was \(days) day(s) ago — consider backing up first."
        case .some:
            detail += " Your last backup is recent."
        }
        return detail
    }

    /// Exposed for tests/diagnostics.
    public var emptied: Int { emptiedCount }
}
