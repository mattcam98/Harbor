import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

/// Hands out anisette data with a different one-time password each time,
/// as the real thing does.
final class FakeAnisette: AnisetteProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requests: Int { lock.withLock { count } }

    static func data(oneTimePassword: String) -> AnisetteData {
        AnisetteData(
            machineID: "machine", oneTimePassword: oneTimePassword, localUserID: "", routingInfo: "",
            deviceID: "", serialNumber: "", clientInfo: "", userAgent: "", clientTime: "", locale: "", timeZone: ""
        )
    }

    func anisetteData() async throws -> AnisetteData {
        let number = lock.withLock { () -> Int in
            count += 1
            return count
        }
        return Self.data(oneTimePassword: "otp-\(number)")
    }
}

@Suite struct AccountServiceTests {
    let secrets = InMemorySecretStore()
    let anisette = FakeAnisette()

    func service(_ portal: FakePortal) -> AccountService {
        AccountService(portal: portal, anisette: anisette, secrets: secrets)
    }

    func signIn(_ portal: FakePortal, rememberPassword: Bool = false) async throws -> SignedInAccount {
        try await service(portal).signIn(
            appleID: "user@example.com",
            password: Redacted("hunter2"),
            rememberPassword: rememberPassword,
            verification: nil
        )
    }

    @Test func signsInAndKeepsTheSessionButNotThePassword() async throws {
        let portal = FakePortal()

        let signedIn = try await signIn(portal)

        #expect(signedIn.account == FakePortal.account)
        #expect(signedIn.team == FakePortal.team)
        #expect(signedIn.session.authToken == "token-1")
        #expect(portal.calls == [.authenticate(appleID: "user@example.com", password: "hunter2"), .fetchTeams])
        #expect(try secrets.read(.applePassword) == nil)
        #expect(try service(portal).storedAppleID() == "user@example.com")
    }

    @Test func restoresTheSessionWithFreshAnisetteAndNoPortalCall() async throws {
        let portal = FakePortal()
        let signedIn = try await signIn(portal)
        let callsAfterSignIn = portal.calls

        let restored = try #require(try await service(portal).restore())

        #expect(restored.account == signedIn.account)
        #expect(restored.team == signedIn.team)
        #expect(restored.session.authToken == "token-1")
        #expect(restored.session.dsid == signedIn.session.dsid)
        #expect(restored.session.anisetteData.oneTimePassword == "otp-2")
        #expect(portal.calls == callsAfterSignIn)
    }

    @Test func restoreIsNilWhenNobodyIsSignedIn() async throws {
        #expect(try await service(FakePortal()).restore() == nil)
        #expect(anisette.requests == 0)
    }

    @Test func remembersThePasswordOnlyOnRequestAndForgetsItAfterwards() async throws {
        let portal = FakePortal()

        _ = try await signIn(portal, rememberPassword: true)
        #expect(try secrets.read(.applePassword)?.expose() == Data("hunter2".utf8))

        _ = try await signIn(portal, rememberPassword: false)
        #expect(try secrets.read(.applePassword) == nil)
    }

    @Test func thePasswordNeverEntersTheStoredSession() async throws {
        _ = try await signIn(FakePortal(), rememberPassword: true)

        let stored = try #require(try secrets.read(.appleSessionToken)).expose()
        #expect(stored.range(of: Data("hunter2".utf8)) == nil)
    }

    @Test func anAccountWithoutTeamsCannotSignIn() async throws {
        let portal = FakePortal(teams: [])

        await #expect(throws: AccountError.noTeams) {
            try await signIn(portal)
        }
        #expect(try secrets.read(.appleSessionToken) == nil)
    }

    @Test func decliningToChooseATeamCancelsAndStoresNothing() async throws {
        let portal = FakePortal()

        await #expect(throws: SigningError.cancelled) {
            try await service(portal).signIn(
                appleID: "user@example.com", password: Redacted("hunter2"),
                verification: nil, selectTeam: { _ in nil })
        }
        #expect(try secrets.read(.appleSessionToken) == nil)
        #expect(try secrets.read(.applePassword) == nil)
    }

    @Test func prefersAPersonalTeamAndNeverAnOrganisationFirst() async {
        let organisation = Team(identifier: "ORG", name: "Org", type: .organization)
        let free = Team(identifier: "FREE", name: "Free", type: .free)
        let individual = Team(identifier: "PAID", name: "Paid", type: .individual)

        #expect(await AccountService.preferredTeam([organisation, free, individual]) == individual)
        #expect(await AccountService.preferredTeam([organisation, free]) == free)
        #expect(await AccountService.preferredTeam([organisation]) == organisation)
        #expect(await AccountService.preferredTeam([]) == nil)
    }

    @Test func signOutRemovesTheSessionAndThePassword() async throws {
        let portal = FakePortal()
        _ = try await signIn(portal, rememberPassword: true)

        try service(portal).signOut()

        #expect(try secrets.read(.appleSessionToken) == nil)
        #expect(try secrets.read(.applePassword) == nil)
        #expect(try await service(portal).restore() == nil)
    }

    @Test func renewingNeedsARememberedPassword() async throws {
        let portal = FakePortal()
        _ = try await signIn(portal)

        await #expect(throws: AccountError.signInRequired) {
            try await service(portal).renewSession(verification: nil)
        }
    }

    @Test func renewsWithTheRememberedPasswordAndKeepsTheTeam() async throws {
        let chosen = Team(identifier: "SECOND", name: "Second", type: .free)
        let portal = FakePortal(teams: [FakePortal.team, chosen])
        _ = try await service(portal).signIn(
            appleID: "user@example.com", password: Redacted("hunter2"), rememberPassword: true,
            verification: nil, selectTeam: { _ in chosen })

        let renewed = try await service(portal).renewSession(verification: nil)

        #expect(renewed.session.authToken == "token-2")
        #expect(renewed.team == chosen)
        #expect(try secrets.read(.applePassword) != nil)
        #expect(try await service(portal).restore()?.session.authToken == "token-2")
    }

    // MARK: Apple refusing the machine

    @Test func applesRefusalOfTheMachineIsNotAnAccountProblem() {
        let refusal = ServerError.underlyingError(
            code: -80045, message: "This action cannot be completed at this time.")
        #expect(AccountService.classified(refusal) as? AccountError == .machineIdentityRefused)
    }

    @Test func otherAnswersFromApplePassThroughUnchanged() {
        let wrongPassword = ServerError.underlyingError(
            code: -20101, message: "Your account information was entered incorrectly.")
        guard case ServerError.underlyingError(code: -20101, _) = AccountService.classified(wrongPassword) else {
            Issue.record("a wrong password was reclassified")
            return
        }
        #expect(AccountService.classified(URLError(.notConnectedToInternet)) is URLError)
    }
}
