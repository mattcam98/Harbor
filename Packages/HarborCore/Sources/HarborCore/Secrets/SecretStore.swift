import Foundation

/// Every secret Harbor persists. There is no free-form key: adding a secret
/// means adding a case here and deciding its policy.
public enum SecretKey: String, CaseIterable, Sendable {
    /// The signed-in account, team and the session token used to rebuild a
    /// developer session without the password.
    case appleSessionToken
    /// The Apple ID password. Only written when the user opts in to unattended
    /// re-login; see `SecretPolicy.requiresOptIn`.
    case applePassword
    /// The signing certificate (DER). Public, but kept with its key so the
    /// two cannot drift apart.
    case signingCertificate
    /// The signing certificate's private key. Generated on the device and
    /// never exported.
    case signingPrivateKey
    /// Device pairing record (lockdown and/or RemotePairing credentials).
    case pairingRecord
    /// Anisette provisioning state.
    case anisetteState
    /// The machine an anisette server provisioned for Harbor, and which
    /// server it lives on.
    case serverAnisetteState
}

/// Which processes may read a secret.
public enum SecretAudience: Sendable {
    /// The main app only. Stored in a keychain access group that the
    /// extensions hosting guest apps do not have in their entitlements.
    case hostOnly
}

public struct SecretPolicy: Equatable, Sendable {
    public var audience: SecretAudience
    /// The secret may only be stored after an explicit user choice.
    public var requiresOptIn: Bool

    /// Secrets never leave the device and never sync. This is not configurable.
    public let synchronizable = false
    public let deviceOnly = true
}

extension SecretKey {
    public var policy: SecretPolicy {
        switch self {
        case .applePassword:
            SecretPolicy(audience: .hostOnly, requiresOptIn: true)
        case .appleSessionToken, .signingCertificate,
             .signingPrivateKey, .pairingRecord, .anisetteState, .serverAnisetteState:
            SecretPolicy(audience: .hostOnly, requiresOptIn: false)
        }
    }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// The key needs an opt-in that was not given.
    case optInRequired(SecretKey)
}

/// Storage for secrets. The keychain-backed implementation lives in
/// `HarborPlatform`; `InMemorySecretStore` is for tests and previews.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> Redacted<Data>?
    /// - Parameter optedIn: must be `true` for keys whose policy requires it.
    func write(_ value: Redacted<Data>, for key: SecretKey, optedIn: Bool) throws
    func delete(_ key: SecretKey) throws
}

extension SecretStore {
    public func write(_ value: Redacted<Data>, for key: SecretKey) throws {
        try write(value, for: key, optedIn: false)
    }

    /// Removes everything, for sign-out and reset.
    public func deleteAll() throws {
        for key in SecretKey.allCases {
            try delete(key)
        }
    }

    /// Shared guard so every implementation enforces the opt-in rule the same way.
    public func checkWriteAllowed(_ key: SecretKey, optedIn: Bool) throws {
        if key.policy.requiresOptIn && !optedIn {
            throw SecretStoreError.optInRequired(key)
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecretKey: Data] = [:]

    public init() {}

    public func read(_ key: SecretKey) throws -> Redacted<Data>? {
        lock.withLock { storage[key].map(Redacted.init) }
    }

    public func write(_ value: Redacted<Data>, for key: SecretKey, optedIn: Bool) throws {
        try checkWriteAllowed(key, optedIn: optedIn)
        lock.withLock { storage[key] = value.expose() }
    }

    public func delete(_ key: SecretKey) throws {
        lock.withLock { storage[key] = nil }
    }
}
