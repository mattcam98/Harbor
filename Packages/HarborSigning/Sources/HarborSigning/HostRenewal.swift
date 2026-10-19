import Foundation
import HarborCore
import SideSign

/// Harbor renewing itself, from the phone.
///
/// Renewing is what refreshing an installed app already does: new
/// provisioning profiles from Apple, installed on the device. Nothing is
/// signed again and nothing is reinstalled, so Harbor can do it to itself
/// while it runs, as SideStore does. The certificate the profiles name is
/// the one Harbor Setup signed Harbor with and handed over, which Harbor
/// keeps.
///
/// What refreshing needs is the record of the install, which Setup has and
/// Harbor does not: the identifiers as shipped. They are the installed ones
/// without the team's suffix (`ProfileProvisioner.registeredIdentifier`).
public enum HostRenewal {
    public enum Failure: Error, Equatable, Sendable {
        /// This copy's identifiers do not carry the signed-in team's suffix:
        /// it was installed by Xcode, or for another Apple ID.
        case installedForAnotherTeam
    }

    /// The record of the Harbor at `appURL`, as Harbor Setup would have
    /// made it when installing.
    public static func record(ofAppAt appURL: URL, team: Team, expiry: Date, now: Date = Date()) throws -> InstalledApp {
        let installed = try AppSigner.targets(ofAppAt: appURL)
        return try record(
            installed: installed.map { InstalledApp.Target(bundleIdentifier: $0.bundleIdentifier, name: $0.name) },
            version: AppBundle(fileURL: appURL)?.version ?? "",
            team: team,
            expiry: expiry,
            now: now
        )
    }

    /// - Parameter installed: the app first, then its extensions, by their
    ///   identifiers as installed.
    static func record(
        installed: [InstalledApp.Target],
        version: String,
        team: Team,
        expiry: Date,
        now: Date
    ) throws -> InstalledApp {
        guard let app = installed.first else { throw AppSigningError.invalidApp }
        let suffix = "." + team.identifier
        guard
            app.bundleIdentifier.count > suffix.count,
            app.bundleIdentifier.lowercased().hasSuffix(suffix.lowercased())
        else {
            throw Failure.installedForAnotherTeam
        }
        let shippedApp = String(app.bundleIdentifier.dropLast(suffix.count))

        let targets = try installed.map { target -> InstalledApp.Target in
            let shipped: String
            if target.bundleIdentifier == app.bundleIdentifier {
                shipped = shippedApp
            } else if target.bundleIdentifier.lowercased().hasPrefix(app.bundleIdentifier.lowercased() + ".") {
                shipped = shippedApp + target.bundleIdentifier.dropFirst(app.bundleIdentifier.count)
            } else {
                throw Failure.installedForAnotherTeam
            }
            return InstalledApp.Target(bundleIdentifier: shipped, name: target.name)
        }

        return InstalledApp(
            id: shippedApp,
            installedBundleIdentifier: app.bundleIdentifier,
            name: app.name,
            version: version,
            targets: targets,
            expiry: expiry,
            installedAt: now,
            isHost: true
        )
    }
}
