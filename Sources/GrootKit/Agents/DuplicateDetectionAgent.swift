import Foundation
import CryptoKit

/// Finds byte-identical files (SHA-256) across a set of roots, groups them, and
/// asks permission before recovering space. **Never deletes automatically** —
/// deletion is destructive, so it always routes through an `ApprovalRequest`,
/// and even then duplicates go to the Trash (recoverable), never `unlink`.
public actor DuplicateDetectionAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let roots: [URL]
    private let fileService: FileService
    private let scanner: FileScanner
    /// The safety gate. Trashing is destructive, so this agent can never act
    /// without an explicit answer — in ANY autonomy mode.
    private let approvals: ApprovalService?

    public init(
        roots: [URL],
        fileService: FileService,
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "duplicate-detector",
        name: String = "Duplicates",
        colorHex: String = "#EF4444",
        symbol: String = "square.on.square"
    ) {
        self.roots = roots
        self.fileService = fileService
        self.approvals = approvals
        self.scanner = FileScanner()
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "idle")
    }


    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        if case .command(.scanDuplicates) = event { await scan() }
    }

    /// Scan all roots, group identical files, publish a report + an approval
    /// request for reclaiming the recoverable space.
    public func scan() async {
        await core.report(task: "scanning for duplicates…", progress: nil, last: nil)
        let files = scanner.scan(roots: roots)
        let groups = Self.groupDuplicates(files)
        let reportModel = DuplicateReport(groups: groups)
        await core.publish(.duplicatesFound(reportModel))

        guard !groups.isEmpty else {
            await core.report(task: "idle", last: "no duplicates found")
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
            isDestructive: FileOperationKind.trash.isDestructive)

        await core.report(task: "idle",
                     last: "found \(reportModel.duplicateCount) dupes · \(ByteFormat.string(recoverable)) recoverable")

        // `.trash` is destructive, so `ApprovalPolicy` routes this to the user
        // even under `.autopilot`. The agent doesn't get a say.
        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await trashDuplicates(groups.flatMap(\.duplicates))
        case .previewOnly, .declined:
            await core.report(task: "idle", last: "kept all files")
        }
    }

    /// Move approved duplicates to the Trash. Originals are never touched, and
    /// nothing is `unlink`ed — items stay recoverable from the Finder Trash.
    private func trashDuplicates(_ paths: [String]) async {
        var trashed = 0
        var skipped = 0
        for path in paths {
            do {
                let entry = try await fileService.trash(URL(fileURLWithPath: path), agentID: descriptor.id)
                await core.journaled(entry)
                trashed += 1
            } catch {
                // A file that vanished or changed since the scan is expected, not
                // fatal — but it's still worth logging rather than swallowing.
                skipped += 1
                GrootLog.fileops.notice(
                    "skipped duplicate \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let summary = skipped == 0
            ? "trashed \(trashed) duplicate(s)"
            : "trashed \(trashed), skipped \(skipped) that changed since the scan"
        await core.report(task: "idle", last: summary)
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

}
