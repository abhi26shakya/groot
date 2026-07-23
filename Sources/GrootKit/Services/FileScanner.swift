import Foundation

/// Recursively enumerates regular files under a set of roots, collecting size
/// and modification date. Shared by the Duplicate Detection and Storage Analyzer
/// agents. Skips hidden files, package contents (`.app`, `.bundle`), and symlinks.
public struct FileScanner: Sendable {
    public init() {}

    public func scan(roots: [URL]) -> [FileEntry] {
        var results: [FileEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey, .isSymbolicLinkKey]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize else { continue }
                results.append(FileEntry(
                    path: url.path,
                    sizeBytes: UInt64(size),
                    modified: values.contentModificationDate ?? .distantPast))
            }
        }
        return results
    }
}
