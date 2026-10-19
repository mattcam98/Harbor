import Foundation

/// Dates as Harbor shows them: always in the iPhone's own time zone and
/// region, which these formats follow even when either changes.
extension Date {
    /// "Mon 26 Oct at 14:00", or "Today at 14:00".
    var dayAndTime: String { dayAndTime(relativeTo: Date()) }

    /// As `dayAndTime`, with "Today" and "Tomorrow" counted from `now`. Views
    /// pass `AppModel.clock`, so they redraw when the day or time zone
    /// changes. `midSentence` gives "today at 14:00" for use inside a
    /// sentence.
    func dayAndTime(relativeTo now: Date = Date(), midSentence: Bool = false) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = formatted(.dateTime.hour().minute())
        func named(_ day: String) -> String {
            "\(midSentence ? day.lowercased() : day) at \(time)"
        }
        if calendar.isDate(self, inSameDayAs: now) { return named("Today") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(self, inSameDayAs: tomorrow) {
            return named("Tomorrow")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return named("Yesterday")
        }
        return "\(formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
    }

    /// "26 Oct 2026".
    var day: String {
        formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "in 6 days", "in 30 hours", "in 5 minutes", or "2 days ago". Never
    /// rounds up to a larger unit, so 6 days isn't shown as a week.
    var relative: String {
        let left = timeIntervalSinceNow
        guard left > 0 else { return formatted(.relative(presentation: .numeric, unitsStyle: .wide)) }
        let days = Int(left / 86_400), hours = Int(left / 3600), minutes = Int(left / 60)
        if days >= 2 { return "in \(days) days" }
        if hours >= 2 { return "in \(hours) hours" }
        if hours == 1 { return "in 1 hour" }
        if minutes >= 2 { return "in \(minutes) minutes" }
        return minutes == 1 ? "in 1 minute" : "in under a minute"
    }
}

enum PublishedDate {
    /// A date as sources publish it, shown like Harbor's own dates. A full
    /// timestamp is shown in the iPhone's time zone; a plain day such as
    /// "2026-10-19" is shown as that day wherever the iPhone is.
    static func display(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let instant = try? Date(trimmed, strategy: .iso8601) {
            return instant.day
        }
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let dayOnly = Date.ISO8601FormatStyle(timeZone: utc).year().month().day()
        if let day = try? Date(String(trimmed.prefix(10)), strategy: dayOnly) {
            var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
            style.timeZone = utc
            return day.formatted(style)
        }
        return trimmed
    }
}
