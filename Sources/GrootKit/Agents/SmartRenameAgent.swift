import Foundation

/// Generalizes `ScreenshotAgent`'s rename pipeline to any file type: reads a
/// bounded content excerpt via `ContentExtractor`, asks a `FilenameSuggester`
/// for a descriptive name, and renames the file **in place** through the
/// standard safety gate.
///
/// Screenshots stay `ScreenshotAgent`'s job — they have no real name to
/// preserve and get relocated into a dated folder, a different operation from
/// a generic in-place rename — so this agent explicitly excludes anything
/// `ScreenshotAgent.isScreenshot` would claim. It only ever issues `.rename`,
/// so destructive operations are structurally impossible.
///
/// Renaming and categorization (`CategorizationAgent`) both react to the same
/// `.fileCreated` event with no locking between them — exactly how
/// `CategorizationAgent`/`DownloadsOrganizerAgent` already coexist via
/// disjoint claims rather than sequencing. If categorization wins the race,
/// this agent's rename attempt fails harmlessly on the now-moved source
/// (`FileService`'s source-missing guard); if this agent wins, its rename is
/// journaled and it explicitly re-publishes `.fileCreated(destination)` so
/// categorization (and anyone else) sees the renamed file — necessary because
/// the File Monitor's loop guard would otherwise suppress that path for
/// everyone, not just this agent, for its 5s window.
public actor SmartRenameAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    /// Folders whose new files we consider (typically Desktop + Downloads).
    private let watchedRoots: [URL]
    /// Paths we never touch: other agents' output roots (e.g. the
    /// Categorizer's organized root, the Screenshots root).
    private let excludedRoots: [URL]
    private let fileService: FileService
    private let approvals: ApprovalService?
    private let extractor: ContentExtractor
    private let namer: FilenameSuggester
    /// `nil` means "anything `ContentExtractor` can read" (text/pdf/image).
    private let allowedExtensions: Set<String>?
    private var renamedCount = 0

    /// Partial-download / temp extensions we never touch.
    private static let skipExtensions: Set<String> = ["crdownload", "part", "download", "tmp"]

    public init(
        watchedRoots: [URL],
        excludedRoots: [URL] = [],
        fileService: FileService,
        extractor: ContentExtractor,
        namer: FilenameSuggester,
        allowedExtensions: Set<String>? = nil,
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "smart-rename",
        name: String = "Smart Rename",
        colorHex: String = "#6366F1",
        symbol: String = "textformat"
    ) {
        self.watchedRoots = watchedRoots.map(\.standardizedFileURL)
        self.excludedRoots = excludedRoots.map(\.standardizedFileURL)
        self.fileService = fileService
        self.extractor = extractor
        self.namer = namer
        self.allowedExtensions = allowedExtensions.map { Set($0.map { $0.lowercased() }) }
        self.approvals = approvals
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "reading new files")
    }

    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        guard case .fileCreated(let url) = event else { return }
        guard shouldRename(url) else { return }
        await process(url)
    }

    /// Only act on a regular, extractor-supported file living directly in a
    /// watched root, not already well-named, and never a screenshot or our own
    /// (or another agent's) output. `nonisolated` — reads only immutable
    /// state, so it's a pure, testable check (mirrors `shouldCategorize`).
    nonisolated func shouldRename(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        for excluded in excludedRoots where standardized.path.hasPrefix(excluded.path) {
            return false
        }
        let parent = standardized.deletingLastPathComponent()
        guard watchedRoots.contains(parent) else { return false }
        if url.lastPathComponent.hasPrefix(".") { return false }
        let ext = url.pathExtension.lowercased()
        if Self.skipExtensions.contains(ext) { return false }
        // Screenshots are ScreenshotAgent's job — a different operation
        // (rename + relocate), not a generic in-place rename.
        if ScreenshotAgent.isScreenshot(url) { return false }
        if ContentExtractor.strategy(for: ext) == .unsupported { return false }
        if let allowed = allowedExtensions, !allowed.contains(ext) { return false }
        if Self.looksAlreadyNamed(url) { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return !isDir.boolValue
    }

    private func process(_ url: URL) async {
        await core.report(task: "reading \(url.lastPathComponent)", last: nil)

        let excerpt = await extractor.excerpt(from: url)
        let base = await namer.suggest(ocrText: excerpt, original: url)
        let originalBase = url.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base.caseInsensitiveCompare(originalBase) != .orderedSame else {
            await core.report(task: "reading new files", last: "no signal for \(url.lastPathComponent)")
            return
        }

        let ext = url.pathExtension
        let proposedName = ext.isEmpty ? base : "\(base).\(ext)"
        let destination = DestinationResolver.collisionSafe(
            for: proposedName, in: url.deletingLastPathComponent())

        // Renaming is reversible, so `.autopilot` proceeds without asking — but
        // the decision is `ApprovalService`'s to make, never the agent's.
        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Rename \(url.lastPathComponent) to “\(destination.lastPathComponent)”",
            itemCount: 1,
            bytesAffected: fileSize(url),
            isDestructive: FileOperationKind.rename.isDestructive)

        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await perform(source: url, destination: destination)
        case .previewOnly:
            await core.report(task: nil, last: "proposed → \(destination.lastPathComponent)")
        case .declined:
            await core.report(task: "reading new files", last: "skipped \(url.lastPathComponent)")
        }
    }

    /// The actual reversible rename, shared by autopilot and post-approval paths.
    private func perform(source: URL, destination: URL) async {
        do {
            let entry = try await fileService.move(
                from: source, to: destination, agentID: descriptor.id, kind: .rename)
            renamedCount += 1
            // Tell the File Monitor this write was ours (loop guard).
            await core.journaled(entry)
            // The loop guard suppresses the destination path for everyone, so
            // re-publish ourselves — otherwise CategorizationAgent would never
            // see the renamed file.
            await core.publish(.fileCreated(destination))
            await core.report(task: "reading new files", last: "renamed → \(destination.lastPathComponent)")
        } catch {
            await core.fail("rename failed: \(error)", userFacing: "could not rename \(source.lastPathComponent)")
        }
    }

    // MARK: Pure helpers (unit-tested)

    /// Conservative "already has a real name" heuristic: placeholder names
    /// (`Untitled`, `document`, …), camera/download patterns (`IMG_1234`,
    /// `DSC_0001`), bare numeric names, and UUID-looking names are never
    /// considered already-named. Anything else with 3+ meaningful words is
    /// left alone.
    static func looksAlreadyNamed(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        let lower = name.lowercased()

        let placeholders = ["untitled", "document", "scan", "img", "image", "photo", "file", "new document"]
        for placeholder in placeholders {
            if lower == placeholder
                || lower.hasPrefix(placeholder + " ")
                || lower.hasPrefix(placeholder + "_")
                || lower.hasPrefix(placeholder + "-") {
                return false
            }
        }
        if lower.range(of: #"^[a-z]{2,5}[_-]\d{3,}$"#, options: .regularExpression) != nil { return false }
        if lower.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        if lower.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                       options: .regularExpression) != nil { return false }

        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 1 && $0.rangeOfCharacter(from: .letters) != nil }
        return words.count >= 3
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }

    /// Exposed for tests/diagnostics.
    public var renamed: Int { renamedCount }
}
