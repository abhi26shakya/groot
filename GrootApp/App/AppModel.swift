import SwiftUI
import Observation
import GrootKit

/// The single MainActor-bound view model. Owns the whole runtime, wires the
/// agents together, and exposes plain `@Observable` state the SwiftUI views and
/// the floating bubble panel render.
@MainActor
@Observable
final class AppModel {
    // MARK: Published UI state
    private(set) var agents: [AgentManager.AgentSummary] = []
    private(set) var activity: [JournalEntry] = []
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var duplicateReport: DuplicateReport?
    private(set) var storageReport: StorageReport?
    var uptime: TimeInterval = 0
    var isRunning = false
    var isScanning = false
    var hasFullDiskAccess = false
    var showBubbles = true

    // Derived stats for the dashboard tiles.
    var runningCount: Int { agents.filter { $0.report.state == .running }.count }
    var filesOrganized: Int { activity.filter { $0.revertedAt == nil && $0.kind != .trash }.count }
    var storageRecovered: String {
        let bytes = activity
            .filter { $0.kind == .trash && $0.revertedAt == nil }
            .count
        // Recovered space is surfaced from the last duplicate report when available.
        if let recoverable = duplicateReport?.totalRecoverableBytes, bytes == 0 {
            return ByteFormat.string(recoverable) + " avail."
        }
        return bytes == 0 ? "—" : "\(bytes) items"
    }

    // MARK: Runtime (actors — reached via await)
    private var bus: MessageBus?
    private var manager: AgentManager?
    private var fileService: FileService?
    /// Agents that raise approvals, keyed by id so the UI can route decisions
    /// without knowing concrete types.
    private var approvingAgents: [AgentID: any ApprovingAgent] = [:]

    private var tickTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var bubblePanel: BubblePanelController?

    private var started = false

    // MARK: Bootstrap

    func bootstrap() async {
        guard !started else { return }
        started = true

        hasFullDiskAccess = Self.checkFullDiskAccess()

        let bus = MessageBus()
        let manager = AgentManager(bus: bus)

        // Persistence: durable SQLite, falling back to in-memory if it can't open.
        let store: JournalStore = (try? SQLiteJournalStore()) ?? InMemoryJournalStore()
        let fileService = FileService(store: store)

        // Agents.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop")
        let downloads = home.appendingPathComponent("Downloads")

        let monitor = FileMonitoringAgent(roots: [desktop, downloads])
        let screenshot = ScreenshotAgent(
            recognizer: VisionOCR(),
            suggester: HeuristicFilenameSuggester(),
            fileService: fileService,
            autonomy: .approval)
        let downloadsOrganizer = DownloadsOrganizerAgent(
            root: downloads, fileService: fileService, autonomy: .approval)
        let desktopCleaner = DesktopCleanerAgent(
            root: desktop, fileService: fileService, autonomy: .approval)
        let duplicates = DuplicateDetectionAgent(
            roots: [desktop, downloads], fileService: fileService, autonomy: .approval)
        let storage = StorageAnalyzerAgent(roots: [desktop, downloads])

        let allAgents: [any Agent] = [
            monitor, screenshot, downloadsOrganizer, desktopCleaner, duplicates, storage
        ]
        for agent in allAgents { await manager.register(agent) }
        await manager.startEventPump()

        // Index the approving agents for UI-driven approve/reject routing.
        for case let approver as any ApprovingAgent in allAgents {
            approvingAgents[approver.id] = approver
        }

        self.bus = bus
        self.manager = manager
        self.fileService = fileService

        startTicking(bus: bus)
        startPolling()
        startApprovalListener(bus: bus)

        if showBubbles { presentBubbles() }
    }

    // MARK: Scans (intent-driven)

    func scanDuplicates() async {
        isScanning = true
        await bus?.publish(.command(.scanDuplicates))
    }

    func analyzeStorage() async {
        isScanning = true
        await bus?.publish(.command(.analyzeStorage))
    }

    func organizeDesktop() async {
        await bus?.publish(.command(.organizeDesktop))
    }

    // MARK: Global controls

    func startAll() async {
        await manager?.startAll()
        isRunning = true
        await refresh()
    }

    func pauseAll() async {
        await manager?.pauseAll()
        isRunning = false
        await refresh()
    }

    func toggleRunning() async {
        if isRunning { await pauseAll() } else { await startAll() }
    }

    // MARK: Approvals

    func approve(_ request: ApprovalRequest) async {
        await approvingAgents[request.agentID]?.approve(request.id)
        pendingApprovals.removeAll { $0.id == request.id }
        await refresh()
    }

    func reject(_ request: ApprovalRequest) async {
        await approvingAgents[request.agentID]?.reject(request.id)
        pendingApprovals.removeAll { $0.id == request.id }
    }

    func approveAll() async {
        let requests = pendingApprovals
        for request in requests { await approve(request) }
    }

    // MARK: Undo

    func undo(_ entry: JournalEntry) async {
        try? await fileService?.undo(entry.id)
        await refresh()
    }

    // MARK: Bubbles

    func presentBubbles() {
        if bubblePanel == nil { bubblePanel = BubblePanelController(model: self) }
        bubblePanel?.show()
    }

    func hideBubbles() { bubblePanel?.hide() }

    // MARK: Internal loops

    private func startTicking(bus: MessageBus) {
        tickTask = Task {
            while !Task.isCancelled {
                await bus.publish(.tick(Date()))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func startApprovalListener(bus: MessageBus) {
        approvalTask = Task { [weak self] in
            let stream = await bus.subscribe()
            for await event in stream {
                switch event {
                case .approvalRequested(let request):
                    await MainActor.run {
                        guard let self else { return }
                        if !self.pendingApprovals.contains(where: { $0.id == request.id }) {
                            self.pendingApprovals.append(request)
                        }
                    }
                case .duplicatesFound(let report):
                    await MainActor.run { self?.duplicateReport = report; self?.isScanning = false }
                case .storageAnalyzed(let report):
                    await MainActor.run { self?.storageReport = report; self?.isScanning = false }
                default:
                    break
                }
            }
        }
    }

    private func refresh() async {
        guard let manager else { return }
        let snap = await manager.snapshot()
        self.agents = snap.agents
        self.uptime = snap.uptime
        if let history = try? await fileService?.history() {
            self.activity = history
        }
    }

    // MARK: Full Disk Access probe

    /// Best-effort: FDA lets us read the TCC database. If readable, it's granted.
    static func checkFullDiskAccess() -> Bool {
        let probe = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
            .expandingTildeInPath
        return FileManager.default.isReadableFile(atPath: probe)
    }

    /// Open System Settings at the Full Disk Access pane.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func recheckFullDiskAccess() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
    }
}
