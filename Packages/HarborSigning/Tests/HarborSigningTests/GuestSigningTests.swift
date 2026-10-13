import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct IdentityImportTests {
    let secrets = InMemorySecretStore()
    var store: SigningIdentityStore { SigningIdentityStore(secrets: secrets) }

    /// The fixture identity as a `.p12` file.
    func archive(_ identity: Fixture.Identity = Fixture.iPhoneDeveloper) throws -> Data {
        try identity.keyStore.exportP12()
    }

    @Test func importsAnIdentityAndStoresIt() throws {
        let imported = try store.importPKCS12(try archive(), password: Redacted(""))

        #expect(CertificateProvisioner.sameSerial(imported.certificate, Fixture.iPhoneDeveloper.certificate))
        let stored = try #require(try store.load())
        #expect(CertificateProvisioner.sameSerial(stored.certificate, Fixture.iPhoneDeveloper.certificate))
    }

    @Test func refusesWhatIsNotAnIdentityFile() {
        #expect(throws: IdentityImportError.unreadable) {
            try store.importPKCS12(Data("not a p12".utf8), password: Redacted("x"))
        }
    }

    @Test func refusesAnExpiredCertificateAndKeepsTheOldOne() throws {
        try store.save(Fixture.iOSDevelopment.keyStore)
        let expiry = try #require(Fixture.iPhoneDeveloper.certificate.notAfter)
        let file = try archive()

        #expect(throws: IdentityImportError.expired(on: expiry)) {
            try store.importPKCS12(file, password: Redacted(""), now: expiry.addingTimeInterval(1))
        }
        // The identity that was already there is untouched.
        let kept = try #require(try store.load())
        #expect(CertificateProvisioner.sameSerial(kept.certificate, Fixture.iOSDevelopment.certificate))
    }

    @Test func refusesACertificateThisInstallWouldNotAccept() throws {
        let accepted = [Fixture.iOSDevelopment.certificate, Fixture.appleDevelopment.certificate]

        do {
            _ = try store.importPKCS12(try archive(), password: Redacted(""), acceptedCertificates: accepted)
            Issue.record("the import should have been refused")
        } catch IdentityImportError.notAcceptedByThisInstall(let described) {
            // The error names what would work, so the user can find it.
            #expect(described.count == 2)
            #expect(described[0].hasPrefix("iOS Development: Test B (BBBBBBBBBB), expires "))
            #expect(described[1].hasPrefix("Apple Development: Test C (CCCCCCCCCC), expires "))
        }
        #expect(try store.load() == nil)
    }

    @Test func acceptsACertificateThisInstallLists() throws {
        let accepted = [Fixture.appleDevelopment.certificate, Fixture.iPhoneDeveloper.certificate]
        _ = try store.importPKCS12(try archive(), password: Redacted(""), acceptedCertificates: accepted)
        #expect(try store.load() != nil)
    }

    @Test func summarisesACertificateForDisplay() {
        let summary = IdentitySummary(Fixture.iPhoneDeveloper.certificate)
        #expect(summary.name == "iPhone Developer: Test A (AAAAAAAAAA)")
        #expect(summary.expires == Fixture.iPhoneDeveloper.certificate.notAfter)
        #expect(Fixture.iPhoneDeveloper.serial.lowercased().hasSuffix(summary.serialSuffix.lowercased()))
    }
}

#if os(macOS)
/// Signs real executables and reads the result back with Apple's `codesign`.
@Suite struct GuestSignerTests {
    static func run(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
        }
        stdin.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A guest bundle holding two compiled executables and two files that are not code.
    static func makeBundle() throws -> URL {
        let fileManager = FileManager.default
        let bundle = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-sign-\(UUID().uuidString)/Guest.app", isDirectory: true)
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)

        let source = Data("int main(void) { return 0; }\n".utf8)
        for path in ["Guest", "Frameworks/libextra.dylib"] {
            let built = try run("/usr/bin/xcrun", [
                "clang", "-x", "c", "-", "-o", bundle.appendingPathComponent(path).path,
            ], input: source)
            try #require(built.status == 0, "clang failed: \(built.output)")
        }
        try Data("<plist/>".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("settings.json"))
        return bundle
    }

    @Test func signsEveryMachOFileUnderTheHostsIdentifier() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let plistBefore = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))

        let signed = try GuestSigner().sign(
            bundleAt: bundle,
            identity: Fixture.iPhoneDeveloper.keyStore,
            hostBundleIdentifier: "me.example.host"
        )

        #expect(signed == 2)
        for path in ["Guest", "Frameworks/libextra.dylib"] {
            let described = try Self.run("/usr/bin/codesign", ["-dvv", bundle.appendingPathComponent(path).path]).output
            #expect(described.contains("Identifier=me.example.host"), "\(path): \(described)")
            #expect(described.contains("TeamIdentifier=TESTTEAM01"), "\(path): \(described)")
            // A real signature, not an ad-hoc one. codesign prints the signer
            // as "(unavailable)" because the test certificate chains to
            // nothing it trusts, so the name cannot be checked here.
            #expect(described.contains("Authority="), "\(path): \(described)")
            #expect(!described.contains("Signature=adhoc"), "\(path): \(described)")
            // Signed as a bare library: nothing ties it to an Info.plist or resources.
            #expect(described.contains("Info.plist=not bound"), "\(path): \(described)")
            #expect(described.contains("Sealed Resources=none"), "\(path): \(described)")
        }
        // Files that are not code are left exactly as they were.
        #expect(try Data(contentsOf: bundle.appendingPathComponent("Info.plist")) == plistBefore)
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("_CodeSignature").path))
    }

    @Test func theSignedPagesMatchTheirHashes() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        try GuestSigner().sign(
            bundleAt: bundle, identity: Fixture.iPhoneDeveloper.keyStore, hostBundleIdentifier: "me.example.host")

        // codesign cannot trust a self-signed test certificate, but it still
        // checks every page against the hashes in the signature first. A
        // mismatch there reads differently from an untrusted signer.
        let verified = try Self.run("/usr/bin/codesign", ["--verify", "--verbose=4", bundle.appendingPathComponent("Guest").path])
        #expect(!verified.output.contains("invalid signature"), "\(verified.output)")
        #expect(!verified.output.contains("modified"), "\(verified.output)")
    }

    @Test func findsOnlyMachOFiles() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let names = GuestSigner.machOFiles(in: bundle).map(\.lastPathComponent)
        #expect(names == ["libextra.dylib", "Guest"])
    }
}
#endif
