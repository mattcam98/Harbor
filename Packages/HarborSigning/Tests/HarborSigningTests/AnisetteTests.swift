import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

/// Stands in for Apple's libraries: records what it was asked and returns a
/// new blob once, the way first-time provisioning does.
final class FakeGenerator: AnisetteGenerating, @unchecked Sendable {
    struct Request: Equatable {
        var identifier: UUID
        var existingBlob: Data?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    func generate(
        libraries: URL,
        provisioning: URL,
        identifier: UUID,
        existingBlob: Data?
    ) async throws -> (data: AnisetteData, newBlob: Data?) {
        let isFirst = lock.withLock { () -> Bool in
            recorded.append(Request(identifier: identifier, existingBlob: existingBlob))
            return recorded.count == 1
        }
        return (FakeAnisette.data(oneTimePassword: "otp"), isFirst ? Data("provisioned".utf8) : nil)
    }
}

final class DownloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite struct OnDeviceAnisetteTests {
    let secrets = InMemorySecretStore()
    let generator = FakeGenerator()
    let downloads = DownloadCounter()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-anisette-\(UUID().uuidString)", isDirectory: true)

    static let libraryNames = ["libstoreservicescore.so", "libCoreADI.so"]

    /// Builds a zip holding empty files with the given names.
    static func archive(containing names: [String]) throws -> Data {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-archive-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        for name in names {
            try Data("stub".utf8).write(to: contents.appendingPathComponent(name))
        }
        let zipURL = root.appendingPathComponent("archive.zip")
        try fileManager.zipDirectory(at: contents, to: zipURL)
        return try Data(contentsOf: zipURL)
    }

    func anisette(serving archive: Data, expecting digest: ContentDigest) -> OnDeviceAnisette {
        let downloads = self.downloads
        return OnDeviceAnisette(
            release: AnisetteLibraryRelease(url: URL(string: "https://example.com/libraries.zip")!, sha256: digest),
            directory: directory,
            secrets: secrets,
            download: { _ in
                downloads.increment()
                return archive
            },
            generator: generator
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func installsVerifiedLibrariesOnceAndKeepsItsState() async throws {
        defer { cleanUp() }
        let archive = try Self.archive(containing: Self.libraryNames)
        let subject = anisette(serving: archive, expecting: ContentDigest(hashing: archive))

        _ = try await subject.anisetteData()
        _ = try await subject.anisetteData()

        #expect(downloads.value == 1)
        #expect(subject.librariesInstalled)

        // Same device identifier both times; the blob from the first run is
        // handed back on the second.
        let requests = generator.requests
        #expect(requests.count == 2)
        #expect(requests[0].existingBlob == nil)
        #expect(requests[1].identifier == requests[0].identifier)
        #expect(requests[1].existingBlob == Data("provisioned".utf8))
        #expect(try subject.loadState()?.blob == Data("provisioned".utf8))
    }

    @Test func refusesLibrariesThatDoNotMatchThePinnedDigest() async throws {
        defer { cleanUp() }
        let archive = try Self.archive(containing: Self.libraryNames)
        let pinned = ContentDigest(hashing: Data("the release we trust".utf8))
        let subject = anisette(serving: archive, expecting: pinned)

        await #expect(throws: VerificationError.digestMismatch(
            expected: pinned, actual: ContentDigest(hashing: archive))
        ) {
            try await subject.anisetteData()
        }
        #expect(!subject.librariesInstalled)
        #expect(!FileManager.default.fileExists(atPath: subject.librariesDirectory.path))
        #expect(generator.requests.isEmpty)
        #expect(try secrets.read(.anisetteState) == nil)
    }

    @Test func refusesAVerifiedArchiveWithoutTheLibraries() async throws {
        defer { cleanUp() }
        let archive = try Self.archive(containing: ["readme.txt"])
        let subject = anisette(serving: archive, expecting: ContentDigest(hashing: archive))

        await #expect(throws: AnisetteSetupError.missingLibraries) {
            try await subject.installLibrariesIfNeeded()
        }
        #expect(!FileManager.default.fileExists(atPath: subject.librariesDirectory.path))
    }
}

@Suite struct SafeArchiveTests {
    @Test func refusesEntriesThatEscapeTheDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-zipslip-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let zipURL = root.appendingPathComponent("hostile.zip")
        let writer = try Archive.Writer.create(at: zipURL)
        try writer.writeFile(path: "ok.txt", data: Data("fine".utf8), permissions: 0o100644)
        try writer.writeFile(path: "../escaped.txt", data: Data("gotcha".utf8), permissions: 0o100644)
        try writer.close()

        #expect(throws: ArchivePolicyError.unsafePath("../escaped.txt")) {
            try SafeArchive.extract(archiveAt: zipURL, to: destination, limits: .smallPackage)
        }
        // Nothing is written, not even the harmless entry that came first.
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        #expect(try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func extractsAnOrdinaryArchive() throws {
        let fileManager = FileManager.default
        let archive = try OnDeviceAnisetteTests.archive(containing: ["a.txt", "b.txt"])
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-unzip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let zipURL = root.appendingPathComponent("archive.zip")
        try archive.write(to: zipURL)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        try SafeArchive.extract(archiveAt: zipURL, to: destination, limits: .smallPackage)

        #expect(try Set(fileManager.contentsOfDirectory(atPath: destination.path)) == ["a.txt", "b.txt"])
    }
}
