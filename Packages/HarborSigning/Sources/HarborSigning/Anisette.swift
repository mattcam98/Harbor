import Foundation
import HarborCore
import SideSign

/// Supplies the device-attestation headers Apple's authentication requires.
public protocol AnisetteProviding: Sendable {
    func anisetteData() async throws -> AnisetteData
}

/// The archive of Apple's provisioning libraries that on-device anisette
/// runs, and exactly what it must hash to.
public struct AnisetteLibraryRelease: Equatable, Sendable {
    public var url: URL
    public var sha256: ContentDigest
    public var size: Int64?

    public init(url: URL, sha256: ContentDigest, size: Int64? = nil) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    var expectation: ArtifactExpectation {
        ArtifactExpectation(sha256: sha256, size: size)
    }
}

public enum AnisetteSetupError: Error, Equatable, Sendable {
    /// The archive verified but does not contain the libraries.
    case missingLibraries
}

/// Runs the provisioning libraries for one request. Separated from
/// `OnDeviceAnisette` so the surrounding logic can be tested without them.
protocol AnisetteGenerating: Sendable {
    func generate(
        libraries: URL,
        provisioning: URL,
        identifier: UUID,
        existingBlob: Data?
    ) async throws -> (data: AnisetteData, newBlob: Data?)
}

struct SideSignAnisetteGenerator: AnisetteGenerating {
    func generate(
        libraries: URL,
        provisioning: URL,
        identifier: UUID,
        existingBlob: Data?
    ) async throws -> (data: AnisetteData, newBlob: Data?) {
        let manager = AnisetteDataManager(mode: nil, baseDirectory: provisioning.deletingLastPathComponent())
        let result = try await manager.fetchAnisetteData(
            mode: .localODA(libsDir: libraries, provisioningDir: provisioning),
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        return (result.data, result.newAdiBlob)
    }
}

/// Generates anisette data on the device, with no anisette server involved.
///
/// The libraries are downloaded once. They are only unpacked after the
/// archive matches the pinned digest; a mismatch is an error, never a
/// warning. SideSign's own download path, which carries on after a mismatch,
/// is not used.
public struct OnDeviceAnisette: AnisetteProviding {
    public typealias Download = @Sendable (URL) async throws -> Data

    struct State: Codable, Equatable {
        var identifier: UUID
        var blob: Data?
    }

    private let release: AnisetteLibraryRelease
    private let directory: URL
    private let secrets: any SecretStore
    private let download: Download
    private let generator: any AnisetteGenerating

    var librariesDirectory: URL { directory.appendingPathComponent("libraries", isDirectory: true) }
    var provisioningDirectory: URL { directory.appendingPathComponent("provisioning", isDirectory: true) }

    /// - Parameter directory: a private directory Harbor owns, for the
    ///   libraries and their provisioning state.
    public init(
        release: AnisetteLibraryRelease,
        directory: URL,
        secrets: any SecretStore,
        download: @escaping Download = OnDeviceAnisette.urlSessionDownload
    ) {
        self.init(
            release: release, directory: directory, secrets: secrets,
            download: download, generator: SideSignAnisetteGenerator())
    }

    init(
        release: AnisetteLibraryRelease,
        directory: URL,
        secrets: any SecretStore,
        download: @escaping Download,
        generator: any AnisetteGenerating
    ) {
        self.release = release
        self.directory = directory
        self.secrets = secrets
        self.download = download
        self.generator = generator
    }

    public static let urlSessionDownload: Download = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public var librariesInstalled: Bool {
        AnisetteDataManager.validateLibrariesExist(at: librariesDirectory)
    }

    public func installLibrariesIfNeeded() async throws {
        guard !librariesInstalled else { return }

        let archive = try await download(release.url)
        _ = try ArtifactVerifier.verify(archive, against: release.expectation, policy: .required)

        // Unpack beside the final location and move into place only once the
        // result is complete, so a failure never leaves half a library set.
        let fileManager = FileManager.default
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archiveURL = staging.appendingPathComponent("libraries.zip")
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try archive.write(to: archiveURL, options: .atomic)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try SafeArchive.extract(archiveAt: archiveURL, to: unpacked, limits: .smallPackage)

        guard AnisetteDataManager.validateLibrariesExist(at: unpacked) else {
            throw AnisetteSetupError.missingLibraries
        }

        if fileManager.fileExists(atPath: librariesDirectory.path) {
            try fileManager.removeItem(at: librariesDirectory)
        }
        try fileManager.moveItem(at: unpacked, to: librariesDirectory)
    }

    public func anisetteData() async throws -> AnisetteData {
        try await installLibrariesIfNeeded()
        try FileManager.default.createDirectory(at: provisioningDirectory, withIntermediateDirectories: true)

        var state = try loadState() ?? State(identifier: UUID(), blob: nil)
        let result = try await generator.generate(
            libraries: librariesDirectory,
            provisioning: provisioningDirectory,
            identifier: state.identifier,
            existingBlob: state.blob
        )
        if let newBlob = result.newBlob {
            state.blob = newBlob
        }
        try secrets.write(Redacted(JSONEncoder().encode(state)), for: .anisetteState)
        return result.data
    }

    func loadState() throws -> State? {
        guard let stored = try secrets.read(.anisetteState) else { return nil }
        return try? JSONDecoder().decode(State.self, from: stored.expose())
    }
}
