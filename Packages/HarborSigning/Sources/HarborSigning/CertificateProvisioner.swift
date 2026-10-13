import Foundation
import HarborCore
import SideSign

/// What to do about development certificates that already exist on the team
/// when Harbor needs a new one.
public enum RevocationDecision: Sendable {
    /// Leave them and request another certificate. Apple may refuse if the
    /// team is at its limit.
    case keepExisting
    /// Revoke these, then request a new certificate. Apps signed with a
    /// revoked certificate stop launching until they are re-signed.
    case revoke([X509Certificate])
    case cancel
}

public enum SigningError: Error, Equatable, Sendable {
    case cancelled
}

/// Produces the identity Harbor signs with, creating a certificate on the
/// developer portal only when the stored one is missing or no longer valid.
public struct CertificateProvisioner: Sendable {
    /// Called with the team's existing iOS development certificates. Revoking
    /// affects other tools and devices, so the choice always goes to the user.
    public typealias RevocationHandler = @Sendable ([X509Certificate]) async -> RevocationDecision

    private let portal: any DeveloperPortalAPI
    private let identities: SigningIdentityStore
    private let machineName: String

    /// - Parameter machineName: shown on the developer portal next to the
    ///   certificate, so the user can tell which device requested it.
    public init(portal: any DeveloperPortalAPI, identities: SigningIdentityStore, machineName: String) {
        self.portal = portal
        self.identities = identities
        self.machineName = machineName
    }

    public func resolveIdentity(
        team: Team,
        session: Session,
        onExistingCertificates: RevocationHandler
    ) async throws -> KeyStore {
        let portalCertificates = try await portal.fetchCertificates(for: team, session: session)

        if let stored = try identities.load(),
           portalCertificates.contains(where: { Self.sameSerial($0, stored.certificate) }) {
            return stored
        }

        let existing = portalCertificates.filter(Self.isIOSDevelopmentCertificate)
        if !existing.isEmpty {
            switch await onExistingCertificates(existing) {
            case .keepExisting:
                break
            case .revoke(let selected):
                try await revoke(selected, team: team, session: session)
            case .cancel:
                throw SigningError.cancelled
            }
        }

        let identity = try await portal.addCertificate(
            machineName: machineName, type: .development, to: team, session: session)
        try identities.save(identity)
        return identity
    }

    /// Attempts every revocation before reporting a failure, so one bad
    /// certificate does not leave the rest half-done without the user knowing.
    private func revoke(_ certificates: [X509Certificate], team: Team, session: Session) async throws {
        var firstError: (any Error)?
        for certificate in certificates {
            do {
                _ = try await portal.revokeCertificate(certificate, for: team, session: session)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    static func sameSerial(_ lhs: X509Certificate, _ rhs: X509Certificate) -> Bool {
        lhs.serialNumber.caseInsensitiveCompare(rhs.serialNumber) == .orderedSame
    }

    /// Certificates Harbor may offer to revoke. Same rule as SideStore:
    /// only iOS development certificates, never "Apple Development" ones.
    static func isIOSDevelopmentCertificate(_ certificate: X509Certificate) -> Bool {
        let name = certificate.name.lowercased()
        return name.contains("ios development") || name.contains("iphone developer")
    }
}
