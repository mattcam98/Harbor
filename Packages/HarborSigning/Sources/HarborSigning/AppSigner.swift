import Foundation
import HarborCore
import SideSign

public enum AppSigningError: Error, Equatable, Sendable {
    /// Not an app bundle, or its Info.plist has no bundle identifier.
    case invalidApp
    case missingProfile(bundleIdentifier: String)
    case unreadableInfoPlist(bundleIdentifier: String)
}

/// Prepares an unpacked app bundle and signs it.
///
/// Preparation gives every bundle the identifier its provisioning profile
/// was issued for, and removes the old signature. Nothing else is added to
/// the app: no URL scheme, no marker type, and never the signing certificate.
public struct AppSigner: Sendable {
    public typealias SignerFactory = @Sendable (Team, KeyStore) -> any CodeSignerAPI

    private let makeSigner: SignerFactory

    public init(makeSigner: @escaping SignerFactory = { AppBundleSigner(team: $0, keyStore: $1) }) {
        self.makeSigner = makeSigner
    }

    /// The bundles that need App IDs and profiles: the app, then its extensions.
    public static func targets(ofAppAt appURL: URL) throws -> [SigningTarget] {
        guard let app = AppBundle(fileURL: appURL) else { throw AppSigningError.invalidApp }
        return app.allAppBundles.map { bundle in
            let entitlements = bundle.entitlements
            return SigningTarget(
                bundleIdentifier: bundle.bundleIdentifier,
                name: bundle.name,
                capabilities: enabledEntitlements(in: entitlements),
                appGroups: entitlements[Entitlement.appGroups.rawValue] as? [String] ?? []
            )
        }
    }

    /// Entitlement keys that are switched on: `true`, a non-empty list, or
    /// any other value. `false` and an empty list mean off.
    static func enabledEntitlements(in entitlements: [String: any Sendable]) -> Set<String> {
        Set(entitlements.compactMap { key, value in
            if let flag = value as? Bool { return flag ? key : nil }
            if let list = value as? [Any] { return list.isEmpty ? nil : key }
            return key
        })
    }

    /// - Parameter profiles: keyed by each bundle's identifier as shipped,
    ///   which is what `ProfileProvisioner.provision` returns.
    public func sign(
        appAt appURL: URL,
        profiles: [String: ProvisioningProfile],
        identity: KeyStore,
        team: Team
    ) async throws {
        guard let app = AppBundle(fileURL: appURL) else { throw AppSigningError.invalidApp }

        // Match every bundle to its profile before changing any file, so a
        // missing profile leaves the app exactly as it was.
        let assignments = try app.allAppBundles.map { bundle in
            guard let profile = profiles[bundle.bundleIdentifier] else {
                throw AppSigningError.missingProfile(bundleIdentifier: bundle.bundleIdentifier)
            }
            return (bundle: bundle, profile: profile)
        }

        for assignment in assignments {
            try Self.prepare(assignment.bundle, for: assignment.profile)
        }

        try await makeSigner(team, identity).signApp(
            at: appURL,
            provisioningProfiles: assignments.map(\.profile),
            progress: nil
        )
    }

    static func prepare(_ bundle: AppBundle, for profile: ProvisioningProfile) throws {
        let original = bundle.bundleIdentifier
        let assigned = profile.bundleIdentifier
        let url = bundle.infoPlistURL

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: &format),
            var info = plist as? [String: Any]
        else {
            throw AppSigningError.unreadableInfoPlist(bundleIdentifier: original)
        }

        info["CFBundleIdentifier"] = assigned
        if let taskIdentifiers = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
            info["BGTaskSchedulerPermittedIdentifiers"] =
                rebased(taskIdentifiers, from: original, to: assigned)
        }

        try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
            .write(to: url, options: .atomic)

        let oldSignature = bundle.fileURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: oldSignature.path) {
            try FileManager.default.removeItem(at: oldSignature)
        }
    }

    /// Background task identifiers have to stay under the bundle identifier,
    /// or the system refuses to schedule them.
    static func rebased(_ identifiers: [String], from original: String, to assigned: String) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let rebasedIdentifier: String
            if identifier == assigned || identifier.hasPrefix(assigned + ".") {
                rebasedIdentifier = identifier
            } else if identifier == original || identifier.hasPrefix(original + ".") {
                rebasedIdentifier = assigned + identifier.dropFirst(original.count)
            } else {
                rebasedIdentifier = identifier
            }
            return seen.insert(rebasedIdentifier).inserted ? rebasedIdentifier : nil
        }
    }
}
