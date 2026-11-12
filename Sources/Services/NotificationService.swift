import Foundation
import UserNotifications

/// What the system currently allows the app to notify about.
enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    /// Quiet delivery (`.provisional`) or App Clip delivery (`.ephemeral`) —
    /// notifications are still shown, so the UI reads both as "on".
    case provisional
    case denied

    var isEnabled: Bool {
        switch self {
        case .authorized, .provisional: true
        case .denied, .notDetermined: false
        }
    }

    /// The only place `UNAuthorizationStatus` is read: a pure table, so the
    /// mapping is testable without a notification center.
    static func from(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized: .authorized
        case .provisional, .ephemeral: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

/// Seam over `UNUserNotificationCenter` — the single wrapper for the
/// notification center in this app. The permission surface (issue #16) and the
/// backup-completion local notification both go through it; tests inject a
/// recorder instead of talking to the system.
///
/// Every requirement is `async` so an actor-isolated (`@MainActor`) fake can
/// satisfy the protocol.
protocol NotificationServicing: AnyObject, Sendable {
    func permission() async -> NotificationPermission

    /// Asks the system. iOS shows the prompt **once per install**: from
    /// `.denied` this returns `.denied` again without ever surfacing UI.
    @discardableResult
    func requestAuthorization() async -> NotificationPermission

    func notifyBackupComplete(uploaded: Int, total: Int, failed: Int, success: Bool) async
}

/// `UNUserNotificationCenter`-backed implementation. Stateless, so the actor
/// hops cost nothing.
final class NotificationService: NotificationServicing, Sendable {
    nonisolated init() {}

    func permission() async -> NotificationPermission {
        NotificationPermission.from(
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        )
    }

    func requestAuthorization() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        return await permission()
    }

    /// Body of the "backup finished" notification: "3 photos uploaded, 0 failed."
    /// on success, "3 uploaded, 2 failed." otherwise. Each count is a catalog
    /// plural, so every language agrees each word with its number. Pure, so each
    /// shipped language is testable.
    static func backupCompleteBody(
        uploaded: Int,
        failed: Int,
        success: Bool,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        success
            ? String(localized: "\(uploaded) photos uploaded, \(failed) failed.", bundle: bundle, locale: locale)
            : String(localized: "\(uploaded) uploaded, \(failed) failed.", bundle: bundle, locale: locale)
    }

    /// Posts a single local notification when a backup run finishes, so a
    /// background backup still surfaces its result.
    func notifyBackupComplete(uploaded: Int, total: Int, failed: Int, success: Bool) async {
        let content = UNMutableNotificationContent()
        if success {
            content.title = String(localized: "Backup complete")
        } else {
            content.title = String(localized: "Backup finished with errors")
        }
        content.body = Self.backupCompleteBody(uploaded: uploaded, failed: failed, success: success)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
