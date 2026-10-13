import Foundation
import Testing

@testable import HarborCore

@Suite struct RedactedTests {
    let secret = Redacted("hunter2")

    @Test func neverPrintsItsValue() {
        var dumped = ""
        dump(secret, to: &dumped)

        let renderings = ["\(secret)", String(describing: secret), String(reflecting: secret), dumped]
        for rendering in renderings {
            #expect(!rendering.contains("hunter2"))
        }
    }

    @Test func staysHiddenInsideOtherValues() {
        struct Account { let email: String; let password: Redacted<String> }
        var dumped = ""
        dump(Account(email: "a@example.com", password: secret), to: &dumped)

        #expect(dumped.contains("a@example.com"))
        #expect(!dumped.contains("hunter2"))
    }

    @Test func exposesOnRequest() {
        #expect(secret.expose() == "hunter2")
    }
}

@Suite struct SecretPolicyTests {
    @Test func everySecretIsHostOnlyAndNeverSyncs() {
        for key in SecretKey.allCases {
            #expect(key.policy.audience == .hostOnly)
            #expect(key.policy.synchronizable == false)
            #expect(key.policy.deviceOnly)
        }
    }

    @Test func onlyThePasswordNeedsOptIn() {
        let optIn = SecretKey.allCases.filter(\.policy.requiresOptIn)
        #expect(optIn == [.applePassword])
    }
}

@Suite struct InMemorySecretStoreTests {
    let store = InMemorySecretStore()
    let value = Redacted(Data("token".utf8))

    @Test func roundTrips() throws {
        try store.write(value, for: .appleSessionToken)
        #expect(try store.read(.appleSessionToken)?.expose() == Data("token".utf8))
        #expect(try store.read(.pairingRecord) == nil)
    }

    @Test func refusesThePasswordWithoutOptIn() throws {
        #expect(throws: SecretStoreError.optInRequired(.applePassword)) {
            try store.write(value, for: .applePassword)
        }
        #expect(try store.read(.applePassword) == nil)

        try store.write(value, for: .applePassword, optedIn: true)
        #expect(try store.read(.applePassword) != nil)
    }

    @Test func deleteAllRemovesEverything() throws {
        for key in SecretKey.allCases {
            try store.write(value, for: key, optedIn: true)
        }
        try store.deleteAll()
        for key in SecretKey.allCases {
            #expect(try store.read(key) == nil)
        }
    }
}
