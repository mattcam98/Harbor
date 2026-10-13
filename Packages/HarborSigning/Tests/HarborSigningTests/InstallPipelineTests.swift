import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

final class FakeTransport: DeviceTransport, @unchecked Sendable {
    enum Call: Equatable {
        case deviceIdentifier
        case installApp(bundleName: String, bundleIdentifier: String, signedIdentifier: String?)
        case installProfile(Data)
    }

    static let udid = "00008110-000A1234567890AB"

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let failure: DeviceIssue?

    init(failingWith failure: DeviceIssue? = nil) {
        self.failure = failure
    }

    var calls: [Call] { lock.withLock { recorded } }

    func connect(using pairing: PairingRecord) async throws {}

    func deviceIdentifier() async throws -> String {
        lock.withLock { recorded.append(.deviceIdentifier) }
        if let failure { throw failure }
        return Self.udid
    }

    func installApp(at bundleURL: URL, bundleIdentifier: String) async throws {
        // Read the bundle now: the pipeline deletes its work directory afterwards.
        let call = Call.installApp(
            bundleName: bundleURL.lastPathComponent,
            bundleIdentifier: bundleIdentifier,
            signedIdentifier: FakeApp.identifier(at: bundleURL)
        )
        lock.withLock { recorded.append(call) }
    }

    func installProfile(_ profile: Data) async throws {
        lock.withLock { recorded.append(.installProfile(profile)) }
    }

    func removeApp(bundleIdentifier: String) async throws {}
}

@Suite struct InstallPipelineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    let secrets = InMemorySecretStore()
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-work-\(UUID().uuidString)", isDirectory: true)
    let account = SignedInAccount(account: FakePortal.account, team: FakePortal.team, session: FakePortal.session)

    var identities: SigningIdentityStore { SigningIdentityStore(secrets: secrets) }

    func pipeline(_ portal: FakePortal, _ transport: FakeTransport, signer: FakeSigner) -> InstallPipeline {
        InstallPipeline(
            portal: portal,
            identities: identities,
            transport: transport,
            signer: AppSigner(makeSigner: { _, _ in signer }),
            machineName: "Harbor - Test iPhone",
            deviceName: "Test iPhone",
            workDirectory: workDirectory
        )
    }

    func makeSigner() -> FakeSigner {
        FakeSigner(team: FakePortal.team, keyStore: Fixture.iPhoneDeveloper.keyStore)
    }

    /// Zips a fake app as `Payload/Example.app`, the layout of an IPA.
    static func makeIPA(payloadName: String = "Payload") throws -> (url: URL, cleanUp: @Sendable () -> Void) {
        let fileManager = FileManager.default
        let app = try FakeApp()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-ipa-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        try fileManager.createDirectory(
            at: contents.appendingPathComponent(payloadName), withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: app.appURL, to: contents.appendingPathComponent("\(payloadName)/Example.app"))
        app.remove()

        let ipa = root.appendingPathComponent("Example.ipa")
        try fileManager.zipDirectory(at: contents, to: ipa)
        return (ipa, { try? FileManager.default.removeItem(at: root) })
    }

    func workDirectoryIsEmpty() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []).isEmpty
    }

    @Test func installsAnIPAEndToEnd() async throws {
        let ipa = try Self.makeIPA()
        defer { ipa.cleanUp() }
        let portal = FakePortal()
        let transport = FakeTransport()
        let signer = makeSigner()
        let steps = StepLog()

        let installed = try await pipeline(portal, transport, signer: signer).install(
            ipaAt: ipa.url,
            account: account,
            activeApps: 0,
            isAlreadyActive: false,
            deviceType: .iPhone,
            onExistingCertificates: { _ in .cancel },
            progress: steps.record,
            now: Self.now
        )

        #expect(steps.values == InstallPipeline.Step.allCases)
        #expect(portal.calls == [
            .fetchDevices,
            .registerDevice(name: "Test iPhone", identifier: FakeTransport.udid),
            .fetchCertificates,
            .addCertificate(machineName: "Harbor - Test iPhone"),
            .fetchAppIDs,
            .addAppID(name: "Example", bundleIdentifier: "com.example.app.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01"),
            .addAppID(name: "Widget", bundleIdentifier: "com.example.app.widget.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.widget.TESTTEAM01"),
        ])
        #expect(signer.observations.count == 1)
        // The bundle handed to the device already carries its new identifier.
        #expect(transport.calls == [
            .deviceIdentifier,
            .installApp(
                bundleName: "Example.app",
                bundleIdentifier: "com.example.app.TESTTEAM01",
                signedIdentifier: "com.example.app.TESTTEAM01"),
        ])
        #expect(installed == InstalledApp(
            id: "com.example.app",
            installedBundleIdentifier: "com.example.app.TESTTEAM01",
            name: "Example",
            version: "1.2",
            targets: [
                .init(bundleIdentifier: "com.example.app", name: "Example"),
                .init(bundleIdentifier: "com.example.app.widget", name: "Widget"),
            ],
            expiry: Date(timeIntervalSince1970: 7 * 24 * 3600),
            installedAt: Self.now
        ))
        #expect(workDirectoryIsEmpty())
    }

    @Test func doesNotRegisterADeviceTheTeamAlreadyHas() async throws {
        let ipa = try Self.makeIPA()
        defer { ipa.cleanUp() }
        let known = Device(name: "Mine", identifier: FakeTransport.udid.lowercased(), type: .iPhone)
        let portal = FakePortal(devices: [known])

        _ = try await pipeline(portal, FakeTransport(), signer: makeSigner()).install(
            ipaAt: ipa.url, account: account, activeApps: 0, isAlreadyActive: false,
            deviceType: .iPhone, onExistingCertificates: { _ in .cancel }, now: Self.now)

        #expect(!portal.calls.contains { if case .registerDevice = $0 { true } else { false } })
    }

    @Test func aDeviceProblemStopsBeforeAnythingIsCreatedAtApple() async throws {
        let ipa = try Self.makeIPA()
        defer { ipa.cleanUp() }
        let portal = FakePortal()
        let transport = FakeTransport(failingWith: .vpnOff)

        await #expect(throws: DeviceIssue.vpnOff) {
            try await pipeline(portal, transport, signer: makeSigner()).install(
                ipaAt: ipa.url, account: account, activeApps: 0, isAlreadyActive: false,
                deviceType: .iPhone, onExistingCertificates: { _ in .cancel }, now: Self.now)
        }
        #expect(portal.calls.isEmpty)
        #expect(workDirectoryIsEmpty())
    }

    @Test func aBlockedInstallCreatesNoAppIDsAndCleansUp() async throws {
        let ipa = try Self.makeIPA()
        defer { ipa.cleanUp() }
        let portal = FakePortal()
        let transport = FakeTransport()

        await #expect(throws: ProvisioningError.blocked(.blockedByActiveAppLimit(active: 3, limit: 3))) {
            try await pipeline(portal, transport, signer: makeSigner()).install(
                ipaAt: ipa.url, account: account, activeApps: 3, isAlreadyActive: false,
                deviceType: .iPhone, onExistingCertificates: { _ in .cancel }, now: Self.now)
        }
        #expect(!portal.calls.contains { if case .addAppID = $0 { true } else { false } })
        #expect(transport.calls == [.deviceIdentifier])
        #expect(workDirectoryIsEmpty())
    }

    @Test func rejectsAnArchiveThatIsNotAnApp() async throws {
        let ipa = try Self.makeIPA(payloadName: "NotPayload")
        defer { ipa.cleanUp() }
        let portal = FakePortal()

        await #expect(throws: InstallError.notAnApp) {
            try await pipeline(portal, FakeTransport(), signer: makeSigner()).install(
                ipaAt: ipa.url, account: account, activeApps: 0, isAlreadyActive: false,
                deviceType: .iPhone, onExistingCertificates: { _ in .cancel }, now: Self.now)
        }
        #expect(portal.calls.isEmpty)
        #expect(workDirectoryIsEmpty())
    }

    static let installed = InstalledApp(
        id: "com.example.app",
        installedBundleIdentifier: "com.example.app.TESTTEAM01",
        name: "Example",
        version: "1.2",
        targets: [
            .init(bundleIdentifier: "com.example.app", name: "Example"),
            .init(bundleIdentifier: "com.example.app.widget", name: "Widget"),
        ],
        expiry: Date(timeIntervalSince1970: 100),
        installedAt: Date(timeIntervalSince1970: 0)
    )

    @Test func refreshInstallsNewProfilesAndMovesTheExpiry() async throws {
        try identities.save(Fixture.iPhoneDeveloper.keyStore)
        let portal = FakePortal(certificates: [Fixture.iPhoneDeveloper.certificate])
        let transport = FakeTransport()

        let refreshed = try await pipeline(portal, transport, signer: makeSigner()).refresh(
            Self.installed, account: account, deviceType: .iPhone, now: Self.now)

        #expect(refreshed.expiry == Date(timeIntervalSince1970: 7 * 24 * 3600))
        #expect(refreshed.id == Self.installed.id)
        // Two profiles pushed, no app transfer, no certificate created.
        #expect(transport.calls == [.installProfile(Data()), .installProfile(Data())])
        #expect(!portal.calls.contains { if case .addCertificate = $0 { true } else { false } })
    }

    @Test func refreshRefusesWhenTheSigningCertificateIsGone() async throws {
        try identities.save(Fixture.iPhoneDeveloper.keyStore)
        let portal = FakePortal(certificates: [Fixture.iOSDevelopment.certificate])
        let transport = FakeTransport()

        await #expect(throws: InstallError.reinstallRequired) {
            try await pipeline(portal, transport, signer: makeSigner()).refresh(
                Self.installed, account: account, deviceType: .iPhone, now: Self.now)
        }
        #expect(transport.calls.isEmpty)
        #expect(portal.calls == [.fetchCertificates])
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [InstallPipeline.Step] = []
    var values: [InstallPipeline.Step] { lock.withLock { steps } }
    func record(_ step: InstallPipeline.Step) { lock.withLock { steps.append(step) } }
}
