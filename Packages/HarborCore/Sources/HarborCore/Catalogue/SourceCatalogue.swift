import Foundation

/// How much Harbor trusts a source of apps.
public enum SourceTrust: Equatable, Sendable {
    /// Every artifact must carry a digest, and it must match. Anything wrong
    /// anywhere in the catalogue rejects all of it.
    case verified
    /// A third-party source. Artifacts without a digest can be installed
    /// after the user confirms, and are shown as unverified. Entries Harbor
    /// cannot use are left out and counted, not allowed to hide the rest.
    case unverified

    public var verificationPolicy: VerificationPolicy {
        switch self {
        case .verified: .required
        case .unverified: .allowUnverified
        }
    }
}

public enum SourceError: Error, Equatable, Sendable {
    case insecureURL(String)
    case invalidBundleIdentifier(String)
    case duplicateApp(String)
    case missingDigest(bundleIdentifier: String, version: String)
}

/// A catalogue of installable apps, read from the AltStore source format.
///
/// Sources in use differ in two ways this accepts. Newer ones give each app
/// a `versions` list; older ones put a single version's fields on the app
/// itself and repeat the app once per version. Both end up as one app with a
/// list of versions, newest first as the source listed them.
public struct SourceCatalogue: Equatable, Sendable {
    public struct App: Equatable, Sendable, Identifiable {
        public var name: String
        public var bundleIdentifier: String
        public var developerName: String?
        public var subtitle: String?
        public var summary: String?
        public var iconURL: URL?
        public var versions: [Version]

        /// A source may list variants of one app under different names, so
        /// the bundle identifier alone does not tell listings apart.
        public var id: String { "\(bundleIdentifier)\u{1f}\(name)" }

        public init(
            name: String,
            bundleIdentifier: String,
            developerName: String? = nil,
            subtitle: String? = nil,
            summary: String? = nil,
            iconURL: URL? = nil,
            versions: [Version] = []
        ) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.developerName = developerName
            self.subtitle = subtitle
            self.summary = summary
            self.iconURL = iconURL
            self.versions = versions
        }
    }

    public struct Version: Equatable, Sendable, Identifiable {
        public var version: String
        /// As the source wrote it; sources do not agree on a date format.
        public var date: String?
        public var notes: String?
        public var downloadURL: URL
        public var size: Int64?
        public var sha256: ContentDigest?
        public var minOSVersion: String?

        public var id: String { downloadURL.absoluteString }

        public init(
            version: String,
            date: String? = nil,
            notes: String? = nil,
            downloadURL: URL,
            size: Int64? = nil,
            sha256: ContentDigest? = nil,
            minOSVersion: String? = nil
        ) {
            self.version = version
            self.date = date
            self.notes = notes
            self.downloadURL = downloadURL
            self.size = size
            self.sha256 = sha256
            self.minOSVersion = minOSVersion
        }

        /// What the download must be. A size is only enforced together with
        /// a digest: on its own it proves nothing about the contents, and
        /// sources that publish no digest often get it wrong.
        public var expectation: ArtifactExpectation {
            ArtifactExpectation(sha256: sha256, size: sha256 == nil ? nil : size)
        }
    }

    public var name: String
    public var identifier: String?
    public var apps: [App]
    /// Entries of an unverified source that were left out: malformed, with an
    /// identifier that is not a bundle identifier, or not served over HTTPS.
    public var skippedEntries: Int

    public init(name: String, identifier: String? = nil, apps: [App], skippedEntries: Int = 0) {
        self.name = name
        self.identifier = identifier
        self.apps = apps
        self.skippedEntries = skippedEntries
    }

    /// Decodes and validates in one step.
    public static func decode(_ data: Data, trust: SourceTrust) throws -> SourceCatalogue {
        let decoder = JSONDecoder()
        switch trust {
        case .verified:
            let raw = try decoder.decode(Raw<[RawApp]>.self, from: data)
            return try build(name: raw.name, identifier: raw.identifier, entries: raw.apps, skipped: 0, trust: trust)
        case .unverified:
            let raw = try decoder.decode(Raw<Lossy<RawApp>>.self, from: data)
            return try build(
                name: raw.name, identifier: raw.identifier,
                entries: raw.apps.elements, skipped: raw.apps.failures, trust: trust)
        }
    }

    private static func build(
        name: String,
        identifier: String?,
        entries: [RawApp],
        skipped: Int,
        trust: SourceTrust
    ) throws -> SourceCatalogue {
        var skipped = skipped
        var apps: [App] = []
        var position: [String: Int] = [:]
        var seenIdentifiers = Set<String>()

        for entry in entries {
            guard Identifier.isBundleIdentifier(entry.bundleIdentifier) else {
                if trust == .verified { throw SourceError.invalidBundleIdentifier(entry.bundleIdentifier) }
                skipped += 1
                continue
            }

            var versions: [Version] = []
            var unusable = false
            for raw in entry.listedVersions {
                guard let url = secureURL(raw.downloadURL) else {
                    if trust == .verified { throw SourceError.insecureURL(raw.downloadURL) }
                    unusable = true
                    continue
                }
                if trust == .verified, raw.sha256 == nil {
                    throw SourceError.missingDigest(
                        bundleIdentifier: entry.bundleIdentifier, version: raw.version)
                }
                versions.append(Version(
                    version: raw.version,
                    date: raw.date,
                    notes: raw.localizedDescription,
                    downloadURL: url,
                    size: raw.size,
                    sha256: raw.sha256,
                    minOSVersion: raw.minOSVersion
                ))
            }
            if unusable {
                skipped += 1
                // Nothing left to offer: do not list an app that cannot be had.
                if versions.isEmpty { continue }
            }

            let app = App(
                name: entry.name,
                bundleIdentifier: entry.bundleIdentifier,
                developerName: entry.developerName.nonEmpty,
                subtitle: entry.subtitle.nonEmpty,
                summary: entry.localizedDescription.nonEmpty,
                iconURL: entry.iconURL.flatMap(secureURL),
                versions: versions
            )

            switch trust {
            case .verified:
                guard seenIdentifiers.insert(app.bundleIdentifier).inserted else {
                    throw SourceError.duplicateApp(app.bundleIdentifier)
                }
                apps.append(app)
            case .unverified:
                // One listing per version is how older sources publish a
                // history. Fold them together, keeping the order given.
                if let index = position[app.id] {
                    let known = Set(apps[index].versions.map(\.id))
                    apps[index].versions.append(contentsOf: app.versions.filter { !known.contains($0.id) })
                } else {
                    position[app.id] = apps.count
                    apps.append(app)
                }
            }
        }
        return SourceCatalogue(name: name, identifier: identifier, apps: apps, skippedEntries: skipped)
    }

    private static func secureURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }
}

// MARK: - The format as written

private struct Raw<Apps: Decodable>: Decodable {
    var name: String
    var identifier: String?
    var apps: Apps
}

private struct RawApp: Decodable {
    var name: String
    var bundleIdentifier: String
    var developerName: String?
    var subtitle: String?
    var localizedDescription: String?
    var iconURL: String?
    var versions: [RawVersion]?
    // The older layout: one version, on the app itself.
    var version: String?
    var versionDate: String?
    var downloadURL: String?
    var size: Int64?
    var sha256: ContentDigest?
    var minOSVersion: String?

    var listedVersions: [RawVersion] {
        if let versions, !versions.isEmpty { return versions }
        guard let downloadURL else { return [] }
        return [RawVersion(
            version: version ?? "",
            date: versionDate,
            localizedDescription: nil,
            downloadURL: downloadURL,
            size: size,
            sha256: sha256,
            minOSVersion: minOSVersion
        )]
    }
}

private struct RawVersion: Decodable {
    var version: String
    var date: String?
    var localizedDescription: String?
    var downloadURL: String
    var size: Int64?
    // A digest that is present but malformed fails the entry. It is never
    // read as "no digest".
    var sha256: ContentDigest?
    var minOSVersion: String?
}

/// An array that drops the elements it cannot decode and counts them.
private struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var failures = 0

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                failures += 1
                // A failed decode leaves the container where it was.
                _ = try container.decode(Ignored.self)
            }
        }
    }

    private struct Ignored: Decodable {}
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
