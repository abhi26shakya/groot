import Foundation

/// The resolved answer for a proposed operation.
public enum ApprovalOutcome: Sendable, Equatable {
    /// Carry out the operation.
    case proceed
    /// The user said no (or the request timed out / was cancelled).
    case declined
    /// Preview mode — report the proposal, change nothing.
    case previewOnly
}

/// The single safety gate every agent routes mutating work through.
///
/// Agents no longer keep their own `pending` dictionaries or hand-roll the
/// autonomy `switch`: they call `evaluate(_:autonomy:)`, which applies
/// `ApprovalPolicy` and — when the answer is "ask the user" — suspends until the
/// UI resolves the request.
///
/// **Continuation discipline.** A `CheckedContinuation` resumed twice traps, and
/// one never resumed leaks the calling agent's task forever. Every path
/// (approve, reject, timeout, task cancellation, shutdown) funnels through
/// `resolve(_:approved:)`, which removes the entry *before* resuming — so each
/// continuation resumes exactly once.
public actor ApprovalService {
    private let bus: MessageBus
    private let database: GrootDatabase?
    /// How long a request may sit unanswered before it is auto-declined.
    /// `nil` (the default) means it waits indefinitely, as the app does today.
    private let timeout: TimeInterval?

    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var requests: [UUID: ApprovalRequest] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    public init(bus: MessageBus, database: GrootDatabase? = nil, timeout: TimeInterval? = nil) {
        self.bus = bus
        self.database = database
        self.timeout = timeout
    }

    // MARK: The gate

    /// Decide what an agent should do with a proposed operation, waiting for the
    /// user when the policy demands it.
    ///
    /// - Important: `request.isDestructive` should come from
    ///   `FileOperationKind.isDestructive`, not from the agent's own judgement.
    public func evaluate(_ request: ApprovalRequest, autonomy: AutonomyMode) async -> ApprovalOutcome {
        switch ApprovalPolicy.decide(isDestructive: request.isDestructive, autonomy: autonomy) {
        case .propose:
            return .previewOnly
        case .proceed:
            return .proceed
        case .askUser:
            return await ask(request) ? .proceed : .declined
        }
    }

    /// Evaluate through the gate when one is wired up, and fall back to the pure
    /// policy when it isn't (headless tests, agents constructed standalone).
    ///
    /// The fallback **declines** anything that would need a user rather than
    /// performing it: no gate means no one to ask, and silently proceeding is
    /// exactly the failure mode this whole service exists to prevent.
    public static func evaluate(
        _ request: ApprovalRequest,
        autonomy: AutonomyMode,
        using service: ApprovalService?
    ) async -> ApprovalOutcome {
        if let service {
            return await service.evaluate(request, autonomy: autonomy)
        }
        switch ApprovalPolicy.decide(isDestructive: request.isDestructive, autonomy: autonomy) {
        case .proceed: return .proceed
        case .propose: return .previewOnly
        case .askUser: return .declined
        }
    }

    /// Requests still waiting on the user, newest last. For the UI and tests.
    public var pending: [ApprovalRequest] {
        requests.values.sorted { $0.summary < $1.summary }
    }

    public var pendingCount: Int { continuations.count }

    // MARK: Resolution (the only way a continuation is ever resumed)

    /// Answer a pending request. Safe to call with an unknown or already-resolved
    /// id — a late second call is a no-op rather than a trap.
    public func resolve(_ id: UUID, approved: Bool) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)
        forgetPersisted(id)
        // Remove BEFORE resuming: this is what makes resumption exactly-once.
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: approved)
    }

    public func approve(_ id: UUID) { resolve(id, approved: true) }
    public func reject(_ id: UUID) { resolve(id, approved: false) }

    /// Decline everything still outstanding — used at shutdown so no agent task
    /// is left suspended on a continuation that will never be resumed.
    public func declineAll() {
        for id in continuations.keys { resolve(id, approved: false) }
    }

    // MARK: Waiting

    private func ask(_ request: ApprovalRequest) async -> Bool {
        requests[request.id] = request
        persist(request)
        await bus.publish(.approvalRequested(request))
        startTimeout(for: request.id)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                continuations[request.id] = continuation
            }
        } onCancel: {
            // The agent's task went away while we were suspended. Resolve so the
            // continuation isn't orphaned.
            Task { await self.resolve(request.id, approved: false) }
        }
    }

    private func startTimeout(for id: UUID) {
        guard let timeout else { return }
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resolve(id, approved: false)
        }
    }

    // MARK: Persistence
    //
    // Pending requests are written to `pending_approvals` purely so the app can
    // tell the user what was outstanding when it quit. They are NOT resumed on
    // relaunch: the agent-side job (source/destination URLs) lives in memory
    // only, so a "restored" request could never actually be carried out.
    // `expireRestoredRequests()` clears them and reports the count.

    private func persist(_ request: ApprovalRequest) {
        guard let database else { return }
        let statement = SQLStatement("""
        INSERT OR REPLACE INTO pending_approvals
            (id, agent_id, summary, detail, item_count, bytes_affected, is_destructive, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .text(request.id.uuidString),
            .text(request.agentID.raw),
            .text(request.summary),
            .text(orNull: request.detail),
            .integer(Int64(request.itemCount)),
            .integer(Int64(request.bytesAffected)),
            .bool(request.isDestructive),
            .date(Date())
        ])
        Task { try? await database.execute(statement.sql, statement.bindings) }
    }

    private func forgetPersisted(_ id: UUID) {
        guard let database else { return }
        Task {
            try? await database.execute(
                "DELETE FROM pending_approvals WHERE id = ?;", [.text(id.uuidString)])
        }
    }

    /// Clear approvals left over from a previous run. Returns how many were
    /// discarded so the caller can surface it in the activity log.
    @discardableResult
    public func expireRestoredRequests() async -> Int {
        guard let database else { return 0 }
        let rows = (try? await database.query("SELECT COUNT(*) FROM pending_approvals;")) ?? []
        let count = rows.first?.int(0) ?? 0
        if count > 0 {
            try? await database.execute("DELETE FROM pending_approvals;")
        }
        return count
    }
}
