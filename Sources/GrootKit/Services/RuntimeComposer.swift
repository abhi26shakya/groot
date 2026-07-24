import Foundation

/// Everything a running Groot consists of, assembled and wired.
public struct Runtime: Sendable {
    public let bus: MessageBus
    public let manager: AgentManager
    public let fileService: FileService
    public let approvals: ApprovalService
    public let settings: SettingsStore?
    public let database: GrootDatabase?
    /// The agents that were registered, in a stable order.
    public let agentIDs: [AgentID]
}

/// Builds the whole system from persisted settings.
///
/// This wiring used to live in `AppModel.bootstrap()` inside the app target,
/// which meant the single most important piece of assembly in the project —
/// which agents exist, what they're injected with, what autonomy they start in —
/// could not be tested without launching a SwiftUI app. It's a plain composition
/// root in `GrootKit` now.
public enum RuntimeComposer {

    /// Options that don't come from persisted settings.
    public struct Options: Sendable {
        /// Where the database lives. `nil` uses the default app-support path.
        public var databaseURL: URL?
        /// Use an in-memory journal and skip persistence entirely (tests).
        public var ephemeral: Bool
        /// OCR implementation. Injected so tests avoid the Vision framework.
        public var recognizer: (any TextRecognizing)?
        /// How long an approval may sit unanswered. `nil` waits indefinitely,
        /// matching the app's current behaviour.
        public var approvalTimeout: TimeInterval?

        public init(
            databaseURL: URL? = nil,
            ephemeral: Bool = false,
            recognizer: (any TextRecognizing)? = nil,
            approvalTimeout: TimeInterval? = nil
        ) {
            self.databaseURL = databaseURL
            self.ephemeral = ephemeral
            self.recognizer = recognizer
            self.approvalTimeout = approvalTimeout
        }
    }

    /// Assemble the runtime: database → services → agents → event pump.
    ///
    /// Does **not** start the agents or the clock; the caller decides when.
    public static func compose(options: Options = Options()) async -> Runtime {
        // MARK: Persistence
        let database: GrootDatabase? = options.ephemeral
            ? nil
            : try? GrootDatabase(url: options.databaseURL)
        let store: JournalStore = database.map { SQLiteJournalStore(database: $0) }
            ?? InMemoryJournalStore()
        let settings = database.map(SettingsStore.init(database:))

        // MARK: Core services
        let bus = MessageBus()
        let manager = AgentManager(bus: bus)
        let fileService = FileService(store: store)
        let approvals = ApprovalService(
            bus: bus, database: database, timeout: options.approvalTimeout)
        // Approvals outstanding when the app last quit can't be carried out —
        // the agent-side job was in memory — so clear them rather than reviving
        // requests that would do nothing.
        let expired = await approvals.expireRestoredRequests()
        if expired > 0 {
            GrootLog.approvals.notice("discarded \(expired) approval(s) left over from a previous run")
        }

        // MARK: AI (local-first; Ollama only if the user turned it on)
        let suggester = await makeFilenameSuggester(settings: settings)

        // MARK: Agents
        let roots = await settings?.watchedRoots() ?? SettingsStore.defaultRoots()
        let desktop = roots.first { $0.lastPathComponent == "Desktop" } ?? roots[0]
        let downloads = roots.first { $0.lastPathComponent == "Downloads" } ?? roots.last ?? desktop

        func autonomy(_ id: AgentID, _ fallback: AutonomyMode) async -> AutonomyMode {
            await settings?.autonomy(for: id, default: fallback) ?? fallback
        }

        let monitor = FileMonitoringAgent(roots: roots)
        let screenshot = ScreenshotAgent(
            recognizer: options.recognizer ?? VisionOCR(),
            suggester: suggester,
            fileService: fileService,
            approvals: approvals,
            autonomy: await autonomy("screenshot", .approval))
        let downloadsOrganizer = DownloadsOrganizerAgent(
            root: downloads, fileService: fileService, approvals: approvals,
            autonomy: await autonomy("downloads-organizer", .approval))
        let desktopCleaner = DesktopCleanerAgent(
            root: desktop, fileService: fileService, approvals: approvals,
            autonomy: await autonomy("desktop-cleaner", .approval))
        let duplicates = DuplicateDetectionAgent(
            roots: roots, fileService: fileService, approvals: approvals,
            autonomy: await autonomy("duplicate-detector", .approval))
        let storage = StorageAnalyzerAgent(roots: roots)

        let categorization = CategorizationAgent(
            watchedRoots: roots,
            organizedRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Groot", isDirectory: true),
            fileService: fileService,
            provider: await makeCategorizationProvider(settings: settings),
            extractor: ContentExtractor(recognizer: options.recognizer ?? VisionOCR()),
            catalog: CategoryCatalog(custom: await settings?.customCategories() ?? []),
            threshold: await settings?.categorizationThreshold() ?? 0.6,
            extensionFallback: await settings?.categorizationExtensionFallback() ?? true,
            approvals: approvals,
            autonomy: await autonomy("categorization", .approval))

        let agents: [any Agent] = [
            monitor, screenshot, downloadsOrganizer, desktopCleaner, duplicates, storage,
            categorization
        ]
        for agent in agents { await manager.register(agent) }
        await manager.startEventPump()

        return Runtime(
            bus: bus,
            manager: manager,
            fileService: fileService,
            approvals: approvals,
            settings: settings,
            database: database,
            agentIDs: agents.map(\.id))
    }

    /// Local-first: the on-device heuristic unless the user explicitly enabled
    /// Ollama, and even then it falls back automatically when the server is down.
    static func makeFilenameSuggester(settings: SettingsStore?) async -> FilenameSuggester {
        guard let settings, await settings.ollamaEnabled() else {
            return HeuristicFilenameSuggester()
        }
        let model = await settings.ollamaModel()
        return FilenameUseCase(provider: OllamaProvider(model: model))
    }

    /// The provider the Categorizer classifies with. Local-first: the on-device
    /// heuristic (which returns nothing → the agent leaves files alone / falls
    /// back to extension buckets) unless the user enabled Ollama, and even then
    /// the chain falls back to the heuristic when the server is down.
    static func makeCategorizationProvider(settings: SettingsStore?) async -> any AIProvider {
        guard let settings, await settings.ollamaEnabled() else {
            return HeuristicProvider()
        }
        let model = await settings.ollamaModel()
        return FallbackChain([OllamaProvider(model: model), HeuristicProvider()])
    }
}
