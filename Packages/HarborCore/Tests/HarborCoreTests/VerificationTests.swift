import Crypto
import Foundation
import Testing

@testable import HarborCore

@Suite struct ContentDigestTests {
    @Test func matchesKnownVector() {
        let digest = ContentDigest(hashing: Data("abc".utf8))
        #expect(digest.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func parsesHexInEitherCase() throws {
        let lower = try #require(ContentDigest(hex: String(repeating: "ab", count: 32)))
        let upper = try #require(ContentDigest(hex: String(repeating: "AB", count: 32)))
        #expect(lower == upper)
    }

    @Test(arguments: ["", "abcd", String(repeating: "zz", count: 32), String(repeating: "a", count: 63)])
    func rejectsMalformedHex(_ hex: String) {
        #expect(ContentDigest(hex: hex) == nil)
    }

    @Test func hashesFilesInChunks() throws {
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let url = try TemporaryFile(data)
        defer { url.remove() }

        let streamed = try ContentDigest(hashingFileAt: url.url, chunkSize: 97)
        #expect(streamed == ContentDigest(hashing: data))
    }
}

@Suite struct ArtifactVerifierTests {
    let data = Data("payload".utf8)
    var digest: ContentDigest { ContentDigest(hashing: data) }
    let other = ContentDigest(hashing: Data("something else".utf8))

    @Test func acceptsMatchingDigest() throws {
        let outcome = try ArtifactVerifier.verify(
            data, against: ArtifactExpectation(sha256: digest, size: 7), policy: .required)
        #expect(outcome == .verified(digest))
    }

    @Test(arguments: [VerificationPolicy.required, .allowUnverified])
    func mismatchIsAlwaysAnError(_ policy: VerificationPolicy) {
        #expect(throws: VerificationError.digestMismatch(expected: other, actual: digest)) {
            try ArtifactVerifier.verify(data, against: ArtifactExpectation(sha256: other), policy: policy)
        }
    }

    @Test func missingDigestFailsWhenRequired() {
        #expect(throws: VerificationError.digestMissing) {
            try ArtifactVerifier.verify(data, against: ArtifactExpectation(sha256: nil), policy: .required)
        }
    }

    @Test func missingDigestIsReportedWhenTolerated() throws {
        let outcome = try ArtifactVerifier.verify(
            data, against: ArtifactExpectation(sha256: nil), policy: .allowUnverified)
        #expect(outcome == .unverified(actual: digest))
    }

    @Test func rejectsWrongSize() {
        #expect(throws: VerificationError.sizeMismatch(expected: 8, actual: 7)) {
            try ArtifactVerifier.verify(
                data, against: ArtifactExpectation(sha256: digest, size: 8), policy: .required)
        }
    }

    @Test func verifiesFiles() throws {
        let file = try TemporaryFile(data)
        defer { file.remove() }

        let outcome = try ArtifactVerifier.verify(
            fileAt: file.url, against: ArtifactExpectation(sha256: digest, size: 7), policy: .required)
        #expect(outcome == .verified(digest))

        #expect(throws: VerificationError.digestMismatch(expected: other, actual: digest)) {
            try ArtifactVerifier.verify(
                fileAt: file.url, against: ArtifactExpectation(sha256: other), policy: .required)
        }
    }
}

@Suite struct SignedManifestTests {
    let key = Curve25519.Signing.PrivateKey()
    var trusted: TrustedKeys { TrustedKeys(["release": key.publicKey.rawRepresentation]) }

    let manifest = ReleaseManifest(
        version: "1.0.0",
        artifacts: [
            "Harbor.ipa": .init(
                url: URL(string: "https://example.com/Harbor.ipa")!,
                sha256: ContentDigest(hashing: Data("ipa".utf8)),
                size: 3
            )
        ]
    )

    func envelope(payload: Data, signedWith signer: Curve25519.Signing.PrivateKey, keyID: String = "release") throws -> Data {
        let signature = try signer.signature(for: payload)
        return try JSONSerialization.data(withJSONObject: [
            "keyID": keyID,
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ])
    }

    @Test func opensAValidManifest() throws {
        let payload = try JSONEncoder().encode(manifest)
        let opened = try SignedManifest.open(
            ReleaseManifest.self, from: envelope(payload: payload, signedWith: key), trustedKeys: trusted)
        #expect(opened == manifest)
        #expect(opened.artifacts["Harbor.ipa"]?.expectation.size == 3)
    }

    @Test func rejectsATamperedPayload() throws {
        let payload = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: payload)
        let tampered = Data(String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "1.0.0", with: "9.9.9").utf8)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "keyID": "release",
            "payload": tampered.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ])
        #expect(throws: SignedManifestError.invalidSignature) {
            try SignedManifest.open(envelope, trustedKeys: trusted)
        }
    }

    @Test func rejectsAnotherSignersKey() throws {
        let payload = try JSONEncoder().encode(manifest)
        let stranger = Curve25519.Signing.PrivateKey()
        #expect(throws: SignedManifestError.invalidSignature) {
            try SignedManifest.open(envelope(payload: payload, signedWith: stranger), trustedKeys: trusted)
        }
    }

    @Test func rejectsAnUnknownKeyIdentifier() throws {
        let payload = try JSONEncoder().encode(manifest)
        #expect(throws: SignedManifestError.untrustedKey("someone")) {
            try SignedManifest.open(
                envelope(payload: payload, signedWith: key, keyID: "someone"), trustedKeys: trusted)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: SignedManifestError.malformedEnvelope) {
            try SignedManifest.open(Data("not json".utf8), trustedKeys: trusted)
        }
    }

    @Test func reportsAPayloadOfTheWrongShape() throws {
        let payload = Data(#"{"unexpected":true}"#.utf8)
        #expect(throws: SignedManifestError.malformedPayload) {
            try SignedManifest.open(
                ReleaseManifest.self, from: envelope(payload: payload, signedWith: key), trustedKeys: trusted)
        }
    }
}

struct TemporaryFile {
    let url: URL

    init(_ data: Data) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-test-\(UUID().uuidString)")
        try data.write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
