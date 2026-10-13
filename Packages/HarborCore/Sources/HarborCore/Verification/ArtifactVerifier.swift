import Foundation

/// What a downloaded artifact is expected to be.
public struct ArtifactExpectation: Equatable, Sendable {
    public var sha256: ContentDigest?
    public var size: Int64?

    public init(sha256: ContentDigest?, size: Int64? = nil) {
        self.sha256 = sha256
        self.size = size
    }
}

public enum VerificationPolicy: Equatable, Sendable {
    /// A digest must be supplied and must match. Used for everything Harbor
    /// executes or installs from a verified source.
    case required
    /// A missing digest is tolerated and reported as `.unverified`. A digest
    /// that is supplied must still match.
    case allowUnverified
}

public enum VerificationOutcome: Equatable, Sendable {
    case verified(ContentDigest)
    /// No digest was supplied. The caller must surface this to the user.
    case unverified(actual: ContentDigest)
}

public enum VerificationError: Error, Equatable, Sendable {
    case digestMissing
    case digestMismatch(expected: ContentDigest, actual: ContentDigest)
    case sizeMismatch(expected: Int64, actual: Int64)
}

/// Checks artifacts before they are unpacked, installed or loaded.
///
/// A mismatch is always an error. There is deliberately no mode that logs a
/// mismatch and carries on.
public enum ArtifactVerifier {
    public static func verify(
        _ data: Data,
        against expectation: ArtifactExpectation,
        policy: VerificationPolicy
    ) throws -> VerificationOutcome {
        try check(
            size: Int64(data.count),
            digest: ContentDigest(hashing: data),
            against: expectation,
            policy: policy
        )
    }

    public static func verify(
        fileAt url: URL,
        against expectation: ArtifactExpectation,
        policy: VerificationPolicy
    ) throws -> VerificationOutcome {
        // Size first: it is cheap and rejects truncated downloads before hashing.
        let size = try fileSize(of: url)
        if let expected = expectation.size, expected != size {
            throw VerificationError.sizeMismatch(expected: expected, actual: size)
        }
        return try check(
            size: size,
            digest: ContentDigest(hashingFileAt: url),
            against: expectation,
            policy: policy
        )
    }

    private static func check(
        size: Int64,
        digest: ContentDigest,
        against expectation: ArtifactExpectation,
        policy: VerificationPolicy
    ) throws -> VerificationOutcome {
        if let expected = expectation.size, expected != size {
            throw VerificationError.sizeMismatch(expected: expected, actual: size)
        }
        guard let expected = expectation.sha256 else {
            switch policy {
            case .required: throw VerificationError.digestMissing
            case .allowUnverified: return .unverified(actual: digest)
            }
        }
        guard expected == digest else {
            throw VerificationError.digestMismatch(expected: expected, actual: digest)
        }
        return .verified(digest)
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.int64Value
    }
}
