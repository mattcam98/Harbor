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
        #expect(source.skippedEntries == 0)

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
        let version = try #require(source.apps.first?.versions.first)
        #expect(version.sha256 == nil)
        // With nothing to check the contents against, the size is not
        // enforced either: it is only for showing.
        #expect(version.size == 1234)
        #expect(version.expectation == ArtifactExpectation(sha256: nil, size: nil))
    }

    @Test func trustDecidesTheVerificationPolicy() {
        #expect(SourceTrust.verified.verificationPolicy == .required)
        #expect(SourceTrust.unverified.verificationPolicy == .allowUnverified)
    }

    // MARK: A verified source is rejected whole

    @Test func aVerifiedSourceWithAPlainHTTPDownloadIsRejected() {
        #expect(throws: SourceError.insecureURL("http://example.com/App.ipa")) {
            try SourceCatalogue.decode(Self.catalogue(downloadURL: "http://example.com/App.ipa"), trust: .verified)
        }
    }

    @Test func aVerifiedSourceWithAMalformedDigestIsRejected() {
        #expect(throws: DecodingError.self) {
            try SourceCatalogue.decode(Self.catalogue(sha256: "abc123"), trust: .verified)
        }
    }

    @Test func aVerifiedSourceWithDuplicateOrMalformedBundleIdentifiersIsRejected() {
        #expect(throws: SourceError.duplicateApp("com.example.app")) {
            try SourceCatalogue.decode(
                Self.catalogue(secondBundleIdentifier: "com.example.app"), trust: .verified)
        }
        #expect(throws: SourceError.invalidBundleIdentifier("../evil")) {
            try SourceCatalogue.decode(Self.catalogue(secondBundleIdentifier: "../evil"), trust: .verified)
        }
    }

    // MARK: An unverified source loses only its bad entries

    @Test func plainHTTPDownloadsAreNeverOffered() throws {
        let source = try SourceCatalogue.decode(
            Self.catalogue(downloadURL: "http://example.com/App.ipa"), trust: .unverified)
        #expect(source.apps.map(\.name) == ["Other"])
        #expect(source.skippedEntries == 1)
    }

    @Test func aMalformedDigestDropsTheEntryInsteadOfCountingAsMissing() throws {
        let source = try SourceCatalogue.decode(Self.catalogue(sha256: "abc123"), trust: .unverified)
        #expect(source.apps.map(\.name) == ["Other"])
        #expect(source.skippedEntries == 1)
    }

    @Test func entriesWithIdentifiersThatAreNotBundleIdentifiersAreDropped() throws {
        let source = try SourceCatalogue.decode(
            Self.catalogue(secondBundleIdentifier: "../evil"), trust: .unverified)
        #expect(source.apps.map(\.bundleIdentifier) == ["com.example.app"])
        #expect(source.skippedEntries == 1)
    }

    @Test func entriesOfTheWrongShapeAreDroppedAndCounted() throws {
        let data = Data("""
        {
          "name": "Mixed",
          "apps": [
            42,
            { "name": "No identifier" },
            { "name": "Good", "bundleIdentifier": "com.example.good",
              "downloadURL": "https://example.com/good.ipa", "version": "1.0", "size": "not a number" },
            { "name": "Fine", "bundleIdentifier": "com.example.fine",
              "downloadURL": "https://example.com/fine.ipa", "version": "2.0" }
          ]
        }
        """.utf8)
        let source = try SourceCatalogue.decode(data, trust: .unverified)
        #expect(source.apps.map(\.name) == ["Fine"])
        #expect(source.skippedEntries == 3)
    }

    @Test func somethingThatIsNotASourceIsStillAnError() {
        #expect(throws: DecodingError.self) {
            try SourceCatalogue.decode(Data("<html>Not found</html>".utf8), trust: .unverified)
        }
        #expect(throws: DecodingError.self) {
            try SourceCatalogue.decode(Data(#"{"name": "No apps"}"#.utf8), trust: .unverified)
        }
    }

    // MARK: The older layout

    /// One entry per version, the version's fields on the app itself, as
    /// large third-party sources publish.
    static let olderLayout = Data("""
    {
      "name": "Older Source",
      "apps": [
        { "name": "Player", "bundleIdentifier": "com.example.player", "version": "3.0",
          "versionDate": "2026-10-13", "size": 300, "downloadURL": "https://example.com/player-3.0.ipa",
          "developerName": "", "localizedDescription": "  Plays things  ",
          "iconURL": "https://example.com/player.png" },
        { "name": "Player Lite", "bundleIdentifier": "com.example.player", "version": "3.0",
          "downloadURL": "https://example.com/player-lite-3.0.ipa", "iconURL": "http://example.com/lite.png" },
        { "name": "Player", "bundleIdentifier": "com.example.player", "version": "2.9",
          "versionDate": "2026-09-01", "size": 290, "downloadURL": "https://example.com/player-2.9.ipa" },
        { "name": "Player", "bundleIdentifier": "com.example.player", "version": "2.9",
          "downloadURL": "https://example.com/player-2.9.ipa" },
        { "name": "Notes", "bundleIdentifier": "com.example.notes" }
      ]
    }
    """.utf8)

    @Test func readsVersionFieldsFromTheAppItself() throws {
        let source = try SourceCatalogue.decode(Self.olderLayout, trust: .unverified)
        let player = try #require(source.apps.first)

        #expect(player.name == "Player")
        #expect(player.summary == "Plays things")
        #expect(player.developerName == nil)
        #expect(player.iconURL == URL(string: "https://example.com/player.png"))

        let newest = try #require(player.versions.first)
        #expect(newest.version == "3.0")
        #expect(newest.date == "2026-10-13")
        #expect(newest.size == 300)
        #expect(newest.downloadURL == URL(string: "https://example.com/player-3.0.ipa"))
    }

    @Test func foldsRepeatedListingsIntoVersionsInTheOrderGiven() throws {
        let source = try SourceCatalogue.decode(Self.olderLayout, trust: .unverified)

        #expect(source.apps.map(\.name) == ["Player", "Player Lite", "Notes"])
        // The same download listed twice is one version.
        #expect(source.apps[0].versions.map(\.version) == ["3.0", "2.9"])
        #expect(source.skippedEntries == 0)
    }

    @Test func aVariantUnderAnotherNameStaysItsOwnListing() throws {
        let source = try SourceCatalogue.decode(Self.olderLayout, trust: .unverified)
        let lite = source.apps[1]

        #expect(lite.bundleIdentifier == "com.example.player")
        #expect(lite.id != source.apps[0].id)
        #expect(lite.versions.map(\.downloadURL.lastPathComponent) == ["player-lite-3.0.ipa"])
        // An icon that is not served over HTTPS is not fetched.
        #expect(lite.iconURL == nil)
    }

    @Test func anAppWithNothingToDownloadIsListedWithoutVersions() throws {
        let source = try SourceCatalogue.decode(Self.olderLayout, trust: .unverified)
        #expect(source.apps[2].versions.isEmpty)
    }
}

@Suite struct SourceListTests {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-sources-\(UUID().uuidString)/sources.json")

    var list: SourceList { SourceList(fileURL: file) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test(arguments: [
        ("https://example.com/source.json", "https://example.com/source.json"),
        ("  example.com/apps  \n", "https://example.com/apps"),
        ("HTTPS://Example.com", "HTTPS://Example.com"),
    ])
    func readsAnAddressAsTyped(_ typed: String, _ expected: String) throws {
        #expect(try SourceList.address(from: typed).absoluteString == expected)
    }

    @Test(arguments: [
        "http://example.com/source.json",
        "ftp://example.com/source.json",
        "https://user:secret@example.com/source.json",
        "https://localhost/source.json",
        "not an address",
        "",
    ])
    func refusesWhatIsNotASecureAddress(_ typed: String) {
        #expect(throws: SourceListError.notASecureAddress(typed)) {
            try SourceList.address(from: typed)
        }
    }

    @Test func startsEmpty() throws {
        defer { cleanUp() }
        #expect(try list.all().isEmpty)
    }

    @Test func savesUpdatesAndRemovesSources() throws {
        defer { cleanUp() }
        let first = SavedSource(url: URL(string: "https://example.com/a.json")!, name: "A")
        let second = SavedSource(url: URL(string: "https://example.com/b.json")!, name: "B")

        try list.save(first)
        #expect(try list.save(second) == [first, second])

        // Saving the same address again renames it in place.
        var renamed = first
        renamed.name = "A, renamed"
        #expect(try list.save(renamed) == [renamed, second])

        #expect(try list.remove(renamed) == [second])
        #expect(try list.all() == [second])
    }
}
