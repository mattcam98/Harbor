import Foundation
import Testing

@testable import HarborCore

/// Compares the Swift patcher with LiveContainer's original on real iOS
/// executables. The inputs and the original's outputs are produced by
/// `scripts/differential-machopatch.sh`, which sets the environment variable;
/// without it these tests are skipped.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_MACHO_FIXTURES"] != nil))
struct DifferentialPatchTests {
    struct Fixture {
        let original: Data
        /// What LiveContainer wrote, and the result code it returned.
        let expected: Data
        let expectedResult: Int

        init(variant: String, inject: Bool) throws {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARBOR_MACHO_FIXTURES"] ?? "")
                .appendingPathComponent(variant)
            let patched = root.appendingPathComponent(inject ? "lc-1" : "lc-0")
            original = try Data(contentsOf: root.appendingPathComponent("guest"))
            expected = try Data(contentsOf: patched.appendingPathComponent("guest"))
            let result = try String(contentsOf: patched.appendingPathComponent("result"), encoding: .utf8)
            expectedResult = try #require(Int(result.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    @Test(arguments: ["real"])
    func matchesLiveContainerByteForByteWhenInjecting(_ variant: String) throws {
        let fixture = try Fixture(variant: variant, inject: true)

        let patched = try GuestExecutable.patch(fixture.original, name: "guest", injectTweakLoader: true)

        #expect(fixture.expected != fixture.original, "the original patcher changed nothing")
        #expect(patched.file == fixture.expected)
        #expect(patched.warnings.rawValue == fixture.expectedResult)
    }

    @Test(arguments: ["real"])
    func differsOnlyInTheParkedSlotSizeWhenNotInjecting(_ variant: String) throws {
        let fixture = try Fixture(variant: variant, inject: false)

        let patched = try GuestExecutable.patch(fixture.original, name: "guest", injectTweakLoader: false)
        #expect(patched.warnings.rawValue == fixture.expectedResult)

        guard !patched.warnings.contains(.noSpaceForTweakLoader) else {
            // Neither patcher added a slot, so there is nothing to differ in.
            #expect(patched.file == fixture.expected)
            return
        }

        // Harbor reserves the tweak loader's full size for a parked slot;
        // LiveContainer sizes it to the shorter placeholder path. That shows
        // up in exactly two fields: the slot's size and the total size of
        // the load commands. Put LiveContainer's values there and the files
        // must be identical.
        let slot = try #require(try Inspection(patched.file).commands.last)
        #expect(slot.command == 0x114514)
        #expect(slot.size == 0x48)

        var normalised = Array(patched.file)
        let expected = Array(fixture.expected)
        normalised.replaceSubrange(20..<24, with: expected[20..<24])
        normalised.replaceSubrange((slot.offset + 4)..<(slot.offset + 8), with: expected[(slot.offset + 4)..<(slot.offset + 8)])
        #expect(normalised == expected)

        let originalSlotSize = try MachOBytes(bytes: expected).uint32(at: slot.offset + 4)
        #expect(originalSlotSize == 0x30)
    }

    @Test(arguments: ["real"])
    func aRealExecutableIsReadCorrectlyAndPatchingIsRepeatable(_ variant: String) throws {
        let fixture = try Fixture(variant: variant, inject: true)
        let original = try Inspection(fixture.original)

        #expect(try original.fileType == 2)
        #expect(try original.bytes.fixedName(at: original.commands[0].offset + 8) == "__PAGEZERO")
        #expect(try !GuestExecutable.isEncrypted(fixture.original))

        let once = try GuestExecutable.patch(fixture.original, name: "guest", injectTweakLoader: true)
        let twice = try GuestExecutable.patch(once.file, name: "guest", injectTweakLoader: true)
        #expect(twice.file == once.file)
        #expect(try Inspection(once.file).fileType == 6)
    }
}
