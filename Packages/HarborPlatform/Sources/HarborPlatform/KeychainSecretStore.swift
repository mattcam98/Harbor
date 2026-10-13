#if canImport(Security)
import Foundation
import HarborCore
import Security

public struct KeychainError: Error, Equatable, Sendable {
    public enum Operation: String, Sendable {
        case read, write, delete
    }

    public let operation: Operation
    public let status: OSStatus
}

/// Keychain-backed `SecretStore`.
///
/// Every item is a generic password that is
/// - never synchronizable, so it does not reach iCloud Keychain;
/// - `AfterFirstUnlockThisDeviceOnly`, so a background refresh can read it
///   while the device is locked, and it is excluded from backups to other
///   devices;
/// - in `hostOnlyAccessGroup` when one is configured. The extensions that run
///   guest apps must not list that group in their entitlements.
public struct KeychainSecretStore: SecretStore {
    public struct Configuration: Equatable, Sendable {
        public var service: String
        /// A keychain access group present only in the main app's
        /// entitlements. `nil` uses the app's default group, which is only
        /// acceptable where no guest code runs (tests, previews).
        public var hostOnlyAccessGroup: String?

        public init(service: String = "harbor.secrets", hostOnlyAccessGroup: String?) {
            self.service = service
            self.hostOnlyAccessGroup = hostOnlyAccessGroup
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func read(_ key: SecretKey) throws -> Redacted<Data>? {
        var query = itemQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError(operation: .read, status: errSecDecode)
            }
            return Redacted(data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(operation: .read, status: status)
        }
    }

    public func write(_ value: Redacted<Data>, for key: SecretKey, optedIn: Bool) throws {
        try checkWriteAllowed(key, optedIn: optedIn)

        let query = itemQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: value.expose(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(operation: .write, status: status)
        }
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(itemQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: .delete, status: status)
        }
    }

    private func itemQuery(for key: SecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group = configuration.hostOnlyAccessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
#endif
