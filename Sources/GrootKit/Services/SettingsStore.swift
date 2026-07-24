import Foundation

/// Everything the user configures that must outlive a launch: which folders are
/// watched, how much autonomy each agent has, and whether AI may leave the
/// machine.
///
/// Before this existed, `AppModel.bootstrap()` hardcoded the roots and set every
/// agent to `.approval` on every launch, so changing a mode in the dashboard was
/// forgotten the moment the app quit.
///
/// A thin typed façade over the `settings` and `agent_state` tables — all
/// connection handling lives in `GrootDatabase`.
public actor SettingsStore {
    private let db: GrootDatabase

    public init(database: GrootDatabase) {
        self.db = database
    }

    // MARK: Keys

    private enum Key {
        static let watchedRoots = "watched_roots"
        static let ollamaEnabled = "ollama_enabled"
        static let ollamaModel = "ollama_model"
        static let cloudConsent = "cloud_consent"
        static let showBubbles = "show_bubbles"
        static let customCategories = "custom_categories"
        static let categorizationThreshold = "categorization_threshold"
        static let categorizationFallback = "categorization_fallback"
    }

    // MARK: Raw key/value access

    public func string(_ key: String) async -> String? {
        let rows = (try? await db.query(
            "SELECT value FROM settings WHERE key = ?;", [.text(key)])) ?? []
        return rows.first?.string(0)
    }

    public func setString(_ value: String, for key: String) async {
        try? await db.execute("""
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, [.text(key), .text(value)])
    }

    public func bool(_ key: String, default fallback: Bool) async -> Bool {
        guard let raw = await string(key) else { return fallback }
        return raw == "1" || raw.lowercased() == "true"
    }

    public func setBool(_ value: Bool, for key: String) async {
        await setString(value ? "1" : "0", for: key)
    }

    // MARK: Watched roots

    /// Folders the File Monitoring Agent watches. Defaults to Desktop +
    /// Downloads, matching the behaviour before settings were persisted.
    public func watchedRoots() async -> [URL] {
        guard let raw = await string(Key.watchedRoots), !raw.isEmpty else {
            return Self.defaultRoots()
        }
        let roots = raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        return roots.isEmpty ? Self.defaultRoots() : roots
    }

    public func setWatchedRoots(_ roots: [URL]) async {
        await setString(roots.map(\.path).joined(separator: "\n"), for: Key.watchedRoots)
    }

    public nonisolated static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Downloads")]
    }

    // MARK: Per-agent autonomy

    /// The agent's saved mode, or `fallback` if it has never been set.
    ///
    /// Note this only controls how much the agent may do on its own —
    /// `ApprovalPolicy` still refuses to let any mode perform destructive work
    /// unattended.
    public func autonomy(for id: AgentID, default fallback: AutonomyMode = .approval) async -> AutonomyMode {
        let rows = (try? await db.query(
            "SELECT autonomy FROM agent_state WHERE agent_id = ?;", [.text(id.raw)])) ?? []
        guard let raw = rows.first?.string(0), let mode = AutonomyMode(rawValue: raw) else {
            return fallback
        }
        return mode
    }

    public func setAutonomy(_ mode: AutonomyMode, for id: AgentID) async {
        try? await db.execute("""
        INSERT INTO agent_state (agent_id, autonomy, enabled) VALUES (?, ?, 1)
        ON CONFLICT(agent_id) DO UPDATE SET autonomy = excluded.autonomy;
        """, [.text(id.raw), .text(mode.rawValue)])
    }

    public func isEnabled(_ id: AgentID, default fallback: Bool = true) async -> Bool {
        let rows = (try? await db.query(
            "SELECT enabled FROM agent_state WHERE agent_id = ?;", [.text(id.raw)])) ?? []
        return rows.first?.bool(0) ?? fallback
    }

    public func setEnabled(_ enabled: Bool, for id: AgentID) async {
        try? await db.execute("""
        INSERT INTO agent_state (agent_id, autonomy, enabled) VALUES (?, ?, ?)
        ON CONFLICT(agent_id) DO UPDATE SET enabled = excluded.enabled;
        """, [.text(id.raw), .text(AutonomyMode.approval.rawValue), .bool(enabled)])
    }

    /// Persist an agent's last known lifecycle state, for diagnostics.
    public func recordState(_ state: AgentState, for id: AgentID) async {
        try? await db.execute("""
        INSERT INTO agent_state (agent_id, autonomy, enabled, last_state) VALUES (?, ?, 1, ?)
        ON CONFLICT(agent_id) DO UPDATE SET last_state = excluded.last_state;
        """, [.text(id.raw), .text(AutonomyMode.approval.rawValue), .text(state.rawValue)])
    }

    // MARK: AI

    public func ollamaEnabled() async -> Bool { await bool(Key.ollamaEnabled, default: false) }
    public func setOllamaEnabled(_ value: Bool) async { await setBool(value, for: Key.ollamaEnabled) }

    public func ollamaModel() async -> String { await string(Key.ollamaModel) ?? "llama3.1" }
    public func setOllamaModel(_ value: String) async { await setString(value, for: Key.ollamaModel) }

    /// Whether the user has agreed to let file content reach a cloud model.
    /// Defaults to **false** — local-first is the product promise, so cloud use
    /// is opt-in and nothing may assume consent.
    public func cloudConsent() async -> Bool { await bool(Key.cloudConsent, default: false) }
    public func setCloudConsent(_ value: Bool) async { await setBool(value, for: Key.cloudConsent) }

    // MARK: Categorization

    /// User-defined content categories, on top of `CategoryCatalog.builtInNames`.
    /// Stored as a JSON array under a single settings key.
    public func customCategories() async -> [CustomCategory] {
        guard let raw = await string(Key.customCategories),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CustomCategory].self, from: data) else {
            return []
        }
        return decoded
    }

    public func setCustomCategories(_ categories: [CustomCategory]) async {
        guard let data = try? JSONEncoder().encode(categories),
              let json = String(data: data, encoding: .utf8) else { return }
        await setString(json, for: Key.customCategories)
    }

    /// Confidence below which the Categorizer treats the model as "don't know".
    public func categorizationThreshold() async -> Double {
        guard let raw = await string(Key.categorizationThreshold), let value = Double(raw) else {
            return 0.6
        }
        return value
    }

    public func setCategorizationThreshold(_ value: Double) async {
        await setString(String(value), for: Key.categorizationThreshold)
    }

    /// Whether the Categorizer falls back to extension-based buckets when the
    /// model is unavailable or undecided. Defaults to **true**.
    public func categorizationExtensionFallback() async -> Bool {
        await bool(Key.categorizationFallback, default: true)
    }

    public func setCategorizationExtensionFallback(_ value: Bool) async {
        await setBool(value, for: Key.categorizationFallback)
    }

    // MARK: UI

    public func showBubbles() async -> Bool { await bool(Key.showBubbles, default: true) }
    public func setShowBubbles(_ value: Bool) async { await setBool(value, for: Key.showBubbles) }
}
