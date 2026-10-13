import Foundation
import HarborCore
import HarborDevice
import HarborPlatform
import HarborSigning
import SideSign
import UIKit

/// The long-lived objects behind the interface, built once at launch.
struct Services: Sendable {
    let secrets: any SecretStore
    let account: AccountService
    let transport: any DeviceTransport
    let pipeline: InstallPipeline
    let library: InstalledAppLibrary
    let deviceType: DeviceType
    /// Apps that run inside Harbor's own process.
    let guests: GuestLibrary
    let identities: SigningIdentityStore
    let guestSigner: GuestSigner

    /// Keychain access groups reserved for guests in Harbor's entitlements
    /// (`com.kdt.livecontainer.shared` and `.1` to `.15`; the engine picks
    /// them by this name).
    static let guestKeychainGroups = 16

    /// Apple's provisioning libraries for on-device anisette.
    ///
    /// The digest is of the archive as served on 13 October 2026. There is no
    /// authoritative published hash to compare against, so this is trust on
    /// first use: if the host ever serves different bytes, Harbor refuses
    /// them. The libraries inside hash to
    ///   libCoreADI.so            48aa3fca97c3655229adab617e4eb455964ed6dbb25a25ca0fc5d8dd408af62d
    ///   libstoreservicescore.so  bd335e6963ba5ae2f5babca613435ad56d2660a9aee37df35f876c458d105ce4
    /// which can be checked against a copy extracted from Apple's own app.
    static let anisetteLibraries = AnisetteLibraryRelease(
        url: URL(string: "https://zzz.haus/oda.json")!,
        sha256: ContentDigest(hex: "a2f9aeef4cc31efda69ecdceeadd0f1bbd04199e6339b880636c14a3ecba2b96")!,
        size: 2_609_673
    )

    @MainActor
    static func live() throws -> Services {
        let fileManager = FileManager.default
        let support = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Harbor", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)

        // No guest apps run in this build, so the default keychain group is
        // acceptable. A host-only group is required before any guest does.
        let secrets = KeychainSecretStore(configuration: .init(hostOnlyAccessGroup: nil))
        let portal = DeveloperPortal.shared
        let anisette = OnDeviceAnisette(
            release: anisetteLibraries,
            directory: support.appendingPathComponent("anisette", isDirectory: true),
            secrets: secrets,
            download: OnDeviceAnisette.inlinePayloadDownload
        )
        let transport = MinimuxerTransport(
            diskImageDirectory: support.appendingPathComponent("disk-images", isDirectory: true))

        let device = UIDevice.current
        let identities = SigningIdentityStore(secrets: secrets)
        let documents = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return Services(
            secrets: secrets,
            account: AccountService(portal: portal, anisette: anisette, secrets: secrets),
            transport: transport,
            pipeline: InstallPipeline(
                portal: portal,
                identities: identities,
                transport: transport,
                machineName: "Harbor - \(device.name)",
                deviceName: device.name,
                workDirectory: fileManager.temporaryDirectory.appendingPathComponent("harbor-work", isDirectory: true)
            ),
            library: InstalledAppLibrary(fileURL: support.appendingPathComponent("apps.json")),
            deviceType: device.userInterfaceIdiom == .pad ? .iPad : .iPhone,
            guests: GuestLibrary(documents: documents, keychainGroupCount: guestKeychainGroups),
            identities: identities,
            guestSigner: GuestSigner()
        )
    }
}
