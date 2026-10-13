import Foundation

/// Where Harbor Setup leaves a pairing file for Harbor to take.
///
/// Setup, on a computer, writes the file into Harbor's container over the
/// cable. The user never handles it: it is not saved to Files, sent or
/// pasted. Harbor moves it into the keychain the next time it is in front
/// and removes the file, so the time it spends on disk is short.
///
/// The folder is Harbor's Application Support, not Documents: Documents is
/// where apps running inside Harbor keep their files.
public struct PairingInbox: Sendable {
    /// The name Setup writes. Both sides have to agree on it; Setup's copy
    /// is `pairing::INBOX_FILE`.
    public static let fileName = "pairing-from-setup.plist"

    public let fileURL: URL

    /// - Parameter directory: Harbor's folder in Application Support.
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Hands a waiting pairing file to `store` and then removes it.
    ///
    /// The file is removed only once `store` has returned: if storing fails
    /// the file stays for the next try. A file that is not a pairing record
    /// is removed and reported, so that it is not tried again for ever.
    ///
    /// - Returns: `false` when nothing was waiting.
    @discardableResult
    public func receive(_ store: (PairingRecord) throws -> Void) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }

        let record: PairingRecord
        do {
            record = try PairingRecord(propertyList: Data(contentsOf: fileURL))
        } catch let error as PairingError {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
        try store(record)
        try fileManager.removeItem(at: fileURL)
        return true
    }
}

/// Where Harbor Setup leaves the certificate and key Harbor was signed with.
///
/// Harbor needs them to sign the apps it runs, and Setup is the only place
/// they exist: it asked Apple for the certificate. They travel the same way
/// as the pairing file and are taken the same way.
public struct IdentityInbox: Sendable {
    /// Setup's copy of this name is `pairing::IDENTITY_INBOX_FILE`.
    public static let fileName = "identity-from-setup.p12"

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Hands a waiting identity file to `store` and then removes it, whether
    /// or not it was accepted: a key that could not be stored is not left
    /// lying in a file. Setup can send it again.
    ///
    /// - Returns: `false` when nothing was waiting.
    @discardableResult
    public func receive(_ store: (Data) throws -> Void) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let contents = try Data(contentsOf: fileURL)
        defer { try? fileManager.removeItem(at: fileURL) }
        try store(contents)
        return true
    }
}
