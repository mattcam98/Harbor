import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct HostRenewalTests {
    let team = FakePortal.team
    let expiry = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 0)

    /// Harbor as Harbor Setup installs it: every identifier under the
    /// team's suffix.
    static let installed: [InstalledApp.Target] = [
        .init(bundleIdentifier: "me.mattcam.harbor.TESTTEAM01", name: "Harbor"),
        .init(bundleIdentifier: "me.mattcam.harbor.TESTTEAM01.LiveProcess", name: "LiveProcess"),
    ]

    @Test func recoversTheIdentifiersAsShipped() throws {
        let record = try HostRenewal.record(
            installed: Self.installed, version: "1.0", team: team, expiry: expiry, now: now)

        #expect(record.id == "me.mattcam.harbor")
        #expect(record.installedBundleIdentifier == "me.mattcam.harbor.TESTTEAM01")
        #expect(record.targets.map(\.bundleIdentifier) == ["me.mattcam.harbor", "me.mattcam.harbor.LiveProcess"])
        #expect(record.isHost)
        #expect(record.expiry == expiry)
    }

    /// The App IDs a refresh will ask Apple for are the ones Setup registered.
    @Test func mapsBackToTheRegisteredIdentifiers() throws {
        let record = try HostRenewal.record(
            installed: Self.installed, version: "1.0", team: team, expiry: expiry, now: now)

        let registered = record.targets.map {
            ProfileProvisioner.registeredIdentifier(for: $0.bundleIdentifier, inApp: record.id, team: team)
        }
        #expect(registered == Self.installed.map(\.bundleIdentifier))
    }

    @Test func refusesACopyInstalledByXcode() {
        let xcode: [InstalledApp.Target] = [
            .init(bundleIdentifier: "me.mattcam.harbor", name: "Harbor"),
            .init(bundleIdentifier: "me.mattcam.harbor.LiveProcess", name: "LiveProcess"),
        ]
        #expect(throws: HostRenewal.Failure.installedForAnotherTeam) {
            try HostRenewal.record(installed: xcode, version: "1.0", team: team, expiry: expiry, now: now)
        }
    }

    @Test func refusesACopyInstalledForAnotherTeam() {
        let other = Team(identifier: "OTHERTEAM9", name: "Other", type: .free)
        #expect(throws: HostRenewal.Failure.installedForAnotherTeam) {
            try HostRenewal.record(installed: Self.installed, version: "1.0", team: other, expiry: expiry, now: now)
        }
    }

    @Test func refusesAnExtensionNotNamedAfterTheApp() {
        let stray = [Self.installed[0], .init(bundleIdentifier: "com.other.widget", name: "Widget")]
        #expect(throws: HostRenewal.Failure.installedForAnotherTeam) {
            try HostRenewal.record(installed: stray, version: "1.0", team: team, expiry: expiry, now: now)
        }
    }
}
