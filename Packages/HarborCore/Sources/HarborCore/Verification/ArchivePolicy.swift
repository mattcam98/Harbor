/// One entry in a zip archive, as listed in its directory.
public struct ArchiveEntry: Equatable, Sendable {
    public var name: String
    public var uncompressedSize: Int64

    public init(name: String, uncompressedSize: Int64) {
        self.name = name
        self.uncompressedSize = uncompressedSize
    }
}

public struct ArchiveLimits: Equatable, Sendable {
    public var maxEntries: Int
    public var maxTotalUncompressedSize: Int64

    public init(maxEntries: Int, maxTotalUncompressedSize: Int64) {
        self.maxEntries = maxEntries
        self.maxTotalUncompressedSize = maxTotalUncompressedSize
    }

    /// Generous for an app: 4 GiB unpacked, 200,000 files.
    public static let appBundle = ArchiveLimits(maxEntries: 200_000, maxTotalUncompressedSize: 4 << 30)
    /// A handful of small libraries.
    public static let smallPackage = ArchiveLimits(maxEntries: 256, maxTotalUncompressedSize: 256 << 20)
}

public enum ArchivePolicyError: Error, Equatable, Sendable {
    /// The entry would be written outside the extraction directory.
    case unsafePath(String)
    case tooManyEntries(Int)
    case tooLarge(Int64)
}

/// Decides whether an archive is safe to extract, from its entry list alone.
///
/// Run this before extracting anything. An extractor that joins entry names
/// onto a destination path will otherwise follow `../` out of it.
public enum ArchivePolicy {
    public static func check(_ entries: [ArchiveEntry], limits: ArchiveLimits) throws {
        guard entries.count <= limits.maxEntries else {
            throw ArchivePolicyError.tooManyEntries(entries.count)
        }

        var total: Int64 = 0
        for entry in entries {
            guard isSafe(entry.name) else {
                throw ArchivePolicyError.unsafePath(entry.name)
            }
            // A negative size is a corrupt or hostile header, not a discount.
            let (sum, overflow) = total.addingReportingOverflow(max(0, entry.uncompressedSize))
            guard !overflow, entry.uncompressedSize >= 0, sum <= limits.maxTotalUncompressedSize else {
                throw ArchivePolicyError.tooLarge(overflow ? .max : sum)
            }
            total = sum
        }
    }

    /// A relative path that stays inside the directory it is joined onto.
    public static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else {
            return false
        }
        // "C:evil" is drive-relative on Windows; no legitimate entry needs a colon first.
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if let first = components.first, first.contains(":") {
            return false
        }
        return !components.contains("..")
    }
}
