import Foundation

/// A single file with its size, produced by the scanner and analyzer.
public struct FileEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: UInt64
    public let modified: Date

    public init(path: String, sizeBytes: UInt64, modified: Date) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// A set of byte-identical files. The first path is treated as the original
/// (the oldest); the rest are the removable duplicates.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let contentHash: String
    /// Sorted oldest-first; `paths[0]` is the keeper.
    public let paths: [String]
    public let perFileBytes: UInt64

    public init(id: UUID = UUID(), contentHash: String, paths: [String], perFileBytes: UInt64) {
        self.id = id
        self.contentHash = contentHash
        self.paths = paths
        self.perFileBytes = perFileBytes
    }

    public var original: String? { paths.first }
    public var duplicates: [String] { Array(paths.dropFirst()) }
    public var recoverableBytes: UInt64 { UInt64(duplicates.count) * perFileBytes }
}

/// Result of a duplicate scan.
public struct DuplicateReport: Sendable, Hashable {
    public let groups: [DuplicateGroup]
    public let scannedAt: Date

    public init(groups: [DuplicateGroup], scannedAt: Date = Date()) {
        self.groups = groups
        self.scannedAt = scannedAt
    }

    public var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicates.count } }
    public var totalRecoverableBytes: UInt64 { groups.reduce(0) { $0 + $1.recoverableBytes } }
}

/// A plain-language storage recommendation ("Downloads has 3.2 GB of installers").
public struct StorageInsight: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let reclaimableBytes: UInt64

    public init(id: UUID = UUID(), title: String, detail: String, reclaimableBytes: UInt64) {
        self.id = id
        self.title = title
        self.detail = detail
        self.reclaimableBytes = reclaimableBytes
    }
}

/// Result of a storage analysis.
public struct StorageReport: Sendable, Hashable {
    public let largestFiles: [FileEntry]
    public let insights: [StorageInsight]
    public let totalScannedBytes: UInt64
    public let analyzedAt: Date

    public init(largestFiles: [FileEntry], insights: [StorageInsight],
                totalScannedBytes: UInt64, analyzedAt: Date = Date()) {
        self.largestFiles = largestFiles
        self.insights = insights
        self.totalScannedBytes = totalScannedBytes
        self.analyzedAt = analyzedAt
    }
}

/// What the Large File Manager does with a file at/above its threshold.
public enum LargeFileAction: String, Sendable, Hashable, Codable {
    /// Move into a dated `Large Files/<YYYY-MM>/` folder — reversible.
    case archive
    /// Move to the Trash — destructive, always approval-gated regardless of
    /// autonomy (see `FileOperationKind.isDestructive`).
    case trash
}

public extension LargeFileAction {
    var operationKind: FileOperationKind {
        switch self {
        case .archive: return .move
        case .trash: return .trash
        }
    }
}

/// Result of a large-file scan.
public struct LargeFileReport: Sendable, Hashable {
    /// Files at/above the threshold, largest first.
    public let entries: [FileEntry]
    public let thresholdBytes: UInt64
    public let scannedAt: Date

    public init(entries: [FileEntry], thresholdBytes: UInt64, scannedAt: Date = Date()) {
        self.entries = entries
        self.thresholdBytes = thresholdBytes
        self.scannedAt = scannedAt
    }

    public var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.sizeBytes } }
}

/// Result of an empty-folder scan.
public struct EmptyFolderReport: Sendable, Hashable {
    /// Top-level empty folders — nested empty subfolders are collapsed into
    /// their outermost empty ancestor, since trashing it removes the whole
    /// (empty) subtree.
    public let paths: [String]
    public let scannedAt: Date

    public init(paths: [String], scannedAt: Date = Date()) {
        self.paths = paths
        self.scannedAt = scannedAt
    }
}

/// Shared byte formatting for UI and log messages.
public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
