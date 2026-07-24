import Foundation

/// Watches for new screenshots, reads their text with OCR, proposes an
/// intelligent filename, and (depending on autonomy) files them into
/// `~/Pictures/Screenshots/<YYYY-MM>/`.
///
/// Renaming a screenshot is reversible and non-destructive, so under
/// `.autopilot` it acts immediately; under `.approval` it asks first; under
/// `.preview` it only proposes.
public actor ScreenshotAgent: CoreAgent {
    public nonisolated let descriptor: AgentDescriptor
    public var core: AgentCore
    public var autonomy: AutonomyMode

    private let recognizer: TextRecognizing
    private let suggester: FilenameSuggester
    private let fileService: FileService
    /// The safety gate. Injected, so tests can supply one with a short timeout.
    private let approvals: ApprovalService?
    private let screenshotsRoot: URL

    private var organizedCount = 0

    public init(
        recognizer: TextRecognizing,
        suggester: FilenameSuggester,
        fileService: FileService,
        approvals: ApprovalService? = nil,
        screenshotsRoot: URL? = nil,
        autonomy: AutonomyMode = .approval,
        id: AgentID = "screenshot",
        name: String = "Screenshots",
        colorHex: String = "#F59E0B",
        symbol: String = "camera.viewfinder"
    ) {
        self.recognizer = recognizer
        self.suggester = suggester
        self.fileService = fileService
        self.approvals = approvals
        self.screenshotsRoot = screenshotsRoot
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screenshots", isDirectory: true)
        self.autonomy = autonomy
        let descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
        self.descriptor = descriptor
        self.core = AgentCore(descriptor: descriptor, idleTask: "idle")
    }


    // MARK: Lifecycle

    // Lifecycle, `attach` and `state` come from the `CoreAgent` extension.

    // MARK: Events

    public func handle(_ event: BusEvent) async {
        guard core.isRunning else { return }
        guard case .fileCreated(let url) = event, Self.isScreenshot(url) else { return }
        await process(url)
    }

    /// The core pipeline: OCR → suggest name → act per autonomy mode.
    private func process(_ url: URL) async {
        await core.report(task: "reading \(url.lastPathComponent)", last: nil)

        let ocrText = (try? await recognizer.recognizeText(in: url)) ?? ""
        let base = await suggester.suggest(ocrText: ocrText, original: url)
        let destination = Self.collisionSafeURL(
            base: base,
            ext: url.pathExtension.isEmpty ? "png" : url.pathExtension,
            in: monthFolder(for: Date()))

        // Renaming is reversible, so `.autopilot` proceeds without asking — but
        // the decision is `ApprovalService`'s to make, never the agent's.
        let request = ApprovalRequest(
            agentID: descriptor.id,
            summary: "Rename screenshot to “\(destination.lastPathComponent)”",
            detail: "Move into \(destination.deletingLastPathComponent().path)",
            itemCount: 1,
            bytesAffected: fileSize(url),
            isDestructive: FileOperationKind.rename.isDestructive)

        switch await decide(request) {
        case .proceed:
            await perform(source: url, destination: destination)
        case .previewOnly:
            await core.report(task: nil, last: "proposed → \(destination.lastPathComponent)")
        case .declined:
            await core.report(task: "idle", last: "skipped \(url.lastPathComponent)")
        }
    }

    private func decide(_ request: ApprovalRequest) async -> ApprovalOutcome {
        await ApprovalService.evaluate(request, autonomy: autonomy, using: approvals)
    }

    /// The actual reversible rename, shared by autopilot and post-approval paths.
    private func perform(source: URL, destination: URL) async {
        do {
            let entry = try await fileService.move(
                from: source, to: destination, agentID: descriptor.id, kind: .rename)
            organizedCount += 1
            // Tell the File Monitor this write was ours (loop guard).
            await core.journaled(entry)
            await core.report(task: "idle", last: "renamed → \(destination.lastPathComponent)")
        } catch {
            await core.fail("rename failed: \(error)", userFacing: "could not rename \(source.lastPathComponent)")
        }
    }

    // MARK: Pure helpers (unit-tested)

    /// Heuristic screenshot detection: a `.png` whose name looks like a macOS
    /// screenshot. Refined later with `kMDItemIsScreenCapture` metadata.
    public static func isScreenshot(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "png" else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("screenshot")
            || name.hasPrefix("screen shot")
            || name.contains("cleanshot")
    }

    /// Append " 2", " 3"… until the path is free, so we never clobber.
    static func collisionSafeURL(base: String, ext: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let safeBase = base.isEmpty ? "Screenshot" : base
        var candidate = folder.appendingPathComponent(safeBase).appendingPathExtension(ext)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safeBase) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    private func monthFolder(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return screenshotsRoot.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }

    /// Exposed for tests/diagnostics.
    public var organized: Int { organizedCount }

}
