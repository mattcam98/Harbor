import Foundation
import HarborCore
import HarborDevice
import Observation
import UIKit
@preconcurrency import UserNotifications

/// Pairs this iPhone with Harbor itself, on iOS 27 and later, so no
/// computer is needed for a pairing record.
///
/// Harbor advertises itself on the local network; the user picks it under
/// Settings › Privacy & Security › Developer Mode and types the PIN Harbor
/// shows. The record that exchange makes replaces any stored one.
@MainActor
@Observable
final class PhonePairing {
    enum Phase: Equatable {
        case idle
        /// Asking for notifications and publishing the service.
        case starting
        /// "Pair with Harbor" can be tapped in Settings now.
        case waitingForSettings
        /// The device asked for the PIN; it is in `pin`.
        case showingPIN
        case paired
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var pin: String?
    /// After Stop, the engine keeps waiting for the device until Harbor
    /// quits, and a second attempt would trip over the first. So Start
    /// stays off until Harbor is opened again.
    private(set) var needsRelaunch = false

    /// Whether this iOS can do it at all.
    static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SelfPairing.isSupported(systemVersion: (version.majorVersion, version.minorVersion))
    }

    var isRunning: Bool {
        [.starting, .waitingForSettings, .showingPIN].contains(phase)
    }

    /// Called on the main actor once a new record is stored.
    @ObservationIgnored var onPaired: () -> Void = {}

    private let secrets: any SecretStore
    private let host: SelfPairingHost
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var pairing: Task<Void, Never>?
    /// Counts attempts, so anything a stopped one reports late is ignored.
    private var attempt = 0

    private static let pinNotification = "harbor.pairing.pin"

    init(secrets: any SecretStore) {
        self.secrets = secrets
        host = SelfPairingHost(
            workDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("harbor-pairing", isDirectory: true))
    }

    /// Advertises Harbor, waits for the pairing started in Settings, and
    /// stores the record it makes.
    func start() {
        guard !isRunning, !needsRelaunch else { return }
        pin = nil
        phase = .starting
        attempt += 1
        let current = attempt

        pairing = Task {
            // The PIN is shown in a notification, since the user is in
            // Settings when it arrives.
            _ = await Notices.requestPermission()
            keepRunningInBackground()
            defer { if current == attempt { endBackgroundTime() } }
            do {
                let paired = try await host.pair(
                    onAdvertising: { _ in
                        guard current == self.attempt, self.phase == .starting else { return }
                        self.phase = .waitingForSettings
                    },
                    onPin: { pin in
                        guard current == self.attempt else { return }
                        self.pin = pin
                        self.phase = .showingPIN
                        Notices.post(
                            title: "Pairing code: \(pin)",
                            body: "Enter it on the Pair with \(SelfPairing.hostName) screen.",
                            identifier: Self.pinNotification)
                    }
                )
                guard current == attempt else { return }  // stopped
                try secrets.write(paired.propertyList, for: .pairingRecord)
                pin = nil
                phase = .paired
                onPaired()
            } catch {
                guard current == attempt else { return }  // stopped
                phase = .failed(Problem(error).detail)
            }
            Notices.remove(Self.pinNotification)
        }
    }

    /// Back to the start after a pairing finished or failed, so the screen
    /// offers Start again.
    func reset() {
        guard !isRunning else { return }
        phase = .idle
        pin = nil
    }

    /// Stops advertising. Nothing stored is touched.
    func stop() {
        guard isRunning else { return }
        attempt += 1
        needsRelaunch = true
        phase = .idle
        host.stop()
        pairing?.cancel()
        pairing = nil
        pin = nil
        Notices.remove(Self.pinNotification)
        endBackgroundTime()
    }

    /// The PIN arrives while the user is in Settings, so Harbor has to keep
    /// running then. A background task gives it about half a minute.
    private func keepRunningInBackground() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Pairing") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
