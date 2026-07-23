import Foundation

/// Analyzes storage across a set of roots and produces plain-language
/// recommendations ("Downloads contains 3.2 GB of installers") plus a
/// largest-files list — not just raw numbers. Read-only: it never moves or
/// deletes anything, it only reports.
public actor StorageAnalyzerAgent: Agent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private let roots: [URL]
    private let scanner: FileScanner
    private var bus: MessageBus?

    /// Files at/above this size are called out individually.
    private let largeFileThreshold: UInt64 = 500 * 1024 * 1024 // 500 MB

    public init(
        roots: [URL],
        autonomy: AutonomyMode = .preview,
        id: AgentID = "storage-analyzer",
        name: String = "Storage",
        colorHex: String = "#06B6D4",
        symbol: String = "chart.pie"
    ) {
        self.roots = roots
        self.scanner = FileScanner()
        self.autonomy = autonomy
        self.descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
    }

    public func attach(to bus: MessageBus) async { self.bus = bus }

    public func start() async { state = .running; await report(task: "idle", last: "started") }
    public func pause() async { guard state == .running else { return }; state = .paused; await report(task: nil, last: "paused") }
    public func resume() async { guard state == .paused else { return }; state = .running; await report(task: "idle", last: "resumed") }
    public func stop() async { state = .stopped; await report(task: nil, last: "stopped") }

    public func handle(_ event: BusEvent) async {
        guard state == .running else { return }
        if case .command(.analyzeStorage) = event { await analyze() }
    }

    public func analyze() async {
        await report(task: "analyzing storage…", last: nil)
        let files = scanner.scan(roots: roots)
        let storageReport = Self.buildReport(files, largeFileThreshold: largeFileThreshold)
        await bus?.publish(.storageAnalyzed(storageReport))
        await report(task: "idle",
                     last: "analyzed \(ByteFormat.string(storageReport.totalScannedBytes)) across \(files.count) files")
    }

    // MARK: Pure analysis (unit-tested)

    public static func buildReport(_ files: [FileEntry], largeFileThreshold: UInt64) -> StorageReport {
        let total = files.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let largest = files.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(15).map { $0 }

        var insights: [StorageInsight] = []

        // Per-category totals → highlight the heaviest reclaimable categories.
        var byCategory: [FileCategory: UInt64] = [:]
        for f in files {
            byCategory[FileCategory.forURL(URL(fileURLWithPath: f.path)), default: 0] += f.sizeBytes
        }
        if let installers = byCategory[.installers], installers > 0 {
            insights.append(StorageInsight(
                title: "Old installers",
                detail: "Installers (.dmg/.pkg) take up \(ByteFormat.string(installers)). "
                      + "These are usually safe to remove after installing.",
                reclaimableBytes: installers))
        }
        if let archives = byCategory[.archives], archives > 0 {
            insights.append(StorageInsight(
                title: "Archives",
                detail: "Compressed archives take up \(ByteFormat.string(archives)).",
                reclaimableBytes: archives))
        }

        // Very large individual files.
        let bigFiles = files.filter { $0.sizeBytes >= largeFileThreshold }
        if !bigFiles.isEmpty {
            let bigTotal = bigFiles.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            insights.append(StorageInsight(
                title: "\(bigFiles.count) large file(s)",
                detail: "\(bigFiles.count) files over \(ByteFormat.string(largeFileThreshold)) "
                      + "total \(ByteFormat.string(bigTotal)). Consider compressing or archiving.",
                reclaimableBytes: bigTotal))
        }

        return StorageReport(
            largestFiles: Array(largest),
            insights: insights.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
            totalScannedBytes: total)
    }

    private func report(task: String?, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id, state: state, currentTask: task, lastAction: last)))
    }
}
