#if os(macOS)
import Foundation
import Testing

@testable import HarborCore

/// Runs LiveContainer's own patcher (the harness built by
/// `scripts/differential-machopatch.sh`) on purpose-built layouts and compares
/// its output with the Swift port's. This reaches the branches a freshly
/// linked executable never takes: no header room, room for only one command,
/// duplicate libraries, mismatched fixups, already patched input.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LC_HARNESS"] != nil))
struct OriginalPatcherComparisonTests {
    /// What the original wrote and the result code it returned.
    static func original(_ file: Data, name: String, inject: Bool) throws -> (file: Data, result: Int) {
        let harness = try #require(ProcessInfo.processInfo.environment["HARBOR_LC_HARNESS"])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-original-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The original names the library after the file it is given.
        let path = directory.appendingPathComponent(name)
        try file.write(to: path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: harness)
        process.arguments = [path.path, inject ? "1" : "0"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "the harness failed")

        let lastLine = String(decoding: printed, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return (try Data(contentsOf: path), try #require(Int(lastLine)))
    }

    /// Asserts both patchers produce the same bytes and the same result code.
    static func expectSame(_ file: Data, name: String = "Example", inject: Bool = true, result expected: Int) throws {
        let theirs = try original(file, name: name, inject: inject)
        let ours = try GuestExecutable.patch(file, name: name, injectTweakLoader: inject)

        #expect(theirs.result == expected, "the layout did not reach the intended branch")
        #expect(ours.file == theirs.file)
        #expect(ours.warnings.rawValue == theirs.result)
    }

    /// The standard executable with code starting `gap` bytes after its load commands.
    static func executable(gap: Int, withCodeSignature: Bool = true) -> Data {
        var builder = MachOBuilder.executable()
        if !withCodeSignature {
            builder.commands.removeLast()
        }
        let textOffset = 32 + builder.commands.reduce(0) { $0 + $1.count } + gap
        builder.commands[1] = MachOBuilder.segment(
            "__TEXT", vmaddr: 0x1_0000_0000, vmsize: 0x4000, sections: [("__text", UInt32(textOffset))])
        builder.textOffset = textOffset
        builder.fileSize = textOffset + 0x100
        return builder.build()
    }

    @Test func aRoomyHeader() throws {
        try Self.expectSame(MachOBuilder.executable().build(), result: 0)
    }

    @Test func noRoomSoTheIdentityTakesOverTheLinkerCommand() throws {
        try Self.expectSame(Self.executable(gap: 0), name: "LongExecutableName", result: 1)
        try Self.expectSame(Self.executable(gap: 0), name: "Short", result: 1)
    }

    @Test func roomForTheIdentityButNotTheTweakLoader() throws {
        // "Example" needs 32 bytes; the tweak loader needs 72 more.
        try Self.expectSame(Self.executable(gap: 32), result: 1)
        try Self.expectSame(Self.executable(gap: 100), result: 1)
    }

    @Test func exactlyEnoughRoomForBoth() throws {
        try Self.expectSame(Self.executable(gap: 104), result: 0)
        try Self.expectSame(Self.executable(gap: 103), result: 1)
    }

    @Test func roomIsHeldBackForAMissingCodeSignature() throws {
        // Without a signature command, 16 bytes are kept free for one.
        try Self.expectSame(Self.executable(gap: 120, withCodeSignature: false), result: 0)
        try Self.expectSame(Self.executable(gap: 119, withCodeSignature: false), result: 1)
        try Self.expectSame(Self.executable(gap: 47, withCodeSignature: false), result: 1)
    }

    @Test func aLibraryLoadedTwice() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.library(0xc, "@rpath/Tweak.dylib"), at: 6)
        builder.commands.insert(MachOBuilder.library(0x8000_0018, "@rpath/Tweak.dylib"), at: 7)
        builder.commands.insert(MachOBuilder.library(0x8000_001f, "@rpath/Tweak.dylib"), at: 8)
        try Self.expectSame(builder.build(), result: 0)
    }

    @Test func aFixupsSegmentCountThatDisagrees() throws {
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.chainedFixups(dataOffset: 0x4800, dataSize: 0x40), at: 6)
        var data = [UInt8](repeating: 0, count: 0x40)
        data.replaceSubrange(4..<8, with: MachOBuilder.u32(0x20))
        data.replaceSubrange(0x20..<0x24, with: MachOBuilder.u32(9))
        builder.blobs = [(0x4800, data)]
        try Self.expectSame(builder.build(), result: 2)
    }

    @Test func withoutTweaksTheSlotIsParked() throws {
        let file = MachOBuilder.executable().build()
        let theirs = try Self.original(file, name: "Example", inject: false)
        let ours = try GuestExecutable.patch(file, name: "Example", injectTweakLoader: false)

        // The one intended difference: Harbor's parked slot is full size
        // (0x48), the original's fits only the placeholder path (0x30).
        let slot = try #require(try Inspection(ours.file).commands.last)
        var normalised = Array(ours.file)
        let expected = Array(theirs.file)
        normalised.replaceSubrange(20..<24, with: expected[20..<24])
        normalised.replaceSubrange((slot.offset + 4)..<(slot.offset + 8), with: expected[(slot.offset + 4)..<(slot.offset + 8)])
        #expect(normalised == expected)
        #expect(ours.warnings.rawValue == theirs.result)
    }

    @Test func patchingTheOriginalsOutputAgainChangesNothingInEither() throws {
        let once = try Self.original(MachOBuilder.executable().build(), name: "Example", inject: true).file
        try Self.expectSame(once, result: 0)
        #expect(try GuestExecutable.patch(once, name: "Example", injectTweakLoader: true).file == once)
    }

    @Test func aSlotTheOriginalParkedIsNotOverrunWhenSwitchedOn() throws {
        // The original parks a 0x30-byte slot and, when tweaks are switched
        // on later, copies the 43-character loader path into its 24 bytes.
        let parked = try Self.original(MachOBuilder.executable().build(), name: "Example", inject: false).file

        let ours = try GuestExecutable.patch(parked, name: "Example", injectTweakLoader: true)

        // Harbor reports there is no room and leaves the file as it was.
        #expect(ours.warnings == .noSpaceForTweakLoader)
        #expect(ours.file == parked)

        // The original writes past the end of the command it is editing.
        let theirs = try Self.original(parked, name: "Example", inject: true).file
        let slot = try #require(try Inspection(parked).commands.last)
        let afterSlot = (slot.offset + slot.size)..<(slot.offset + 0x48)
        #expect(parked[afterSlot].allSatisfy { $0 == 0 })
        #expect(!theirs[afterSlot].allSatisfy { $0 == 0 })
    }
}
#endif
