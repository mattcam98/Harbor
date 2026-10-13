import Foundation

/// An installed app whose provisioning profile expires.
public struct SignedApp: Equatable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var expiry: Date
    /// Harbor itself. If it expires nothing else can be refreshed, so it goes first.
    public var isHost: Bool

    public init(bundleIdentifier: String, name: String, expiry: Date, isHost: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.expiry = expiry
        self.isHost = isHost
    }
}

public struct RefreshPolicy: Equatable, Sendable {
    /// How long before expiry an app becomes due.
    public var leadTime: TimeInterval
    /// Reminders, as time before expiry.
    public var reminderOffsets: [TimeInterval]

    public init(leadTime: TimeInterval, reminderOffsets: [TimeInterval]) {
        self.leadTime = leadTime
        self.reminderOffsets = reminderOffsets
    }

    private static let hour: TimeInterval = 3600

    public static let standard = RefreshPolicy(
        leadTime: 48 * hour,
        reminderOffsets: [48 * hour, 24 * hour, 2 * hour]
    )
}

public struct ExpiryReminder: Equatable, Sendable {
    /// Stable, so rescheduling replaces the earlier reminder instead of adding one.
    public var identifier: String
    public var bundleIdentifier: String
    public var fireDate: Date
    public var timeBeforeExpiry: TimeInterval
}

public struct RefreshPlan: Equatable, Sendable {
    /// Apps to refresh now, in the order to do it.
    public var due: [SignedApp]
    /// The subset of `due` that has already expired and will not launch.
    public var expired: [SignedApp]
    /// The earliest moment another app becomes due; `nil` when none will.
    /// This is what to ask iOS for as the next background run.
    public var nextCheck: Date?
    /// Reminders to schedule. They fire whether or not Harbor runs again.
    public var reminders: [ExpiryReminder]
}

/// Decides what to refresh and when. Pure: the same inputs give the same plan.
public struct RefreshPlanner: Sendable {
    public var policy: RefreshPolicy

    public init(policy: RefreshPolicy = .standard) {
        self.policy = policy
    }

    public func plan(apps: [SignedApp], now: Date) -> RefreshPlan {
        let dueThreshold = now.addingTimeInterval(policy.leadTime)

        let due = apps
            .filter { $0.expiry <= dueThreshold }
            .sorted { lhs, rhs in
                if lhs.isHost != rhs.isHost { return lhs.isHost }
                if lhs.expiry != rhs.expiry { return lhs.expiry < rhs.expiry }
                return lhs.bundleIdentifier < rhs.bundleIdentifier
            }

        let nextCheck = apps
            .filter { $0.expiry > dueThreshold }
            .map { $0.expiry.addingTimeInterval(-policy.leadTime) }
            .min()

        let reminders = apps
            .flatMap { app in
                policy.reminderOffsets.map { offset in
                    ExpiryReminder(
                        identifier: "expiry.\(app.bundleIdentifier).\(Int(offset))",
                        bundleIdentifier: app.bundleIdentifier,
                        fireDate: app.expiry.addingTimeInterval(-offset),
                        timeBeforeExpiry: offset
                    )
                }
            }
            .filter { $0.fireDate > now }
            .sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }

        return RefreshPlan(
            due: due,
            expired: due.filter { $0.expiry <= now },
            nextCheck: nextCheck,
            reminders: reminders
        )
    }
}
