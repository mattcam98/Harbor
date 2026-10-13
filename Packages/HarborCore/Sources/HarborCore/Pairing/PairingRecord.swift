import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case notAPropertyList
    /// Neither a complete lockdown record nor a complete RemotePairing record.
    case incomplete(missingLockdownKeys: [String], missingRemotePairingKeys: [String])
    /// A required field is present but has the wrong type or shape.
    case invalidField(String)
}

/// Credentials that let a host talk to a device's services.
///
/// A record may carry classic lockdown credentials, RemotePairing credentials
/// (iOS 17.4 and later), or both in one property list.
///
/// The record is as sensitive as a password: whoever holds it can install
/// apps on, and read data from, the device. Its description never includes
/// the contents, and the raw bytes are only reachable through `raw.expose()`.
public struct PairingRecord: Sendable {
    public struct Lockdown: Equatable, Sendable {
        public let udid: String
        public let hostID: String
        public let systemBUID: String
    }

    public struct RemotePairing: Equatable, Sendable {
        public let identifier: String
    }

    public let lockdown: Lockdown?
    public let remotePairing: RemotePairing?
    public let raw: Redacted<Data>

    static let lockdownKeys = [
        "DeviceCertificate", "EscrowBag", "HostCertificate", "HostID", "HostPrivateKey",
        "RootCertificate", "RootPrivateKey", "SystemBUID", "UDID", "WiFiMACAddress",
    ]
    static let remotePairingKeys = ["identifier", "private_key", "public_key"]

    public init(propertyList data: Data) throws {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = object as? [String: Any]
        else {
            throw PairingError.notAPropertyList
        }

        let missingLockdown = Self.lockdownKeys.filter { plist[$0] == nil }
        let missingRemote = Self.remotePairingKeys.filter { plist[$0] == nil }
        guard missingLockdown.isEmpty || missingRemote.isEmpty else {
            throw PairingError.incomplete(
                missingLockdownKeys: missingLockdown,
                missingRemotePairingKeys: missingRemote
            )
        }

        self.lockdown = missingLockdown.isEmpty ? try Self.parseLockdown(plist) : nil
        self.remotePairing = missingRemote.isEmpty ? try Self.parseRemotePairing(plist) : nil
        self.raw = Redacted(data)
    }

    private static func parseLockdown(_ plist: [String: Any]) throws -> Lockdown {
        for key in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
            try requirePEM(plist, key, label: "CERTIFICATE")
        }
        for key in ["HostPrivateKey", "RootPrivateKey"] {
            try requirePEM(plist, key, label: "PRIVATE KEY")
        }
        guard let escrowBag = plist["EscrowBag"] as? Data, !escrowBag.isEmpty else {
            throw PairingError.invalidField("EscrowBag")
        }

        let udid = try requireString(plist, "UDID")
        guard isDeviceIdentifier(udid) else { throw PairingError.invalidField("UDID") }

        return Lockdown(
            udid: udid,
            hostID: try requireString(plist, "HostID"),
            systemBUID: try requireString(plist, "SystemBUID")
        )
    }

    private static func parseRemotePairing(_ plist: [String: Any]) throws -> RemotePairing {
        for key in ["private_key", "public_key"] {
            guard let value = plist[key] as? Data, !value.isEmpty else {
                throw PairingError.invalidField(key)
            }
        }
        return RemotePairing(identifier: try requireString(plist, "identifier"))
    }

    private static func requireString(_ plist: [String: Any], _ key: String) throws -> String {
        guard let value = plist[key] as? String, !value.isEmpty else {
            throw PairingError.invalidField(key)
        }
        return value
    }

    /// Pair records store certificates and keys as PEM text inside a data value.
    private static func requirePEM(_ plist: [String: Any], _ key: String, label: String) throws {
        guard
            let value = plist[key] as? Data,
            let text = String(data: value, encoding: .utf8),
            text.hasPrefix("-----BEGIN "),
            text.contains("\(label)-----")
        else {
            throw PairingError.invalidField(key)
        }
    }

    /// 40 hexadecimal characters, or the newer `8-16` hexadecimal form.
    static func isDeviceIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = parts.map(\.count)
        guard lengths == [40] || lengths == [8, 16] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }
}

extension PairingRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let kinds = [lockdown.map { _ in "lockdown" }, remotePairing.map { _ in "remote-pairing" }]
        return "PairingRecord(\(kinds.compactMap { $0 }.joined(separator: "+")))"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
