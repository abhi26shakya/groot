import Foundation

/// Sorts new files by what they **contain** — not just their extension — into a
/// single organized root (`<organizedRoot>/<Category>/`). Reads a bounded content
/// excerpt, asks the local-first model to pick one of the allowed categories, and
/// files the result through the standard safety gate.
///
/// This is "Downloads Organizer, but categorized by content." It reuses the exact
/// same move/approval/journal machinery; the only new behaviour is
/// `ContentExtractor` + `CategorizerUseCase`. It only ever issues `.move`, so
/// destructive operations are structurally impossible.
///
/// To avoid two agents fighting over one file, it claims only the coarse
/// `FileCategory` buckets where content analysis adds value (documents, pictures)
/// and leaves installers/archives/media/audio/code to `DownloadsOrganizerAgent`.
public actor CategorizationAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    /// Folders whose new files we consider (typically Desktop + Downloads).
    private let watchedRoots: [URL]
    /// Where categorized files go: `<organizedRoot>/<Category>/`.
    private let organizedRoot: URL
    private let fileService: FileService
    private let approvals: ApprovalService?
    /// The model behind categorization. Heuristic (offline) by default; the
    /// use case is built per-file so live category/threshold changes take effect.
    private let provider: any AIProvider
    private let extractor: ContentExtractor
    private let catalog: CategoryCatalog
    private let threshold: Double
    /// When the model is unavailable/undecided, fall back to extension buckets.
    private let extensionFallback: Bool
    /// Coarse buckets this agent handles; everything else is left to the
    /// extension-based organizer.
    private let claimed: Set<FileCategory>
    private var categorizedCount = 0

    /// Partial-download / temp extensions we never touch.
    private static let skipExtensions: Set<String> = ["crdownload", "part", "download", "tmp"]

    public init(
        watchedRoots: [URL],
        organizedRoot: URL,
        fileService: FileService,
        provider: any AIProvider,
        extractor: ContentExtractor,
        catalog: CategoryCatalog = CategoryCatalog(),
        threshold: Double = 0.6,
        extensionFallback: Bool = true,
        claimed: Set<FileCategory> = [.documents, .pictures],
        approvals: ApprovalService? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "categorization",
        name: String = "Categorizer",
        colorHex: String = "#22C55E",
        symbol: String = "tag"
    ) {
        self.watchedRoots = watchedRoots.map(\.standardizedFileURL)
        self.organizedRoot = organizedRoot.standardizedFileURL
        self.fileService = fileService
        self.provider = provider
        self.extractor = extractor
        self.catalog = catalog
        self.threshold = threshold
        self.extensionFallback = extensionFallback
        self.claimed = claimed
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
        guard shouldCategorize(url) else { return }
        await process(url)
    }

    /// Only act on a regular file living directly in a watched root, of a claimed
    /// type, and never on our own output. `nonisolated` — reads only immutable
    /// state, so it's a pure, testable check (mirrors `shouldOrganize`).
    nonisolated func shouldCategorize(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        // Never re-process files we already filed.
        if standardized.path.hasPrefix(organizedRoot.path) { return false }
        // Must live directly inside one of the watched roots.
        let parent = standardized.deletingLastPathComponent()
        guard watchedRoots.contains(parent) else { return false }
        let ext = url.pathExtension.lowercased()
        if Self.skipExtensions.contains(ext) { return false }
        if url.lastPathComponent.hasPrefix(".") { return false }
        // Leave buckets we don't claim to the extension-based organizer.
        guard claimed.contains(FileCategory.forURL(url)) else { return false }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return !isDir.boolValue
    }

    private func process(_ url: URL) async {
        let excerpt = await extractor.excerpt(from: url)
        let categorizer = CategorizerUseCase(
            provider: provider,
            allowed: catalog.allowedNames,
            minimumConfidence: threshold)
        let decision = await categorizer.categorize(
            filename: url.lastPathComponent, contentExcerpt: excerpt)

        // Decide the category: model first, then optional extension fallback.
        let categoryName: String
        let reason: String?
        if let decision {
            categoryName = decision.category
            reason = decision.reason
        } else if extensionFallback {
            categoryName = FileCategory.forURL(url).folderName
            reason = "no content signal — filed by type"
        } else {
            await core.report(task: "reading new files",
                              last: "undecided about \(url.lastPathComponent)")
            return
        }

        let folder = organizedRoot.appendingPathComponent(
            catalog.folderName(for: categoryName), isDirectory: true)
        let destination = DestinationResolver.collisionSafe(
            for: url.lastPathComponent, in: folder)

        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Move \(url.lastPathComponent) to \(categoryName)",
            detail: reason, itemCount: 1, bytesAffected: 0,
            isDestructive: FileOperationKind.move.isDestructive)

        switch await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals) {
        case .proceed:
            await perform(source: url, destination: destination, category: categoryName)
        case .previewOnly:
            await core.report(task: nil,
                              last: "would file \(url.lastPathComponent) → \(categoryName)")
        case .declined:
            await core.report(task: "reading new files", last: "skipped \(url.lastPathComponent)")
        }
    }

    private func perform(source: URL, destination: URL, category: String) async {
        do {
            let entry = try await fileService.move(from: source, to: destination, agentID: descriptor.id)
            categorizedCount += 1
            await core.journaled(entry)
            await core.report(task: "reading new files",
                              last: "filed \(source.lastPathComponent) → \(category)")
        } catch {
            await core.fail("move failed: \(error)",
                            userFacing: "could not file \(source.lastPathComponent)")
        }
    }

    public var categorized: Int { categorizedCount }
}
