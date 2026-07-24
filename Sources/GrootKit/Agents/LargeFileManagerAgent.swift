import Foundation

/// Finds individual files at/above a configurable size threshold across a set
/// of roots and offers to reclaim the space, either by **archiving** them into
/// a dated `Large Files/<YYYY-MM>/` folder (reversible, the default) or by
/// **trashing** them outright (destructive, always approval-gated regardless
/// of autonomy — see `FileOperationKind.isDestructive`).
///
/// True compression ("zip these up") is deliberately out of scope: no
/// archive-creation infrastructure exists yet in GrootKit (that would need
/// Apple's `Compression` framework or shelling out to `ditto`/`zip`), so this
/// agent only ever issues `.move` or `.trash` — never creates a new file
/// format. Compression is left for a future phase.
///
/// Command-driven, like `DuplicateDetectionAgent`: a scan finds everything at
/// once, publishes a report, and — if anything was found — raises a single
/// bulk `ApprovalRequest` rather than one per file.
public actor LargeFileManagerAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let roots: [URL]
    private let fileService: FileService
    private let approvals: ApprovalService?
    private let scanner: FileScanner
    private let thresholdBytes: UInt64
    private let action: LargeFileAction
    private var actedCount = 0

    /// Files under a folder with this name are never re-considered — this is
    /// our own archive output, mirroring `DesktopCleanerAgent`'s guard against
    /// re-processing its own `Archive` folder.
    static let archiveFolderName = "Large Files"

    public init(
        roots: [URL],
        fileService: FileService,
        approvals: ApprovalService? = nil,
        thresholdBytes: UInt64 = 500 * 1024 * 1024,
        action: LargeFileAction = .archive,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "large-file-manager",
        name: String = "Large Files",
        colorHex: String = "#F97316",
        symbol: String = "externaldrive.badge.exclamationmark"
    ) {
        self.roots = roots.map(\.standardizedFileURL)
        self.fileService = fileService
        self.approvals = approvals
        self.scanner = FileScanner()
        self.thresholdBytes = thresholdBytes
        self.action = action
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "idle")
    }

    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        if case .command(.scanLargeFiles) = event { await scan() }
    }

    /// Scan all roots, find files at/above the threshold, publish a report,
    /// and (if any were found) ask for approval to act on all of them at once.
    public func scan() async {
        await core.report(task: "scanning for large files…", progress: nil, last: nil)
        let files = scanner.scan(roots: roots)
        let large = Self.largeFiles(files, thresholdBytes: thresholdBytes)
        let reportModel = LargeFileReport(entries: large, thresholdBytes: thresholdBytes)
        await core.publish(.largeFilesFound(reportModel))

        guard !large.isEmpty else {
            await core.report(task: "idle", last: "no large files found")
            return
        }

        let total = reportModel.totalBytes
        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "\(action == .archive ? "Archive" : "Delete") \(large.count) large file(s)",
            detail: action == .archive
                ? "Moves them into a dated “\(Self.archiveFolderName)” folder, "
                  + "recovering \(ByteFormat.string(total)) from their current location."
                : "Moving them to the Trash will recover \(ByteFormat.string(total)).",
            itemCount: large.count,
            bytesAffected: total,
            isDestructive: action.operationKind.isDestructive)

        await core.report(
            task: "idle",
            last: "found \(large.count) large file(s) · \(ByteFormat.string(total)) reclaimable")

        // Trashing is destructive, so `ApprovalPolicy` routes this to the user
        // even under `.autopilot` when `action == .trash`. The agent doesn't
        // get a say — same guarantee `DuplicateDetectionAgent` relies on.
        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await act(on: large)
        case .previewOnly, .declined:
            await core.report(task: "idle", last: "kept all files")
        }
    }

    private func act(on files: [FileEntry]) async {
        var succeeded = 0
        var skipped = 0
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            do {
                let entry: JournalEntry
                switch action {
                case .archive:
                    entry = try await fileService.move(
                        from: url, to: archiveDestination(for: url), agentID: descriptor.id)
                case .trash:
                    entry = try await fileService.trash(url, agentID: descriptor.id)
                }
                await core.journaled(entry)
                succeeded += 1
            } catch {
                // A file that vanished or changed since the scan is expected,
                // not fatal — but still worth logging rather than swallowing.
                skipped += 1
                GrootLog.fileops.notice(
                    "skipped large file \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        actedCount += succeeded
        let verb = action == .archive ? "archived" : "trashed"
        let summary = skipped == 0
            ? "\(verb) \(succeeded) file(s)"
            : "\(verb) \(succeeded), skipped \(skipped) that changed since the scan"
        await core.report(task: "idle", last: summary)
    }

    /// Which watched root a file lives under, so its archive folder lands
    /// alongside it rather than always under the first root.
    private func rootContaining(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return roots.first { standardized.path.hasPrefix($0.path) }
            ?? roots.first
            ?? standardized.deletingLastPathComponent()
    }

    private func archiveDestination(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: Date())
        let folder = rootContaining(url)
            .appendingPathComponent(Self.archiveFolderName, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
        return DestinationResolver.collisionSafe(for: url.lastPathComponent, in: folder)
    }

    // MARK: Pure filtering (unit-tested)

    /// Files at/above the threshold, largest first, excluding our own
    /// previously-archived output.
    public static func largeFiles(_ files: [FileEntry], thresholdBytes: UInt64) -> [FileEntry] {
        files
            .filter { $0.sizeBytes >= thresholdBytes }
            .filter { !$0.path.components(separatedBy: "/").contains(archiveFolderName) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Exposed for tests/diagnostics.
    public var acted: Int { actedCount }
}
