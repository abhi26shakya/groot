import Foundation

/// Sorts new files in a Downloads-style folder into category subfolders
/// (Archives, Installers, Documents, Pictures, Media, Audio, Code, Other).
///
/// Reacts to `.fileCreated`. Skips files that are already inside a category
/// folder (its own output), in-progress downloads, and directories. Moves are
/// reversible, so `.autopilot` acts immediately; other modes preview/approve.
public actor DownloadsOrganizerAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let root: URL
    private let fileService: FileService
    /// The safety gate — decides proceed/propose/ask on the agent's behalf.
    private let approvals: ApprovalService?
    private var organizedCount = 0

    /// Partial-download / temp extensions we never touch.
    private static let skipExtensions: Set<String> = ["crdownload", "part", "download", "tmp"]

    public init(
        root: URL,
        fileService: FileService,
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .autopilot,
        id: AgentID = "downloads-organizer",
        name: String = "Downloads",
        colorHex: String = "#8B5CF6",
        symbol: String = "arrow.down.circle"
    ) {
        self.root = root
        self.fileService = fileService
        self.approvals = approvals
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "watching Downloads")
    }


    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        guard case .fileCreated(let url) = event else { return }
        guard shouldOrganize(url) else { return }
        await process(url)
    }

    /// Only act on regular files directly inside `root` (not already sorted).
    /// `nonisolated` — reads only immutable state, so it's a pure, testable check.
    nonisolated func shouldOrganize(_ url: URL) -> Bool {
        guard url.path.hasPrefix(root.path) else { return false }
        // Must live directly in root, not in a subfolder (avoids re-sorting output).
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if Self.skipExtensions.contains(ext) { return false }
        if url.lastPathComponent.hasPrefix(".") { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return !isDir.boolValue
    }

    private func process(_ url: URL) async {
        let category = FileCategory.forURL(url)
        let folder = root.appendingPathComponent(category.folderName, isDirectory: true)
        let destination = DestinationResolver.collisionSafe(for: url.lastPathComponent, in: folder)

        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Move \(url.lastPathComponent) to \(category.folderName)",
            detail: nil, itemCount: 1, bytesAffected: 0,
            isDestructive: FileOperationKind.move.isDestructive)

        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await perform(source: url, destination: destination, category: category)
        case .previewOnly:
            await core.report(task: nil, last: "would file \(url.lastPathComponent) → \(category.folderName)")
        case .declined:
            await core.report(task: "watching Downloads", last: "skipped \(url.lastPathComponent)")
        }
    }

    private func perform(source: URL, destination: URL, category: FileCategory) async {
        do {
            let entry = try await fileService.move(from: source, to: destination, agentID: descriptor.id)
            organizedCount += 1
            await core.journaled(entry)
            await core.report(task: "watching Downloads",
                         last: "filed \(source.lastPathComponent) → \(category.folderName)")
        } catch {
            await core.fail("move failed: \(error)", userFacing: "could not file \(source.lastPathComponent)")
        }
    }

    public var organized: Int { organizedCount }

}
