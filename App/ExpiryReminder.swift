import Foundation
@preconcurrency import UserNotifications

/// Notifications ahead of the day this copy of Harbor stops opening.
///
/// A free Apple ID signs an app for seven days. When they run out the app
/// will not launch at all, and neither will anything inside it, so a warning
/// has to come from iOS and not from Harbor.
enum ExpiryReminder {
    private static let leads: [(identifier: String, before: TimeInterval, body: String)] = [
        ("harbor.expiry.day", 24 * 3600, "Harbor stops opening tomorrow. Open it and tap Renew Harbor."),
        ("harbor.expiry.hours", 3 * 3600, "Harbor stops opening in three hours. Open it and tap Renew Harbor."),
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
            let moment = expiry.addingTimeInterval(-lead.before)
            guard moment > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Harbor expires soon"
            content.body = lead.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
            try await center.add(UNNotificationRequest(
                identifier: lead.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            ))
        }
        return true
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: leads.map(\.identifier))
    }
}
