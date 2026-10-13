import Foundation

/// How much Harbor trusts a source of apps.
public enum SourceTrust: Equatable, Sendable {
    /// Every artifact must carry a digest, and it must match.
    case verified
    /// Artifacts without a digest can be installed after the user confirms,
    /// and are shown as unverified.
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

/// A catalogue of installable apps. The JSON layout follows the AltStore
/// source format, so existing sources decode without changes.
public struct SourceCatalogue: Decodable, Equatable, Sendable {
    public struct App: Decodable, Equatable, Sendable {
        public var name: String
        public var bundleIdentifier: String
        public var developerName: String?
        public var versions: [Version]
    }

    public struct Version: Decodable, Equatable, Sendable {
        public var version: String
        public var downloadURL: URL
        public var size: Int64?
        public var sha256: ContentDigest?
        public var minOSVersion: String?

        public var expectation: ArtifactExpectation {
            ArtifactExpectation(sha256: sha256, size: size)
        }
    }

    public var name: String
    public var identifier: String?
    public var apps: [App]

    /// Decodes and validates in one step. A catalogue that fails validation is
    /// rejected whole: a source is not partly trusted.
    public static func decode(_ data: Data, trust: SourceTrust) throws -> SourceCatalogue {
        let catalogue = try JSONDecoder().decode(SourceCatalogue.self, from: data)
        try catalogue.validate(trust: trust)
        return catalogue
    }

    public func validate(trust: SourceTrust) throws {
        var seen = Set<String>()
        for app in apps {
            guard Identifier.isBundleIdentifier(app.bundleIdentifier) else {
                throw SourceError.invalidBundleIdentifier(app.bundleIdentifier)
            }
            guard seen.insert(app.bundleIdentifier).inserted else {
                throw SourceError.duplicateApp(app.bundleIdentifier)
            }
            for version in app.versions {
                guard version.downloadURL.scheme?.lowercased() == "https",
                      version.downloadURL.host?.isEmpty == false
                else {
                    throw SourceError.insecureURL(version.downloadURL.absoluteString)
                }
                if trust == .verified, version.sha256 == nil {
                    throw SourceError.missingDigest(
                        bundleIdentifier: app.bundleIdentifier,
                        version: version.version
                    )
                }
            }
        }
    }
}
