import Foundation
import Testing

@testable import HarborCore

@Suite struct SelfPairingTests {
    /// The keys idevice writes for a RemotePairing file, as its string table
    /// lists them: the host's key pair and identifier, the device's
    /// `alt_irk`, and who made it.
    static var madeByIdevice: [String: Any] {
        PairingRecordTests.remotePairing.merging([
            "alt_irk": Data(repeating: 3, count: 16),
            "generated_by": "idevice",
        ]) { first, _ in first }
    }

    @Test func onlyIOS27AndLaterPairWithThemselves() {
        #expect(!SelfPairing.isSupported(systemVersion: (17, 0)))
        #expect(!SelfPairing.isSupported(systemVersion: (26, 7)))
        #expect(SelfPairing.isSupported(systemVersion: (27, 0)))
        #expect(SelfPairing.isSupported(systemVersion: (28, 1)))
    }

    @Test func acceptsARemotePairingRecord() throws {
        let record = try SelfPairing.accept(PairingRecordTests.plist(Self.madeByIdevice))
        #expect(record.remotePairing?.identifier == "9B0E7E0A-1C1D-4F7B-8B43-2D0C6F5E4A31")
        // It is what a stored record would connect with on iOS 27.
        #expect(record.preferredKind(systemVersion: (27, 0)) == .remotePairing)
    }

    @Test func refusesALockdownRecord() throws {
        #expect(throws: SelfPairingError.notARemotePairingRecord) {
            try SelfPairing.accept(PairingRecordTests.plist(PairingRecordTests.lockdown))
        }
        let combined = PairingRecordTests.lockdown.merging(Self.madeByIdevice) { first, _ in first }
        #expect(throws: SelfPairingError.notARemotePairingRecord) {
            try SelfPairing.accept(PairingRecordTests.plist(combined))
        }
    }

    @Test func refusesSomethingThatIsNotARecord() {
        #expect(throws: PairingError.self) {
            try SelfPairing.accept(Data("not a plist".utf8))
        }
    }

    @Test func reportsKeyNamesWithoutValues() throws {
        let names = SelfPairing.keyNames(of: try PairingRecordTests.plist(Self.madeByIdevice))
        #expect(names == ["alt_irk", "generated_by", "identifier", "private_key", "public_key"])
        #expect(SelfPairing.keyNames(of: Data("nope".utf8)).isEmpty)
    }
}
