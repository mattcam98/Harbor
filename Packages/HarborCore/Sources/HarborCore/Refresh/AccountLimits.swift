import Foundation

/// Limits Apple applies to a developer account.
public struct AccountLimits: Equatable, Sendable {
    /// Sideloaded apps that can be active on one device; `nil` for no limit.
    public var maxActiveApps: Int?
    /// App IDs that can exist at once; `nil` for no limit. On a free account
    /// each App ID expires a week after it is created, which frees its slot.
    public var maxAppIDs: Int?

    public init(maxActiveApps: Int?, maxAppIDs: Int?) {
        self.maxActiveApps = maxActiveApps
        self.maxAppIDs = maxAppIDs
    }

    public static let free = AccountLimits(maxActiveApps: 3, maxAppIDs: 10)
    public static let paid = AccountLimits(maxActiveApps: nil, maxAppIDs: nil)
}

/// An App ID registered on the developer portal.
public struct RegisteredAppID: Equatable, Sendable {
    public var bundleIdentifier: String
    /// `nil` when the App ID does not expire (paid accounts).
    public var expiry: Date?

    public init(bundleIdentifier: String, expiry: Date?) {
        self.bundleIdentifier = bundleIdentifier
        self.expiry = expiry
    }
}

public struct InstallRequest: Equatable, Sendable {
    /// The app and each of its extensions. Every one needs its own App ID.
    public var bundleIdentifiers: [String]
    /// Reinstalling or updating an app that already counts as active.
    public var isAlreadyActive: Bool

    public init(bundleIdentifiers: [String], isAlreadyActive: Bool) {
        self.bundleIdentifiers = bundleIdentifiers
        self.isAlreadyActive = isAlreadyActive
    }
}

public enum InstallFeasibility: Equatable, Sendable {
    case allowed(newAppIDs: Int, appIDsRemainingAfter: Int?)
    /// `nextSlot` is when enough existing App IDs will have expired.
    case blockedByAppIDLimit(needed: Int, available: Int, nextSlot: Date?)
    case blockedByActiveAppLimit(active: Int, limit: Int)
}

extension AccountLimits {
    /// Checks an install against the limits before anything is sent to Apple,
    /// so a doomed install fails with an explanation instead of a portal error
    /// halfway through.
    public func evaluate(
        _ request: InstallRequest,
        registered: [RegisteredAppID],
        activeApps: Int,
        now: Date
    ) -> InstallFeasibility {
        if let limit = maxActiveApps, !request.isAlreadyActive, activeApps >= limit {
            return .blockedByActiveAppLimit(active: activeApps, limit: limit)
        }

        let live = registered.filter { $0.expiry.map { $0 > now } ?? true }
        let liveIdentifiers = Set(live.map(\.bundleIdentifier))
        let needed = Set(request.bundleIdentifiers).subtracting(liveIdentifiers).count

        guard let limit = maxAppIDs else {
            return .allowed(newAppIDs: needed, appIDsRemainingAfter: nil)
        }

        let available = max(0, limit - live.count)
        guard needed > available else {
            return .allowed(newAppIDs: needed, appIDsRemainingAfter: available - needed)
        }

        // Enough slots open once the `shortfall` soonest-expiring App IDs lapse.
        let shortfall = needed - available
        let expiries = live.compactMap(\.expiry).sorted()
        let nextSlot = expiries.count >= shortfall ? expiries[shortfall - 1] : nil
        return .blockedByAppIDLimit(needed: needed, available: available, nextSlot: nextSlot)
    }
}
