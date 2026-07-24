import Foundation

/// Watches a set of folders with FSEvents and republishes classified changes
/// onto the bus as `.fileCreated` / `.fileModified` / `.fileDeleted` /
/// `.fileRenamed`. Every other agent reacts to these — this is the single
/// source of filesystem signal for the whole system.
public actor FileMonitoringAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let roots: [URL]
    private let watcherLatency: CFTimeInterval
    private var watcher: FSEventsWatcher?

    private var eventsSeen = 0
    private var lastPath: String?

    /// Paths this app just wrote, kept briefly to suppress the FSEvents they
    /// trigger (the loop guard). Value is the time added, for pruning.
    private var recentlyWritten: [String: Date] = [:]
    private let selfEventWindow: TimeInterval = 5

    public init(
        roots: [URL],
        latency: CFTimeInterval = 1.0,
        id: AgentID = "file-monitor",
        name: String = "File Monitor",
        colorHex: String = "#34D399",
        symbol: String = "eye",
        autonomy: AutonomyMode = .autopilot
    ) {
        self.roots = roots
        self.watcherLatency = latency
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "watching")
        self.autonomy = autonomy
    }

    public func attach(to bus: MessageBus) async { core.attach(to: bus) }

    // MARK: Lifecycle

    public func start() async {
        guard core.state != .running else { return }
        let paths = roots.map(\.path)
        let watcher = FSEventsWatcher(paths: paths, latency: watcherLatency) { [weak self] changes in
            // Runs on the FSEvents queue; hop into the actor.
            Task { await self?.ingest(changes) }
        }
        watcher.start()
        self.watcher = watcher
        core.state = .running
        await core.report(task: "watching \(roots.count) folder(s)", last: "started")
    }

    public func pause() async {
        guard core.state == .running else { return }
        watcher?.stop()
        watcher = nil
        core.state = .paused
        await core.report(task: nil, last: "paused")
    }

    public func resume() async {
        guard core.state == .paused else { return }
        await start()
    }

    public func stop() async {
        watcher?.stop()
        watcher = nil
        core.state = .stopped
        await core.report(task: nil, last: "stopped")
    }

    // MARK: Events

    public func handle(_ event: BusEvent) async {
        // Loop guard: remember paths this app wrote so we ignore their FSEvents.
        if case .operationJournaled(let entry) = event {
            let now = Date()
            recentlyWritten[entry.sourcePath] = now
            if let dest = entry.destinationPath { recentlyWritten[dest] = now }
        }
    }

    /// Apply the loop guard, translate to bus events, and publish. Actor-isolated.
    private func ingest(_ changes: [FSChange]) async {
        guard core.state == .running else { return }
        pruneRecentlyWritten()

        for change in changes {
            if recentlyWritten[change.path] != nil { continue } // self-triggered
            let url = URL(fileURLWithPath: change.path)
            switch change.kind {
            case .created:  await core.publish(.fileCreated(url))
            case .modified: await core.publish(.fileModified(url))
            case .removed:  await core.publish(.fileDeleted(url))
            case .renamed:
                // FSEvents file-level rename gives one path per side; treat as
                // create/delete signal. Downstream agents re-check existence.
                if FileManager.default.fileExists(atPath: change.path) {
                    await core.publish(.fileCreated(url))
                } else {
                    await core.publish(.fileDeleted(url))
                }
            case .other:
                continue
            }
            eventsSeen += 1
            lastPath = change.path
        }
        await core.report(task: "watching \(roots.count) folder(s)",
                     last: lastPath.map { "saw \(($0 as NSString).lastPathComponent)" })
    }

    private func pruneRecentlyWritten() {
        let cutoff = Date().addingTimeInterval(-selfEventWindow)
        recentlyWritten = recentlyWritten.filter { $0.value > cutoff }
    }

    /// Exposed for tests/diagnostics.
    public var eventCount: Int { eventsSeen }

}
