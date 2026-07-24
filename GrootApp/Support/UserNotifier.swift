import Foundation
import UserNotifications
import GrootKit

/// The production `Notifying` implementation. Lives in the app target because
/// `UserNotifications` needs a real bundle identifier — `GrootKit` stays
/// headless so `swift test` never touches it.
public struct UserNotifier: Notifying {
    public init() {}

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            GrootLog.runtime.error(
                "notification authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func notify(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            GrootLog.runtime.error(
                "could not post notification: \(String(describing: error), privacy: .public)")
        }
    }
}
