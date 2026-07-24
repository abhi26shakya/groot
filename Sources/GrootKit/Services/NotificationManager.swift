import Foundation

/// Delivers user-facing notifications. A protocol so `GrootKit` stays headless
/// and testable — only the concrete implementation imports `UserNotifications`.
public protocol Notifying: Sendable {
    /// Ask the OS for permission. Returns whether it was granted.
    func requestAuthorization() async -> Bool
    /// Post a notification. Silently does nothing if permission was denied.
    func notify(title: String, body: String, identifier: String) async
}

public extension Notifying {
    /// Surface an approval that was raised while the app wasn't in front, so a
    /// pending request doesn't sit unnoticed (agents now wait on it).
    func notifyApprovalRequested(_ request: ApprovalRequest) async {
        await notify(
            title: request.isDestructive ? "Groot needs permission" : "Groot has a suggestion",
            body: request.detail.map { "\(request.summary) — \($0)" } ?? request.summary,
            identifier: request.id.uuidString)
    }
}

/// Records what would have been posted. For tests and previews.
public actor SpyNotifier: Notifying {
    public struct Posted: Sendable, Equatable {
        public let title: String
        public let body: String
        public let identifier: String
    }

    public private(set) var posted: [Posted] = []
    public private(set) var authorizationRequested = false
    private let granted: Bool

    public init(granted: Bool = true) {
        self.granted = granted
    }

    public func requestAuthorization() async -> Bool {
        authorizationRequested = true
        return granted
    }

    public func notify(title: String, body: String, identifier: String) async {
        guard granted else { return }
        posted.append(Posted(title: title, body: body, identifier: identifier))
    }

    public var count: Int { posted.count }
}

/// A notifier that does nothing — the default when the app hasn't wired one up,
/// so no code path has to special-case a missing notifier.
public struct NoopNotifier: Notifying {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func notify(title: String, body: String, identifier: String) async {}
}
