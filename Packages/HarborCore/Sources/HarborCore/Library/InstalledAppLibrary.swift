import Foundation

/// An app Harbor has signed and installed.
public struct InstalledApp: Codable, Equatable, Identifiable, Sendable {
    /// The bundle identifier as shipped in the IPA.
    public var id: String
    /// The team-unique identifier it is installed under.
    public var installedBundleIdentifier: String
    public var name: String
    public var version: String
    /// The app and its extensions, by shipped bundle identifier, each paired
    /// with the name its App ID was registered under.
    public var targets: [Target]
    /// When its provisioning profile expires and it stops launching.
    public var expiry: Date
    public var installedAt: Date
    /// Harbor itself.
    public var isHost: Bool

    public struct Target: Codable, Equatable, Sendable {
        public var bundleIdentifier: String
        public var name: String

        public init(bundleIdentifier: String, name: String) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
        }
    }

    public init(
        id: String,
        installedBundleIdentifier: String,
        name: String,
        version: String,
        targets: [Target],
        expiry: Date,
        installedAt: Date,
        isHost: Bool = false
    ) {
        self.id = id
        self.installedBundleIdentifier = installedBundleIdentifier
        self.name = name
        self.version = version
        self.targets = targets
        self.expiry = expiry
        self.installedAt = installedAt
        self.isHost = isHost
    }

    /// The view of this app the refresh planner works with.
    public var signedApp: SignedApp {
        SignedApp(bundleIdentifier: id, name: name, expiry: expiry, isHost: isHost)
    }
}

/// The list of installed apps, kept in one JSON file.
///
/// It holds nothing secret. An unreadable file is reported, not silently
/// replaced: losing the list would hide apps that are about to expire.
public actor InstalledAppLibrary {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func all() throws -> [InstalledApp] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([InstalledApp].self, from: Data(contentsOf: fileURL))
    }

    /// Adds the app, or replaces the entry with the same `id`.
    public func save(_ app: InstalledApp) throws {
        var apps = try all().filter { $0.id != app.id }
        apps.append(app)
        try write(apps)
    }

    public func remove(id: String) throws {
        try write(try all().filter { $0.id != id })
    }

    private func write(_ apps: [InstalledApp]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(apps.sorted { $0.id < $1.id }).write(to: fileURL, options: .atomic)
    }
}
