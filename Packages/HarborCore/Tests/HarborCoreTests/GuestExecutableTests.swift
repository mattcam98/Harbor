import Foundation
import Testing

@testable import HarborCore

/// Assembles small but structurally real Mach-O files for the tests.
struct MachOBuilder {
    var cpuSubtype: UInt32 = 0
    var commands: [[UInt8]] = []
    /// Where code starts. Load commands live between the header and here.
    var textOffset = 0x4000
    var fileSize = 0x5000
    /// Extra bytes to place at fixed file offsets.
    var blobs: [(offset: Int, bytes: [UInt8])] = []

    static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func padded(_ string: String, to length: Int) -> [UInt8] {
        let utf8 = Array(string.utf8)
        return utf8 + [UInt8](repeating: 0, count: length - utf8.count)
    }

    static func segment(
        _ name: String, vmaddr: UInt64, vmsize: UInt64, sections: [(name: String, offset: UInt32)] = []
    ) -> [UInt8] {
        var body = padded(name, to: 16) + u64(vmaddr) + u64(vmsize) + u64(0) + u64(0)
        body += u32(7) + u32(5) + u32(UInt32(sections.count)) + u32(0)
        for section in sections {
            body += padded(section.name, to: 16) + padded(name, to: 16)
            body += u64(0) + u64(0) + u32(section.offset) + [UInt8](repeating: 0, count: 28)
        }
        return u32(0x19) + u32(UInt32(8 + body.count)) + body
    }

    static func library(_ command: UInt32, _ path: String) -> [UInt8] {
        let nameLength = (path.utf8.count + 1 + 7) & ~7
        return u32(command) + u32(UInt32(24 + nameLength)) + u32(24) + u32(2) + u32(0x10000) + u32(0x10000)
            + padded(path, to: nameLength)
    }

    static let dylinker: [UInt8] = u32(0xe) + u32(32) + u32(12) + padded("/usr/lib/dyld", to: 20)
    static let codeSignature: [UInt8] = u32(0x1d) + u32(16) + u32(0x4800) + u32(0x100)
    static let uuid: [UInt8] = u32(0x1b) + u32(24) + [UInt8](repeating: 0xab, count: 16)

    static func encryptionInfo(cryptid: UInt32) -> [UInt8] {
        u32(0x2c) + u32(24) + u32(0x4000) + u32(0x1000) + u32(cryptid) + u32(0)
    }

    /// LC_BUILD_VERSION for iOS, with no tool entries.
    static func buildVersion(minimum: UInt32 = 0x000f_0000, sdk: UInt32) -> [UInt8] {
        u32(0x32) + u32(24) + u32(2) + u32(minimum) + u32(sdk) + u32(0)
    }

    /// LC_VERSION_MIN_IPHONEOS, as binaries built before 2018 carry.
    static func versionMinimum(_ minimum: UInt32 = 0x0009_0000, sdk: UInt32) -> [UInt8] {
        u32(0x25) + u32(16) + u32(minimum) + u32(sdk)
    }

    static func chainedFixups(dataOffset: UInt32, dataSize: UInt32) -> [UInt8] {
        u32(0x8000_0034) + u32(16) + u32(dataOffset) + u32(dataSize)
    }

    /// A typical app executable: zero page, text, linker, one library, signature.
    static func executable() -> MachOBuilder {
        var builder = MachOBuilder()
        builder.commands = [
            segment("__PAGEZERO", vmaddr: 0, vmsize: 0x1_0000_0000),
            segment("__TEXT", vmaddr: 0x1_0000_0000, vmsize: 0x4000, sections: [("__text", 0x4000)]),
            segment("__LINKEDIT", vmaddr: 0x1_0000_4000, vmsize: 0x4000),
            dylinker,
            uuid,
            library(0xc, "/usr/lib/libSystem.B.dylib"),
            codeSignature,
        ]
        return builder
    }

    func build() -> Data {
        let commandBytes = commands.flatMap { $0 }
        var file = Self.u32(0xfeed_facf) + Self.u32(0x0100_000c) + Self.u32(cpuSubtype)
            + Self.u32(2)  // MH_EXECUTE
            + Self.u32(UInt32(commands.count)) + Self.u32(UInt32(commandBytes.count))
            + Self.u32(0x0020_0085)  // NOUNDEFS | DYLDLINK | TWOLEVEL | PIE
            + Self.u32(0)
        file += commandBytes
        file += [UInt8](repeating: 0, count: textOffset - file.count)
        // Recognisable "code", to check nothing past the header is disturbed.
        file += (0..<(fileSize - textOffset)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        for blob in blobs {
            file.replaceSubrange(blob.offset..<(blob.offset + blob.bytes.count), with: blob.bytes)
        }
        return Data(file)
    }

    /// Wraps slices in a fat header (big-endian), each page-aligned.
    static func fat(_ slices: [(cpuSubtype: UInt32, file: Data)]) -> Data {
        func be(_ value: UInt32) -> [UInt8] { u32(value.byteSwapped) }
        var header = be(0xcafe_babe) + be(UInt32(slices.count))
        var body: [UInt8] = []
        let firstOffset = 0x4000
        for slice in slices {
            let offset = firstOffset + body.count
            header += be(0x0100_000c) + be(slice.cpuSubtype) + be(UInt32(offset)) + be(UInt32(slice.file.count)) + be(14)
            body += Array(slice.file)
        }
        return Data(header + [UInt8](repeating: 0, count: firstOffset - header.count) + body)
    }
}

/// Reads back what the patcher wrote.
struct Inspection {
    let bytes: MachOBytes
    let slice: MachOBytes.Slice
    let commands: [MachOBytes.LoadCommand]

    init(_ file: Data, slice index: Int = 0) throws {
        bytes = MachOBytes(bytes: Array(file))
        slice = try bytes.slices()[index]
        commands = try bytes.loadCommands(of: slice)
    }

    var fileType: UInt32 { get throws { try bytes.uint32(at: slice.offset + 12) } }
    var flags: UInt32 { get throws { try bytes.uint32(at: slice.offset + 24) } }
    var commandIDs: [UInt32] { commands.map(\.command) }

    func libraryPath(_ command: MachOBytes.LoadCommand) throws -> String {
        try bytes.cString(at: command.offset + 24, limit: command.offset + command.size)
    }

    func libraryPaths(of id: UInt32) throws -> [String] {
        try commands.filter { $0.command == id }.map(libraryPath)
    }
}

@Suite struct GuestExecutablePatchTests {
    let original = MachOBuilder.executable().build()

    @Test func turnsAnExecutableIntoALoadableLibrary() throws {
        let patched = try GuestExecutable.patch(original, name: "Example", injectTweakLoader: true)
        let result = try Inspection(patched.file)

        #expect(patched.warnings.isEmpty)
        #expect(try result.fileType == 6)
        #expect(try result.flags & 0x0020_0000 == 0)  // PIE cleared
        #expect(try result.flags & 0x0010_0000 != 0)  // NO_REEXPORTED_DYLIBS set
        #expect(try result.flags & 0x85 == 0x85)  // the rest untouched

        // Identity first, tweak loader last, everything else in its old order.
        #expect(result.commandIDs == [0xd, 0x19, 0x19, 0x19, 0xe, 0x1b, 0xc, 0x1d, 0xc])
        #expect(try result.libraryPath(result.commands[0]) == "Example")
        #expect(try result.libraryPath(result.commands[8]) == "@loader_path/../../Tweaks/TweakLoader.dylib")
        #expect(result.commands[8].size == 0x48)

        // The zero page is one page just under 4 GB.
        let zeroPage = result.commands[1]
        #expect(try result.bytes.fixedName(at: zeroPage.offset + 8) == "__PAGEZERO")
        #expect(try result.bytes.uint64(at: zeroPage.offset + 24) == 0xffff_c000)
        #expect(try result.bytes.uint64(at: zeroPage.offset + 32) == 0x4000)
    }

    @Test func leavesTheCodeAndTheFileSizeAlone() throws {
        let patched = try GuestExecutable.patch(original, name: "Example", injectTweakLoader: true).file

        #expect(patched.count == original.count)
        #expect(patched[0x4000...] == original[0x4000...])
    }

    @Test func parksTheLoaderSlotWhenTweaksAreOff() throws {
        let patched = try GuestExecutable.patch(original, name: "Example", injectTweakLoader: false)
        let result = try Inspection(patched.file)

        #expect(patched.warnings.isEmpty)
        #expect(result.commandIDs.last == 0x114514)
        #expect(try result.libraryPath(result.commands[8]) == "/usr/lib/libc++.1.dylib")
        // Full size, so it can be switched on later.
        #expect(result.commands[8].size == 0x48)
    }

    @Test func patchingAgainChangesNothingAndTheSlotCanBeSwitched() throws {
        let once = try GuestExecutable.patch(original, name: "Example", injectTweakLoader: true).file
        let twice = try GuestExecutable.patch(once, name: "Example", injectTweakLoader: true)
        #expect(twice.file == once)
        #expect(twice.warnings.isEmpty)

        let off = try GuestExecutable.patch(once, name: "Example", injectTweakLoader: false)
        #expect(off.warnings.isEmpty)
        #expect(try Inspection(off.file).commandIDs == [0xd, 0x19, 0x19, 0x19, 0xe, 0x1b, 0xc, 0x1d, 0x114514])

        let onAgain = try GuestExecutable.patch(off.file, name: "Example", injectTweakLoader: true)
        #expect(onAgain.warnings.isEmpty)
        #expect(onAgain.file == once)
    }

    @Test func switchesAParkedSlotThatWasCreatedParked() throws {
        let parked = try GuestExecutable.patch(original, name: "Example", injectTweakLoader: false).file
        let switched = try GuestExecutable.patch(parked, name: "Example", injectTweakLoader: true)

        #expect(switched.warnings.isEmpty)
        #expect(try Inspection(switched.file).libraryPaths(of: 0xc).contains(
            "@loader_path/../../Tweaks/TweakLoader.dylib"))
    }

    @Test func reusesTheLinkerCommandWhenThereIsNoRoom() throws {
        var builder = MachOBuilder.executable()
        // Code starts immediately after the load commands: no padding at all.
        let headerAndCommands = 32 + builder.commands.reduce(0) { $0 + $1.count }
        builder.textOffset = headerAndCommands
        builder.commands[1] = MachOBuilder.segment(
            "__TEXT", vmaddr: 0x1_0000_0000, vmsize: 0x4000, sections: [("__text", UInt32(headerAndCommands))])
        builder.fileSize = headerAndCommands + 0x100

        let patched = try GuestExecutable.patch(
            builder.build(), name: "LongExecutableName", injectTweakLoader: true)
        let result = try Inspection(patched.file)

        #expect(patched.warnings == .noSpaceForTweakLoader)
        // Same commands, with the linker's slot now holding the identity,
        // its name cut to the seven characters that fit.
        #expect(result.commandIDs == [0x19, 0x19, 0x19, 0xd, 0x1b, 0xc, 0x1d])
        #expect(try result.libraryPath(result.commands[3]) == "LongExe")
        #expect(patched.file.count == builder.build().count)
    }

    @Test func neutralisesALibraryLoadedTwice() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.library(0xc, "@rpath/Tweak.dylib"), at: 6)
        builder.commands.insert(MachOBuilder.library(0x8000_0018, "@rpath/Tweak.dylib"), at: 7)

        let result = try Inspection(
            GuestExecutable.patch(builder.build(), name: "Example", injectTweakLoader: true).file)

        #expect(try result.libraryPaths(of: 0xc).filter { $0 == "@rpath/Tweak.dylib" }.count == 1)
        #expect(result.commandIDs.contains(0x114515))
        #expect(!result.commandIDs.contains(0x8000_0018))
    }

    @Test func flagsAChainedFixupsSegmentCountThatDisagrees() throws {
        func build(segmentCount: UInt32) -> Data {
            var builder = MachOBuilder.executable()
            builder.commands.insert(MachOBuilder.chainedFixups(dataOffset: 0x4800, dataSize: 0x40), at: 6)
            // dyld_chained_fixups_header with starts_offset 0x20, then seg_count there.
            var data = [UInt8](repeating: 0, count: 0x40)
            data.replaceSubrange(4..<8, with: MachOBuilder.u32(0x20))
            data.replaceSubrange(0x20..<0x24, with: MachOBuilder.u32(segmentCount))
            builder.blobs = [(0x4800, data)]
            return builder.build()
        }

        #expect(try GuestExecutable.patch(build(segmentCount: 3), name: "E", injectTweakLoader: true)
            .warnings.isEmpty)
        #expect(try GuestExecutable.patch(build(segmentCount: 4), name: "E", injectTweakLoader: true)
            .warnings == .segmentCountMismatch)
    }

    @Test func patchesTheARM64SliceOfAFatFile() throws {
        let fat = MachOBuilder.fat([(0, original)])
        let patched = try GuestExecutable.patch(fat, name: "Example", injectTweakLoader: true)

        #expect(try Inspection(patched.file).fileType == 6)
        #expect(patched.file.count == fat.count)
    }
}

@Suite struct GuestExecutableInspectionTests {
    @Test func detectsFairPlayEncryption() throws {
        func build(cryptid: UInt32?) -> Data {
            var builder = MachOBuilder.executable()
            if let cryptid {
                builder.commands.insert(MachOBuilder.encryptionInfo(cryptid: cryptid), at: 5)
            }
            return builder.build()
        }

        #expect(try GuestExecutable.isEncrypted(build(cryptid: 1)))
        #expect(try !GuestExecutable.isEncrypted(build(cryptid: 0)))
        #expect(try !GuestExecutable.isEncrypted(build(cryptid: nil)))
        #expect(try GuestExecutable.isEncrypted(MachOBuilder.fat([(0, build(cryptid: 0)), (0, build(cryptid: 1))])))
    }

    @Test func detectsEncryptionFromAFileReadingOnlyItsHeaders() throws {
        func build(cryptid: UInt32) -> Data {
            var builder = MachOBuilder.executable()
            builder.commands.insert(MachOBuilder.encryptionInfo(cryptid: cryptid), at: 5)
            return builder.build()
        }
        func check(_ file: Data) throws -> Bool {
            let temporary = try TemporaryFile(file)
            defer { temporary.remove() }
            return try GuestExecutable.isEncrypted(fileAt: temporary.url)
        }

        #expect(try check(build(cryptid: 1)))
        #expect(try !check(build(cryptid: 0)))
        #expect(try check(MachOBuilder.fat([(0, build(cryptid: 0)), (0, build(cryptid: 1))])))
        #expect(throws: MachOError.notMachO) { try check(Data("plain text".utf8)) }

        // A header that claims an enormous command area is refused, not allocated.
        var greedy = Array(build(cryptid: 0))
        greedy.replaceSubrange(20..<24, with: MachOBuilder.u32(0x7fff_ffff))
        #expect(throws: MachOError.unsupported("load commands too large")) { try check(Data(greedy)) }
    }

    @Test func marksAnARM64eSliceInBothHeaders() throws {
        var arm64e = MachOBuilder.executable()
        arm64e.cpuSubtype = 2
        let fat = MachOBuilder.fat([(0, MachOBuilder.executable().build()), (2, arm64e.build())])

        let fixed = try GuestExecutable.fixUpARM64eSlices(fat)
        let bytes = MachOBytes(bytes: Array(fixed))
        let slices = try bytes.slices()

        #expect(try bytes.uint32(at: slices[1].offset + 8) == 0x8000_0002)
        #expect(try bytes.uint32BigEndian(at: slices[1].fatArchOffset! + 4) == 0x8000_0002)
        // The plain arm64 slice is untouched, and a thin file is left as it is.
        #expect(try bytes.uint32(at: slices[0].offset + 8) == 0)
        #expect(try GuestExecutable.fixUpARM64eSlices(arm64e.build()) == arm64e.build())
    }

    @Test func rejectsWhatIsNotMachO() {
        #expect(throws: MachOError.notMachO) {
            try GuestExecutable.isEncrypted(Data("#!/bin/sh\necho hello\n".utf8))
        }
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.isEncrypted(Data([0xcf, 0xfa]))
        }
    }

    @Test func malformedFilesFailCleanlyInsteadOfReadingOutOfBounds() throws {
        let file = MachOBuilder.executable().build()

        // Cut off in the middle of the load commands.
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.patch(file.prefix(200), name: "E", injectTweakLoader: true)
        }

        // A command count far beyond what the file holds.
        var hugeCount = Array(file)
        hugeCount.replaceSubrange(16..<20, with: MachOBuilder.u32(.max))
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.patch(Data(hugeCount), name: "E", injectTweakLoader: true)
        }

        // A command that claims zero size would loop forever in a naive reader.
        var zeroSize = Array(file)
        zeroSize.replaceSubrange(36..<40, with: MachOBuilder.u32(0))
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.patch(Data(zeroSize), name: "E", injectTweakLoader: true)
        }

        // A command that runs past the declared command area, though still
        // inside the file: the last command claims 0x100 bytes instead of 16.
        var overrun = Array(file)
        let lastCommand = 32 + MachOBuilder.executable().commands.dropLast().reduce(0) { $0 + $1.count }
        overrun.replaceSubrange((lastCommand + 4)..<(lastCommand + 8), with: MachOBuilder.u32(0x100))
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.isEncrypted(Data(overrun))
        }
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.patch(Data(overrun), name: "E", injectTweakLoader: true)
        }

        // A declared command area larger than the file.
        var hugeArea = Array(file)
        hugeArea.replaceSubrange(20..<24, with: MachOBuilder.u32(0x00ff_ffff))
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.patch(Data(hugeArea), name: "E", injectTweakLoader: true)
        }

        // A fat header pointing past the end of the file.
        var fat = Array(MachOBuilder.fat([(0, file)]))
        fat.replaceSubrange(16..<20, with: MachOBuilder.u32(UInt32(0x7fff_0000).byteSwapped))
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.isEncrypted(Data(fat))
        }
    }

    @Test func aFileWithNoARM64SliceIsNotPatched() throws {
        var other = Array(MachOBuilder.executable().build())
        other.replaceSubrange(4..<8, with: MachOBuilder.u32(0x0100_0007))  // x86_64
        #expect(throws: MachOError.unsupported("no 64-bit ARM slice")) {
            try GuestExecutable.patch(Data(other), name: "E", injectTweakLoader: true)
        }
    }
}

@Suite struct GuestExecutableFileInspectionTests {
    func withFile<Result>(_ data: Data, _ body: (URL) throws -> Result) throws -> Result {
        let file = try TemporaryFile(data)
        defer { file.remove() }
        return try body(file.url)
    }

    @Test func recognises64BitMachOFiles() throws {
        let thin = MachOBuilder.executable().build()
        #expect(try withFile(thin) { GuestExecutable.is64BitMachO(fileAt: $0) })
        #expect(try withFile(MachOBuilder.fat([(0, thin)])) { GuestExecutable.is64BitMachO(fileAt: $0) })
        #expect(try !withFile(Data("{\"json\": true}".utf8)) { GuestExecutable.is64BitMachO(fileAt: $0) })
        #expect(try !withFile(Data()) { GuestExecutable.is64BitMachO(fileAt: $0) })

        var thirtyTwoBit = Array(thin)
        thirtyTwoBit.replaceSubrange(0..<4, with: MachOBuilder.u32(0xfeed_face))
        #expect(try !withFile(Data(thirtyTwoBit)) { GuestExecutable.is64BitMachO(fileAt: $0) })
    }

    @Test func findsTheCodeSignature() throws {
        // The builder's signature command points at 0x4800, 0x100 bytes long.
        let thin = MachOBuilder.executable().build()
        #expect(try withFile(thin) { try GuestExecutable.signatureLocation(fileAt: $0) }
            == GuestExecutable.SignatureLocation(sliceOffset: 0, offset: 0x4800, size: 0x100))

        // In a fat file the offsets stay relative to the slice.
        #expect(try withFile(MachOBuilder.fat([(0, thin)])) { try GuestExecutable.signatureLocation(fileAt: $0) }
            == GuestExecutable.SignatureLocation(sliceOffset: 0x4000, offset: 0x4800, size: 0x100))
    }

    @Test func reportsAnUnsignedExecutable() throws {
        var builder = MachOBuilder.executable()
        builder.commands.removeLast()
        #expect(try withFile(builder.build()) { try GuestExecutable.signatureLocation(fileAt: $0) } == nil)
    }
}

@Suite struct SDKVersionTests {
    @Test func readsTheBuildVersionCommand() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.buildVersion(sdk: 0x0011_0400), at: 4)
        #expect(try GuestExecutable.sdkVersion(of: builder.build()) == 0x0011_0400)
    }

    @Test func readsTheOlderVersionMinimumCommand() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.versionMinimum(sdk: 0x000a_0300), at: 4)
        #expect(try GuestExecutable.sdkVersion(of: builder.build()) == 0x000a_0300)
    }

    @Test func aBinaryThatDoesNotSayHasNoVersion() throws {
        #expect(try GuestExecutable.sdkVersion(of: MachOBuilder.executable().build()) == nil)

        // A zero is "not recorded", not "iOS 0".
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.buildVersion(sdk: 0), at: 4)
        #expect(try GuestExecutable.sdkVersion(of: builder.build()) == nil)
    }

    @Test func readsTheSameFromAFileWithoutLoadingIt() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.buildVersion(sdk: 0x0012_0000), at: 4)
        let file = try TemporaryFile(builder.build())
        defer { file.remove() }
        #expect(try GuestExecutable.sdkVersion(fileAt: file.url) == 0x0012_0000)
    }

    @Test func aCommandTooShortToHoldAVersionIsRefused() {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.u32(0x32) + MachOBuilder.u32(16) + MachOBuilder.u32(2) + MachOBuilder.u32(0), at: 4)
        #expect(throws: MachOError.truncated) {
            try GuestExecutable.sdkVersion(of: builder.build())
        }
    }
}
