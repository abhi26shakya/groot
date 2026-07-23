import Foundation

/// Watches for new screenshots, reads their text with OCR, proposes an
/// intelligent filename, and (depending on autonomy) files them into
/// `~/Pictures/Screenshots/<YYYY-MM>/`.
///
/// Renaming a screenshot is reversible and non-destructive, so under
/// `.autopilot` it acts immediately; under `.approval` it asks first; under
/// `.preview` it only proposes.
public actor ScreenshotAgent: ApprovingAgent {
    public nonisolated let descriptor: AgentDescriptor
    public private(set) var state: AgentState = .idle
    public var autonomy: AutonomyMode

    private let recognizer: TextRecognizing
    private let suggester: FilenameSuggester
    private let fileService: FileService
    private let screenshotsRoot: URL

    private var bus: MessageBus?
    private var organizedCount = 0

    /// Proposals awaiting user approval, keyed by the ApprovalRequest id.
    private var pending: [UUID: (source: URL, destination: URL)] = [:]

    public init(
        recognizer: TextRecognizing,
        suggester: FilenameSuggester,
        fileService: FileService,
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
        self.screenshotsRoot = screenshotsRoot
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screenshots", isDirectory: true)
        self.autonomy = autonomy
        self.descriptor = AgentDescriptor(id: id, name: name, colorHex: colorHex, symbol: symbol)
    }

    public func attach(to bus: MessageBus) async {
        self.bus = bus
    }

    // MARK: Lifecycle

    public func start() async {
        state = .running
        await report(task: "idle", last: "started")
    }
    public func pause() async {
        guard state == .running else { return }
        state = .paused
        await report(task: nil, last: "paused")
    }
    public func resume() async {
        guard state == .paused else { return }
        state = .running
        await report(task: "idle", last: "resumed")
    }
    public func stop() async {
        state = .stopped
        await report(task: nil, last: "stopped")
    }

    // MARK: Events

    public func handle(_ event: BusEvent) async {
        guard state == .running else { return }
        guard case .fileCreated(let url) = event, Self.isScreenshot(url) else { return }
        await process(url)
    }

    /// The core pipeline: OCR → suggest name → act per autonomy mode.
    private func process(_ url: URL) async {
        await report(task: "reading \(url.lastPathComponent)", last: nil)

        let ocrText = (try? await recognizer.recognizeText(in: url)) ?? ""
        let base = await suggester.suggest(ocrText: ocrText, original: url)
        let destination = Self.collisionSafeURL(
            base: base,
            ext: url.pathExtension.isEmpty ? "png" : url.pathExtension,
            in: monthFolder(for: Date()))

        switch autonomy {
        case .preview:
            await report(task: nil,
                         last: "proposed → \(destination.lastPathComponent)")

        case .approval:
            let request = ApprovalRequest(
                agentID: descriptor.id,
                summary: "Rename screenshot to “\(destination.lastPathComponent)”",
                detail: "Move into \(destination.deletingLastPathComponent().path)",
                itemCount: 1,
                bytesAffected: fileSize(url),
                isDestructive: false)
            pending[request.id] = (url, destination)
            await bus?.publish(.approvalRequested(request))
            await report(task: nil, last: "awaiting approval for \(destination.lastPathComponent)")

        case .autopilot:
            await perform(source: url, destination: destination)
        }
    }

    /// Approve a pending proposal (invoked by the UI). Performs the move.
    public func approve(_ requestID: UUID) async {
        guard let job = pending.removeValue(forKey: requestID) else { return }
        await perform(source: job.source, destination: job.destination)
    }

    /// Reject a pending proposal — discard it, leave the file untouched.
    public func reject(_ requestID: UUID) async {
        guard let job = pending.removeValue(forKey: requestID) else { return }
        await report(task: "idle", last: "skipped \(job.source.lastPathComponent)")
    }

    /// The actual reversible rename, shared by autopilot and post-approval paths.
    private func perform(source: URL, destination: URL) async {
        do {
            let entry = try await fileService.move(
                from: source, to: destination, agentID: descriptor.id, kind: .rename)
            organizedCount += 1
            // Tell the File Monitor this write was ours (loop guard).
            await bus?.publish(.operationJournaled(entry))
            await report(task: "idle", last: "renamed → \(destination.lastPathComponent)")
        } catch {
            await report(task: "idle", last: "failed: \(error)")
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

    private func report(task: String?, last: String?) async {
        await bus?.publish(.agentReport(AgentReport(
            agentID: descriptor.id,
            state: state,
            currentTask: task,
            lastAction: last)))
    }
}
