import Foundation
import HarborCore
import HarborPlatform
import HarborSigning
import Observation
import SideSign
import UIKit

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
    /// Apps installed inside Harbor's container.
    private(set) var guests: [GuestApp] = []
    /// When this copy of Harbor stops opening: the end of the profile it
    /// was installed with, or of the last renewal. `nil` where there is no
    /// profile, as on the simulator.
    private(set) var harborExpiry: Date?
    /// What the last renewal did, while Harbor stays open.
    private(set) var renewalNote: String?
    /// Whether iOS has been asked to warn ahead of that.
    private(set) var expiryReminders = UserDefaults.standard.bool(forKey: AppModel.expiryRemindersKey)
    private static let expiryRemindersKey = "HarborExpiryReminders"
    /// When a Shortcuts automation last asked Harbor to renew, which shows
    /// the automation is set up and running.
    private(set) var lastAutomaticRenewal = UserDefaults.standard.object(forKey: AppModel.lastAutomaticKey) as? Date
    private static let lastAutomaticKey = "HarborLastAutomaticRenewal"
    /// Why that run failed, or `nil` when it worked.
    private(set) var lastAutomaticFailure = UserDefaults.standard.string(forKey: AppModel.lastFailureKey)
    private static let lastFailureKey = "HarborLastAutomaticFailure"

    /// Whether the automation has run recently enough to count as working:
    /// it runs daily, so two days without a run means it has stopped.
    var automationHealth: AutomationHealth {
        guard let last = lastAutomaticRenewal else { return .notSetUp }
        if lastAutomaticFailure != nil { return .failing }
        return clock.timeIntervalSince(last) > 48 * 3600 ? .stopped : .working
    }

    enum AutomationHealth {
        case notSetUp, working, failing, stopped
    }

    /// Now, as far as the interface is concerned. Moved on when Harbor comes
    /// to the front and when the day, clock or time zone changes, so dates
    /// such as "Tomorrow at 14:00" are redrawn.
    private(set) var clock = Date()

    func tick() {
        clock = Date()
    }
    /// Whether an automatic renewal that renewed something says so. Failures
    /// are always reported.
    var notifiesAfterRenewal = UserDefaults.standard.bool(forKey: AppModel.notifyKey) {
        didSet { UserDefaults.standard.set(notifiesAfterRenewal, forKey: Self.notifyKey) }
    }
    private static let notifyKey = "HarborNotifyAfterRenewal"

    /// Guests running beside Harbor, each in its own process.
    let sessions = GuestSessions()
    /// A Home Screen shortcut waiting for the user to install it.
    var shortcutOffer: ShortcutOffer?

    /// How a guest is run.
    enum LaunchMode {
        /// In its own process, with Harbor still there underneath: the user
        /// can come back to Harbor and have several apps open.
        case beside
        /// Harbor's own process becomes the app. Nothing of Harbor is left
        /// until the app is closed. For apps that will not run the other way.
        case wholeApp
    }

    /// A configuration profile, at the address Safari is sent to.
    struct ShortcutOffer: Identifiable {
        let id = UUID()
        var name: String
        var address: URL
        /// Serves the profile to this device. It stops when the offer goes.
        let server: LoopbackFileServer
    }

    /// The sources of apps the user has added.
    private(set) var sources: [SavedSource] = []
    /// The download in progress, which can be cancelled.
    private(set) var download: Task<Void, Never>?
    var isDownloading: Bool { download != nil }
    /// The imported signing certificate, or `nil` when there is none.
    private(set) var signingIdentity: IdentitySummary?
    var hasSigningIdentity: Bool { signingIdentity != nil }

    enum RenewalError: Error, Equatable {
        /// There is no profile to renew, as on the simulator.
        case notSigned
        /// The certificate Harbor was signed with is gone from the account.
        case certificateGone
        /// Apple answered, but the named app's end date did not move.
        case notExtended(String)
    }

    enum GuestError: Error, Equatable {
        case certificateRequired
        /// iOS will not load the signed guest; `reason` is what it said.
        case signatureRejected(reason: String)
    }
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
    /// Sources already read since launch, by address.
    private var catalogues: [String: SourceCatalogue] = [:]
    /// Guests' own icons, by folder. `nil` is remembered too.
    @ObservationIgnored private var icons: [String: UIImage?] = [:]
    /// A link that arrived before the apps were loaded.
    private var pendingLink: URL?
    private var hasLoaded = false

    /// Pairing this iPhone with Harbor itself, on iOS 27 and later.
    let phonePairing: PhonePairing

    init(services: Services) {
        self.services = services
        phonePairing = PhonePairing(secrets: services.secrets)
        phonePairing.onPaired = { [weak self] in
            guard let self else { return }
            self.pairing = .stored
            Task { await self.connect() }
        }
        sessions.onFailure = { [weak self] guest, reason in
            self?.problem = Problem(title: "\(guest.name) didn't open", detail: reason)
        }
        Notices.showWhileOpen()
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
            try self.takePairingFromSetup()
            try self.takeIdentityFromSetup()
            self.guests = try self.services.guests.apps()
            self.sources = try self.services.sources.all()
            self.signingIdentity = try self.services.identities.load().map { IdentitySummary($0.certificate) }
            EngineBridge.setGuestsAreSigned(self.hasSigningIdentity)
        }
        // A guest that failed to start leaves its reason behind for us.
        if problem == nil, let reason = EngineBridge.takeLastError() {
            problem = Problem(title: "The app didn't open", detail: reason)
        }
        harborExpiry = Self.currentHarborExpiry()
        if expiryReminders, let harborExpiry {
            // Harbor was renewed since they were set: move them.
            _ = try? await ExpiryReminder.schedule(for: harborExpiry)
        }

        hasLoaded = true
        if let link = pendingLink {
            pendingLink = nil
            await open(link)
        }
        if pairing == .stored {
            await connect()
        }

        #if targetEnvironment(simulator)
        await runSimulatorHooks()
        #endif
    }

    // MARK: Pairing

    /// Takes a pairing file Harbor Setup has left, when there is one.
    /// - Returns: whether there was one.
    @discardableResult
    private func takePairingFromSetup() throws -> Bool {
        let secrets = services.secrets
        let received = try services.pairingInbox.receive { record in
            try secrets.write(Redacted(record.raw.expose()), for: .pairingRecord)
        }
        if received {
            pairing = .stored
        }
        return received
    }

    /// Takes the signing certificate Harbor Setup has left, when there is
    /// one. It is the certificate this copy of Harbor was signed with.
    @discardableResult
    private func takeIdentityFromSetup() throws -> Bool {
        let identities = services.identities
        var summary: IdentitySummary?
        let received = try services.identityInbox.receive { file in
            // Setup writes the file without a password; it never leaves the
            // cable and Harbor's own storage.
            let identity = try identities.importPKCS12(
                file, password: Redacted(""), acceptedCertificates: Self.certificatesThisInstallAccepts())
            summary = IdentitySummary(identity.certificate)
        }
        if received, let summary {
            signingIdentity = summary
            EngineBridge.setGuestsAreSigned(true)
        }
        return received
    }

    /// Harbor has come to the front. Setup may have left things for it
    /// while it was in the background.
    func cameToFront() async {
        guard hasLoaded, !isBusy else { return }
        do {
            try takeIdentityFromSetup()
            if try takePairingFromSetup() {
                await connect()
            }
        } catch {
            problem = Problem(error)
        }
    }

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
        await perform("Connecting") {
            try await self.connectNow()
        }
    }

    private func connectNow() async throws {
        guard let stored = try services.secrets.read(.pairingRecord) else {
            throw DeviceIssue.pairingMissing
        }
        let record = try PairingRecord(propertyList: stored.expose())
        try await services.transport.connect(using: record)
        let identifier = try await services.transport.deviceIdentifier()
        pairing = .connected(deviceIdentifier: identifier)
    }

    private func connectIfNeeded() async throws {
        if case .connected = pairing { return }
        try await connectNow()
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

    // MARK: Apps inside Harbor

    /// Puts an app into Harbor's container. It is not installed on the Home
    /// Screen and does not count towards the three-app limit.
    func addGuest(ipaAt url: URL) async {
        await perform("Adding to Harbor") {
            let local = try Self.copySecurityScoped(url)
            defer { try? FileManager.default.removeItem(at: local) }
            try await self.installGuest(fromIPAAt: local)
        }
    }

    /// Unpacks an IPA that is already in Harbor's own space, adds the app to
    /// the container and signs it.
    private func installGuest(fromIPAAt local: URL) async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-guest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        activity = "Adding to Harbor"
        let library = services.guests
        let guest = try await Task.detached {
            try library.install(appBundleAt: IPA.unpack(local, into: work))
        }.value
        guests = try library.apps()

        #if targetEnvironment(simulator)
        let bundle = library.bundleURL(of: guest)
        let signer = services.guestSigner
        try await Task.detached { try signer.signAdHoc(bundleAt: bundle) }.value
        #else
        if hasSigningIdentity {
            activity = "Signing \(guest.name)"
            try await sign(guest)
        }
        #endif
    }

    // MARK: Sources

    /// Adds a source after reading it once, so an address that is not a
    /// source is never saved.
    func addSource(_ typed: String) async {
        await perform("Reading the source") {
            let url = try SourceList.address(from: typed)
            let catalogue = try await self.fetchCatalogue(url)
            self.catalogues[url.absoluteString] = catalogue
            self.sources = try self.services.sources.save(SavedSource(url: url, name: catalogue.name))
        }
    }

    func removeSource(_ source: SavedSource) {
        do {
            sources = try services.sources.remove(source)
            catalogues[source.id] = nil
        } catch {
            problem = Problem(error)
        }
    }

    /// What a source lists. Read once per launch unless `reload`.
    func catalogue(of source: SavedSource, reload: Bool = false) async throws -> SourceCatalogue {
        if !reload, let known = catalogues[source.id] {
            return known
        }
        let catalogue = try await fetchCatalogue(source.url)
        catalogues[source.id] = catalogue
        if catalogue.name != source.name {
            sources = try services.sources.save(SavedSource(url: source.url, name: catalogue.name))
        }
        return catalogue
    }

    private func fetchCatalogue(_ url: URL) async throws -> SourceCatalogue {
        let file = try await services.downloader.download(url, limit: ArtifactDownloader.catalogueLimit)
        return try await Task.detached {
            defer { try? FileManager.default.removeItem(at: file) }
            // Sources the user adds are third parties: nothing vouches for
            // them, so nothing they list is treated as verified.
            return try SourceCatalogue.decode(Data(contentsOf: file), trust: .unverified)
        }.value
    }

    /// Downloads a version of an app from a source and adds it to Harbor.
    /// Returns at once; `cancelDownload` stops it.
    func startAdding(_ version: SourceCatalogue.Version, of app: SourceCatalogue.App) {
        guard download == nil, !isBusy else { return }
        download = Task {
            await self.add(version, of: app)
            self.download = nil
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    private func add(_ version: SourceCatalogue.Version, of app: SourceCatalogue.App) async {
        let name = app.name
        await perform("Downloading \(name)") {
            let file = try await self.services.downloader.download(
                version.downloadURL, limit: ArtifactDownloader.appLimit
            ) { [weak self] received, expected in
                Task { @MainActor in
                    self?.showDownload(of: name, received: received, expected: expected ?? version.size)
                }
            }
            defer { try? FileManager.default.removeItem(at: file) }

            self.activity = "Checking \(name)"
            let expectation = version.expectation
            _ = try await Task.detached {
                try ArtifactVerifier.verify(fileAt: file, against: expectation, policy: .allowUnverified)
            }.value
            try Task.checkCancellation()

            // Past this point the app is being put in place; stopping
            // half way would leave it unsigned.
            self.download = nil
            try await self.installGuest(fromIPAAt: file)
        }
    }

    private func showDownload(of name: String, received: Int64, expected: Int64?) {
        // Reports can arrive after the download has moved on.
        guard download != nil, activity?.hasPrefix("Downloading") == true else { return }
        let done = received.formatted(.byteCount(style: .file))
        if let expected, expected >= received {
            activity = "Downloading \(name) · \(done) of \(expected.formatted(.byteCount(style: .file)))"
        } else {
            activity = "Downloading \(name) · \(done)"
        }
    }

    /// The way guests run unless asked otherwise.
    var defaultLaunchMode: LaunchMode {
        GuestSessions.isAvailable ? .beside : .wholeApp
    }

    func launch(_ guest: GuestApp, mode: LaunchMode? = nil, container: String? = nil) async {
        // Already open beside Harbor: just bring it back.
        if mode != .wholeApp, sessions.isRunning(guest) {
            try? sessions.open(guest, container: container)
            return
        }
        await perform("Opening \(guest.name)") {
            if self.hasSigningIdentity {
                if try self.verdict(on: guest) != .accepted {
                    try await self.sign(guest)
                }
            } else if Self.signedGuestsRequired {
                throw GuestError.certificateRequired
            }
            try self.services.guests.prepareForLaunch(guest)

            switch mode ?? self.defaultLaunchMode {
            case .beside:
                try self.sessions.open(guest, container: container)
            case .wholeApp:
                try EngineBridge.launch(folderName: guest.folderName, container: container)
            }
        }
    }

    // MARK: Links and Home Screen shortcuts

    /// Acts on a link sent to Harbor, such as a Home Screen shortcut's.
    func open(_ url: URL) async {
        guard hasLoaded else {
            pendingLink = url
            return
        }
        switch try? DeepLinkRouter(scheme: Self.scheme).route(url) {
        case .launchApp(let bundleIdentifier, let container):
            guard let guest = guests.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                problem = Problem(
                    title: "App not found",
                    detail: "This icon opens an app that's no longer in Harbor. Add the app again or delete the icon.")
                return
            }
            await launch(guest, container: container)
        case .showHarbor:
            sessions.showHarbor()
        case .refreshAll(let callback):
            await renewWhatIsDue(callback: callback, automatic: true)
        default:
            // Links that fetch or install things are not acted on yet.
            break
        }
    }

    /// The scheme of links to Harbor: the first one in its Info.plist, which
    /// is also the one the container engine answers to.
    static let scheme: String = {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "harbor"
    }()

    /// Offers a Home Screen icon for a guest: a bookmark with the app's own
    /// name and icon that opens it inside Harbor.
    func offerShortcut(for guest: GuestApp) async {
        await perform("Preparing icon") {
            let shortcut = HomeScreenShortcut(
                app: guest,
                hostScheme: Self.scheme,
                hostBundleIdentifier: Bundle.main.bundleIdentifier ?? "harbor"
            )
            let profile = try shortcut.profile(icon: self.icon(for: guest).map { GuestIcon.shortcutPNG(from: $0) })
            // iOS only installs a profile that Safari downloads from a web
            // address, so the profile is served from this iPhone to itself.
            let server = LoopbackFileServer(
                body: profile, contentType: "application/x-apple-aspen-config", fileName: "\(guest.name).mobileconfig")
            self.shortcutOffer = ShortcutOffer(name: guest.name, address: try await server.start(), server: server)
        }
    }

    func icon(for guest: GuestApp) -> UIImage? {
        if let known = icons[guest.folderName] {
            return known
        }
        let image = GuestIcon.image(inBundleAt: services.guests.bundleURL(of: guest))
        icons[guest.folderName] = image
        return image
    }

    func removeGuest(_ guest: GuestApp) {
        for session in sessions.running where session.guest.folderName == guest.folderName {
            sessions.close(session.id)
        }
        icons[guest.folderName] = nil
        do {
            try services.guests.remove(guest)
            guests = try services.guests.apps()
        } catch {
            problem = Problem(error)
        }
    }

    /// Imports the signing identity from a `.p12` file and signs every guest
    /// with it.
    func importIdentity(from url: URL, password: String) async {
        await perform("Importing certificate") {
            let file = try Self.readSecurityScoped(url)
            let identity = try self.services.identities.importPKCS12(
                file,
                password: Redacted(password),
                acceptedCertificates: Self.certificatesThisInstallAccepts()
            )
            self.signingIdentity = IdentitySummary(identity.certificate)
            EngineBridge.setGuestsAreSigned(true)

            for guest in self.guests {
                self.activity = "Signing \(guest.name)"
                try await self.sign(guest)
            }
        }
    }

    private func sign(_ guest: GuestApp) async throws {
        guard let identity = try services.identities.load() else {
            throw GuestError.certificateRequired
        }
        let bundle = services.guests.bundleURL(of: guest)
        let signer = services.guestSigner
        let host = Bundle.main.bundleIdentifier ?? ""
        _ = try await Task.detached {
            try signer.sign(bundleAt: bundle, identity: identity, hostBundleIdentifier: host)
        }.value

        switch try verdict(on: guest) {
        case .accepted:
            return
        case .unsigned:
            throw GuestError.signatureRejected(reason: "The app has no signature after signing.")
        case .rejected(let stage, let code, let reason):
            throw GuestError.signatureRejected(reason: "\(reason) (\(stage.rawValue), error \(code))")
        }
    }

    /// Whether iOS would let this process load the guest's executable.
    private func verdict(on guest: GuestApp) throws -> LibraryValidation.Verdict {
        #if targetEnvironment(simulator)
        // The simulator does not check whose signature it is.
        return .accepted
        #else
        let executable = services.guests.bundleURL(of: guest).appendingPathComponent(guest.executableName)
        return try LibraryValidation.check(executableAt: executable)
        #endif
    }

    /// The certificates in the provisioning profile this copy of Harbor was
    /// installed with: the only ones iOS will accept on a guest. `nil` when
    /// there is no profile to read, as on the simulator.
    private static func certificatesThisInstallAccepts() -> [X509Certificate]? {
        guard let certificates = installedProfile()?.certificates, !certificates.isEmpty else { return nil }
        return certificates
    }

    /// The provisioning profile this copy of Harbor was installed with.
    private static func installedProfile() -> ProvisioningProfile? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? ProvisioningProfile(fileURL: url)
    }

    // MARK: Renewing Harbor

    /// What a renewal did.
    struct RenewalSummary {
        /// The names of what was renewed; empty when nothing was due.
        var renewed: [String]
        var harborExpiry: Date?

        var message: String {
            let until = harborExpiry.map { " Harbor now runs until \($0.dayAndTime)." } ?? ""
            if renewed.isEmpty {
                return "Nothing needed renewing." + (harborExpiry.map { " Harbor runs until \($0.dayAndTime)." } ?? "")
            }
            return "Renewed \(ListFormatter.localizedString(byJoining: renewed))." + until
        }
    }

    /// Renews this copy of Harbor from the phone: new profiles from Apple,
    /// installed over the loopback VPN. Nothing is reinstalled.
    func renewHarbor() async {
        await perform("Renewing Harbor") {
            let summary = try await self.withRetries {
                try await self.connectIfNeeded()
                let before = self.harborExpiry
                try await self.renewHost(account: try await self.currentAccount(), previous: before)
                return RenewalSummary(renewed: ["Harbor"], harborExpiry: self.harborExpiry)
            }
            self.renewalNote = summary.message
        }
    }

    /// What `harbor://renew` does, so a daily Shortcuts automation keeps
    /// Harbor renewed: renews Harbor, and the apps it installed, when they
    /// expire within two days (`RefreshPolicy.standard`), Harbor first.
    /// Passing problems, such as the VPN still connecting, are retried.
    ///
    /// With a `callback` the result goes back to Shortcuts, which shows a
    /// failure itself. Without one, an automatic run reports by notification.
    func renewWhatIsDue(callback: XCallback? = nil, automatic: Bool = false, now: Date = Date()) async {
        // Only a shortcut asks for a reply, so only those runs say whether
        // the automation works. A plain link could come from anywhere.
        let fromShortcut = callback != nil
        if fromShortcut {
            lastAutomaticRenewal = now
            UserDefaults.standard.set(now, forKey: Self.lastAutomaticKey)
            clock = now
        }
        // Harbor may be finishing something it started as it opened, such
        // as connecting. Wait for that rather than fail the shortcut.
        for _ in 0..<60 where activity != nil {
            try? await Task.sleep(for: .seconds(1))
        }
        guard activity == nil else {
            let message = "Harbor was busy. Try again in a minute."
            if fromShortcut { recordAutomatic(failure: message) }
            if let callback {
                await UIApplication.shared.open(callback.failed(message))
            }
            return
        }
        activity = "Renewing"
        let outcome: Result<RenewalSummary, any Error>
        do {
            outcome = .success(try await withRetries { try await self.renewDue(now: now) })
        } catch {
            outcome = .failure(error)
        }
        activity = nil

        switch outcome {
        case .success(let summary):
            renewalNote = summary.message
            if fromShortcut { recordAutomatic(failure: nil) }
            if automatic, notifiesAfterRenewal, !summary.renewed.isEmpty {
                Notices.post(title: "Renewed", body: summary.message)
            }
            if let callback {
                var values = ["status": summary.renewed.isEmpty ? "current" : "renewed", "message": summary.message]
                values["expires"] = summary.harborExpiry.map { $0.ISO8601Format() }
                await UIApplication.shared.open(callback.succeeded(values))
            }
        case .failure(let error) where error is CancellationError:
            // Shortcuts waits for an answer; don't leave it waiting.
            if let callback {
                await UIApplication.shared.open(callback.cancel ?? callback.failed("Renewal was cancelled."))
            }
        case .failure(let error):
            let shown = Problem(error)
            if fromShortcut { recordAutomatic(failure: "\(shown.title). \(shown.detail)") }
            if let callback {
                await UIApplication.shared.open(callback.failed("\(shown.title). \(shown.detail)"))
            } else {
                problem = shown
                if automatic {
                    Notices.post(title: "Couldn't renew", body: "\(shown.title). \(shown.detail)")
                }
            }
        }
    }

    private func recordAutomatic(failure: String?) {
        lastAutomaticFailure = failure
        UserDefaults.standard.set(failure, forKey: Self.lastFailureKey)
    }

    private func renewDue(now: Date) async throws -> RenewalSummary {
        let installed = try await services.library.all()
        var signed = installed.map(\.signedApp)
        if let expiry = Self.currentHarborExpiry() {
            signed.append(SignedApp(bundleIdentifier: Self.hostKey, name: "Harbor", expiry: expiry, isHost: true))
        }
        let plan = RefreshPlanner().plan(apps: signed, now: now)
        guard !plan.due.isEmpty else {
            return RenewalSummary(renewed: [], harborExpiry: Self.currentHarborExpiry())
        }

        try await connectIfNeeded()
        let account = try await currentAccount()
        var renewed: [String] = []
        for item in plan.due {
            if item.isHost {
                try await renewHost(account: account, previous: item.expiry)
            } else if let app = installed.first(where: { $0.id == item.bundleIdentifier }) {
                let refreshed = try await services.pipeline.refresh(
                    app, account: account, deviceType: services.deviceType)
                guard refreshed.expiry > app.expiry else { throw RenewalError.notExtended(app.name) }
                try await services.library.save(refreshed)
            }
            renewed.append(item.name)
        }
        apps = try await services.library.all()
        return RenewalSummary(renewed: renewed, harborExpiry: harborExpiry)
    }

    /// Runs `work` again after problems that tend to pass by themselves:
    /// the VPN still connecting, the device or a server not answering.
    private func withRetries<T>(_ work: () async throws -> T) async throws -> T {
        for delay in [5, 15] {
            do {
                return try await work()
            } catch let error where Self.isPassing(error) {
                // Connect afresh next time.
                if case .connected = pairing { pairing = .stored }
                activity = "Trying again"
                try await Task.sleep(for: .seconds(delay))
            }
        }
        return try await work()
    }

    private static func isPassing(_ error: any Error) -> Bool {
        switch error {
        case DeviceIssue.vpnOff, DeviceIssue.deviceUnreachable:
            return true
        case let error as URLError:
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(error.code)
        default:
            return false
        }
    }

    private func renewHost(account: SignedInAccount, previous: Date?) async throws {
        guard let profile = Self.installedProfile() else { throw RenewalError.notSigned }
        let host = try HostRenewal.record(
            ofAppAt: Bundle.main.bundleURL,
            team: account.team,
            expiry: Self.currentHarborExpiry() ?? profile.expirationDate
        )
        let renewed: InstalledApp
        do {
            renewed = try await services.pipeline.refresh(host, account: account, deviceType: services.deviceType)
        } catch InstallError.reinstallRequired {
            throw RenewalError.certificateGone
        }
        // Apple can hand back the profile it already issued; that is not a
        // renewal, and saying it was would hide the expiry coming.
        if let previous, renewed.expiry <= previous {
            throw RenewalError.notExtended("Harbor")
        }
        // The profile inside the app does not change, so the new end date is
        // kept beside it, for this install only.
        UserDefaults.standard.set(renewed.expiry, forKey: Self.renewedUntilKey)
        UserDefaults.standard.set(profile.uuid.uuidString, forKey: Self.renewedProfileKey)
        harborExpiry = renewed.expiry
        if expiryReminders {
            _ = try? await ExpiryReminder.schedule(for: renewed.expiry)
        }
    }

    /// Stands for Harbor among the installed apps when planning a renewal.
    private static let hostKey = "harbor.host"
    private static let renewedUntilKey = "HarborRenewedUntil"
    private static let renewedProfileKey = "HarborRenewedProfile"

    /// When this copy of Harbor stops opening: the profile it was installed
    /// with, unless this same install has been renewed since.
    private static func currentHarborExpiry() -> Date? {
        guard let profile = installedProfile() else { return nil }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: renewedProfileKey) == profile.uuid.uuidString,
           let renewed = defaults.object(forKey: renewedUntilKey) as? Date,
           renewed > profile.expirationDate {
            return renewed
        }
        return profile.expirationDate
    }

    // MARK: Shortcuts

    /// The link a shortcut opens to renew, reporting back to Shortcuts.
    static var renewalLink: String { "\(scheme)://x-callback-url/renew" }

    /// The shared "Renew Harbor" shortcut, when this build was given one
    /// (`HARBOR_SHORTCUT_ID` in CodeSigning.xcconfig).
    static let sharedShortcut: URL? = {
        guard
            let id = Bundle.main.object(forInfoDictionaryKey: "HarborShortcutID") as? String,
            id.count == 32, id.allSatisfy(\.isHexDigit)
        else { return nil }
        return URL(string: "https://www.icloud.com/shortcuts/\(id.lowercased())")
    }()

    static let shortcutName = "Renew Harbor"

    /// Turns the warnings ahead of Harbor's expiry on or off.
    func setExpiryReminders(_ wanted: Bool) async {
        guard let harborExpiry else { return }
        if wanted {
            do {
                guard try await ExpiryReminder.schedule(for: harborExpiry) else {
                    problem = Problem(
                        title: "Notifications are off",
                        detail: "Turn on notifications for Harbor in Settings, then try again.")
                    return
                }
            } catch {
                problem = Problem(error)
                return
            }
        } else {
            ExpiryReminder.cancel()
        }
        expiryReminders = wanted
        UserDefaults.standard.set(wanted, forKey: Self.expiryRemindersKey)
    }

    /// From iOS 26 the engine cannot load unsigned code even with a debugger
    /// attached, so a certificate is the only way.
    static var signedGuestsRequired: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26, *) { return true }
        return false
        #endif
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
        } catch is CancellationError {
            // The user stopped it; there is nothing to report.
        } catch {
            problem = Problem(error)
        }
    }

    private static func describe(_ step: InstallPipeline.Step) -> String {
        switch step {
        case .unpack: "Unpacking"
        case .registerDevice: "Registering iPhone"
        case .certificate: "Preparing certificate"
        case .profiles: "Getting profiles"
        case .sign: "Signing"
        case .install: "Installing"
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
