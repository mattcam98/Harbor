import Combine
import Foundation
import HarborCore
import Minimuxer
import MinimuxerCommon
import Testing

@testable import HarborDevice

/// Records calls and fails on demand. Members outside the transport's use
/// throw, so a test that strays fails loudly.
final class FakeMinimuxer: MinimuxerAPI, @unchecked Sendable {
    struct Unsupported: Error {}

    enum Call: Equatable {
        case bindConnectionConfig(mode: DeviceConnectionMode)
        case start(pairingFileIsXML: Bool, mountPath: String, preferred: PairingProtocol?)
        case fetchUDID
        case sendAppBundle(bundleId: String, appName: String)
        case installAppBundle(bundleId: String, appName: String)
        case installProfile(Data)
        case removeApp(bundleId: String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let failure: MinimuxerError?
    private let readiness: Result<Bool, MinimuxerError>

    init(failingWith failure: MinimuxerError? = nil, readiness: Result<Bool, MinimuxerError> = .success(false)) {
        self.failure = failure
        self.readiness = readiness
    }

    var calls: [Call] { lock.withLock { recorded } }

    private func record(_ call: Call) throws {
        lock.withLock { recorded.append(call) }
        if let failure { throw failure }
    }

    // MARK: Used by the transport

    func bindConnectionConfig(_ binding: ConnectionConfigBinding) async {
        let mode = binding.getConnectionMode()
        lock.withLock { recorded.append(.bindConnectionConfig(mode: mode)) }
    }

    func start(pairingFile: String, mountPath: String, preferred: PairingProtocol?) async throws {
        try record(.start(pairingFileIsXML: pairingFile.hasPrefix("<?xml"), mountPath: mountPath, preferred: preferred))
    }

    func fetchUDID() async throws -> String {
        try record(.fetchUDID)
        return "00008110-000A1234567890AB"
    }

    func sendAppBundleAfc(bundleId: String, appURL: URL) async throws {
        try record(.sendAppBundle(bundleId: bundleId, appName: appURL.lastPathComponent))
    }

    func installAppBundle(bundleId: String, appName: String) async throws {
        try record(.installAppBundle(bundleId: bundleId, appName: appName))
    }

    func installProvisioningProfile(profile: Data) async throws {
        try record(.installProfile(profile))
    }

    func removeApp(bundleId: String) async throws {
        try record(.removeApp(bundleId: bundleId))
    }

    // MARK: Not part of these tests

    var pairingFileType: PairingProtocol { .unknown }
    var isLoggingEnabled: Bool { false }
    var isPairingFileLoaded: Bool { false }
    var deviceProbeTimeout: Int { 0 }
    var statusPublisher: AnyPublisher<Result<Bool, MinimuxerError>, Never> { Empty().eraseToAnyPublisher() }
    func getConnectionMode() async -> DeviceConnectionMode { .notConfigured }
    func isReady(withNetworkCheck: Bool, withDDIMountCheck: Bool) async -> Result<Bool, MinimuxerError> { readiness }
    func describeError(_ error: MinimuxerError) -> String { error.description }
    func setLogging(_ enabled: Bool) {}
    func setDeviceProbeTimeout(_ timeoutMs: Int) {}
    func stop() async throws { throw Unsupported() }
    func restart() async throws { throw Unsupported() }
    func reinitializePairingData(pairingFile: String) async throws { throw Unsupported() }
    func mountDDI(docsPath: String) async throws -> Bool { throw Unsupported() }
    func isDDIMounted() async throws -> Bool { throw Unsupported() }
    func testDeviceConnection(ifaddr: String, timeout: Int) -> Bool { false }
    func sendIpaAfc(bundleId: String, ipaBytes: Data) async throws { throw Unsupported() }
    func installIpa(bundleId: String) async throws { throw Unsupported() }
    func wipeContainer(identifier: String) async throws { throw Unsupported() }
    func debugApp(appId: String) async throws { throw Unsupported() }
    func attachDebugger(pid: UInt32) async throws { throw Unsupported() }
    func removeProvisioningProfile(id: String) async throws { throw Unsupported() }
    func dumpProfiles(docsPath: String, mode: ProfileDumpMode) async throws -> String { throw Unsupported() }
    func afcListDirectory(bundleId: String, path: String) async throws -> [String] { throw Unsupported() }
    func afcReadFile(bundleId: String, path: String) async throws -> Data { throw Unsupported() }
    func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) { throw Unsupported() }
}

enum PairingFixture {
    static let certificate = Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".utf8)
    static let privateKey = Data("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----\n".utf8)

    static var lockdown: [String: Any] { [
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
    ] }

    static var remotePairing: [String: Any] { [
        "identifier": "9B0E7E0A-1C1D-4F7B-8B43-2D0C6F5E4A31",
        "private_key": Data(repeating: 7, count: 32),
        "public_key": Data(repeating: 9, count: 32),
    ] }

    /// A record with both kinds of credentials, in binary form.
    static func combined() throws -> PairingRecord {
        let merged = lockdown.merging(remotePairing) { first, _ in first }
        return try PairingRecord(
            propertyList: PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0))
    }
}

@Suite struct MinimuxerTransportTests {
    let directory = URL(fileURLWithPath: "/private/harbor/disk-images", isDirectory: true)

    func transport(_ fake: FakeMinimuxer, iOS version: (Int, Int) = (18, 0)) -> MinimuxerTransport {
        MinimuxerTransport(core: fake, diskImageDirectory: directory, systemVersion: version)
    }

    @Test func connectsOverTheLoopbackVPNWithRemotePairingOnCurrentSystems() async throws {
        let fake = FakeMinimuxer()

        try await transport(fake).connect(using: PairingFixture.combined())

        #expect(fake.calls == [
            .bindConnectionConfig(mode: .localVPN),
            .start(pairingFileIsXML: true, mountPath: directory.absoluteString, preferred: .rppairing),
        ])
    }

    @Test func usesLockdownCredentialsBeforeiOS17Point4() async throws {
        let fake = FakeMinimuxer()

        try await transport(fake, iOS: (17, 2)).connect(using: PairingFixture.combined())

        #expect(fake.calls.last == .start(
            pairingFileIsXML: true, mountPath: directory.absoluteString, preferred: .lockdown))
    }

    @Test func installsByCopyingTheBundleThenAskingTheDeviceToInstallIt() async throws {
        let fake = FakeMinimuxer()
        let bundle = URL(fileURLWithPath: "/tmp/work/Example.app", isDirectory: true)

        try await transport(fake).installApp(at: bundle, bundleIdentifier: "com.example.app.TEAM")

        #expect(fake.calls == [
            .sendAppBundle(bundleId: "com.example.app.TEAM", appName: "Example.app"),
            .installAppBundle(bundleId: "com.example.app.TEAM", appName: "Example.app"),
        ])
    }

    @Test func forwardsProfilesRemovalsAndTheIdentifier() async throws {
        let fake = FakeMinimuxer()
        let subject = transport(fake)

        try await subject.installProfile(Data("profile".utf8))
        try await subject.removeApp(bundleIdentifier: "com.example.app.TEAM")
        #expect(try await subject.deviceIdentifier() == "00008110-000A1234567890AB")

        #expect(fake.calls == [
            .installProfile(Data("profile".utf8)),
            .removeApp(bundleId: "com.example.app.TEAM"),
            .fetchUDID,
        ])
    }

    @Test func aFailedCopyStopsBeforeInstalling() async throws {
        let fake = FakeMinimuxer(failingWith: .rwAfc("disk full"))
        let bundle = URL(fileURLWithPath: "/tmp/work/Example.app", isDirectory: true)

        await #expect(throws: DeviceIssue.self) {
            try await transport(fake).installApp(at: bundle, bundleIdentifier: "com.example.app.TEAM")
        }
        #expect(fake.calls == [.sendAppBundle(bundleId: "com.example.app.TEAM", appName: "Example.app")])
    }

    @Test func reportsFailuresAsIssuesTheUserCanActOn() async throws {
        let cases: [(MinimuxerError, DeviceIssue)] = [
            (.noVPN("off"), .vpnOff),
            (.invalidVPN("wrong kind"), .vpnOff),
            (.pairingNotLoaded("none"), .pairingMissing),
            (.invalidPairing(protocol: .rppairing, reason: "refused"), .pairingRejected("refused")),
            (.noDevice("gone"), .deviceUnreachable("gone")),
            (.noConnection("gone"), .deviceUnreachable("gone")),
            (.notReachable("gone"), .deviceUnreachable("gone")),
        ]
        for (error, issue) in cases {
            #expect(MinimuxerTransport.issue(for: error) == issue)

            let fake = FakeMinimuxer(failingWith: error)
            await #expect(throws: issue) {
                try await transport(fake).deviceIdentifier()
            }
        }

        guard case .failed(let description) = MinimuxerTransport.issue(for: .installApp("code 3")) else {
            Issue.record("expected a generic failure")
            return
        }
        #expect(description.contains("code 3"))
    }

    /// With LocalDevVPN off, fetching the identifier fails with no reason.
    @Test func aBareFailureToReachTheDeviceIsExplainedByMinimuxersChecks() async throws {
        #expect(MinimuxerTransport.issue(for: .fetchUDID("")) == .deviceUnreachable("FetchUDID"))

        let vpnOff = FakeMinimuxer(failingWith: .fetchUDID(""), readiness: .failure(.noVPN("no utun")))
        await #expect(throws: DeviceIssue.vpnOff) {
            try await transport(vpnOff).deviceIdentifier()
        }

        let notAnswering = FakeMinimuxer(failingWith: .fetchUDID("timed out"), readiness: .failure(.fetchUDID("timed out")))
        await #expect(throws: DeviceIssue.deviceUnreachable("timed out")) {
            try await transport(notAnswering).deviceIdentifier()
        }
    }

    @Test func unrelatedFailuresAreNotRediagnosed() async throws {
        let fake = FakeMinimuxer(failingWith: .profileInstall("bad profile"), readiness: .failure(.noVPN("no utun")))
        guard case .failed(let description) = MinimuxerTransport.issue(for: .profileInstall("bad profile")) else {
            Issue.record("expected a generic failure")
            return
        }
        #expect(description.contains("bad profile"))
        await #expect(throws: DeviceIssue.failed(description)) {
            try await transport(fake).installProfile(Data())
        }
    }
}
