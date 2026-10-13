import Foundation
import HarborCore
import SideSign

/// Persists the signing identity (certificate and private key) in the secret
/// store.
///
/// The private key is generated on the device when the certificate is
/// requested and is never written anywhere else: not to user defaults, not to
/// an app group, not to a file.
///
/// The two parts are stored as separate items rather than as a PKCS#12
/// archive. The PKCS#12 writer available here (`CodeSignKit.PKCS12Builder`,
/// behind `KeyStore.exportP12`) ignores its password and writes the key
/// unencrypted, so an archive would add a false sense of protection and
/// nothing else. The secret store is what protects the key.
public struct SigningIdentityStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// `nil` when either part is missing or the certificate no longer parses.
    public func load() throws -> KeyStore? {
        guard
            let certificateData = try secrets.read(.signingCertificate),
            let privateKey = try secrets.read(.signingPrivateKey),
            let certificate = X509Certificate(data: certificateData.expose())
        else {
            return nil
        }
        return KeyStore(certificate: certificate, privateKey: privateKey.expose())
    }

    public func save(_ identity: KeyStore) throws {
        // Key first: a certificate without its key is useless, and `load`
        // reports that as "no identity".
        try secrets.write(Redacted(identity.privateKey), for: .signingPrivateKey)
        try secrets.write(Redacted(identity.certificate.rawDER), for: .signingCertificate)
    }

    public func clear() throws {
        try secrets.delete(.signingCertificate)
        try secrets.delete(.signingPrivateKey)
    }
}
