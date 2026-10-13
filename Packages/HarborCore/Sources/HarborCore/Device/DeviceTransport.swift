import Foundation

/// The device's own install services, reached through the loopback VPN with
/// the pairing record.
public protocol DeviceTransport: Sendable {
    /// Opens the connection. Must succeed before any other call.
    func connect(using pairing: PairingRecord) async throws
    func deviceIdentifier() async throws -> String
    /// Copies a signed app bundle to the device and installs it.
    func installApp(at bundleURL: URL, bundleIdentifier: String) async throws
    /// Installs a provisioning profile. This is all a refresh needs.
    func installProfile(_ profile: Data) async throws
    func removeApp(bundleIdentifier: String) async throws
}

/// Why a device operation failed, reduced to what the user can act on.
public enum DeviceIssue: Error, Equatable, Sendable {
    /// The loopback VPN is off or is not the expected kind.
    case vpnOff
    /// No pairing record has been loaded.
    case pairingMissing
    /// The device refused the pairing record, or it is malformed.
    case pairingRejected(String)
    /// The VPN is up but the device did not answer.
    case deviceUnreachable(String)
    /// Anything else, with the transport's own description.
    case failed(String)
}

/// The single next step that fixes a `DeviceIssue`.
public enum RecoveryAction: Equatable, Sendable {
    case turnOnVPN
    case importPairingFile
    /// The current pairing no longer works; a new one has to be made on a computer.
    case replacePairingFile
    case retry
}

extension DeviceIssue {
    public var recovery: RecoveryAction {
        switch self {
        case .vpnOff: .turnOnVPN
        case .pairingMissing: .importPairingFile
        case .pairingRejected: .replacePairingFile
        case .deviceUnreachable, .failed: .retry
        }
    }
}
