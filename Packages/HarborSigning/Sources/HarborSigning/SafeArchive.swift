import Foundation
import HarborCore
import SideSign

/// Zip extraction that checks the archive before writing anything.
///
/// SideSign's extractor joins entry names onto the destination without
/// checking them, so an entry named `../x` is written outside it. Every
/// archive Harbor unpacks, including IPAs from arbitrary sources, goes
/// through here instead.
public enum SafeArchive {
    public static func extract(
        archiveAt archiveURL: URL,
        to directoryURL: URL,
        limits: ArchiveLimits
    ) throws {
        let entries = try Archive.Reader.open(at: archiveURL).entries().map {
            ArchiveEntry(name: $0.filename, uncompressedSize: $0.uncompressedSize)
        }
        try ArchivePolicy.check(entries, limits: limits)
        try FileManager.default.unzipArchive(at: archiveURL, to: directoryURL)
    }
}
