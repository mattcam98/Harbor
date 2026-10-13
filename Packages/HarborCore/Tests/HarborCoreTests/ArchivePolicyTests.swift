import Testing

@testable import HarborCore

@Suite struct ArchivePolicyTests {
    let limits = ArchiveLimits(maxEntries: 3, maxTotalUncompressedSize: 100)

    func entries(_ names: String..., size: Int64 = 1) -> [ArchiveEntry] {
        names.map { ArchiveEntry(name: $0, uncompressedSize: size) }
    }

    @Test func acceptsAnOrdinaryBundle() throws {
        try ArchivePolicy.check(
            entries("Payload/", "Payload/App.app/Info.plist", "Payload/App.app/a..b/file"),
            limits: limits
        )
    }

    @Test(arguments: [
        "../evil",
        "Payload/../../evil",
        "Payload/App.app/..",
        "/etc/passwd",
        "Payload\\..\\evil",
        "C:evil",
        "C:/evil",
        "",
        "a\0b",
    ])
    func rejectsPathsThatEscape(_ name: String) {
        #expect(!ArchivePolicy.isSafe(name))
        #expect(throws: ArchivePolicyError.unsafePath(name)) {
            try ArchivePolicy.check([ArchiveEntry(name: name, uncompressedSize: 1)], limits: limits)
        }
    }

    @Test func rejectsTooManyEntries() {
        #expect(throws: ArchivePolicyError.tooManyEntries(4)) {
            try ArchivePolicy.check(entries("a", "b", "c", "d"), limits: limits)
        }
    }

    @Test func rejectsArchivesThatUnpackTooLarge() {
        #expect(throws: ArchivePolicyError.tooLarge(120)) {
            try ArchivePolicy.check(entries("a", "b", size: 60), limits: limits)
        }
    }

    @Test func rejectsNegativeAndOverflowingSizes() {
        #expect(throws: ArchivePolicyError.self) {
            try ArchivePolicy.check(entries("a", size: -1), limits: limits)
        }
        #expect(throws: ArchivePolicyError.tooLarge(.max)) {
            try ArchivePolicy.check(
                entries("a", "b", size: .max),
                limits: ArchiveLimits(maxEntries: 3, maxTotalUncompressedSize: .max)
            )
        }
    }

    @Test func theLimitItselfIsAllowed() throws {
        try ArchivePolicy.check(entries("a", "b", size: 50), limits: limits)
    }
}
