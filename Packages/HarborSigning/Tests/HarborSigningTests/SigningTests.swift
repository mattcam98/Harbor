import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct FixtureTests {
    @Test func fixturesParseWithTheExpectedSerialsAndNames() {
        for identity in [Fixture.iPhoneDeveloper, .iOSDevelopment, .appleDevelopment] {
            #expect(identity.certificate.serialNumber.caseInsensitiveCompare(identity.serial) == .orderedSame)
        }
        #expect(Fixture.iPhoneDeveloper.certificate.name == "iPhone Developer: Test A (AAAAAAAAAA)")
    }
}

@Suite struct SigningIdentityStoreTests {
    let secrets = InMemorySecretStore()
    var store: SigningIdentityStore { SigningIdentityStore(secrets: secrets) }

    @Test func isEmptyAtFirst() throws {
        #expect(try store.load() == nil)
    }

    @Test func roundTripsAnIdentity() throws {
        try store.save(Fixture.iPhoneDeveloper.keyStore)

        let loaded = try #require(try store.load())
        #expect(CertificateProvisioner.sameSerial(loaded.certificate, Fixture.iPhoneDeveloper.certificate))
        #expect(!loaded.privateKey.isEmpty)
    }

    @Test func storesAnEncryptedArchiveNotTheBareKey() throws {
        try store.save(Fixture.iPhoneDeveloper.keyStore)

        let archive = try #require(try secrets.read(.signingIdentity)).expose()
        let pem = Fixture.iPhoneDeveloper.privateKeyPEM
        let keyBody = pem.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        #expect(!keyBody.isEmpty)
        #expect(archive.range(of: Data(pem.utf8)) == nil)
        #expect(archive.range(of: Data(base64Encoded: keyBody) ?? Data([0])) == nil)
    }

    @Test func usesAFreshPassphraseEachTime() throws {
        try store.save(Fixture.iPhoneDeveloper.keyStore)
        let first = try #require(try secrets.read(.signingIdentityPassphrase)).expose()
        try store.save(Fixture.iPhoneDeveloper.keyStore)
        let second = try #require(try secrets.read(.signingIdentityPassphrase)).expose()

        #expect(first != second)
        #expect(first.count >= 32)
    }

    @Test func aMissingPassphraseMeansNoIdentity() throws {
        try store.save(Fixture.iPhoneDeveloper.keyStore)
        try secrets.delete(.signingIdentityPassphrase)
        #expect(try store.load() == nil)
    }

    @Test func clearRemovesBothParts() throws {
        try store.save(Fixture.iPhoneDeveloper.keyStore)
        try store.clear()

        #expect(try store.load() == nil)
        #expect(try secrets.read(.signingIdentity) == nil)
        #expect(try secrets.read(.signingIdentityPassphrase) == nil)
    }
}

@Suite struct CertificateProvisionerTests {
    let secrets = InMemorySecretStore()
    var identities: SigningIdentityStore { SigningIdentityStore(secrets: secrets) }

    func provisioner(_ portal: FakePortal) -> CertificateProvisioner {
        CertificateProvisioner(portal: portal, identities: identities, machineName: "Harbor - Test iPhone")
    }

    /// Records what the user was asked, and answers with a fixed decision.
    final class Prompt: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [[String]] = []
        private let decide: @Sendable ([X509Certificate]) -> RevocationDecision

        init(_ decide: @escaping @Sendable ([X509Certificate]) -> RevocationDecision) {
            self.decide = decide
        }

        var askedSerials: [[String]] { lock.withLock { asked } }

        func handle(_ certificates: [X509Certificate]) -> RevocationDecision {
            lock.withLock { asked.append(certificates.map(\.serialNumber)) }
            return decide(certificates)
        }
    }

    @Test func reusesTheStoredIdentityWhileThePortalStillListsIt() async throws {
        try identities.save(Fixture.iPhoneDeveloper.keyStore)
        let portal = FakePortal(
            certificates: [Fixture.iPhoneDeveloper.certificate],
            issuing: Fixture.iOSDevelopment.keyStore
        )
        let prompt = Prompt { _ in .cancel }

        let identity = try await provisioner(portal).resolveIdentity(
            team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)

        #expect(CertificateProvisioner.sameSerial(identity.certificate, Fixture.iPhoneDeveloper.certificate))
        #expect(portal.calls == [.fetchCertificates])
        #expect(prompt.askedSerials.isEmpty)
    }

    @Test func requestsACertificateWhenTheTeamHasNone() async throws {
        let portal = FakePortal(certificates: [], issuing: Fixture.iPhoneDeveloper.keyStore)
        let prompt = Prompt { _ in .cancel }

        let identity = try await provisioner(portal).resolveIdentity(
            team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)

        #expect(CertificateProvisioner.sameSerial(identity.certificate, Fixture.iPhoneDeveloper.certificate))
        #expect(portal.calls == [.fetchCertificates, .addCertificate(machineName: "Harbor - Test iPhone")])
        #expect(prompt.askedSerials.isEmpty)

        let stored = try #require(try identities.load())
        #expect(CertificateProvisioner.sameSerial(stored.certificate, Fixture.iPhoneDeveloper.certificate))
    }

    @Test func asksBeforeReplacingAndOnlyOffersIOSDevelopmentCertificates() async throws {
        // The stored identity was revoked elsewhere: the portal no longer lists it.
        try identities.save(Fixture.iPhoneDeveloper.keyStore)
        let existing = Fixture.iOSDevelopment.certificate
        let portal = FakePortal(
            certificates: [existing, Fixture.appleDevelopment.certificate],
            issuing: Fixture.iPhoneDeveloper.keyStore
        )
        let prompt = Prompt { offered in .revoke(offered) }

        _ = try await provisioner(portal).resolveIdentity(
            team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)

        #expect(prompt.askedSerials == [[existing.serialNumber]])
        #expect(portal.calls == [
            .fetchCertificates,
            .revokeCertificate(serial: existing.serialNumber),
            .addCertificate(machineName: "Harbor - Test iPhone"),
        ])
        #expect(portal.remainingSerials.contains(Fixture.appleDevelopment.certificate.serialNumber))
        #expect(!portal.remainingSerials.contains(existing.serialNumber))
    }

    @Test func keepingExistingCertificatesRevokesNothing() async throws {
        let portal = FakePortal(
            certificates: [Fixture.iOSDevelopment.certificate],
            issuing: Fixture.iPhoneDeveloper.keyStore
        )
        let prompt = Prompt { _ in .keepExisting }

        _ = try await provisioner(portal).resolveIdentity(
            team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)

        #expect(portal.calls == [.fetchCertificates, .addCertificate(machineName: "Harbor - Test iPhone")])
    }

    @Test func cancellingChangesNothing() async throws {
        let portal = FakePortal(
            certificates: [Fixture.iOSDevelopment.certificate],
            issuing: Fixture.iPhoneDeveloper.keyStore
        )
        let prompt = Prompt { _ in .cancel }

        await #expect(throws: SigningError.cancelled) {
            try await provisioner(portal).resolveIdentity(
                team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)
        }
        #expect(portal.calls == [.fetchCertificates])
        #expect(try identities.load() == nil)
    }

    @Test func aFailedRevocationStopsBeforeRequestingACertificate() async throws {
        let failing = Fixture.iOSDevelopment.certificate
        let other = Fixture.iPhoneDeveloper.certificate
        let portal = FakePortal(
            certificates: [failing, other],
            issuing: Fixture.appleDevelopment.keyStore,
            failingRevocations: [failing.serialNumber]
        )
        let prompt = Prompt { offered in .revoke(offered) }

        await #expect(throws: FakePortal.RevokeFailed(serial: failing.serialNumber)) {
            try await provisioner(portal).resolveIdentity(
                team: FakePortal.team, session: FakePortal.session, onExistingCertificates: prompt.handle)
        }
        // Both revocations were attempted; no certificate was requested.
        #expect(portal.calls == [
            .fetchCertificates,
            .revokeCertificate(serial: failing.serialNumber),
            .revokeCertificate(serial: other.serialNumber),
        ])
        #expect(try identities.load() == nil)
    }

    @Test func recognisesIOSDevelopmentCertificatesByName() {
        #expect(CertificateProvisioner.isIOSDevelopmentCertificate(Fixture.iPhoneDeveloper.certificate))
        #expect(CertificateProvisioner.isIOSDevelopmentCertificate(Fixture.iOSDevelopment.certificate))
        #expect(!CertificateProvisioner.isIOSDevelopmentCertificate(Fixture.appleDevelopment.certificate))
    }
}
