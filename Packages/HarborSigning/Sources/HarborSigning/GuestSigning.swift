import CodeSignKit
import Foundation
import HarborCore
import SideSign

public enum IdentityImportError: Error, Equatable, Sendable {
    /// Wrong password, or not a PKCS#12 file this reader understands.
    case unreadable
    /// The file holds a certificate but not its private key, so it cannot sign.
    case noPrivateKey
}

extension SigningIdentityStore {
    /// Takes a signing identity from a `.p12` file, such as one exported from
    /// Keychain Access on the Mac that installed Harbor, and stores it.
    ///
    /// This is the way to get an identity without signing in to Apple from
    /// Harbor. The file and its password are only needed for this call.
    @discardableResult
    public func importPKCS12(_ file: Data, password: Redacted<String>) throws -> KeyStore {
        let identity: KeyStore
        do {
            identity = try KeyStore(p12Data: file, password: password.expose())
        } catch {
            throw IdentityImportError.unreadable
        }
        guard !identity.privateKey.isEmpty else {
            throw IdentityImportError.noPrivateKey
        }
        try save(identity)
        return identity
    }
}

/// Unpacks an IPA and finds the app inside it.
public enum IPA {
    /// Extracts into `directory`, which must exist, and returns the URL of
    /// the single `Payload/<name>.app`.
    public static func unpack(_ ipaURL: URL, into directory: URL) throws -> URL {
        try SafeArchive.extract(archiveAt: ipaURL, to: directory, limits: .appBundle)
        return try InstallPipeline.appBundle(in: directory)
    }
}

/// Signs a guest app so iOS will let Harbor load it without JIT.
///
/// A process may only load code signed by its own team with a certificate
/// the device trusts. Signing every binary of the guest with the identity
/// Harbor itself was signed with satisfies that. No entitlements are
/// attached: a guest runs with Harbor's, whatever its own binary claims.
public struct GuestSigner: Sendable {
    public init() {}

    public func sign(bundleAt bundleURL: URL, identity: KeyStore) throws {
        // The signer takes the identity as PKCS#12. This copy exists only in
        // memory for the duration of the call.
        let archive = try identity.exportP12()
        try CodeSigner.sign(
            appPath: bundleURL.path,
            keyData: archive,
            entitlementProvider: { _ in "" },
            progress: {}
        )
    }

    /// Signs with no identity at all. Patching a guest's executable breaks
    /// the signature it shipped with, and the iOS Simulator on Apple silicon
    /// still insists that code pages match a signature, though not on whose
    /// it is. A real device needs `sign(bundleAt:identity:)`.
    public func signAdHoc(bundleAt bundleURL: URL) throws {
        try CodeSigner.signAdHoc(appPath: bundleURL.path)
    }
}
