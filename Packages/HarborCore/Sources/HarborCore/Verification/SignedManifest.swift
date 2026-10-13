import Crypto
import Foundation

/// Ed25519 public keys Harbor accepts manifests from, by key identifier.
public struct TrustedKeys: Sendable {
    private let keys: [String: Data]

    /// - Parameter keys: key identifier to 32-byte raw Ed25519 public key.
    public init(_ keys: [String: Data]) {
        self.keys = keys
    }

    func publicKey(for keyID: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = keys[keyID] else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}

public enum SignedManifestError: Error, Equatable, Sendable {
    case malformedEnvelope
    case untrustedKey(String)
    case invalidSignature
    case malformedPayload
}

/// A detached-signature envelope around an arbitrary JSON payload.
///
/// ```json
/// { "keyID": "release-2026", "payload": "<base64>", "signature": "<base64>" }
/// ```
///
/// The signature covers the exact payload bytes, so the payload is only
/// decoded after the signature has been checked.
public struct SignedManifest: Sendable {
    private struct Envelope: Decodable {
        let keyID: String
        let payload: String
        let signature: String
    }

    /// Verifies the envelope and returns the payload bytes.
    public static func open(_ envelope: Data, trustedKeys: TrustedKeys) throws -> Data {
        guard
            let decoded = try? JSONDecoder().decode(Envelope.self, from: envelope),
            let payload = Data(base64Encoded: decoded.payload),
            let signature = Data(base64Encoded: decoded.signature)
        else {
            throw SignedManifestError.malformedEnvelope
        }
        guard let key = trustedKeys.publicKey(for: decoded.keyID) else {
            throw SignedManifestError.untrustedKey(decoded.keyID)
        }
        guard key.isValidSignature(signature, for: payload) else {
            throw SignedManifestError.invalidSignature
        }
        return payload
    }

    /// Verifies the envelope, then decodes the payload.
    public static func open<Payload: Decodable>(
        _ type: Payload.Type,
        from envelope: Data,
        trustedKeys: TrustedKeys,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Payload {
        let payload = try open(envelope, trustedKeys: trustedKeys)
        do {
            return try decoder.decode(type, from: payload)
        } catch {
            throw SignedManifestError.malformedPayload
        }
    }
}

/// The payload of a release manifest: the artifacts a release consists of.
///
/// Used for Harbor's own IPA (checked by the setup tool) and for binary
/// dependencies fetched at run time, such as the anisette libraries.
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public var url: URL
        public var sha256: ContentDigest
        public var size: Int64

        public init(url: URL, sha256: ContentDigest, size: Int64) {
            self.url = url
            self.sha256 = sha256
            self.size = size
        }

        public var expectation: ArtifactExpectation {
            ArtifactExpectation(sha256: sha256, size: size)
        }
    }

    public var version: String
    public var artifacts: [String: Artifact]

    public init(version: String, artifacts: [String: Artifact]) {
        self.version = version
        self.artifacts = artifacts
    }
}
