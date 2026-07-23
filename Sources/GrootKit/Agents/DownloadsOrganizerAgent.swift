import Foundation

/// Sorts new files in a Downloads-style folder into category subfolders
/// (Archives, Installers, Documents, Pictures, Media, Audio, Code, Other).
///
/// Reacts to `.fileCreated`. Skips files that are already inside a category
/// folder (its own output), in-progress downloads, and directories. Moves are
/// reversible, so `.autopilot` acts immediately; other modes preview/approve.
public actor DownloadsOrganizerAgent: ApprovingAgent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private let root: URL
    private let fileService: FileService
    private var bus: MessageBus?
    private var organizedCount = 0
    private var pending: [UUID: (source: URL, destination: URL)] = [:]

    /// Partial-download / temp extensions we never touch.
    private static let skipExtensions: Set<String> = ["crdownload", "part", "download", "tmp"]

    public init(
        root: URL,
        fileService: FileService,
        autonomy: AutonomyMode = .autopilot,
        id: AgentID = "downloads-organizer",
        name: String = "Downloads",
        colorHex: String = "#8B5CF6",
        symbol: String = "arrow.down.circle"
    ) {
        self.root = root
        self.fileService = fileService
        self.autonomy = autonomy
        self.descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
    }

    public func attach(to bus: MessageBus) async { self.bus = bus }

    public func start() async { state = .running; await report(task: "watching Downloads", last: "started") }
    public func pause() async { guard state == .running else { return }; state = .paused; await report(task: nil, last: "paused") }
    public func resume() async { guard state == .paused else { return }; state = .running; await report(task: "watching Downloads", last: "resumed") }
    public func stop() async { state = .stopped; await report(task: nil, last: "stopped") }

    public func handle(_ event: BusEvent) async {
        guard state == .running else { return }
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

        switch autonomy {
        case .preview:
            await report(task: nil, last: "would file \(url.lastPathComponent) → \(category.folderName)")
        case .approval:
            let request = ApprovalRequest(
                agentID: descriptor.id,
                summary: "Move \(url.lastPathComponent) to \(category.folderName)",
                detail: nil, itemCount: 1, bytesAffected: 0, isDestructive: false)
            pending[request.id] = (url, destination)
            await bus?.publish(.approvalRequested(request))
        case .autopilot:
            await perform(source: url, destination: destination, category: category)
        }
    }

    public func approve(_ requestID: UUID) async {
        guard let job = pending.removeValue(forKey: requestID) else { return }
        await perform(source: job.source, destination: job.destination,
                      category: FileCategory.forURL(job.source))
    }

    public func reject(_ requestID: UUID) async {
        guard pending.removeValue(forKey: requestID) != nil else { return }
    }

    private func perform(source: URL, destination: URL, category: FileCategory) async {
        do {
            let entry = try await fileService.move(from: source, to: destination, agentID: descriptor.id)
            organizedCount += 1
            await bus?.publish(.operationJournaled(entry))
            await report(task: "watching Downloads",
                         last: "filed \(source.lastPathComponent) → \(category.folderName)")
        } catch {
            await report(task: "watching Downloads", last: "failed: \(error)")
        }
    }

    public var organized: Int { organizedCount }

    private func report(task: String?, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id, state: state, currentTask: task, lastAction: last)))
    }
}
