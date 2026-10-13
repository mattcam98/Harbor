import Foundation
import Testing

@testable import HarborCore

@Suite struct InstalledAppLibraryTests {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-library-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("apps.json")

    func cleanUp() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    static func app(_ id: String, expiresAt seconds: TimeInterval = 1_800_600_000) -> InstalledApp {
        InstalledApp(
            id: id,
            installedBundleIdentifier: "\(id).TEAM",
            name: id.uppercased(),
            version: "1.0",
            targets: [.init(bundleIdentifier: id, name: id.uppercased())],
            expiry: Date(timeIntervalSince1970: seconds),
            installedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func startsEmpty() async throws {
        #expect(try await InstalledAppLibrary(fileURL: fileURL).all().isEmpty)
    }

    @Test func savesAndReloadsAcrossInstances() async throws {
        defer { cleanUp() }
        let library = InstalledAppLibrary(fileURL: fileURL)
        try await library.save(Self.app("b.app"))
        try await library.save(Self.app("a.app"))

        let reloaded = try await InstalledAppLibrary(fileURL: fileURL).all()
        #expect(reloaded == [Self.app("a.app"), Self.app("b.app")])
    }

    @Test func savingAgainReplacesTheEntry() async throws {
        defer { cleanUp() }
        let library = InstalledAppLibrary(fileURL: fileURL)
        try await library.save(Self.app("a.app"))
        try await library.save(Self.app("a.app", expiresAt: 1_801_000_000))

        let apps = try await library.all()
        #expect(apps.count == 1)
        #expect(apps.first?.expiry == Date(timeIntervalSince1970: 1_801_000_000))
    }

    @Test func removes() async throws {
        defer { cleanUp() }
        let library = InstalledAppLibrary(fileURL: fileURL)
        try await library.save(Self.app("a.app"))
        try await library.save(Self.app("b.app"))
        try await library.remove(id: "a.app")

        #expect(try await library.all().map(\.id) == ["b.app"])
    }

    @Test func aCorruptFileIsAnErrorNotAnEmptyList() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let library = InstalledAppLibrary(fileURL: fileURL)
        await #expect(throws: DecodingError.self) { try await library.all() }
        // Saving must not paper over it either.
        await #expect(throws: DecodingError.self) { try await library.save(Self.app("a.app")) }
        #expect(try Data(contentsOf: fileURL) == Data("not json".utf8))
    }

    @Test func feedsTheRefreshPlanner() {
        let app = Self.app("a.app")
        #expect(app.signedApp == SignedApp(
            bundleIdentifier: "a.app", name: "A.APP", expiry: app.expiry, isHost: false))
    }
}
