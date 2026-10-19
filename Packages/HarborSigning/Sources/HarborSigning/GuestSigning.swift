import CodeSignKit
import Foundation
import HarborCore
import SideSign

public enum IdentityImportError: Error, Equatable, Sendable {
    /// Wrong password, or not a PKCS#12 file this reader understands.
    case unreadable
    /// The file holds a certificate but not its private key, so it cannot sign.
    case noPrivateKey
    case expired(on: Date)
    /// The certificate is valid but is not one this copy of Harbor was
    /// installed with, so iOS will not load code it signs. `accepted`
    /// describes the certificates that would work.
    case notAcceptedByThisInstall(accepted: [String])
}

/// A signing certificate in words, for showing to the user.
public struct IdentitySummary: Equatable, Sendable {
    public var name: String
    public var expires: Date?
    /// The last characters of the serial number, to tell apart certificates
    /// that share a name.
    public var serialSuffix: String

    public init(_ certificate: X509Certificate) {
        name = certificate.name
        expires = certificate.notAfter
        serialSuffix = String(certificate.serialNumber.suffix(6))
    }
}

extension SigningIdentityStore {
    /// Takes a signing identity from a `.p12` file, such as one exported from
    /// Keychain Access on the Mac that installed Harbor, and stores it.
    ///
    /// This is the way to get an identity without signing in to Apple from
    /// Harbor. The file and its password are only needed for this call.
    ///
    /// - Parameter acceptedCertificates: the certificates in the provisioning
    ///   profile Harbor was installed with, when that is known. iOS only
    ///   loads code signed by one of them, so anything else is refused here
    ///   with an explanation, not later with a crash.
    @discardableResult
    public func importPKCS12(
        _ file: Data,
        password: Redacted<String>,
        acceptedCertificates: [X509Certificate]? = nil,
        now: Date = Date()
    ) throws -> KeyStore {
        let identity: KeyStore
        do {
            identity = try KeyStore(p12Data: file, password: password.expose())
        } catch {
            throw IdentityImportError.unreadable
        }
        guard !identity.privateKey.isEmpty else {
            throw IdentityImportError.noPrivateKey
        }
        if let expiry = identity.certificate.notAfter, expiry <= now {
            throw IdentityImportError.expired(on: expiry)
        }
        if let acceptedCertificates,
           !acceptedCertificates.contains(where: { CertificateProvisioner.sameSerial($0, identity.certificate) }) {
            throw IdentityImportError.notAcceptedByThisInstall(
                accepted: acceptedCertificates.map(Self.describe))
        }
        try save(identity)
        return identity
    }

    static func describe(_ certificate: X509Certificate) -> String {
        let summary = IdentitySummary(certificate)
        let expiry = summary.expires.map { ", expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "\(summary.name)\(expiry)"
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
/// the device trusts. This follows what LiveContainer does (ZSign, at
/// `4dbe0f9`), which is known to satisfy iOS 26 and later: every 64-bit
/// Mach-O file in the guest is signed on its own, as a plain library, under
/// the host app's bundle identifier, with no entitlements and no ties to the
/// guest's Info.plist or resources. A guest runs with Harbor's entitlements
/// whatever its own binary claims.
public struct GuestSigner: Sendable {
    public init() {}

    /// - Parameter hostBundleIdentifier: Harbor's own bundle identifier as
    ///   installed, which becomes the signing identifier.
    /// - Returns: how many files were signed.
    @discardableResult
    public func sign(bundleAt bundleURL: URL, identity: KeyStore, hostBundleIdentifier: String) throws -> Int {
        // The signer takes the identity as PKCS#12. This copy exists only in
        // memory for the duration of the call.
        let cms = CMSSigner(p12Data: try identity.exportP12(), password: "")
        let teamIdentifier = identity.certificate.organizationalUnit

        var signed = 0
        for file in Self.machOFiles(in: bundleURL) {
            let signer = MachOSigner(
                binaryData: try Data(contentsOf: file),
                bundleIdentifier: hostBundleIdentifier,
                teamIdentifier: teamIdentifier,
                entitlementsXML: nil,
                infoPlistData: nil,
                codeResourcesData: nil,
                cmsSigner: cms
            )
            // A new file, not an edit in place: the kernel remembers the
            // signature it saw on a file and kills a process that maps one
            // whose pages no longer match.
            try signer.sign().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            signed += 1
        }
        return signed
    }

    /// Signs with no identity at all. Patching a guest's executable breaks
    /// the signature it shipped with, and the iOS Simulator on Apple silicon
    /// still insists that code pages match a signature, though not on whose
    /// it is. A real device needs `sign(bundleAt:identity:hostBundleIdentifier:)`.
    public func signAdHoc(bundleAt bundleURL: URL) throws {
        try CodeSigner.signAdHoc(appPath: bundleURL.path)
    }

    /// Every regular file in the bundle that holds 64-bit Mach-O code.
    static func machOFiles(in bundleURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if GuestExecutable.is64BitMachO(fileAt: url) {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
