import Foundation
import Testing

@testable import HarborCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600
private let day: TimeInterval = 24 * 3600

private func app(_ id: String, expiresIn interval: TimeInterval, isHost: Bool = false) -> SignedApp {
    SignedApp(bundleIdentifier: id, name: id, expiry: now.addingTimeInterval(interval), isHost: isHost)
}

@Suite struct RefreshPlannerTests {
    let planner = RefreshPlanner()

    @Test func refreshesWhatIsWithinTheLeadTime() {
        let plan = planner.plan(
            apps: [app("c", expiresIn: 5 * day), app("a", expiresIn: day), app("b", expiresIn: -hour)],
            now: now
        )
        #expect(plan.due.map(\.bundleIdentifier) == ["b", "a"])
        #expect(plan.expired.map(\.bundleIdentifier) == ["b"])
        #expect(plan.nextCheck == now.addingTimeInterval(3 * day))
    }

    @Test func refreshesTheHostFirst() {
        let plan = planner.plan(
            apps: [app("a", expiresIn: hour), app("host", expiresIn: day, isHost: true)],
            now: now
        )
        #expect(plan.due.map(\.bundleIdentifier) == ["host", "a"])
    }

    @Test func nothingDueMeansOnlyANextCheck() {
        let plan = planner.plan(apps: [app("a", expiresIn: 6 * day), app("b", expiresIn: 4 * day)], now: now)
        #expect(plan.due.isEmpty)
        #expect(plan.expired.isEmpty)
        #expect(plan.nextCheck == now.addingTimeInterval(2 * day))
    }

    @Test func noAppsMeansAnEmptyPlan() {
        let plan = planner.plan(apps: [], now: now)
        #expect(plan == RefreshPlan(due: [], expired: [], nextCheck: nil, reminders: []))
    }

    @Test func theLeadTimeBoundaryIsDue() {
        let plan = planner.plan(apps: [app("a", expiresIn: 2 * day)], now: now)
        #expect(plan.due.count == 1)
        #expect(plan.nextCheck == nil)
    }

    @Test func schedulesOnlyFutureReminders() {
        let plan = planner.plan(apps: [app("a", expiresIn: day)], now: now)
        // 48 h and 24 h before expiry are not in the future; 2 h before is.
        #expect(plan.reminders == [
            ExpiryReminder(
                identifier: "expiry.a.7200",
                bundleIdentifier: "a",
                fireDate: now.addingTimeInterval(22 * hour),
                timeBeforeExpiry: 2 * hour
            )
        ])
    }

    @Test func remindersAreOrderedAndStable() {
        let apps = [app("b", expiresIn: 7 * day), app("a", expiresIn: 7 * day)]
        let first = planner.plan(apps: apps, now: now)
        let second = planner.plan(apps: apps.reversed(), now: now)

        #expect(first == second)
        #expect(first.reminders.count == 6)
        #expect(first.reminders.map(\.fireDate) == first.reminders.map(\.fireDate).sorted())
        #expect(first.reminders.first?.identifier == "expiry.a.172800")
    }
}

@Suite struct AccountLimitsTests {
    func registered(_ count: Int, expiringFrom start: TimeInterval = day) -> [RegisteredAppID] {
        (0..<count).map {
            RegisteredAppID(
                bundleIdentifier: "existing.\($0)",
                expiry: now.addingTimeInterval(start + Double($0) * hour)
            )
        }
    }

    @Test func blocksAFourthActiveApp() {
        let result = AccountLimits.free.evaluate(
            InstallRequest(bundleIdentifiers: ["new.app"], isAlreadyActive: false),
            registered: [], activeApps: 3, now: now
        )
        #expect(result == .blockedByActiveAppLimit(active: 3, limit: 3))
    }

    @Test func reinstallingAnActiveAppIsNotAFourthApp() {
        let result = AccountLimits.free.evaluate(
            InstallRequest(bundleIdentifiers: ["existing.0"], isAlreadyActive: true),
            registered: registered(1), activeApps: 3, now: now
        )
        #expect(result == .allowed(newAppIDs: 0, appIDsRemainingAfter: 9))
    }

    @Test func countsEveryExtensionAsAnAppID() {
        let result = AccountLimits.free.evaluate(
            InstallRequest(
                bundleIdentifiers: ["new.app", "new.app.widget", "new.app.share"],
                isAlreadyActive: false
            ),
            registered: registered(6), activeApps: 1, now: now
        )
        #expect(result == .allowed(newAppIDs: 3, appIDsRemainingAfter: 1))
    }

    @Test func blocksWhenAppIDsRunOutAndSaysWhenASlotOpens() {
        let result = AccountLimits.free.evaluate(
            InstallRequest(bundleIdentifiers: ["n.1", "n.2", "n.3", "n.4"], isAlreadyActive: false),
            registered: registered(8), activeApps: 1, now: now
        )
        // 2 slots free, 4 needed: wait for the 2 soonest-expiring App IDs.
        #expect(result == .blockedByAppIDLimit(
            needed: 4, available: 2, nextSlot: now.addingTimeInterval(day + hour)))
    }

    @Test func expiredAppIDsFreeTheirSlotButMustBeRecreated() {
        let expired = RegisteredAppID(bundleIdentifier: "new.app", expiry: now.addingTimeInterval(-hour))
        let result = AccountLimits.free.evaluate(
            InstallRequest(bundleIdentifiers: ["new.app"], isAlreadyActive: false),
            registered: registered(9) + [expired], activeApps: 0, now: now
        )
        #expect(result == .allowed(newAppIDs: 1, appIDsRemainingAfter: 0))
    }

    @Test func repeatedIdentifiersCountOnce() {
        let result = AccountLimits.free.evaluate(
            InstallRequest(bundleIdentifiers: ["new.app", "new.app"], isAlreadyActive: false),
            registered: [], activeApps: 0, now: now
        )
        #expect(result == .allowed(newAppIDs: 1, appIDsRemainingAfter: 9))
    }

    @Test func paidAccountsAreUnlimited() {
        let ids = (0..<50).map { RegisteredAppID(bundleIdentifier: "existing.\($0)", expiry: nil) }
        let result = AccountLimits.paid.evaluate(
            InstallRequest(bundleIdentifiers: ["new.app"], isAlreadyActive: false),
            registered: ids, activeApps: 40, now: now
        )
        #expect(result == .allowed(newAppIDs: 1, appIDsRemainingAfter: nil))
    }
}
