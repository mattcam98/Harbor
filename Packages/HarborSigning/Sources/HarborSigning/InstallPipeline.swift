import Foundation
import HarborCore
import SideSign

public enum InstallError: Error, Equatable, Sendable {
    /// The archive has no `Payload/<name>.app`, or more than one.
    case notAnApp
    /// The app is still FairPlay-encrypted, as a copy taken straight from
    /// the App Store is. It cannot run sideloaded, however it is signed.
    case encrypted
    /// The certificate the app was signed with is gone from the team, so new
    /// profiles alone will not make it launch. It has to be installed again.
    case reinstallRequired
}

/// Installs and refreshes apps: the steps between "here is an IPA" and "it
/// is on the device", in order, with nothing left behind on failure.
public struct InstallPipeline: Sendable {
    public enum Step: String, CaseIterable, Sendable {
        case unpack, registerDevice, certificate, profiles, sign, install
    }

    public typealias Progress = @Sendable (Step) -> Void

    private let portal: any DeveloperPortalAPI
    private let identities: SigningIdentityStore
    private let transport: any DeviceTransport
    private let signer: AppSigner
    private let machineName: String
    private let deviceName: String
    private let workDirectory: URL

    /// - Parameters:
    ///   - machineName: label for the certificate on the developer portal.
    ///   - deviceName: label for this device on the developer portal.
    ///   - workDirectory: scratch space for unpacked apps; emptied after use.
    public init(
        portal: any DeveloperPortalAPI,
        identities: SigningIdentityStore,
        transport: any DeviceTransport,
        signer: AppSigner = AppSigner(),
        machineName: String,
        deviceName: String,
        workDirectory: URL
    ) {
        self.portal = portal
        self.identities = identities
        self.transport = transport
        self.signer = signer
        self.machineName = machineName
        self.deviceName = deviceName
        self.workDirectory = workDirectory
    }

    /// Signs the IPA for this device and installs it.
    ///
    /// - Parameter activeApps: shipped bundle identifiers of the sideloaded
    ///   apps active on the device, Harbor included. Installing one of them
    ///   again is an update and does not count as another app.
    public func install(
        ipaAt ipaURL: URL,
        account: SignedInAccount,
        activeApps: Set<String>,
        deviceType: DeviceType,
        onExistingCertificates: CertificateProvisioner.RevocationHandler,
        progress: Progress = { _ in },
        now: Date = Date()
    ) async throws -> InstalledApp {
        let fileManager = FileManager.default
        let work = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        progress(.unpack)
        try SafeArchive.extract(archiveAt: ipaURL, to: work, limits: .appBundle)
        let appURL = try Self.appBundle(in: work)
        // Before anything is created at Apple for an app that could never launch.
        if try Self.isEncrypted(appAt: appURL) {
            throw InstallError.encrypted
        }
        let targets = try AppSigner.targets(ofAppAt: appURL)
        let version = AppBundle(fileURL: appURL)?.version ?? ""

        progress(.registerDevice)
        try await registerDeviceIfNeeded(type: deviceType, account: account)

        progress(.certificate)
        let identity = try await CertificateProvisioner(
            portal: portal, identities: identities, machineName: machineName
        ).resolveIdentity(
            team: account.team, session: account.session, onExistingCertificates: onExistingCertificates)

        progress(.profiles)
        let provisioned = try await ProfileProvisioner(portal: portal).provision(
            targets,
            isAlreadyActive: activeApps.contains(targets[0].bundleIdentifier),
            activeApps: activeApps.count,
            deviceType: deviceType,
            team: account.team,
            session: account.session,
            now: now
        )

        let profiles = provisioned.profiles

        progress(.sign)
        try await signer.sign(appAt: appURL, profiles: profiles, identity: identity, team: account.team)

        progress(.install)
        let main = targets[0]
        guard let mainProfile = profiles[main.bundleIdentifier] else {
            throw AppSigningError.missingProfile(bundleIdentifier: main.bundleIdentifier)
        }
        try await transport.installApp(at: appURL, bundleIdentifier: mainProfile.bundleIdentifier)

        return InstalledApp(
            id: main.bundleIdentifier,
            installedBundleIdentifier: mainProfile.bundleIdentifier,
            name: main.name,
            version: version,
            targets: targets.map { .init(bundleIdentifier: $0.bundleIdentifier, name: $0.name) },
            expiry: Self.earliestExpiry(of: profiles),
            installedAt: now,
            unavailableCapabilities: provisioned.unavailableCapabilities.sorted()
        )
    }

    /// Extends an installed app's life by fetching and installing fresh
    /// provisioning profiles. The app itself is not touched.
    public func refresh(
        _ app: InstalledApp,
        account: SignedInAccount,
        deviceType: DeviceType,
        now: Date = Date()
    ) async throws -> InstalledApp {
        let certificates = try await portal.fetchCertificates(for: account.team, session: account.session)
        guard
            let identity = try identities.load(),
            certificates.contains(where: { CertificateProvisioner.sameSerial($0, identity.certificate) })
        else {
            throw InstallError.reinstallRequired
        }

        let profiles = try await ProfileProvisioner(portal: portal).provision(
            app.targets.map { SigningTarget(bundleIdentifier: $0.bundleIdentifier, name: $0.name) },
            isAlreadyActive: true,
            activeApps: 0,
            deviceType: deviceType,
            team: account.team,
            session: account.session,
            syncCapabilities: false,
            renewing: true,
            now: now
        ).profiles
        // Extensions before the app, so the app's new profile is the last
        // thing to land and a partial failure is retried from a known state.
        for target in app.targets.reversed() {
            guard let profile = profiles[target.bundleIdentifier] else {
                throw AppSigningError.missingProfile(bundleIdentifier: target.bundleIdentifier)
            }
            try await transport.installProfile(profile.data)
        }

        var refreshed = app
        refreshed.expiry = Self.earliestExpiry(of: profiles)
        return refreshed
    }

    /// A team profile only covers devices registered with the team.
    private func registerDeviceIfNeeded(type: DeviceType, account: SignedInAccount) async throws {
        let identifier = try await transport.deviceIdentifier()
        let registered = try await portal.fetchDevices(for: account.team, types: type, session: account.session)
        guard !registered.contains(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            return
        }
        _ = try await portal.registerDevice(
            name: deviceName, identifier: identifier, type: type, team: account.team, session: account.session)
    }

    static func appBundle(in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let apps = ((try? FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1 else { throw InstallError.notAnApp }
        return apps[0]
    }

    static func isEncrypted(appAt appURL: URL) throws -> Bool {
        guard
            let name = AppBundle(fileURL: appURL)?.infoPlist["CFBundleExecutable"] as? String,
            ArchivePolicy.isSafe(name), !name.contains("/")
        else {
            return false
        }
        let executable = appURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: executable.path) else { return false }
        return try GuestExecutable.isEncrypted(fileAt: executable)
    }

    /// The app stops launching when the first of its profiles lapses.
    static func earliestExpiry(of profiles: [String: ProvisioningProfile]) -> Date {
        profiles.values.map(\.expirationDate).min() ?? .distantPast
    }
}
