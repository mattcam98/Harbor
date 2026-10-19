#if HARBOR_SELF_PAIRING
import Foundation
import HarborCore
import HarborDevice
import Observation
import UIKit
@preconcurrency import UserNotifications

/// The device spike for pairing with no computer (docs/ARCHITECTURE.md,
/// section 9, Q1): this iPhone pairs with Harbor itself, and Harbor then
/// installs a provisioning profile through LocalDevVPN with that record.
///
/// Compiled only with `HARBOR_SELF_PAIRING` (Debug builds, or an IPA built
/// with `HARBOR_SELF_PAIRING=1 bash scripts/check.sh ipa`), and offered only
/// on iOS 27 and later. Without both, Harbor Setup remains the only way a
/// record arrives. docs/DEVICE-TEST.md, Test 6, is how it is run.
@MainActor
@Observable
final class SelfPairingSpike {
    enum Phase: Equatable {
        case idle
        /// Asking for notifications and publishing the service.
        case starting
        /// "Pair with Harbor" can be tapped in Settings now.
        case advertising
        /// The device asked for the PIN; it is in `pin`.
        case waitingForPIN
        case paired
        case proving
        /// The proof installed the profile.
        case proved
        case failed
    }

    struct Step: Identifiable, Equatable {
        enum Outcome: Equatable {
            case passed
            case failed
            case note
        }

        let id = UUID()
        /// Seconds since Start was tapped.
        let at: TimeInterval
        let outcome: Outcome
        let text: String
    }

    private(set) var phase = Phase.idle
    private(set) var pin: String?
    private(set) var steps: [Step] = []

    /// Whether this iOS can do it at all.
    static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SelfPairing.isSupported(systemVersion: (version.majorVersion, version.minorVersion))
    }

    var isRunning: Bool {
        [.starting, .advertising, .waitingForPIN, .proving].contains(phase)
    }

    /// Whether a record made here is the one stored now.
    var storedRecordIsSelfMade: Bool {
        UserDefaults.standard.object(forKey: Self.pairedAtKey) != nil
    }

    private let secrets: any SecretStore
    private let transport: any DeviceTransport
    private let host: SelfPairingHost
    /// Tells the rest of Harbor the stored record changed.
    @ObservationIgnored var onRecordChanged: (AppModel.PairingState) -> Void = { _ in }
    private var startedAt = Date()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var pairing: Task<Void, Never>?

    private static let pairedAtKey = "HarborSelfPairedAt"
    private static let pinNotification = "harbor.selfpairing.pin"

    init(secrets: any SecretStore, transport: any DeviceTransport) {
        self.secrets = secrets
        self.transport = transport
        host = SelfPairingHost(
            workDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("harbor-self-pairing", isDirectory: true))
    }

    // MARK: Pairing

    /// Advertises Harbor, waits for the pairing started in Settings, and
    /// stores the record it makes in place of any stored one.
    func start() {
        guard !isRunning else { return }
        steps = []
        pin = nil
        startedAt = Date()
        phase = .starting
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        note("iOS \(version), \(UIDevice.current.model)")

        pairing = Task {
            await askForNotifications()
            keepRunningInBackground()
            defer { endBackgroundTime() }
            do {
                let paired = try await host.pair(
                    onAdvertising: { name in
                        guard self.phase == .starting else { return }
                        self.phase = .advertising
                        self.log(.passed, "Advertising \(SelfPairing.serviceType) as “\(name)”")
                    },
                    onPin: { pin in
                        self.show(pin: pin)
                    }
                )
                try store(paired)
            } catch {
                guard phase != .idle else { return }  // stopped by the user
                phase = .failed
                log(.failed, "Pairing failed: \(Self.describe(error))")
            }
            removePINNotification()
        }
    }

    /// Stops advertising. Nothing stored is touched.
    func stop() {
        guard [.starting, .advertising, .waitingForPIN].contains(phase) else { return }
        phase = .idle
        host.stop()
        pairing?.cancel()
        pairing = nil
        pin = nil
        removePINNotification()
        endBackgroundTime()
        note("Stopped by the user; advertising ended")
    }

    private func show(pin: String) {
        self.pin = pin
        phase = .waitingForPIN
        let state = UIApplication.shared.applicationState == .active ? "in front" : "in the background"
        log(.passed, "The device asked for a PIN (Harbor was \(state))")
        postPINNotification(pin)
    }

    private func store(_ paired: SelfPairingHost.Paired) throws {
        let keys = SelfPairing.keyNames(of: paired.propertyList.expose())
        log(.passed, "Pairing finished with \(paired.deviceModel). Record keys: \(keys.joined(separator: ", "))")
        try secrets.write(paired.propertyList, for: .pairingRecord)
        UserDefaults.standard.set(Date(), forKey: Self.pairedAtKey)
        pin = nil
        phase = .paired
        log(.passed, "Stored in the keychain as this device's pairing record")
        onRecordChanged(.stored)
    }

    // MARK: Proof

    /// Connects with the stored record through LocalDevVPN and installs this
    /// copy of Harbor's own provisioning profile again: the smallest install
    /// that proves the record works end to end. It changes nothing on the
    /// phone, since that profile is already installed.
    func prove() async {
        guard !isRunning else { return }
        phase = .proving
        if steps.isEmpty { startedAt = Date() }
        note("Proof started")
        defer { if phase == .proving { phase = .idle } }

        let record: PairingRecord
        do {
            guard let stored = try secrets.read(.pairingRecord) else {
                throw DeviceIssue.pairingMissing
            }
            record = try PairingRecord(propertyList: stored.expose())
            let source = storedRecordIsSelfMade ? "made on this iPhone" : "not made on this iPhone"
            self.log(.passed, "Loaded the stored record (\(record), \(source))")
        } catch {
            fail("Loading the record", error)
            return
        }

        do {
            try await transport.connect(using: record)
            self.log(.passed, "Loaded into minimuxer for RemotePairing over LocalDevVPN")
        } catch {
            fail("Connecting", error)
            return
        }

        if let profile = Self.harborsOwnProfile() {
            do {
                // The first service call is what opens the RemotePairing tunnel.
                try await transport.installProfile(profile)
                phase = .proved
                self.log(.passed, "Installed Harbor's own provisioning profile (\(profile.count) bytes) through the tunnel")
            } catch {
                fail("Installing the profile", error)
            }
        } else {
            self.log(.failed, "This copy of Harbor has no embedded.mobileprovision to install")
        }

        // Harbor's usual check after connecting. Lockdown is closed on iOS 27
        // by most reports, so a failure here alone does not fail the spike.
        do {
            let identifier = try await transport.deviceIdentifier()
            self.log(.passed, "Read the device identifier (…\(identifier.suffix(6)))")
            onRecordChanged(.connected(deviceIdentifier: identifier))
        } catch {
            self.log(.failed, "Reading the device identifier: \(Self.describe(error))")
        }
    }

    private func fail(_ what: String, _ error: any Error) {
        phase = .failed
        log(.failed, "\(what): \(Self.describe(error))")
    }

    // MARK: Report

    /// What to send back from the device test. It has no PIN, key or full
    /// device identifier in it.
    var report: String {
        steps.map { step in
            let mark = switch step.outcome {
            case .passed: "ok  "
            case .failed: "FAIL"
            case .note: "    "
            }
            return String(format: "+%5.1fs ", step.at) + "\(mark) \(step.text)"
        }
        .joined(separator: "\n")
    }

    private func log(_ outcome: Step.Outcome, _ text: String) {
        steps.append(Step(at: Date().timeIntervalSince(startedAt), outcome: outcome, text: text))
    }

    private func note(_ text: String) {
        log(.note, text)
    }

    private static func describe(_ error: any Error) -> String {
        "\(error)"
    }

    private static func harborsOwnProfile() -> Data? {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: Staying alive while the user is in Settings

    /// The PIN arrives while the user is in Settings, so Harbor has to be
    /// running then. A background task gives it about half a minute; that is
    /// the spike's whole keep-alive, and the test measures whether it is
    /// enough.
    private func keepRunningInBackground() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Self-pairing") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.note("iOS ended Harbor's background time")
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func askForNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        if !granted {
            note("Notifications are off: the PIN shows only inside Harbor")
        }
    }

    private func postPINNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing PIN"
        content.body = "Type \(pin) on the Pair with \(SelfPairing.hostName) screen."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.pinNotification, content: content, trigger: nil))
    }

    private func removePINNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pinNotification])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pinNotification])
    }
}
#endif
