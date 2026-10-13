import Foundation
import HarborCore
import SideSign

/// Persists the signing identity (certificate and private key) in the secret
/// store, as a PKCS#12 archive protected by a random passphrase.
///
/// The private key is generated on the device when the certificate is
/// requested and is never written anywhere else: not to user defaults, not to
/// an app group, not to a file.
public struct SigningIdentityStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func load() throws -> KeyStore? {
        guard
            let archive = try secrets.read(.signingIdentity),
            let passphrase = try secrets.read(.signingIdentityPassphrase)
        else {
            return nil
        }
        return try KeyStore(
            p12Data: archive.expose(),
            password: String(decoding: passphrase.expose(), as: UTF8.self)
        )
    }

    public func save(_ identity: KeyStore) throws {
        let passphrase = Self.randomPassphrase()
        let archive = try identity.exportP12(password: passphrase)

        // Passphrase first: an archive without its passphrase is unusable,
        // and `load` treats that as "no identity".
        try secrets.write(Redacted(Data(passphrase.utf8)), for: .signingIdentityPassphrase)
        try secrets.write(Redacted(archive), for: .signingIdentity)
    }

    public func clear() throws {
        try secrets.delete(.signingIdentity)
        try secrets.delete(.signingIdentityPassphrase)
    }

    static func randomPassphrase() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}
