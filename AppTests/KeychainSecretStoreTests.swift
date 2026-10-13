import Foundation
import HarborCore
import HarborPlatform
import Security
import Testing

/// Runs inside the app on a simulator or device: the keychain needs a signed
/// host, which a bare package test bundle does not have.
@Suite(.serialized) struct KeychainSecretStoreTests {
    let store = KeychainSecretStore(
        configuration: .init(service: "harbor.tests.\(UUID().uuidString)", hostOnlyAccessGroup: nil)
    )

    private func cleanUp() {
        try? store.deleteAll()
    }

    @Test func roundTripsAndOverwrites() throws {
        defer { cleanUp() }

        #expect(try store.read(.appleSessionToken) == nil)

        try store.write(Redacted(Data("first".utf8)), for: .appleSessionToken)
        #expect(try store.read(.appleSessionToken)?.expose() == Data("first".utf8))

        try store.write(Redacted(Data("second".utf8)), for: .appleSessionToken)
        #expect(try store.read(.appleSessionToken)?.expose() == Data("second".utf8))
    }

    @Test func keysAreIndependent() throws {
        defer { cleanUp() }

        try store.write(Redacted(Data("token".utf8)), for: .appleSessionToken)
        try store.write(Redacted(Data("pairing".utf8)), for: .pairingRecord)

        try store.delete(.appleSessionToken)
        #expect(try store.read(.appleSessionToken) == nil)
        #expect(try store.read(.pairingRecord)?.expose() == Data("pairing".utf8))
    }

    @Test func deletingAMissingItemIsNotAnError() throws {
        try store.delete(.signingPrivateKey)
        try store.delete(.signingPrivateKey)
    }

    @Test func refusesThePasswordWithoutOptIn() throws {
        defer { cleanUp() }

        #expect(throws: SecretStoreError.optInRequired(.applePassword)) {
            try store.write(Redacted(Data("password".utf8)), for: .applePassword)
        }
        #expect(try store.read(.applePassword) == nil)
    }

    @Test func itemsStayOnThisDeviceAndNeverSync() throws {
        defer { cleanUp() }
        try store.write(Redacted(Data("identity".utf8)), for: .signingPrivateKey)

        // Look the item up without constraining sync, so a synchronizable
        // item would be found too, then check what was actually stored.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.configuration.service,
            kSecAttrAccount as String: SecretKey.signingPrivateKey.rawValue,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)

        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    }
}
