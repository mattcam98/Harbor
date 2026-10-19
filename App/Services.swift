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
    /// Where Harbor Setup leaves a pairing file.
    let pairingInbox: PairingInbox
    /// Where Harbor Setup leaves the certificate Harbor was signed with.
    let identityInbox: IdentityInbox
    /// The sources of apps the user has added.
    let sources: SourceList
    let downloader: ArtifactDownloader

    /// Keychain access groups reserved for guests in Harbor's entitlements
    /// (`com.kdt.livecontainer.shared` and `.1` to `.15`; the engine picks
    /// them by this name).
    static let guestKeychainGroups = 16

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
        // Apple refuses machine identities made on the phone (-80045), so
        // they come from servers that make them on a real Mac.
        let anisette = ServerAnisette(
            directory: support.appendingPathComponent("anisette-server", isDirectory: true),
            secrets: secrets
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
            guestSigner: GuestSigner(),
            pairingInbox: PairingInbox(directory: support),
            identityInbox: IdentityInbox(directory: support),
            sources: SourceList(fileURL: support.appendingPathComponent("sources.json")),
            downloader: ArtifactDownloader()
        )
    }
}
