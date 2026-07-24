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
    /// The single safety gate. The UI resolves every decision here and never
    /// needs to know which concrete agent raised the request.
    private var approvals: ApprovalService?
    /// Durable user configuration — roots, per-agent autonomy, AI consent.
    private var settings: SettingsStore?
    /// Surfaces approvals raised while the app isn't in front.
    private let notifier: any Notifying = UserNotifier()

    private var pollTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var bubblePanel: BubblePanelController?

    private var started = false

    // MARK: Bootstrap

    func bootstrap() async {
        guard !started else { return }
        started = true

        hasFullDiskAccess = Self.checkFullDiskAccess()

        // All wiring lives in `RuntimeComposer` (GrootKit) so it can be tested
        // headlessly. This view model just holds the result and renders it.
        let runtime = await RuntimeComposer.compose()

        self.bus = runtime.bus
        self.manager = runtime.manager
        self.fileService = runtime.fileService
        self.approvals = runtime.approvals
        self.settings = runtime.settings
        if let settings = runtime.settings {
            showBubbles = await settings.showBubbles()
        }

        // Ask once for permission to surface approvals raised in the background —
        // agents now wait on them, so an unnoticed prompt blocks real work.
        _ = await notifier.requestAuthorization()

        // The runtime owns its own clock now — the UI no longer drives it.
        await runtime.manager.startClock()
        startPolling()
        startApprovalListener(bus: runtime.bus)

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
        await approvals?.approve(request.id)
        pendingApprovals.removeAll { $0.id == request.id }
        await refresh()
    }

    func reject(_ request: ApprovalRequest) async {
        await approvals?.reject(request.id)
        pendingApprovals.removeAll { $0.id == request.id }
    }

    func approveAll() async {
        let requests = pendingApprovals
        for request in requests { await approve(request) }
    }

    // MARK: Settings

    /// Change an agent's autonomy and remember it across launches.
    func setAutonomy(_ mode: AutonomyMode, for id: AgentID) async {
        await settings?.setAutonomy(mode, for: id)
        if let agent = await manager?.agent(id) {
            await agent.setAutonomy(mode)
        }
        await refresh()
    }

    func setWatchedRoots(_ roots: [URL]) async {
        await settings?.setWatchedRoots(roots)
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

    /// Uptime is the only thing that changes without an event, so it's the only
    /// thing still polled — and at 2 s instead of the old 0.5 s whole-snapshot
    /// poll. Everything else updates when the runtime says something happened.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func startApprovalListener(bus: MessageBus) {
        approvalTask = Task { [weak self] in
            let stream = await bus.subscribe()
            for await event in stream {
                switch event {
                case .approvalRequested(let request):
                    let isNew = await MainActor.run {
                        guard let self else { return false }
                        guard !self.pendingApprovals.contains(where: { $0.id == request.id }) else {
                            return false
                        }
                        self.pendingApprovals.append(request)
                        return !NSApplication.shared.isActive
                    }
                    if isNew, let notifier = await self?.notifier {
                        await notifier.notifyApprovalRequested(request)
                    }
                case .agentReport, .agentFailed, .operationJournaled:
                    // Event-driven: refresh when the runtime actually reports
                    // something, rather than re-reading a snapshot twice a second.
                    await self?.scheduleRefresh()
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

    /// Coalesce bursts into one refresh. A bulk operation (a duplicate sweep
    /// trashing 200 files) publishes an event per file; without this, each one
    /// would trigger a full snapshot and a `SELECT *` over the journal.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.refreshTask = nil
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let manager else { return }
        let snap = await manager.snapshot()
        self.agents = snap.agents
        self.uptime = snap.uptime
        await refreshActivity()
    }

    /// Just the journal — cheap enough to run on every journaled operation.
    private func refreshActivity() async {
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
