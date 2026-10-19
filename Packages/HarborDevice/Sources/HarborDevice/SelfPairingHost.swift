import Foundation
import HarborCore
import Minimuxer
import MinimuxerCommon

/// Makes this iPhone pair with itself, on iOS 27 and later: advertises
/// Harbor as a pairable host on Bonjour, waits for the user to pick it under
/// Settings › Privacy & Security › Developer Mode, hands over the PIN to
/// type, and returns the RemotePairing record the exchange produced.
///
/// The protocol is idevice's (`pairable_host_prepare`,
/// `pairable_host_accept_fd`), through minimuxer's `wirelessPair`. Two limits
/// come with that, and both are minimuxer's, not this type's:
/// - idevice makes a new host identity on every run, and minimuxer drops the
///   host `altIRK` that comes with it. The record keeps the host key pair,
///   so the record is what has to be kept; pairing again makes a new host.
/// - `stop()` stops advertising, but the thread waiting for the device stays
///   blocked in `accept()` until something connects or Harbor exits.
@MainActor
public final class SelfPairingHost {
    private let service: any WirelessPairAPI
    private let workDirectory: URL

    /// - Parameter workDirectory: where minimuxer writes the record before
    ///   Harbor takes it. It is emptied before and after every run.
    public convenience init(workDirectory: URL) {
        self.init(service: Minimuxer.shared.wirelessPair, workDirectory: workDirectory)
    }

    init(service: any WirelessPairAPI, workDirectory: URL) {
        self.service = service
        self.workDirectory = workDirectory
    }

    public struct Paired: Sendable {
        /// The record exactly as idevice wrote it. Store it as a secret.
        public let propertyList: Redacted<Data>
        public let record: PairingRecord
        /// The hardware model the device reported, e.g. "iPhone17,1".
        public let deviceModel: String
    }

    /// Advertises and waits for one pairing. Returns once the user has typed
    /// the PIN and the exchange finished, or throws if it failed.
    ///
    /// - Parameters:
    ///   - onAdvertising: called with the Bonjour instance name once the
    ///     service is published: the moment "Pair with Harbor" can appear.
    ///   - onPin: called with the six digits the user must type on the device.
    public func pair(
        onAdvertising: @escaping @MainActor @Sendable (String) -> Void,
        onPin: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> Paired {
        try prepareWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        service.onReadyToPair = { serviceID, _ in
            Task { @MainActor in onAdvertising(serviceID) }
        }
        service.onPinReceived = { pin in
            Task { @MainActor in onPin(pin) }
        }
        defer {
            service.onReadyToPair = nil
            service.onPinReceived = nil
        }

        let outPath = workDirectory.appendingPathComponent("record.plist").path
        let device: Returned = try await withCheckedThrowingContinuation { continuation in
            service.start(
                hostName: SelfPairing.hostName,
                hostModel: MinimuxerConstants.defaultHostModel,
                outPath: outPath,
                resolveFileName: nil
            ) { result in
                continuation.resume(with: result.map {
                    Returned(data: $0.pairingFile.rawData, model: $0.model, path: $0.pairingFilePath)
                })
            }
        }

        // idevice also wrote it to disk; the copy in memory is the one kept.
        try? FileManager.default.removeItem(atPath: device.path)
        return Paired(
            propertyList: Redacted(device.data),
            record: try SelfPairing.accept(device.data),
            deviceModel: device.model
        )
    }

    /// What minimuxer's `PairedDeviceRecord` carries that is used here.
    private struct Returned: Sendable {
        let data: Data
        let model: String
        let path: String
    }

    /// Stops advertising. A `pair` call in progress does not return until
    /// a device connects (see the type's notes).
    public func stop() {
        service.stop()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// The record is a credential: keep it out of backups and unreadable
    /// while the phone is locked, for the moment it is on disk.
    private func prepareWorkDirectory() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: workDirectory)
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var url = workDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
