import Foundation
import HarborCore
import Minimuxer
import MinimuxerCommon

/// `DeviceTransport` backed by minimuxer, over the on-device loopback VPN.
public final class MinimuxerTransport: DeviceTransport, @unchecked Sendable {
    private let core: any MinimuxerAPI
    private let diskImageDirectory: URL
    private let systemVersion: (major: Int, minor: Int)

    /// - Parameter diskImageDirectory: where developer disk images are kept
    ///   for JIT. A private directory, not Documents.
    public convenience init(diskImageDirectory: URL) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        self.init(
            core: Minimuxer.shared.core,
            diskImageDirectory: diskImageDirectory,
            systemVersion: (version.majorVersion, version.minorVersion)
        )
    }

    init(core: any MinimuxerAPI, diskImageDirectory: URL, systemVersion: (major: Int, minor: Int)) {
        self.core = core
        self.diskImageDirectory = diskImageDirectory
        self.systemVersion = systemVersion
    }

    public func connect(using pairing: PairingRecord) async throws {
        let preferred: PairingProtocol =
            switch pairing.preferredKind(systemVersion: systemVersion) {
            case .lockdown: .lockdown
            case .remotePairing: .rppairing
            }
        let pairingFile = try pairing.xmlRepresentation()

        await core.bindConnectionConfig(Self.loopbackVPN)
        try await translating {
            try await core.start(
                pairingFile: pairingFile.expose(),
                mountPath: diskImageDirectory.absoluteString,
                preferred: preferred
            )
        }
    }

    public func deviceIdentifier() async throws -> String {
        try await translating { try await core.fetchUDID() }
    }

    public func installApp(at bundleURL: URL, bundleIdentifier: String) async throws {
        try await translating {
            try await core.sendAppBundleAfc(bundleId: bundleIdentifier, appURL: bundleURL)
            try await core.installAppBundle(bundleId: bundleIdentifier, appName: bundleURL.lastPathComponent)
        }
    }

    public func installProfile(_ profile: Data) async throws {
        try await translating { try await core.installProvisioningProfile(profile: profile) }
    }

    public func removeApp(bundleIdentifier: String) async throws {
        try await translating { try await core.removeApp(bundleId: bundleIdentifier) }
    }

    private func translating<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as MinimuxerError {
            throw Self.issue(for: error)
        }
    }

    /// Reduces minimuxer's errors to the few cases the user can act on.
    static func issue(for error: MinimuxerError) -> DeviceIssue {
        switch error {
        case .noVPN, .invalidVPN:
            .vpnOff
        case .pairingNotLoaded:
            .pairingMissing
        case .invalidPairing(_, let reason):
            .pairingRejected(reason)
        case .noDevice(let reason), .noConnection(let reason), .notReachable(let reason):
            .deviceUnreachable(reason)
        default:
            .failed(error.description)
        }
    }

    /// The device talks to itself through the VPN's tunnel interface.
    /// Nothing here points at another host.
    static let loopbackVPN = ConnectionConfigBinding(
        setTunnelIfaceIp: { _ in },
        setTunnelPeerIp: { _ in },
        setTunnelPeerSubnetMask: { _ in },
        setTunnelPeerReachable: { _ in },
        setTunnelIfaceSubnetMask: { _ in },
        getRemoteServerIp: { "" },
        setRemoteReachable: { _ in },
        getOverrideTunnelPeerIp: { "" },
        setOverrideTunnelPeerReachable: { _ in },
        getConnectionMode: { .localVPN }
    )
}
