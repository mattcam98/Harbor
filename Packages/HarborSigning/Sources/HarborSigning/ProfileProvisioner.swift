import Foundation
import HarborCore
import SideSign

/// One signable bundle inside an app: the app itself or one of its extensions.
public struct SigningTarget: Equatable, Sendable {
    /// The bundle identifier as shipped in the IPA.
    public var bundleIdentifier: String
    /// Display name, used for the App ID's name on the portal.
    public var name: String
    /// Entitlement keys the bundle was built with and has switched on.
    public var capabilities: Set<String>
    /// App groups the bundle was built with.
    public var appGroups: [String]

    public init(
        bundleIdentifier: String,
        name: String,
        capabilities: Set<String> = [],
        appGroups: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.capabilities = capabilities
        self.appGroups = appGroups
    }
}

public enum ProvisioningError: Error, Equatable, Sendable {
    /// The install would exceed an account limit. Nothing was sent to Apple.
    case blocked(InstallFeasibility)
}

public struct ProvisionedProfiles: Sendable {
    /// Keyed by each target's bundle identifier as shipped.
    public var profiles: [String: ProvisioningProfile]
    /// Entitlement keys the app asks for that this team cannot be granted.
    /// The features behind them will not work in the installed app.
    public var unavailableCapabilities: Set<String>
}

/// Registers App IDs, switches on the capabilities the app needs, and
/// fetches provisioning profiles.
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

    /// App groups are per team in the same way.
    public static func registeredGroupIdentifier(for group: String, team: Team) -> String {
        "\(group).\(team.identifier)"
    }

    /// - Parameters:
    ///   - targets: the app first, then its extensions.
    ///   - isAlreadyActive: the app is installed and counts as active already.
    ///   - activeApps: how many sideloaded apps are active on the device.
    ///   - syncCapabilities: bring the App IDs' capabilities and app groups
    ///     in line with the targets. Off for a refresh, which has no bundle
    ///     to read them from and must not switch anything off.
    public func provision(
        _ targets: [SigningTarget],
        isAlreadyActive: Bool,
        activeApps: Int,
        deviceType: DeviceType,
        team: Team,
        session: Session,
        syncCapabilities: Bool = true,
        now: Date = Date()
    ) async throws -> ProvisionedProfiles {
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

        var result = ProvisionedProfiles(profiles: [:], unavailableCapabilities: [])
        var teamGroups: [AppGroup]?

        for target in targets {
            let identifier = Self.registeredIdentifier(for: target.bundleIdentifier, team: team)

            var appID: AppID
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

            if syncCapabilities {
                let plan = Self.capabilityPlan(for: target, team: team)
                result.unavailableCapabilities.formUnion(plan.unavailable)

                let needsUpdate = plan.features.contains { feature, value in
                    (appID.features[feature] ?? "false") != value
                }
                if needsUpdate {
                    var requested = appID
                    requested.features = plan.features
                    appID = try await portal.updateAppID(requested, team: team, session: session)
                }

                if !plan.appGroups.isEmpty {
                    if teamGroups == nil {
                        teamGroups = try await portal.fetchAppGroups(for: team, session: session)
                    }
                    var assigned: [AppGroup] = []
                    for group in plan.appGroups {
                        let groupIdentifier = Self.registeredGroupIdentifier(for: group, team: team)
                        guard !assigned.contains(where: { $0.identifier == groupIdentifier }) else { continue }

                        if let existing = teamGroups?.first(where: { $0.identifier == groupIdentifier }) {
                            assigned.append(existing)
                        } else {
                            let created = try await portal.addAppGroup(
                                name: Self.sanitized("Harbor \(group)"),
                                groupIdentifier: groupIdentifier,
                                team: team,
                                session: session
                            )
                            teamGroups?.append(created)
                            assigned.append(created)
                        }
                    }
                    appID = try await portal.assignAppGroups(assigned, to: appID, team: team, session: session)
                }
            }

            result.profiles[target.bundleIdentifier] = try await portal.downloadProvisioningProfile(
                for: appID,
                isTeamProfile: true,
                subPlatform: nil,
                deviceType: deviceType,
                team: team,
                session: session
            )
        }
        return result
    }

    /// What to ask the portal for on behalf of one target.
    struct CapabilityPlan: Equatable {
        /// Capabilities to switch on for the App ID.
        var features: [Feature: String] = [:]
        /// App groups to register and assign, as shipped.
        var appGroups: [String] = []
        /// Entitlement keys this team cannot have.
        var unavailable: Set<String> = []
    }

    static func capabilityPlan(for target: SigningTarget, team: Team) -> CapabilityPlan {
        // An unrecognised team type gets what a free team gets.
        let allowed = team.type.allowedFeatures ?? Feature.freeFeatures

        var plan = CapabilityPlan()
        for key in target.capabilities {
            // Entitlements with no portal capability behind them need no action.
            guard let feature = Feature(entitlement: Entitlement(rawValue: key)) else { continue }
            if allowed.contains(feature) {
                plan.features[feature] = "true"
            } else {
                plan.unavailable.insert(key)
            }
        }
        if plan.features[.appGroups] != nil {
            plan.appGroups = target.appGroups
        }
        return plan
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

    static func sanitized(_ string: String, limit: Int = 50) -> String {
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
