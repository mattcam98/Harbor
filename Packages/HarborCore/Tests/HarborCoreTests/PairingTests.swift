import Foundation
import Testing

@testable import HarborCore

@Suite struct PairingRecordTests {
    static let certificate = Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".utf8)
    static let privateKey = Data("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\n".utf8)

    static var lockdown: [String: Any] {
        [
            "DeviceCertificate": certificate,
            "EscrowBag": Data([1, 2, 3]),
            "HostCertificate": certificate,
            "HostID": "5E1F0C5E-0D0B-4E0C-9A5C-6C1B6C0D7A11",
            "HostPrivateKey": privateKey,
            "RootCertificate": certificate,
            "RootPrivateKey": privateKey,
            "SystemBUID": "30142955-444094379208051516",
            "UDID": "00008110-000A1234567890AB",
            "WiFiMACAddress": "aa:bb:cc:dd:ee:ff",
        ]
    }

    static var remotePairing: [String: Any] {
        [
            "identifier": "9B0E7E0A-1C1D-4F7B-8B43-2D0C6F5E4A31",
            "private_key": Data(repeating: 7, count: 32),
            "public_key": Data(repeating: 9, count: 32),
        ]
    }

    static func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    @Test func parsesALockdownRecord() throws {
        let record = try PairingRecord(propertyList: Self.plist(Self.lockdown))
        #expect(record.lockdown?.udid == "00008110-000A1234567890AB")
        #expect(record.lockdown?.hostID == "5E1F0C5E-0D0B-4E0C-9A5C-6C1B6C0D7A11")
        #expect(record.remotePairing == nil)
    }

    @Test func parsesARemotePairingRecord() throws {
        let record = try PairingRecord(propertyList: Self.plist(Self.remotePairing))
        #expect(record.remotePairing?.identifier == "9B0E7E0A-1C1D-4F7B-8B43-2D0C6F5E4A31")
        #expect(record.lockdown == nil)
    }

    @Test func parsesACombinedRecord() throws {
        let combined = Self.lockdown.merging(Self.remotePairing) { first, _ in first }
        let record = try PairingRecord(propertyList: Self.plist(combined))
        #expect(record.lockdown != nil)
        #expect(record.remotePairing != nil)
    }

    @Test func reportsWhatIsMissing() throws {
        var partial = Self.lockdown
        partial["EscrowBag"] = nil
        partial["HostID"] = nil

        #expect(throws: PairingError.incomplete(
            missingLockdownKeys: ["EscrowBag", "HostID"],
            missingRemotePairingKeys: ["identifier", "private_key", "public_key"]
        )) {
            try PairingRecord(propertyList: Self.plist(partial))
        }
    }

    @Test func rejectsWhatIsNotAPropertyList() {
        #expect(throws: PairingError.notAPropertyList) {
            try PairingRecord(propertyList: Data("hello".utf8))
        }
    }

    @Test func rejectsMalformedLockdownFields() throws {
        let cases: [(key: String, value: Any)] = [
            ("UDID", "not-a-udid"),
            ("UDID", ""),
            ("HostCertificate", Data("garbage".utf8)),
            ("HostPrivateKey", Data("-----BEGIN CERTIFICATE-----".utf8)),
            ("EscrowBag", Data()),
            ("HostID", 42),
        ]
        for (key, value) in cases {
            var record = Self.lockdown
            record[key] = value
            let data = try Self.plist(record)
            #expect(throws: PairingError.invalidField(key)) {
                try PairingRecord(propertyList: data)
            }
        }
    }

    @Test func rejectsAnEmptyRemotePairingKey() throws {
        var record = Self.remotePairing
        record["private_key"] = Data()
        #expect(throws: PairingError.invalidField("private_key")) {
            try PairingRecord(propertyList: Self.plist(record))
        }
    }

    @Test(arguments: [
        ("00008110-000A1234567890AB", true),
        ("0123456789abcdef0123456789abcdef01234567", true),
        ("00008110000A1234567890AB", false),
        ("00008110-000A1234567890AG", false),
        ("", false),
    ])
    func recognisesDeviceIdentifiers(_ value: String, _ expected: Bool) {
        #expect(PairingRecord.isDeviceIdentifier(value) == expected)
    }

    @Test func descriptionRevealsNothing() throws {
        let combined = Self.lockdown.merging(Self.remotePairing) { first, _ in first }
        let record = try PairingRecord(propertyList: Self.plist(combined))

        var dumped = ""
        dump(record, to: &dumped)

        for rendering in ["\(record)", String(reflecting: record), dumped] {
            #expect(!rendering.contains("BEGIN"))
            #expect(!rendering.contains("00008110"))
        }
        #expect("\(record)" == "PairingRecord(lockdown+remote-pairing)")
    }
}

@Suite struct PairingRecordTransportTests {
    static var combined: [String: Any] {
        PairingRecordTests.lockdown.merging(PairingRecordTests.remotePairing) { first, _ in first }
    }

    @Test(arguments: [
        (17, 0, PairingRecord.Kind.lockdown),
        (17, 3, .lockdown),
        (17, 4, .remotePairing),
        (18, 0, .remotePairing),
        (26, 1, .remotePairing),
    ])
    func choosesCredentialsByOSVersionWhenBothArePresent(_ major: Int, _ minor: Int, _ expected: PairingRecord.Kind) throws {
        let record = try PairingRecord(propertyList: PairingRecordTests.plist(Self.combined))
        #expect(record.preferredKind(systemVersion: (major, minor)) == expected)
    }

    @Test func usesWhateverTheRecordHasWhenThereIsOnlyOneKind() throws {
        let lockdown = try PairingRecord(propertyList: PairingRecordTests.plist(PairingRecordTests.lockdown))
        let remote = try PairingRecord(propertyList: PairingRecordTests.plist(PairingRecordTests.remotePairing))

        #expect(lockdown.preferredKind(systemVersion: (26, 0)) == .lockdown)
        #expect(remote.preferredKind(systemVersion: (17, 0)) == .remotePairing)
    }

    @Test func convertsABinaryRecordToXMLText() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: PairingRecordTests.lockdown, format: .binary, options: 0)
        let record = try PairingRecord(propertyList: binary)

        let xml = try record.xmlRepresentation().expose()

        #expect(xml.hasPrefix("<?xml"))
        let reparsed = try PairingRecord(propertyList: Data(xml.utf8))
        #expect(reparsed.lockdown == record.lockdown)
    }
}

@Suite struct DeviceIssueTests {
    @Test func everyIssueHasOneNextStep() {
        #expect(DeviceIssue.vpnOff.recovery == .turnOnVPN)
        #expect(DeviceIssue.pairingMissing.recovery == .importPairingFile)
        #expect(DeviceIssue.pairingRejected("x").recovery == .replacePairingFile)
        #expect(DeviceIssue.deviceUnreachable("x").recovery == .retry)
        #expect(DeviceIssue.failed("x").recovery == .retry)
    }
}
