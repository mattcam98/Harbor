import Foundation
import HarborCore
import SideSign

/// One signable bundle inside an app: the app itself or one of its extensions.
public struct SigningTarget: Equatable, Sendable {
    /// The bundle identifier as shipped in the IPA.
    public var bundleIdentifier: String
    /// Display name, used for the App ID's name on the portal.
    public var name: String

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

public enum ProvisioningError: Error, Equatable, Sendable {
    /// The install would exceed an account limit. Nothing was sent to Apple.
    case blocked(InstallFeasibility)
}

/// Registers App IDs and fetches provisioning profiles for an app's bundles.
///
/// Scope today: App ID registration, limit checks and profile download.
/// Capabilities (features) and app groups are not yet synchronised with the
/// portal, so entitlements the team profile does not grant are dropped at
/// signing time.
public struct ProfileProvisioner: Sendable {
    private let portal: any DeveloperPortalAPI

    public init(portal: any DeveloperPortalAPI) {
        self.portal = portal
    }

    /// Bundle identifiers are made unique per team, as a personal team cannot
    /// register an identifier another team already owns.
    public static func registeredIdentifier(for bundleIdentifier: String, team: Team) -> String {
        "\(bundleIdentifier).\(team.identifier)"
    }

    /// - Parameters:
    ///   - targets: the app first, then its extensions.
    ///   - isAlreadyActive: the app is installed and counts as active already.
    ///   - activeApps: how many sideloaded apps are active on the device.
    /// - Returns: profiles keyed by each target's original bundle identifier.
    public func provision(
        _ targets: [SigningTarget],
        isAlreadyActive: Bool,
        activeApps: Int,
        deviceType: DeviceType,
        team: Team,
        session: Session,
        now: Date = Date()
    ) async throws -> [String: ProvisioningProfile] {
        var appIDs = try await portal.fetchAppIDs(for: team, session: session)

        // Check the whole request before creating anything, so a blocked
        // install does not burn App IDs on the bundles that would have fitted.
        let request = InstallRequest(
            bundleIdentifiers: targets.map {
                Self.registeredIdentifier(for: $0.bundleIdentifier, team: team).lowercased()
            },
            isAlreadyActive: isAlreadyActive
        )
        let registered = appIDs.map {
            RegisteredAppID(bundleIdentifier: $0.bundleIdentifier.lowercased(), expiry: $0.expirationDate)
        }
        let feasibility = Self.limits(for: team)
            .evaluate(request, registered: registered, activeApps: activeApps, now: now)
        guard case .allowed = feasibility else {
            throw ProvisioningError.blocked(feasibility)
        }

        var profiles: [String: ProvisioningProfile] = [:]
        for target in targets {
            let identifier = Self.registeredIdentifier(for: target.bundleIdentifier, team: team)

            let appID: AppID
            if let existing = appIDs.first(where: {
                $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
            }) {
                appID = existing
            } else {
                appID = try await portal.addAppID(
                    withName: Self.appIDName(for: target),
                    bundleIdentifier: identifier,
                    team: team,
                    session: session
                )
                appIDs.append(appID)
            }

            profiles[target.bundleIdentifier] = try await portal.downloadProvisioningProfile(
                for: appID,
                isTeamProfile: true,
                subPlatform: nil,
                deviceType: deviceType,
                team: team,
                session: session
            )
        }
        return profiles
    }

    /// An unrecognised team type is treated as free: the stricter limits.
    static func limits(for team: Team) -> AccountLimits {
        team.isPaid ? .paid : .free
    }

    /// The portal accepts only ASCII letters, digits and spaces in App ID
    /// names. Falls back to the bundle identifier when nothing usable is left.
    static func appIDName(for target: SigningTarget) -> String {
        let name = sanitized(target.name)
        return name.isEmpty ? sanitized(target.bundleIdentifier) : name
    }

    private static func sanitized(_ string: String, limit: Int = 50) -> String {
        let latin = string
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? string

        var words: [String] = []
        var current = ""
        for scalar in latin.unicodeScalars {
            let isAllowed = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
            if isAllowed {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        return String(words.joined(separator: " ").prefix(limit))
            .trimmingCharacters(in: .whitespaces)
    }
}
