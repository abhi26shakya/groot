import Foundation
import CryptoKit

/// Finds byte-identical files (SHA-256) across a set of roots, groups them, and
/// asks permission before recovering space. **Never deletes automatically** —
/// deletion is destructive, so it always routes through an `ApprovalRequest`,
/// and even then duplicates go to the Trash (recoverable), never `unlink`.
public actor DuplicateDetectionAgent: ApprovingAgent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private let roots: [URL]
    private let fileService: FileService
    private let scanner: FileScanner
    private var bus: MessageBus?
    private var pending: [UUID: [String]] = [:] // requestID → duplicate paths to trash

    public init(
        roots: [URL],
        fileService: FileService,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "duplicate-detector",
        name: String = "Duplicates",
        colorHex: String = "#EF4444",
        symbol: String = "square.on.square"
    ) {
        self.roots = roots
        self.fileService = fileService
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
        if case .command(.scanDuplicates) = event { await scan() }
    }

    /// Scan all roots, group identical files, publish a report + an approval
    /// request for reclaiming the recoverable space.
    public func scan() async {
        await report(task: "scanning for duplicates…", progress: nil, last: nil)
        let files = scanner.scan(roots: roots)
        let groups = Self.groupDuplicates(files)
        let reportModel = DuplicateReport(groups: groups)
        await bus?.publish(.duplicatesFound(reportModel))

        guard !groups.isEmpty else {
            await report(task: "idle", last: "no duplicates found")
            return
        }

        let recoverable = reportModel.totalRecoverableBytes
        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Found \(reportModel.duplicateCount) duplicate files",
            detail: "Deleting them will recover \(ByteFormat.string(recoverable)). "
                  + "Originals are kept; duplicates move to the Trash.",
            itemCount: reportModel.duplicateCount,
            bytesAffected: recoverable,
            isDestructive: true)
        pending[request.id] = groups.flatMap(\.duplicates)
        await bus?.publish(.approvalRequested(request))
        await report(task: "idle",
                     last: "found \(reportModel.duplicateCount) dupes · \(ByteFormat.string(recoverable)) recoverable")
    }

    public func approve(_ requestID: UUID) async {
        guard let paths = pending.removeValue(forKey: requestID) else { return }
        var trashed = 0
        for path in paths {
            do {
                let entry = try await fileService.trash(URL(fileURLWithPath: path), agentID: descriptor.id)
                await bus?.publish(.operationJournaled(entry))
                trashed += 1
            } catch {
                // Skip files that vanished/changed since the scan.
                continue
            }
        }
        await report(task: "idle", last: "trashed \(trashed) duplicate(s)")
    }

    public func reject(_ requestID: UUID) async {
        guard pending.removeValue(forKey: requestID) != nil else { return }
        await report(task: "idle", last: "kept all files")
    }

    // MARK: Pure grouping (unit-tested)

    /// Group files by content hash, returning only groups with 2+ members.
    /// Within a group, paths are sorted oldest-first so `paths[0]` is the keeper.
    /// Only files of matching size are hashed against each other (size is a cheap
    /// pre-filter that avoids hashing obviously-different files).
    public static func groupDuplicates(_ files: [FileEntry]) -> [DuplicateGroup] {
        // Pre-bucket by size; only hash within a bucket that has collisions.
        var bySize: [UInt64: [FileEntry]] = [:]
        for f in files where f.sizeBytes > 0 { bySize[f.sizeBytes, default: []].append(f) }

        var groups: [DuplicateGroup] = []
        for (size, bucket) in bySize where bucket.count > 1 {
            var byHash: [String: [FileEntry]] = [:]
            for file in bucket {
                guard let hash = sha256(ofFileAt: file.path) else { continue }
                byHash[hash, default: []].append(file)
            }
            for (hash, members) in byHash where members.count > 1 {
                let sorted = members.sorted { $0.modified < $1.modified }
                groups.append(DuplicateGroup(
                    contentHash: hash,
                    paths: sorted.map(\.path),
                    perFileBytes: size))
            }
        }
        // Largest recoverable first.
        return groups.sorted { $0.recoverableBytes > $1.recoverableBytes }
    }

    /// Streaming SHA-256 so we don't load large files fully into memory.
    static func sha256(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20) // 1 MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func report(task: String?, progress: Double? = nil, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id, state: state, currentTask: task,
            progress: progress, lastAction: last)))
    }
}
