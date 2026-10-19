import Foundation

/// Dates as Harbor shows them: always in the iPhone's own time zone and
/// region, which these formats follow even when either changes.
extension Date {
    /// "Mon 26 Oct at 14:00", or "Today at 14:00".
    var dayAndTime: String { dayAndTime(relativeTo: Date()) }

    /// As `dayAndTime`, with "Today" and "Tomorrow" counted from `now`. Views
    /// pass `AppModel.clock`, so they redraw when the day or time zone
    /// changes.
    func dayAndTime(relativeTo now: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = formatted(.dateTime.hour().minute())
        if calendar.isDate(self, inSameDayAs: now) { return "Today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(self, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return "Yesterday at \(time)"
        }
        return "\(formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
    }

    /// "26 Oct 2026".
    var day: String {
        formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "in 6 days", "in 3 hours", "2 days ago".
    var relative: String {
        formatted(.relative(presentation: .numeric, unitsStyle: .wide))
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
