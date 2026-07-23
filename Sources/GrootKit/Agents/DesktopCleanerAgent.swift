import Foundation

/// Keeps the Desktop tidy by archiving loose top-level files that haven't been
/// touched in a while into `Desktop/Archive/<YYYY-MM>/`.
///
/// Runs on the `.organizeDesktop` intent and on a throttled `.tick` (at most
/// once per `minInterval`) so it doesn't rescan every second. Archiving is a
/// reversible move → `.autopilot` acts; other modes preview/approve per file.
public actor DesktopCleanerAgent: ApprovingAgent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private let root: URL
    private let fileService: FileService
    private let archiveAfter: TimeInterval
    private let minInterval: TimeInterval
    private var bus: MessageBus?
    private var lastRun: Date = .distantPast
    private var archivedCount = 0
    private var pending: [UUID: (source: URL, destination: URL)] = [:]

    private static let archiveFolderName = "Archive"

    public init(
        root: URL,
        fileService: FileService,
        archiveAfterDays: Double = 14,
        minInterval: TimeInterval = 60,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "desktop-cleaner",
        name: String = "Desktop",
        colorHex: String = "#EC4899",
        symbol: String = "menubar.dock.rectangle"
    ) {
        self.root = root
        self.fileService = fileService
        self.archiveAfter = archiveAfterDays * 86_400
        self.minInterval = minInterval
        self.autonomy = autonomy
        self.descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
    }

    public func attach(to bus: MessageBus) async { self.bus = bus }

    public func start() async { state = .running; await report(task: "monitoring Desktop", last: "started") }
    public func pause() async { guard state == .running else { return }; state = .paused; await report(task: nil, last: "paused") }
    public func resume() async { guard state == .paused else { return }; state = .running; await report(task: "monitoring Desktop", last: "resumed") }
    public func stop() async { state = .stopped; await report(task: nil, last: "stopped") }

    public func handle(_ event: BusEvent) async {
        guard state == .running else { return }
        switch event {
        case .command(.organizeDesktop):
            await sweep(force: true)
        case .tick(let now):
            if now.timeIntervalSince(lastRun) >= minInterval { await sweep(force: false) }
        default:
            break
        }
    }

    /// Find stale top-level files and archive them per the autonomy mode.
    private func sweep(force: Bool) async {
        lastRun = Date()
        let stale = staleFiles()
        guard !stale.isEmpty else {
            if force { await report(task: "monitoring Desktop", last: "nothing to archive") }
            return
        }
        await report(task: "archiving \(stale.count) file(s)", last: nil)

        for url in stale {
            let destination = archiveDestination(for: url)
            switch autonomy {
            case .preview:
                await report(task: nil, last: "would archive \(url.lastPathComponent)")
            case .approval:
                let request = ApprovalRequest(
                    agentID: descriptor.id,
                    summary: "Archive \(url.lastPathComponent)",
                    detail: "Not modified in \(Int(archiveAfter / 86_400)) days",
                    itemCount: 1, bytesAffected: 0, isDestructive: false)
                pending[request.id] = (url, destination)
                await bus?.publish(.approvalRequested(request))
            case .autopilot:
                await perform(source: url, destination: destination)
            }
        }
    }

    /// Top-level regular files older than the threshold, skipping the archive itself.
    /// `nonisolated` — reads only immutable state, so it's a pure, testable scan.
    nonisolated func staleFiles(now: Date = Date()) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }

        return items.filter { url in
            guard url.lastPathComponent != Self.archiveFolderName,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return now.timeIntervalSince(modified) >= archiveAfter
        }
    }

    private func archiveDestination(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let month = formatter.string(from: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date())
        let folder = root.appendingPathComponent(Self.archiveFolderName, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
        return DestinationResolver.collisionSafe(for: url.lastPathComponent, in: folder)
    }

    public func approve(_ requestID: UUID) async {
        guard let job = pending.removeValue(forKey: requestID) else { return }
        await perform(source: job.source, destination: job.destination)
    }

    public func reject(_ requestID: UUID) async {
        guard pending.removeValue(forKey: requestID) != nil else { return }
    }

    private func perform(source: URL, destination: URL) async {
        do {
            let entry = try await fileService.move(from: source, to: destination, agentID: descriptor.id)
            archivedCount += 1
            await bus?.publish(.operationJournaled(entry))
            await report(task: "monitoring Desktop", last: "archived \(source.lastPathComponent)")
        } catch {
            await report(task: "monitoring Desktop", last: "failed: \(error)")
        }
    }

    public var archived: Int { archivedCount }

    private func report(task: String?, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id, state: state, currentTask: task, lastAction: last)))
    }
}
