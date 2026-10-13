import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct ProfileProvisionerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 3600
    static let paidTeam = Team(identifier: "PAIDTEAM01", name: "Paid Team", type: .individual)

    let app = SigningTarget(bundleIdentifier: "com.example.app", name: "Example")
    let widget = SigningTarget(bundleIdentifier: "com.example.app.widget", name: "Example Widget")

    static func registered(_ count: Int) -> [AppID] {
        (0..<count).map {
            AppID(
                identifier: "OLD\($0)",
                name: "Old \($0)",
                bundleIdentifier: "com.old.app\($0).TESTTEAM01",
                expirationDate: now.addingTimeInterval(day + Double($0) * 3600)
            )
        }
    }

    func provision(
        _ targets: [SigningTarget],
        portal: FakePortal,
        isAlreadyActive: Bool = false,
        activeApps: Int = 0,
        team: Team = FakePortal.team
    ) async throws -> [String: ProvisioningProfile] {
        try await ProfileProvisioner(portal: portal).provision(
            targets,
            isAlreadyActive: isAlreadyActive,
            activeApps: activeApps,
            deviceType: .iPhone,
            team: team,
            session: FakePortal.session,
            now: Self.now
        ).profiles
    }

    @Test func registersAnAppIDPerBundleAndFetchesItsProfile() async throws {
        let portal = FakePortal()

        let profiles = try await provision([app, widget], portal: portal)

        #expect(portal.calls == [
            .fetchAppIDs,
            .addAppID(name: "Example", bundleIdentifier: "com.example.app.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01"),
            // The extension's identifier starts with the app's, team included.
            .addAppID(name: "Example Widget", bundleIdentifier: "com.example.app.TESTTEAM01.widget"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01.widget"),
        ])
        #expect(Set(profiles.keys) == ["com.example.app", "com.example.app.widget"])
        #expect(profiles["com.example.app"]?.bundleIdentifier == "com.example.app.TESTTEAM01")
    }

    @Test func reusesAnAppIDThatAlreadyExistsIgnoringCase() async throws {
        let existing = AppID(
            identifier: "KEEP",
            name: "Example",
            bundleIdentifier: "COM.Example.App.TESTTEAM01",
            expirationDate: Self.now.addingTimeInterval(Self.day)
        )
        let portal = FakePortal(appIDs: [existing])

        _ = try await provision([app], portal: portal)

        #expect(portal.calls == [
            .fetchAppIDs,
            .downloadProfile(bundleIdentifier: "COM.Example.App.TESTTEAM01"),
        ])
    }

    @Test func refusesBeforeCreatingAnythingWhenAppIDsWouldRunOut() async throws {
        // 9 of 10 App IDs are in use; the app and its widget need 2.
        let portal = FakePortal(appIDs: Self.registered(9))

        await #expect(throws: ProvisioningError.blocked(
            .blockedByAppIDLimit(needed: 2, available: 1, nextSlot: Self.now.addingTimeInterval(Self.day))
        )) {
            try await provision([app, widget], portal: portal)
        }
        #expect(portal.calls == [.fetchAppIDs])
    }

    @Test func refusesAFourthActiveAppOnAFreeTeam() async throws {
        let portal = FakePortal()

        await #expect(throws: ProvisioningError.blocked(.blockedByActiveAppLimit(active: 3, limit: 3))) {
            try await provision([app], portal: portal, activeApps: 3)
        }
        #expect(portal.calls == [.fetchAppIDs])
    }

    @Test func refreshingAnActiveAppIsAllowedAtTheLimit() async throws {
        let existing = AppID(
            identifier: "KEEP",
            name: "Example",
            bundleIdentifier: "com.example.app.TESTTEAM01",
            expirationDate: Self.now.addingTimeInterval(Self.day)
        )
        let portal = FakePortal(appIDs: Self.registered(9) + [existing])

        let profiles = try await provision([app], portal: portal, isAlreadyActive: true, activeApps: 3)

        #expect(profiles.count == 1)
        #expect(!portal.calls.contains { if case .addAppID = $0 { true } else { false } })
    }

    @Test func paidTeamsHaveNoLimits() async throws {
        let ids = (0..<30).map {
            AppID(identifier: "P\($0)", name: "P\($0)", bundleIdentifier: "com.paid.app\($0).PAIDTEAM01")
        }
        let portal = FakePortal(appIDs: ids)

        let profiles = try await provision([app], portal: portal, activeApps: 20, team: Self.paidTeam)

        #expect(profiles["com.example.app"]?.bundleIdentifier == "com.example.app.PAIDTEAM01")
    }

    @Test func anUnknownTeamTypeGetsTheStricterLimits() {
        let unknown = Team(identifier: "X", name: "X", type: .unknown)
        #expect(ProfileProvisioner.limits(for: unknown) == .free)
        #expect(ProfileProvisioner.limits(for: FakePortal.team) == .free)
        #expect(ProfileProvisioner.limits(for: Self.paidTeam) == .paid)
    }

    @Test(arguments: [
        ("Example", "Example"),
        ("My  App: Pro!", "My App Pro"),
        ("Café Zürich", "Cafe Zurich"),
        ("★★★", "com example app"),
        (String(repeating: "A", count: 80), String(repeating: "A", count: 50)),
    ])
    func sanitisesAppIDNames(_ name: String, _ expected: String) {
        let target = SigningTarget(bundleIdentifier: "com.example.app", name: name)
        #expect(ProfileProvisioner.appIDName(for: target) == expected)
    }

    // MARK: Identifiers iOS will install

    /// iOS refuses an extension whose identifier does not start with its
    /// app's ("does not match required prefix ... for parent"). Found on the
    /// first real install, 13 October 2026.
    @Test func anExtensionsIdentifierStartsWithItsAppsRegisteredIdentifier() {
        let team = Self.freeTeam
        let app = ProfileProvisioner.registeredIdentifier(for: "me.example.harbor", inApp: "me.example.harbor", team: team)
        let inside = ProfileProvisioner.registeredIdentifier(
            for: "me.example.harbor.LiveProcess", inApp: "me.example.harbor", team: team)

        #expect(app == "me.example.harbor.TESTTEAM01")
        #expect(inside == "me.example.harbor.TESTTEAM01.LiveProcess")
        #expect(inside.hasPrefix(app + "."))
    }

    @Test func anExtensionNestedDeeperKeepsItsWholeOwnPart() {
        #expect(ProfileProvisioner.registeredIdentifier(
            for: "com.example.app.share.intents", inApp: "com.example.app", team: Self.freeTeam)
            == "com.example.app.TESTTEAM01.share.intents")
    }

    @Test func anExtensionNotNamedAfterItsAppIsRenamedUnderIt() {
        let inside = ProfileProvisioner.registeredIdentifier(
            for: "org.other.widget", inApp: "com.example.app", team: Self.freeTeam)
        #expect(inside == "com.example.app.TESTTEAM01.widget")
    }

    @Test func theCaseOfTheShippedIdentifierIsKept() {
        #expect(ProfileProvisioner.registeredIdentifier(
            for: "COM.Example.App.Widget", inApp: "com.example.app", team: Self.freeTeam)
            == "com.example.app.TESTTEAM01.Widget")
    }

    @Test func anAppOnItsOwnIsNamedAsBefore() {
        #expect(ProfileProvisioner.registeredIdentifier(for: "com.example.app", team: Self.freeTeam)
            == "com.example.app.TESTTEAM01")
    }
}
