import Foundation

/// Reports the most recent successful backup, so the Trash Manager can warn
/// the user before permanently deleting anything if none exists or it's
/// stale. Kept as a protocol — like `TextRecognizing` — so tests inject a
/// stub: shelling out to `tmutil` doesn't work deterministically headlessly
/// or in CI, and the real answer depends on the host machine's setup.
public protocol BackupChecking: Sendable {
    /// The most recent backup's completion date, or `nil` if unknown/none
    /// (Time Machine never configured, no destination reachable, etc.).
    func latestBackupDate() async -> Date?
}

/// Production implementation: asks Time Machine via `tmutil latestbackup`.
/// Never throws — any failure (no destination configured, tool missing,
/// sandboxed) degrades to `nil`, which callers treat as "no backup available"
/// rather than crashing or blocking.
public struct TimeMachineBackupChecker: BackupChecking {
    public init() {}

    public func latestBackupDate() async -> Date? {
        guard let output = Self.run("/usr/bin/tmutil", ["latestbackup"]) else { return nil }
        return Self.parseBackupDate(from: output)
    }

    /// `tmutil latestbackup` prints a path like
    /// `/Volumes/Backup/Backups.backupdb/Mac/2026-07-24-120000`. Pull the
    /// trailing `yyyy-MM-dd-HHmmss` path component out and parse it.
    static func parseBackupDate(from output: String) -> Date? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "/").last else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: String(last))
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
