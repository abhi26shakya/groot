import Foundation

/// Keeps the Desktop tidy by archiving loose top-level files that haven't been
/// touched in a while into `Desktop/Archive/<YYYY-MM>/`.
///
/// Runs on the `.organizeDesktop` intent and on a throttled `.tick` (at most
/// once per `minInterval`) so it doesn't rescan every second. Archiving is a
/// reversible move → `.autopilot` acts; other modes preview/approve per file.
public actor DesktopCleanerAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let root: URL
    private let fileService: FileService
    /// The safety gate — decides proceed/propose/ask on the agent's behalf.
    private let approvals: ApprovalService?
    private let archiveAfter: TimeInterval
    private let minInterval: TimeInterval
    private var lastRun: Date = .distantPast
    private var archivedCount = 0

    private static let archiveFolderName = "Archive"

    public init(
        root: URL,
        fileService: FileService,
        approvals: ApprovalService? = nil,
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
        self.approvals = approvals
        self.archiveAfter = archiveAfterDays * 86_400
        self.minInterval = minInterval
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "monitoring Desktop")
    }

    /// This agent sweeps on a timer (throttled to `minInterval`), so it opts
    /// into the runtime clock. Most agents are purely event-driven.
    public nonisolated var tickCadence: TickCadence { .every(1.0) }


    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
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
            if force { await core.report(task: "monitoring Desktop", last: "nothing to archive") }
            return
        }
        await core.report(task: "archiving \(stale.count) file(s)", last: nil)

        for url in stale {
            let destination = archiveDestination(for: url)
            let request = ApprovalRequest(
                agentID: descriptor.id,
                summary: "Archive \(url.lastPathComponent)",
                detail: "Not modified in \(Int(archiveAfter / 86_400)) days",
                itemCount: 1, bytesAffected: 0,
                isDestructive: FileOperationKind.move.isDestructive)

            switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
            case .proceed:
                await perform(source: url, destination: destination)
            case .previewOnly:
                await core.report(task: nil, last: "would archive \(url.lastPathComponent)")
            case .declined:
                await core.report(task: "monitoring Desktop", last: "kept \(url.lastPathComponent)")
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

    private func perform(source: URL, destination: URL) async {
        do {
            let entry = try await fileService.move(from: source, to: destination, agentID: descriptor.id)
            archivedCount += 1
            await core.journaled(entry)
            await core.report(task: "monitoring Desktop", last: "archived \(source.lastPathComponent)")
        } catch {
            await core.fail("archive failed: \(error)", userFacing: "could not archive \(source.lastPathComponent)")
        }
    }

    public var archived: Int { archivedCount }

}
