import Foundation

/// Rules for the pairing record an iPhone on iOS 27 makes with itself.
///
/// iOS 27 lets an app act as a "pairable host": it advertises
/// `serviceType` on Bonjour, the user picks it under Settings › Privacy &
/// Security › Developer Mode and types the PIN the app shows, and the app
/// gets a RemotePairing record for this phone. No computer is involved.
/// iOS 26 and earlier have no such thing, so Harbor Setup stays the way to
/// make a record there.
///
/// The exchange itself is idevice's, reached through minimuxer; this type
/// only holds what can be decided without a device.
public enum SelfPairing {
    /// The Bonjour service a pairable host publishes. It must also be listed
    /// under `NSBonjourServices` in the app's Info.plist, without the
    /// trailing dot.
    public static let serviceType = "_remotepairing-pairable-host._tcp"

    /// The name iOS shows as "Pair with …".
    public static let hostName = "Harbor"

    /// Whether this version of iOS can pair with itself.
    public static func isSupported(systemVersion: (major: Int, minor: Int)) -> Bool {
        systemVersion.major >= 27
    }

    /// Checks that what the pairing returned can be stored as this device's
    /// record: RemotePairing credentials, and no lockdown ones (iOS 27
    /// refuses lockdown on every route, so a record that claims to have them
    /// did not come from this exchange).
    public static func accept(_ propertyList: Data) throws -> PairingRecord {
        let record = try PairingRecord(propertyList: propertyList)
        guard record.remotePairing != nil, record.lockdown == nil else {
            throw SelfPairingError.notARemotePairingRecord
        }
        return record
    }

    /// The top-level key names of a record, sorted, and never their values:
    /// what a device test may report without leaking the credentials.
    public static func keyNames(of propertyList: Data) -> [String] {
        guard
            let object = try? PropertyListSerialization.propertyList(from: propertyList, format: nil),
            let plist = object as? [String: Any]
        else { return [] }
        return plist.keys.sorted()
    }
}

public enum SelfPairingError: Error, Equatable, Sendable {
    /// The pairing finished but did not return a RemotePairing-only record.
    case notARemotePairingRecord
    /// This version of iOS cannot pair with itself.
    case unsupportedSystem
}
