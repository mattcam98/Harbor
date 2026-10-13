import Foundation
import HarborCore
import SideSign
import Testing

@testable import HarborSigning

@Suite struct CapabilitySyncTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let paidTeam = Team(identifier: "PAIDTEAM01", name: "Paid Team", type: .individual)

    static let groups = Entitlement.appGroups.rawValue
    static let audio = Entitlement.interAppAudio.rawValue
    static let push = Entitlement.pushNotifications.rawValue

    /// An app built with app groups, inter-app audio and push.
    let app = SigningTarget(
        bundleIdentifier: "com.example.app",
        name: "Example",
        capabilities: [groups, audio, push, "get-task-allow"],
        appGroups: ["group.com.example.app", "group.com.example.shared", "group.com.example.app"]
    )

    func provision(
        _ targets: [SigningTarget],
        portal: FakePortal,
        team: Team = FakePortal.team,
        syncCapabilities: Bool = true
    ) async throws -> ProvisionedProfiles {
        try await ProfileProvisioner(portal: portal).provision(
            targets,
            isAlreadyActive: false,
            activeApps: 0,
            deviceType: .iPhone,
            team: team,
            session: FakePortal.session,
            syncCapabilities: syncCapabilities,
            now: Self.now
        )
    }

    @Test func switchesOnWhatAFreeTeamCanHaveAndReportsTheRest() async throws {
        let portal = FakePortal()

        let result = try await provision([app], portal: portal)

        #expect(portal.calls == [
            .fetchAppIDs,
            .addAppID(name: "Example", bundleIdentifier: "com.example.app.TESTTEAM01"),
            .updateAppID(
                bundleIdentifier: "com.example.app.TESTTEAM01",
                features: [Feature.appGroups.rawValue: "true", Feature.interAppAudio.rawValue: "true"]),
            .fetchAppGroups,
            .addAppGroup(
                name: "Harbor group com example app", identifier: "group.com.example.app.TESTTEAM01"),
            .addAppGroup(
                name: "Harbor group com example shared", identifier: "group.com.example.shared.TESTTEAM01"),
            .assignAppGroups(
                identifiers: ["group.com.example.app.TESTTEAM01", "group.com.example.shared.TESTTEAM01"],
                bundleIdentifier: "com.example.app.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01"),
        ])
        // Push needs a paid team; get-task-allow has no portal capability.
        #expect(result.unavailableCapabilities == [Self.push])
    }

    @Test func aPaidTeamGetsPushToo() async throws {
        let portal = FakePortal()

        let result = try await provision([app], portal: portal, team: Self.paidTeam)

        #expect(result.unavailableCapabilities.isEmpty)
        #expect(portal.calls.contains(.updateAppID(
            bundleIdentifier: "com.example.app.PAIDTEAM01",
            features: [
                Feature.appGroups.rawValue: "true",
                Feature.interAppAudio.rawValue: "true",
                Feature.pushNotifications.rawValue: "true",
            ])))
    }

    @Test func leavesAnAppIDAloneWhenItAlreadyHasEverything() async throws {
        let existing = AppID(
            identifier: "KEEP",
            name: "Example",
            bundleIdentifier: "com.example.app.TESTTEAM01",
            expirationDate: Self.now.addingTimeInterval(3600),
            features: [.appGroups: "true", .interAppAudio: "true"]
        )
        let group = AppGroup(name: "Existing", identifier: "group.com.example.app.TESTTEAM01", groupID: "G1")
        let shared = AppGroup(name: "Existing", identifier: "group.com.example.shared.TESTTEAM01", groupID: "G2")
        let portal = FakePortal(appIDs: [existing], appGroups: [group, shared])

        _ = try await provision([app], portal: portal)

        // No capability update and no new groups; the existing ones are assigned.
        #expect(portal.calls == [
            .fetchAppIDs,
            .fetchAppGroups,
            .assignAppGroups(
                identifiers: ["group.com.example.app.TESTTEAM01", "group.com.example.shared.TESTTEAM01"],
                bundleIdentifier: "com.example.app.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01"),
        ])
    }

    @Test func fetchesTheTeamsGroupsOnceForSeveralBundles() async throws {
        let widget = SigningTarget(
            bundleIdentifier: "com.example.app.widget",
            name: "Widget",
            capabilities: [Self.groups],
            appGroups: ["group.com.example.app"]
        )
        let portal = FakePortal()

        _ = try await provision([app, widget], portal: portal)

        #expect(portal.calls.filter { $0 == .fetchAppGroups }.count == 1)
        // The widget reuses the group the app just created.
        #expect(portal.calls.filter {
            if case .addAppGroup(_, "group.com.example.app.TESTTEAM01") = $0 { true } else { false }
        }.count == 1)
        #expect(portal.calls.contains(.assignAppGroups(
            identifiers: ["group.com.example.app.TESTTEAM01"],
            bundleIdentifier: "com.example.app.TESTTEAM01.widget")))
    }

    @Test func aRefreshChangesNoCapabilities() async throws {
        let portal = FakePortal()

        let result = try await provision([app], portal: portal, syncCapabilities: false)

        #expect(portal.calls == [
            .fetchAppIDs,
            .addAppID(name: "Example", bundleIdentifier: "com.example.app.TESTTEAM01"),
            .downloadProfile(bundleIdentifier: "com.example.app.TESTTEAM01"),
        ])
        #expect(result.unavailableCapabilities.isEmpty)
    }

    @Test func groupsAreOnlyRequestedWhenTheGroupCapabilityIsOn() {
        let target = SigningTarget(
            bundleIdentifier: "a.b", name: "A", capabilities: [Self.audio], appGroups: ["group.a.b"])

        let plan = ProfileProvisioner.capabilityPlan(for: target, team: FakePortal.team)

        #expect(plan == ProfileProvisioner.CapabilityPlan(
            features: [.interAppAudio: "true"], appGroups: [], unavailable: []))
    }

    @Test func anUnknownTeamTypeIsPlannedAsFree() {
        let unknown = Team(identifier: "X", name: "X", type: .unknown)
        let target = SigningTarget(bundleIdentifier: "a.b", name: "A", capabilities: [Self.push, Self.audio])

        let plan = ProfileProvisioner.capabilityPlan(for: target, team: unknown)

        #expect(plan.features == [.interAppAudio: "true"])
        #expect(plan.unavailable == [Self.push])
    }

    @Test func readsWhichEntitlementsAreSwitchedOn() {
        let enabled = AppSigner.enabledEntitlements(in: [
            "on": true,
            "off": false,
            "list": ["a"],
            "empty-list": [String](),
            "text": "development",
        ])
        #expect(enabled == ["on", "list", "text"])
    }
}
