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
            throw await diagnose(error)
        }
    }

    /// The issue behind a failed call. Reaching the device fails with
    /// little to go on (a bare "FetchUDID:" when LocalDevVPN is off), so
    /// minimuxer's own checks are asked what is actually wrong.
    private func diagnose(_ error: MinimuxerError) async -> DeviceIssue {
        let issue = Self.issue(for: error)
        guard case .deviceUnreachable = issue else { return issue }
        if case .failure(let cause) = await core.isReady(withNetworkCheck: false, withDDIMountCheck: false) {
            switch Self.issue(for: cause) {
            case .vpnOff: return .vpnOff
            case .pairingMissing: return .pairingMissing
            case .pairingRejected(let reason): return .pairingRejected(reason)
            case .deviceUnreachable, .failed: break
            }
        }
        return issue
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
        // Steps that only reach the device, failing before anything was
        // asked of it: the tunnel isn't carrying traffic (yet).
        case .notStarted(let reason), .muxerNotListening(let reason), .fetchUDID(let reason),
             .getLockdownValue(let reason), .connect(let reason), .xpcHandshake(let reason),
             .createLockdown(let reason), .createCoreDevice(let reason),
             .createSoftwareTunnel(let reason), .createRemoteServer(let reason):
            .deviceUnreachable(reason.isEmpty ? Self.step(error) : reason)
        default:
            .failed(error.description)
        }
    }

    /// The name minimuxer gives the step, as in "FetchUDID".
    private static func step(_ error: MinimuxerError) -> String {
        String(error.description.prefix { $0 != ":" && $0 != "(" })
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
