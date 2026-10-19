import Foundation
@preconcurrency import UserNotifications

/// Notifications ahead of the day this copy of Harbor stops opening.
///
/// A free Apple ID signs an app for seven days. When they run out the app
/// will not launch at all, and neither will anything inside it, so a warning
/// has to come from iOS and not from Harbor.
enum ExpiryReminder {
    private static let leads: [(identifier: String, before: TimeInterval, body: String)] = [
        ("harbor.expiry.day", 24 * 3600, "Harbor expires tomorrow. Open it and tap Renew."),
        ("harbor.expiry.hours", 3 * 3600, "Harbor expires in 3 hours. Open it and tap Renew."),
    ]

    /// Replaces any earlier reminders with ones for this date. Returns
    /// `false` when the user has not allowed notifications.
    static func schedule(for expiry: Date, now: Date = Date()) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            return false
        }
        cancel()
        for lead in leads {
            // An interval, not a calendar date: it fires at the right moment
            // even if the clocks change or the iPhone moves time zone first.
            let wait = expiry.addingTimeInterval(-lead.before).timeIntervalSince(now)
            guard wait > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Renew Harbor"
            content.body = lead.body
            content.sound = .default
            try await center.add(UNNotificationRequest(
                identifier: lead.identifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
            ))
        }
        return true
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: leads.map(\.identifier))
    }
}

/// One-off notifications, such as the result of an automatic renewal.
@MainActor
enum Notices {
    private static let presenter = Presenter()

    /// Shows Harbor's notifications even while Harbor is on screen, which
    /// is where it is when a Shortcuts automation has just opened it.
    static func showWhileOpen() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// Posts at once. iOS asks for permission first if it hasn't yet.
    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Asks for permission to notify. Returns whether it was given.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func remove(_ identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }
}
