import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

/// Records the state of the bundle at the moment signing is requested.
final class FakeSigner: CodeSignerAPI, @unchecked Sendable {
    struct Observation: Equatable {
        var profileIdentifiers: [String]
        var appIdentifier: String?
        var extensionIdentifier: String?
        var oldSignaturePresent: Bool
    }

    let team: Team
    let keyStore: KeyStore
    private let lock = NSLock()
    private var recorded: [Observation] = []

    init(team: Team, keyStore: KeyStore) {
        self.team = team
        self.keyStore = keyStore
    }

    var observations: [Observation] { lock.withLock { recorded } }

    func signApp(at appURL: URL, provisioningProfiles profiles: [ProvisioningProfile], progress: Progress?) async throws {
        let observation = Observation(
            profileIdentifiers: profiles.map(\.bundleIdentifier),
            appIdentifier: FakeApp.identifier(at: appURL),
            extensionIdentifier: FakeApp.identifier(at: appURL.appendingPathComponent("PlugIns/Widget.appex")),
            oldSignaturePresent: FileManager.default.fileExists(
                atPath: appURL.appendingPathComponent("_CodeSignature").path)
        )
        lock.withLock { recorded.append(observation) }
    }
}

/// An app bundle on disk with one extension and a stale signature.
struct FakeApp {
    let root: URL
    var appURL: URL { root.appendingPathComponent("Example.app", isDirectory: true) }
    var extensionURL: URL { appURL.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true) }

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-app-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: appURL.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: appURL.appendingPathComponent("_CodeSignature/CodeResources"))

        try Self.write([
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example",
            "CFBundleExecutable": "Example",
            "CFBundleShortVersionString": "1.2",
            "BGTaskSchedulerPermittedIdentifiers": ["com.example.app.refresh", "com.example.app", "org.other.task"],
        ], to: appURL)
        try Self.write([
            "CFBundleIdentifier": "com.example.app.widget",
            "CFBundleName": "Widget",
            "CFBundleExecutable": "Widget",
        ], to: extensionURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func write(_ info: [String: Any], to bundle: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
    }

    static func info(at bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func identifier(at bundle: URL) -> String? {
        info(at: bundle)?["CFBundleIdentifier"] as? String
    }

    static func profile(for identifier: String) -> ProvisioningProfile {
        ProvisioningProfile(
            name: "Profile \(identifier)",
            uuid: UUID(),
            bundleIdentifier: "\(identifier).TESTTEAM01",
            teamIdentifier: "TESTTEAM01",
            teamName: "Test Team",
            creationDate: Date(timeIntervalSince1970: 0),
            expirationDate: Date(timeIntervalSince1970: 7 * 24 * 3600),
            data: Data()
        )
    }
}

@Suite struct AppSignerTests {
    let identity = Fixture.iPhoneDeveloper.keyStore

    func signer(recordingTo fake: FakeSigner) -> AppSigner {
        AppSigner(makeSigner: { _, _ in fake })
    }

    @Test func listsTheAppThenItsExtensions() throws {
        let app = try FakeApp()
        defer { app.remove() }

        #expect(try AppSigner.targets(ofAppAt: app.appURL) == [
            SigningTarget(bundleIdentifier: "com.example.app", name: "Example"),
            SigningTarget(bundleIdentifier: "com.example.app.widget", name: "Widget"),
        ])
    }

    @Test func givesEachBundleItsProfilesIdentifierBeforeSigning() async throws {
        let app = try FakeApp()
        defer { app.remove() }
        let fake = FakeSigner(team: FakePortal.team, keyStore: identity)

        try await signer(recordingTo: fake).sign(
            appAt: app.appURL,
            profiles: [
                "com.example.app": FakeApp.profile(for: "com.example.app"),
                "com.example.app.widget": FakeApp.profile(for: "com.example.app.widget"),
            ],
            identity: identity,
            team: FakePortal.team
        )

        #expect(fake.observations == [
            FakeSigner.Observation(
                profileIdentifiers: ["com.example.app.TESTTEAM01", "com.example.app.widget.TESTTEAM01"],
                appIdentifier: "com.example.app.TESTTEAM01",
                extensionIdentifier: "com.example.app.widget.TESTTEAM01",
                oldSignaturePresent: false
            )
        ])

        let info = try #require(FakeApp.info(at: app.appURL))
        #expect(info["BGTaskSchedulerPermittedIdentifiers"] as? [String] == [
            "com.example.app.TESTTEAM01.refresh", "com.example.app.TESTTEAM01", "org.other.task",
        ])
        #expect(info["CFBundleShortVersionString"] as? String == "1.2")
    }

    @Test func aMissingProfileLeavesTheAppUntouched() async throws {
        let app = try FakeApp()
        defer { app.remove() }
        let fake = FakeSigner(team: FakePortal.team, keyStore: identity)

        await #expect(throws: AppSigningError.missingProfile(bundleIdentifier: "com.example.app.widget")) {
            try await signer(recordingTo: fake).sign(
                appAt: app.appURL,
                profiles: ["com.example.app": FakeApp.profile(for: "com.example.app")],
                identity: identity,
                team: FakePortal.team
            )
        }

        #expect(fake.observations.isEmpty)
        #expect(FakeApp.identifier(at: app.appURL) == "com.example.app")
        #expect(FileManager.default.fileExists(atPath: app.appURL.appendingPathComponent("_CodeSignature").path))
    }

    @Test func rejectsSomethingThatIsNotAnApp() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).app")

        #expect(throws: AppSigningError.invalidApp) {
            try AppSigner.targets(ofAppAt: missing)
        }
        await #expect(throws: AppSigningError.invalidApp) {
            try await AppSigner().sign(appAt: missing, profiles: [:], identity: identity, team: FakePortal.team)
        }
    }

    @Test func rebasesBackgroundTaskIdentifiersWithoutDuplicates() {
        #expect(AppSigner.rebased(
            ["a.b", "a.b.sync", "a.b.T", "a.bc", "x.y"], from: "a.b", to: "a.b.T"
        ) == ["a.b.T", "a.b.T.sync", "a.bc", "x.y"])
    }
}
