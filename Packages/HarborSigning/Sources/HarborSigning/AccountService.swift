import Foundation
import HarborCore
import SideSign

/// A developer account ready to make portal requests.
public struct SignedInAccount: Equatable, Sendable {
    public var account: Account
    public var team: Team
    public var session: Session
}

public enum AccountError: Error, Equatable, Sendable {
    case noTeams
    /// Apple refused the request because of the machine it says it comes
    /// from, before looking at the account. Nothing is wrong with the Apple
    /// ID or the password, and trying again changes nothing.
    case machineIdentityRefused
    /// The stored session no longer works and no password was kept, so the
    /// user has to sign in again.
    case signInRequired
}

/// Signs in to an Apple ID and keeps the resulting session.
///
/// What is persisted: the account, the chosen team and the session token.
/// The password is persisted only when the caller says the user opted in.
public struct AccountService: Sendable {
    /// Chooses among several teams. Return `nil` to cancel.
    public typealias TeamSelector = @Sendable ([Team]) async -> Team?

    /// The Xcode version presented to Apple's developer services.
    public static let xcodeVersion = "26.0 (26A242)"

    struct StoredSession: Codable, Equatable {
        var account: Account
        var team: Team
        var dsid: String
        var authToken: String
    }

    private let portal: any DeveloperPortalAPI
    private let anisette: any AnisetteProviding
    private let secrets: any SecretStore

    public init(portal: any DeveloperPortalAPI, anisette: any AnisetteProviding, secrets: any SecretStore) {
        self.portal = portal
        self.anisette = anisette
        self.secrets = secrets
    }

    /// - Parameters:
    ///   - rememberPassword: store the password so an expired session can be
    ///     renewed unattended. Off unless the user chose it.
    ///   - verification: answers two-factor prompts.
    public func signIn(
        appleID: String,
        password: Redacted<String>,
        rememberPassword: Bool = false,
        verification: DeveloperPortal.VerificationHandler?,
        accountRepair: @escaping DeveloperPortal.AccountRepairHandler = DeveloperPortal.defaultAccountRepairHandler,
        selectTeam: TeamSelector = AccountService.preferredTeam
    ) async throws -> SignedInAccount {
        let authenticated: AuthSession
        do {
            authenticated = try await portal.authenticate(
                appleID: appleID,
                password: password.expose(),
                anisetteData: try await anisette.anisetteData(),
                xcodeVersion: Self.xcodeVersion,
                machinePassword: nil,
                accountRepairHandler: accountRepair,
                verificationHandler: verification
            )
        } catch {
            throw Self.classified(error)
        }

        let teams = try await portal.fetchTeams(for: authenticated.account, session: authenticated.session)
        guard !teams.isEmpty else { throw AccountError.noTeams }
        guard let team = await selectTeam(teams) else { throw SigningError.cancelled }

        let stored = StoredSession(
            account: authenticated.account,
            team: team,
            dsid: authenticated.session.dsid,
            authToken: authenticated.session.authToken
        )
        try secrets.write(Redacted(JSONEncoder().encode(stored)), for: .appleSessionToken)

        if rememberPassword {
            try secrets.write(Redacted(Data(password.expose().utf8)), for: .applePassword, optedIn: true)
        } else {
            try secrets.delete(.applePassword)
        }

        return SignedInAccount(account: authenticated.account, team: team, session: authenticated.session)
    }

    /// Apple's code for "this action cannot be completed at this time",
    /// which is what its sign-in answers when it will not deal with the
    /// machine a request comes from.
    static let machineRefusedCode = -80045

    /// Gives Apple's refusal of the machine a name of its own, so it is not
    /// shown as a problem with the account. Everything else passes through.
    static func classified(_ error: any Error) -> any Error {
        if case ServerError.underlyingError(code: machineRefusedCode, _) = error {
            return AccountError.machineIdentityRefused
        }
        return error
    }

    /// Rebuilds the session from storage with fresh anisette data. Returns
    /// `nil` when nobody is signed in. Does not contact Apple, so a revoked
    /// token only shows up on the next portal request.
    public func restore() async throws -> SignedInAccount? {
        guard let stored = try loadStored() else { return nil }
        let session = Session(
            dsid: stored.dsid,
            authToken: stored.authToken,
            anisetteData: try await anisette.anisetteData(),
            xcodeVersion: Self.xcodeVersion
        )
        return SignedInAccount(account: stored.account, team: stored.team, session: session)
    }

    /// Signs in again with the remembered password, keeping the same team.
    /// Used when Apple rejects the stored session.
    public func renewSession(verification: DeveloperPortal.VerificationHandler?) async throws -> SignedInAccount {
        guard
            let stored = try loadStored(),
            let password = try secrets.read(.applePassword)
        else {
            throw AccountError.signInRequired
        }
        let previousTeam = stored.team
        return try await signIn(
            appleID: stored.account.appleID,
            password: Redacted(String(decoding: password.expose(), as: UTF8.self)),
            rememberPassword: true,
            verification: verification,
            selectTeam: { teams in
                teams.first { $0.identifier == previousTeam.identifier }
            }
        )
    }

    public func signOut() throws {
        try secrets.delete(.appleSessionToken)
        try secrets.delete(.applePassword)
    }

    /// The signed-in Apple ID, for display.
    public func storedAppleID() throws -> String? {
        try loadStored()?.account.appleID
    }

    /// A personal paid team, then a free one, then whatever is left. An
    /// organisation team is never preferred: its certificates are shared.
    public static let preferredTeam: TeamSelector = { teams in
        teams.first { $0.type == .individual }
            ?? teams.first { $0.type == .free }
            ?? teams.first
    }

    private func loadStored() throws -> StoredSession? {
        guard let data = try secrets.read(.appleSessionToken) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data.expose())
    }
}
