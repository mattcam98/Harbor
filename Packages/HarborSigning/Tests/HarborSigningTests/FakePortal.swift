import Foundation
import SideSign

/// A developer portal that knows about sign-in, certificates, App IDs and
/// team profiles. Everything else throws, so a test that strays outside its subject fails loudly.
final class FakePortal: DeveloperPortalAPI, @unchecked Sendable {
    struct Unsupported: Error {}
    struct RevokeFailed: Error, Equatable {
        let serial: String
    }

    enum Call: Equatable {
        case fetchCertificates
        case addCertificate(machineName: String)
        case revokeCertificate(serial: String)
        case fetchAppIDs
        case addAppID(name: String, bundleIdentifier: String)
        case downloadProfile(bundleIdentifier: String)
        case authenticate(appleID: String, password: String)
        case fetchTeams
        case updateAppID(bundleIdentifier: String, features: [String: String])
        case fetchAppGroups
        case addAppGroup(name: String, identifier: String)
        case assignAppGroups(identifiers: [String], bundleIdentifier: String)
        case fetchDevices
        case registerDevice(name: String, identifier: String)
    }

    private let lock = NSLock()
    private var certificates: [X509Certificate]
    private var appIDs: [AppID]
    private var teams: [Team]
    private var devices: [Device]
    private var appGroups: [AppGroup]
    private var authTokens: [String]
    private var recorded: [Call] = []
    private let issued: KeyStore
    private let failingRevocations: Set<String>

    /// - Parameters:
    ///   - certificates: what the team already has on the portal.
    ///   - issuing: the identity `addCertificate` hands back.
    ///   - failingRevocations: serials whose revocation fails.
    ///   - appIDs: App IDs already registered on the team.
    init(
        certificates: [X509Certificate] = [],
        issuing: KeyStore = Fixture.iPhoneDeveloper.keyStore,
        failingRevocations: Set<String> = [],
        appIDs: [AppID] = [],
        teams: [Team] = [FakePortal.team],
        authTokens: [String] = ["token-1", "token-2", "token-3"],
        devices: [Device] = [],
        appGroups: [AppGroup] = []
    ) {
        self.appGroups = appGroups
        self.devices = devices
        self.teams = teams
        self.authTokens = authTokens
        self.certificates = certificates
        self.appIDs = appIDs
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

    // MARK: App IDs and profiles

    func fetchAppIDs(for team: Team, session: Session) async throws -> [AppID] {
        lock.withLock {
            recorded.append(.fetchAppIDs)
            return appIDs
        }
    }

    func addAppID(withName name: String, bundleIdentifier: String, team: Team, session: Session) async throws -> AppID {
        lock.withLock {
            recorded.append(.addAppID(name: name, bundleIdentifier: bundleIdentifier))
            let appID = AppID(identifier: "ID\(appIDs.count)", name: name, bundleIdentifier: bundleIdentifier)
            appIDs.append(appID)
            return appID
        }
    }

    func downloadProvisioningProfile(for appID: AppID, isTeamProfile: Bool, subPlatform: String?, deviceType: DeviceType, team: Team, session: Session) async throws -> ProvisioningProfile {
        lock.withLock {
            recorded.append(.downloadProfile(bundleIdentifier: appID.bundleIdentifier))
            return ProvisioningProfile(
                name: "iOS Team Provisioning Profile: \(appID.bundleIdentifier)",
                uuid: UUID(),
                bundleIdentifier: appID.bundleIdentifier,
                teamIdentifier: team.identifier,
                teamName: team.name,
                creationDate: Date(timeIntervalSince1970: 0),
                expirationDate: Date(timeIntervalSince1970: 7 * 24 * 3600),
                isFreeProvisioningProfile: true,
                data: Data()
            )
        }
    }

    // MARK: Sign-in

    static let account = Account(appleID: "user@example.com", identifier: "1234", firstName: "Test", lastName: "User")

    /// Each sign-in hands out the next token, so tests can tell sessions apart.
    func authenticate(appleID unsanitizedAppleID: String, password: String, anisetteData: AnisetteData, xcodeVersion: String, machinePassword: String?, accountRepairHandler: DeveloperPortal.AccountRepairHandler, verificationHandler: DeveloperPortal.VerificationHandler?) async throws -> AuthSession {
        try lock.withLock {
            recorded.append(.authenticate(appleID: unsanitizedAppleID, password: password))
            guard !authTokens.isEmpty else { throw Unsupported() }
            let session = Session(
                dsid: "dsid-1", authToken: authTokens.removeFirst(),
                anisetteData: anisetteData, xcodeVersion: xcodeVersion)
            return AuthSession(account: FakePortal.account, session: session)
        }
    }

    func fetchTeams(for account: Account, session: Session) async throws -> [Team] {
        lock.withLock {
            recorded.append(.fetchTeams)
            return teams
        }
    }

    // MARK: Capabilities and app groups

    func updateAppID(_ appID: AppID, team: Team, session: Session) async throws -> AppID {
        lock.withLock {
            let features = Dictionary(uniqueKeysWithValues: appID.features.map { ($0.key.rawValue, $0.value) })
            recorded.append(.updateAppID(bundleIdentifier: appID.bundleIdentifier, features: features))
            if let index = appIDs.firstIndex(where: { $0.identifier == appID.identifier }) {
                appIDs[index].features.merge(appID.features) { _, new in new }
                return appIDs[index]
            }
            return appID
        }
    }

    func fetchAppGroups(for team: Team, session: Session) async throws -> [AppGroup] {
        lock.withLock {
            recorded.append(.fetchAppGroups)
            return appGroups
        }
    }

    func addAppGroup(name: String, groupIdentifier: String, team: Team, session: Session) async throws -> AppGroup {
        lock.withLock {
            recorded.append(.addAppGroup(name: name, identifier: groupIdentifier))
            let group = AppGroup(name: name, identifier: groupIdentifier, groupID: "GROUP" + String(appGroups.count))
            appGroups.append(group)
            return group
        }
    }

    func assignAppGroups(_ groups: [AppGroup], to appID: AppID, team: Team, session: Session) async throws -> AppID {
        lock.withLock {
            recorded.append(.assignAppGroups(
                identifiers: groups.map { $0.identifier }, bundleIdentifier: appID.bundleIdentifier))
            return appID
        }
    }

    // MARK: Devices

    func fetchDevices(for team: Team, types: DeviceType, session: Session) async throws -> [Device] {
        lock.withLock {
            recorded.append(.fetchDevices)
            return devices
        }
    }

    func registerDevice(name: String, identifier: String, type: DeviceType, team: Team, session: Session) async throws -> Device {
        lock.withLock {
            recorded.append(.registerDevice(name: name, identifier: identifier))
            let device = Device(name: name, identifier: identifier, type: type)
            devices.append(device)
            return device
        }
    }

    // MARK: Not part of these tests

    func fetchAccount(session: Session) async throws -> Account { throw Unsupported() }
    func updateDevice(_ device: Device, team: Team, session: Session) async throws -> Device { throw Unsupported() }
    func disableDevice(_ device: Device, team: Team, session: Session) async throws -> Device { throw Unsupported() }
    func deleteDevice(_ device: Device, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func deleteAppID(_ appID: AppID, for team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func updateAppGroup(_ appGroup: AppGroup, team: Team, session: Session) async throws -> AppGroup { throw Unsupported() }
    func deleteAppGroup(_ appGroup: AppGroup, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func listProvisioningProfiles(includeTeamProfiles: Bool, for team: Team, session: Session) async throws -> [ListedProvisioningProfile] { throw Unsupported() }
    func createProvisioningProfile(name: String, appID: AppID, certificateIDs: [String], deviceIDs: [String], subPlatform: String?, distributionType: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func updateProvisioningProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], subPlatform: String?, distributionType: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func downloadProvisioningProfile(profileID: String, team: Team, session: Session) async throws -> ProvisioningProfile { throw Unsupported() }
    func deleteProvisioningProfile(profileID: String, team: Team, session: Session) async throws -> Bool { throw Unsupported() }
    func fetchAuthDevices(session: Session) async throws -> [AuthDevice] { throw Unsupported() }
    func removeAuthDevice(id: String, session: Session) async throws -> Bool { throw Unsupported() }
}
