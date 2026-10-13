import Foundation
import HarborCore
import HarborSigning
import Observation
import SideSign

/// Everything the interface shows and can do.
@MainActor
@Observable
final class AppModel {
    enum PairingState: Equatable {
        case missing
        case stored
        /// Connected, with the device's identifier as proof.
        case connected(deviceIdentifier: String)
    }

    /// A pending two-factor question. Answer it with `answerCode`.
    struct CodeRequest: Identifiable, Equatable {
        let id = UUID()
        var prompt: VerificationPrompt
    }

    private(set) var pairing: PairingState = .missing
    private(set) var appleID: String?
    private(set) var apps: [InstalledApp] = []
    /// A short description of the work in progress, or `nil` when idle.
    private(set) var activity: String?
    var problem: Problem?
    private(set) var codeRequest: CodeRequest?
    private(set) var revocationRequest: RevocationRequest?

    /// A pending question about existing certificates. Answer it with
    /// `answerRevocation`.
    struct RevocationRequest: Identifiable {
        let id = UUID()
        var certificates: [X509Certificate]
    }

    private let services: Services
    private var codeContinuation: CheckedContinuation<String?, Never>?
    private var revocationContinuation: CheckedContinuation<RevocationDecision, Never>?

    init(services: Services) {
        self.services = services
    }

    var isBusy: Bool { activity != nil }

    // MARK: Launch

    func start() async {
        await perform("Loading") {
            self.appleID = try self.services.account.storedAppleID()
            self.apps = try await self.services.library.all()
            if try self.services.secrets.read(.pairingRecord) != nil {
                self.pairing = .stored
            }
        }
        if pairing == .stored {
            await connect()
        }
    }

    // MARK: Pairing

    func importPairing(from url: URL) async {
        await perform("Importing pairing file") {
            let data = try Self.readSecurityScoped(url)
            // Validate before storing, so a bad file never replaces a good one.
            _ = try PairingRecord(propertyList: data)
            try self.services.secrets.write(Redacted(data), for: .pairingRecord)
            self.pairing = .stored
        }
        if pairing == .stored {
            await connect()
        }
    }

    func connect() async {
        await perform("Connecting to this device") {
            guard let stored = try self.services.secrets.read(.pairingRecord) else {
                throw DeviceIssue.pairingMissing
            }
            let record = try PairingRecord(propertyList: stored.expose())
            try await self.services.transport.connect(using: record)
            let identifier = try await self.services.transport.deviceIdentifier()
            self.pairing = .connected(deviceIdentifier: identifier)
        }
    }

    // MARK: Account

    func signIn(appleID: String, password: String, rememberPassword: Bool) async {
        await perform("Signing in") {
            let signedIn = try await self.services.account.signIn(
                appleID: appleID,
                password: Redacted(password),
                rememberPassword: rememberPassword,
                verification: TwoFactor.handler { [weak self] prompt in
                    await self?.askForCode(prompt)
                }
            )
            self.appleID = signedIn.account.appleID
        }
    }

    func signOut() {
        do {
            try services.account.signOut()
            appleID = nil
        } catch {
            problem = Problem(error)
        }
    }

    private func askForCode(_ prompt: VerificationPrompt) async -> String? {
        await withCheckedContinuation { continuation in
            codeContinuation = continuation
            codeRequest = CodeRequest(prompt: prompt)
        }
    }

    /// Pass `nil` to cancel the sign-in.
    func answerCode(_ code: String?) {
        codeRequest = nil
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
    }

    // MARK: Apps

    func install(ipaAt url: URL) async {
        await perform("Installing") {
            let local = try Self.copySecurityScoped(url)
            defer { try? FileManager.default.removeItem(at: local) }

            let account = try await self.currentAccount()
            let installed = try await self.services.pipeline.install(
                ipaAt: local,
                account: account,
                activeApps: self.activeAppIdentifiers,
                deviceType: self.services.deviceType,
                onExistingCertificates: { [weak self] certificates in
                    await self?.askAboutCertificates(certificates) ?? .cancel
                },
                progress: { [weak self] step in
                    Task { @MainActor in
                        // Only while the install is still running.
                        guard let self, self.activity != nil else { return }
                        self.activity = Self.describe(step)
                    }
                }
            )
            try await self.services.library.save(installed)
            self.apps = try await self.services.library.all()
        }
    }

    func refresh(_ app: InstalledApp) async {
        await perform("Refreshing \(app.name)") {
            let account = try await self.currentAccount()
            let refreshed = try await self.services.pipeline.refresh(
                app, account: account, deviceType: self.services.deviceType)
            try await self.services.library.save(refreshed)
            self.apps = try await self.services.library.all()
        }
    }

    private func askAboutCertificates(_ certificates: [X509Certificate]) async -> RevocationDecision {
        await withCheckedContinuation { continuation in
            revocationContinuation = continuation
            revocationRequest = RevocationRequest(certificates: certificates)
        }
    }

    func answerRevocation(_ decision: RevocationDecision) {
        revocationRequest = nil
        revocationContinuation?.resume(returning: decision)
        revocationContinuation = nil
    }

    /// What the refresh planner says about the installed apps right now.
    func plan(now: Date = Date()) -> RefreshPlan {
        RefreshPlanner().plan(apps: apps.map(\.signedApp), now: now)
    }

    /// Harbor itself occupies one of the three slots.
    private var activeAppIdentifiers: Set<String> {
        Set(apps.map(\.id)).union([Bundle.main.bundleIdentifier ?? "harbor"])
    }

    private func currentAccount() async throws -> SignedInAccount {
        guard let account = try await services.account.restore() else {
            throw AccountError.signInRequired
        }
        return account
    }

    // MARK: Helpers

    private func perform(_ description: String, _ work: () async throws -> Void) async {
        guard activity == nil else { return }
        activity = description
        defer { activity = nil }
        do {
            try await work()
        } catch {
            problem = Problem(error)
        }
    }

    private static func describe(_ step: InstallPipeline.Step) -> String {
        switch step {
        case .unpack: "Unpacking"
        case .registerDevice: "Registering this device"
        case .certificate: "Preparing the signing certificate"
        case .profiles: "Fetching provisioning profiles"
        case .sign: "Signing"
        case .install: "Installing on this device"
        }
    }

    private static func readSecurityScoped(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Copies a picked file into Harbor's own space, so work on it does not
    /// depend on access to the original.
    private static func copySecurityScoped(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-import-\(UUID().uuidString).ipa")
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
