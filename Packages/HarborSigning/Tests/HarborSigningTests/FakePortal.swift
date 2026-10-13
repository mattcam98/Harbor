import Foundation
import SideSign

/// A developer portal that only knows about certificates. Everything else
/// throws, so a test that strays outside its subject fails loudly.
final class FakePortal: DeveloperPortalAPI, @unchecked Sendable {
    struct Unsupported: Error {}
    struct RevokeFailed: Error, Equatable {
        let serial: String
    }

    enum Call: Equatable {
        case fetchCertificates
        case addCertificate(machineName: String)
        case revokeCertificate(serial: String)
    }

    private let lock = NSLock()
    private var certificates: [X509Certificate]
    private var recorded: [Call] = []
    private let issued: KeyStore
    private let failingRevocations: Set<String>

    /// - Parameters:
    ///   - certificates: what the team already has on the portal.
    ///   - issuing: the identity `addCertificate` hands back.
    ///   - failingRevocations: serials whose revocation fails.
    init(certificates: [X509Certificate], issuing: KeyStore, failingRevocations: Set<String> = []) {
        self.certificates = certificates
        self.issued = issuing
        self.failingRevocations = failingRevocations
    }

    var calls: [Call] { lock.withLock { recorded } }
    var remainingSerials: [String] { lock.withLock { certificates.map(\.serialNumber) } }

    static let team = Team(identifier: "TESTTEAM01", name: "Test Team", type: .free)
    static let session = Session(
        dsid: "0",
        authToken: "token",
        anisetteData: AnisetteData(
            machineID: "", oneTimePassword: "", localUserID: "", routingInfo: "", deviceID: "",
            serialNumber: "", clientInfo: "", userAgent: "", clientTime: "", locale: "", timeZone: ""
        ),
        xcodeVersion: "0"
    )

    // MARK: Certificates

    func fetchCertificates(for team: Team, session: Session) async throws -> [X509Certificate] {
        lock.withLock {
            recorded.append(.fetchCertificates)
            return certificates
        }
    }

    func addCertificate(machineName: String, type: CertificateType, to team: Team, session: Session) async throws -> KeyStore {
        lock.withLock {
            recorded.append(.addCertificate(machineName: machineName))
            certificates.append(issued.certificate)
            return issued
        }
    }

    func revokeCertificate(_ certificate: X509Certificate, for team: Team, session: Session) async throws -> Bool {
        let serial = certificate.serialNumber
        return try lock.withLock {
            recorded.append(.revokeCertificate(serial: serial))
            if failingRevocations.contains(serial) {
                throw RevokeFailed(serial: serial)
            }
            certificates.removeAll { $0.serialNumber == serial }
            return true
        }
    }

    // MARK: Not part of these tests

    func authenticate(appleID unsanitizedAppleID: String, password: String, anisetteData: AnisetteData, xcodeVersion: String, machinePassword: String?, accountRepairHandler: DeveloperPortal.AccountRepairHandler, verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession { throw Unsupported() }
    func fetchAccount(session: Session) async throws -> Account { throw Unsupported() }
    func fetchTeams(for account: Account, session: Session) async throws -> [Team] { throw Unsupported() }
    func fetchDevices(for team: Team, types: DeviceType, session: Session) async throws -> [Device] { throw Unsupported() }
    func registerDevice(name: String, identifier: String, type: DeviceType, team: Team, session: Session) async throws -> Device { throw Unsupported() }
    func updateDevice(_ device: Device, team: Team, session: Session) async throws -> Device { throw Unsupported() }
    func disableDevice(_ device: Device, team: Team, session: Session) async throws -> Device { throw Unsupported() }
    func deleteDevice(_ device: Device, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func fetchAppIDs(for team: Team, session: Session) async throws -> [AppID] { throw Unsupported() }
    func addAppID(withName name: String, bundleIdentifier: String, team: Team, session: Session) async throws -> AppID { throw Unsupported() }
    func updateAppID(_ appID: AppID, team: Team, session: Session) async throws -> AppID { throw Unsupported() }
    func deleteAppID(_ appID: AppID, for team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func fetchAppGroups(for team: Team, session: Session) async throws -> [AppGroup] { throw Unsupported() }
    func addAppGroup(name: String, groupIdentifier: String, team: Team, session: Session) async throws -> AppGroup { throw Unsupported() }
    func updateAppGroup(_ appGroup: AppGroup, team: Team, session: Session) async throws -> AppGroup { throw Unsupported() }
    func assignAppGroups(_ appGroups: [AppGroup], to appID: AppID, team: Team, session: Session) async throws -> AppID { throw Unsupported() }
    func deleteAppGroup(_ appGroup: AppGroup, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func listProvisioningProfiles(includeTeamProfiles: Bool, for team: Team, session: Session) async throws -> [ListedProvisioningProfile] { throw Unsupported() }
    func createProvisioningProfile(name: String, appID: AppID, certificateIDs: [String], deviceIDs: [String], subPlatform: String?, distributionType: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], subPlatform: String?, distributionType: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func downloadProvisioningProfile(profileID: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func downloadProvisioningProfile(for appID: AppID, isTeamProfile: Bool, subPlatform: String?, deviceType: DeviceType, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func deleteProvisioningProfile(profileID: String, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func fetchAuthDevices(session: Session) async throws -> [AuthDevice] { throw Unsupported() }
    func removeAuthDevice(id: String, session: Session) async throws -> Bool { throw Unsupported() }
}
