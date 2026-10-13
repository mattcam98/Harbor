/// Why a Mach-O file could not be read or changed.
public enum MachOError: Error, Equatable, Sendable {
    case notMachO
    /// A header or load command points outside the file.
    case truncated
    /// Well-formed, but not a layout this code handles.
    case unsupported(String)
}

/// Mach-O constants used here. Values are from `<mach-o/loader.h>` and
/// `<mach-o/fat.h>`.
enum MachO {
    static let magic32: UInt32 = 0xfeed_face
    static let magic64: UInt32 = 0xfeed_facf
    /// Fat headers are big-endian; this is the magic read that way.
    static let fatMagic: UInt32 = 0xcafe_babe

    static let cpuTypeARM: UInt32 = 12
    static let cpuTypeARM64: UInt32 = 0x0100_000c
    static let cpuSubtypeARM64E: UInt32 = 2
    static let cpuSubtypeLib64: UInt32 = 0x8000_0000

    static let fileTypeDylib: UInt32 = 6
    static let flagPIE: UInt32 = 0x0020_0000
    static let flagNoReexportedDylibs: UInt32 = 0x0010_0000

    static let headerSize32 = 28
    static let headerSize64 = 32
    static let segmentCommandSize64 = 72
    static let sectionSize64 = 80
    static let dylibCommandSize = 24

    enum Command {
        static let loadDylib: UInt32 = 0xc
        static let idDylib: UInt32 = 0xd
        static let loadDylinker: UInt32 = 0xe
        static let segment64: UInt32 = 0x19
        static let codeSignature: UInt32 = 0x1d
        static let encryptionInfo: UInt32 = 0x21
        static let encryptionInfo64: UInt32 = 0x2c
        static let loadWeakDylib: UInt32 = 0x8000_0018
        static let reexportDylib: UInt32 = 0x8000_001f
        static let loadUpwardDylib: UInt32 = 0x8000_0023
        static let chainedFixups: UInt32 = 0x8000_0034
    }
}

/// Bounds-checked access to the bytes of a Mach-O file.
///
/// Every read and write is checked against the buffer. A malformed or
/// hostile file produces `MachOError.truncated`, never an out-of-bounds
/// access: these files come from apps the user installs.
struct MachOBytes {
    var bytes: [UInt8]

    var count: Int { bytes.count }

    private func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else {
            throw MachOError.truncated
        }
    }

    func uint32(at offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    func uint32BigEndian(at offset: Int) throws -> UInt32 {
        try uint32(at: offset).byteSwapped
    }

    func uint64(at offset: Int) throws -> UInt64 {
        try UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int) throws {
        try check(offset, 4)
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func setUInt32BigEndian(_ value: UInt32, at offset: Int) throws {
        try setUInt32(value.byteSwapped, at: offset)
    }

    mutating func setUInt64(_ value: UInt64, at offset: Int) throws {
        try setUInt32(UInt32(truncatingIfNeeded: value), at: offset)
        try setUInt32(UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
    }

    /// The NUL-terminated string starting at `offset`, read no further than `limit`.
    func cString(at offset: Int, limit: Int) throws -> String {
        try check(offset, 0)
        guard limit <= bytes.count, offset <= limit else { throw MachOError.truncated }
        let end = bytes[offset..<limit].firstIndex(of: 0) ?? limit
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    /// A fixed-width name field such as a segment name: up to 16 bytes, NUL padded.
    func fixedName(at offset: Int) throws -> String {
        try cString(at: offset, limit: offset + 16)
    }

    mutating func zero(_ offset: Int, _ length: Int) throws {
        try check(offset, length)
        for index in offset..<(offset + length) {
            bytes[index] = 0
        }
    }

    /// Writes `string` followed by zeros, filling exactly `length` bytes.
    /// The string must leave room for at least one terminating zero.
    mutating func setCString(_ string: String, at offset: Int, length: Int) throws {
        let utf8 = Array(string.utf8)
        guard utf8.count < length else { throw MachOError.unsupported("name does not fit") }
        try zero(offset, length)
        bytes.replaceSubrange(offset..<(offset + utf8.count), with: utf8)
    }

    /// Moves `length` bytes from `source` to `destination`; the ranges may overlap.
    mutating func move(from source: Int, to destination: Int, length: Int) throws {
        try check(source, length)
        try check(destination, length)
        let chunk = Array(bytes[source..<(source + length)])
        bytes.replaceSubrange(destination..<(destination + length), with: chunk)
    }
}

extension MachOBytes {
    struct Slice: Equatable {
        /// Where the slice's Mach-O header starts in the file.
        var offset: Int
        var is64Bit: Bool
        var cpuType: UInt32
        /// Where this slice's entry sits in the fat header, if the file is fat.
        var fatArchOffset: Int?
    }

    /// The slices of a thin or fat file. Fat entries that are not Mach-O
    /// images are skipped.
    func slices() throws -> [Slice] {
        let magic = try uint32(at: 0)
        if magic == MachO.magic64 || magic == MachO.magic32 {
            return [Slice(
                offset: 0, is64Bit: magic == MachO.magic64, cpuType: try uint32(at: 4), fatArchOffset: nil)]
        }
        guard try uint32BigEndian(at: 0) == MachO.fatMagic else { throw MachOError.notMachO }

        let count = try uint32BigEndian(at: 4)
        // A real fat file has a handful of slices; refuse absurd counts
        // instead of looping over them.
        guard count <= 64 else { throw MachOError.unsupported("too many slices") }

        var slices: [Slice] = []
        for index in 0..<Int(count) {
            // fat_arch: cputype, cpusubtype, offset, size, align (all big-endian).
            let entry = 8 + index * 20
            let offset = Int(try uint32BigEndian(at: entry + 8))
            let sliceMagic = try uint32(at: offset)
            guard sliceMagic == MachO.magic64 || sliceMagic == MachO.magic32 else { continue }
            slices.append(Slice(
                offset: offset,
                is64Bit: sliceMagic == MachO.magic64,
                cpuType: try uint32BigEndian(at: entry),
                fatArchOffset: entry
            ))
        }
        return slices
    }

    struct LoadCommand: Equatable {
        var offset: Int
        var command: UInt32
        var size: Int
    }

    /// The load commands of one slice, each verified to lie inside the
    /// declared command area and the file.
    func loadCommands(of slice: Slice) throws -> [LoadCommand] {
        let headerSize = slice.is64Bit ? MachO.headerSize64 : MachO.headerSize32
        let count = try uint32(at: slice.offset + 16)
        let totalSize = Int(try uint32(at: slice.offset + 20))
        let start = slice.offset + headerSize
        try check(start, totalSize)

        var commands: [LoadCommand] = []
        var cursor = start
        for _ in 0..<count {
            guard cursor + 8 <= start + totalSize else { throw MachOError.truncated }
            let size = Int(try uint32(at: cursor + 4))
            guard size >= 8, cursor + size <= start + totalSize else { throw MachOError.truncated }
            commands.append(LoadCommand(offset: cursor, command: try uint32(at: cursor), size: size))
            cursor += size
        }
        return commands
    }
}
