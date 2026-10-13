import Foundation
import Testing

@testable import HarborCore

@Suite struct SourceCatalogueTests {
    static let digest = String(repeating: "ab", count: 32)

    static func catalogue(
        downloadURL: String = "https://example.com/App.ipa",
        sha256: String? = digest,
        secondBundleIdentifier: String = "com.example.other"
    ) -> Data {
        let hashLine = sha256.map { #""sha256": "\#($0)","# } ?? ""
        return Data("""
        {
          "name": "Example Source",
          "identifier": "com.example.source",
          "apps": [
            {
              "name": "App",
              "bundleIdentifier": "com.example.app",
              "developerName": "Example",
              "versions": [
                { "version": "1.2", \(hashLine) "downloadURL": "\(downloadURL)", "size": 1234, "minOSVersion": "17.0" }
              ],
              "ignoredByHarbor": true
            },
            { "name": "Other", "bundleIdentifier": "\(secondBundleIdentifier)", "versions": [] }
          ],
          "news": []
        }
        """.utf8)
    }

    @Test func decodesAnAltStoreStyleSource() throws {
        let source = try SourceCatalogue.decode(Self.catalogue(), trust: .verified)
        #expect(source.name == "Example Source")
        #expect(source.apps.count == 2)

        let version = try #require(source.apps.first?.versions.first)
        #expect(version.expectation == ArtifactExpectation(sha256: ContentDigest(hex: Self.digest), size: 1234))
    }

    @Test func verifiedSourcesMustSupplyDigests() {
        #expect(throws: SourceError.missingDigest(bundleIdentifier: "com.example.app", version: "1.2")) {
            try SourceCatalogue.decode(Self.catalogue(sha256: nil), trust: .verified)
        }
    }

    @Test func unverifiedSourcesMayOmitDigests() throws {
        let source = try SourceCatalogue.decode(Self.catalogue(sha256: nil), trust: .unverified)
        #expect(source.apps.first?.versions.first?.sha256 == nil)
    }

    @Test func trustDecidesTheVerificationPolicy() {
        #expect(SourceTrust.verified.verificationPolicy == .required)
        #expect(SourceTrust.unverified.verificationPolicy == .allowUnverified)
    }

    @Test(arguments: [SourceTrust.verified, .unverified])
    func plainHTTPIsRefusedAtEveryTrustLevel(_ trust: SourceTrust) {
        #expect(throws: SourceError.insecureURL("http://example.com/App.ipa")) {
            try SourceCatalogue.decode(Self.catalogue(downloadURL: "http://example.com/App.ipa"), trust: trust)
        }
    }

    @Test func aMalformedDigestIsADecodingErrorNotAMissingOne() {
        #expect(throws: DecodingError.self) {
            try SourceCatalogue.decode(Self.catalogue(sha256: "abc123"), trust: .unverified)
        }
    }

    @Test func rejectsDuplicateAndMalformedBundleIdentifiers() {
        #expect(throws: SourceError.duplicateApp("com.example.app")) {
            try SourceCatalogue.decode(
                Self.catalogue(secondBundleIdentifier: "com.example.app"), trust: .unverified)
        }
        #expect(throws: SourceError.invalidBundleIdentifier("../evil")) {
            try SourceCatalogue.decode(Self.catalogue(secondBundleIdentifier: "../evil"), trust: .unverified)
        }
    }
}
