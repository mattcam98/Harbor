import Foundation

/// Reads and rewrites a guest app's executable so the container can load it.
///
/// iOS only starts an executable as a new process. To run an app inside
/// Harbor's process its main binary has to be loadable as a library, which
/// is a matter of a few header fields and load commands. This is a port of
/// LiveContainer's `LCPatchExecSlice` (LCMachOUtils.m at `4dbe0f9`), with the
/// same output for well-formed input and bounds checks on everything read
/// from the file.
public enum GuestExecutable {
    /// Things the patcher could not do. The file is still written.
    public struct Warnings: OptionSet, Equatable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// No room in the header for the tweak loader's load command.
        public static let noSpaceForTweakLoader = Warnings(rawValue: 1 << 0)
        /// The chained-fixups segment count disagrees with the load commands.
        public static let segmentCountMismatch = Warnings(rawValue: 1 << 1)
    }

    /// Loaded from the guest's bundle; it brings in tweaks before the app starts.
    static let tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib"
    /// A harmless library named in the placeholder when tweaks are off.
    static let placeholderLibraryPath = "/usr/lib/libc++.1.dylib"
    /// Not a real load command: dyld skips what it does not recognise. Marks
    /// the slot kept for the tweak loader while it is switched off.
    static let placeholderCommand: UInt32 = 0x114514
    /// Marks a duplicate library load that has been neutralised.
    static let neutralisedCommand: UInt32 = 0x114515
    /// The size of the tweak loader's load command.
    static let tweakLoaderCommandSize = 0x48

    /// `true` when any slice is still FairPlay-encrypted, as apps taken
    /// straight from the App Store are. Such an app cannot run sideloaded,
    /// whatever it is signed with.
    public static func isEncrypted(_ file: Data) throws -> Bool {
        try isEncrypted(MachOBytes(bytes: Array(file)))
    }

    /// The same check on a file, reading only its headers. An app's main
    /// executable can be hundreds of megabytes; none of that is loaded.
    public static func isEncrypted(fileAt url: URL) throws -> Bool {
        for slice in try sliceHeaders(ofFileAt: url) {
            if try isEncrypted(slice.headers) {
                return true
            }
        }
        return false
    }

    /// Whether the file holds 64-bit Mach-O code, thin or fat. Anything that
    /// is not Mach-O at all is simply `false`.
    public static func is64BitMachO(fileAt url: URL) -> Bool {
        guard let slices = try? sliceHeaders(ofFileAt: url) else { return false }
        return slices.contains { (try? $0.headers.uint32(at: 0)) == MachO.magic64 }
    }

    /// Where an executable's code signature sits in its file.
    public struct SignatureLocation: Equatable, Sendable {
        /// Start of the 64-bit ARM slice in the file; 0 for a thin file.
        public var sliceOffset: Int
        /// Start of the signature, relative to the slice.
        public var offset: Int
        public var size: Int
    }

    /// The signature of the file's 64-bit ARM slice, or `nil` if it has none.
    public static func signatureLocation(fileAt url: URL) throws -> SignatureLocation? {
        for slice in try sliceHeaders(ofFileAt: url) {
            let headers = slice.headers
            guard
                try headers.uint32(at: 0) == MachO.magic64,
                try headers.uint32(at: 4) == MachO.cpuTypeARM64,
                let thin = try headers.slices().first
            else {
                continue
            }
            for command in try headers.loadCommands(of: thin) where command.command == MachO.Command.codeSignature {
                // linkedit_data_command: cmd, cmdsize, dataoff, datasize.
                guard command.size >= 16 else { throw MachOError.truncated }
                return SignatureLocation(
                    sliceOffset: slice.offset,
                    offset: Int(try headers.uint32(at: command.offset + 8)),
                    size: Int(try headers.uint32(at: command.offset + 12))
                )
            }
            return nil
        }
        return nil
    }

    /// The header and load commands of each slice in a file, and nothing else.
    private static func sliceHeaders(ofFileAt url: URL) throws -> [(offset: Int, headers: MachOBytes)] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        func read(at offset: Int, count: Int) throws -> MachOBytes {
            try handle.seek(toOffset: UInt64(offset))
            return MachOBytes(bytes: Array(try handle.read(upToCount: count) ?? Data()))
        }

        // Enough for a thin header, or a fat header with the most slices accepted.
        let head = try read(at: 0, count: 8 + 64 * 20)
        let magic = try head.uint32(at: 0)

        var sliceOffsets: [Int] = []
        if magic == MachO.magic64 || magic == MachO.magic32 {
            sliceOffsets = [0]
        } else if try head.uint32BigEndian(at: 0) == MachO.fatMagic {
            let count = try head.uint32BigEndian(at: 4)
            guard count <= 64 else { throw MachOError.unsupported("too many slices") }
            sliceOffsets = try (0..<Int(count)).map { Int(try head.uint32BigEndian(at: 8 + $0 * 20 + 8)) }
        } else {
            throw MachOError.notMachO
        }

        var slices: [(offset: Int, headers: MachOBytes)] = []
        for offset in sliceOffsets {
            let header = try read(at: offset, count: MachO.headerSize64)
            let sliceMagic = try header.uint32(at: 0)
            guard sliceMagic == MachO.magic64 || sliceMagic == MachO.magic32 else { continue }

            // Real command areas are a few kilobytes. Refuse to allocate
            // whatever a hostile header asks for.
            let commandsSize = Int(try header.uint32(at: 20))
            guard commandsSize <= 1 << 20 else { throw MachOError.unsupported("load commands too large") }

            slices.append((offset, try read(at: offset, count: MachO.headerSize64 + commandsSize)))
        }
        return slices
    }

    private static func isEncrypted(_ bytes: MachOBytes) throws -> Bool {
        for slice in try bytes.slices() {
            for command in try bytes.loadCommands(of: slice)
            where command.command == MachO.Command.encryptionInfo
                || command.command == MachO.Command.encryptionInfo64 {
                // encryption_info_command: cmd, cmdsize, cryptoff, cryptsize, cryptid.
                guard command.size >= 20 else { throw MachOError.truncated }
                if try bytes.uint32(at: command.offset + 16) != 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Turns an executable into a loadable library, in every 64-bit ARM slice.
    ///
    /// - Parameters:
    ///   - name: the executable's file name, recorded as the library's identity.
    ///   - injectTweakLoader: load the tweak loader, or keep its slot empty.
    public static func patch(
        _ file: Data,
        name: String,
        injectTweakLoader: Bool
    ) throws -> (file: Data, warnings: Warnings) {
        var bytes = MachOBytes(bytes: Array(file))
        var warnings: Warnings = []

        let slices = try bytes.slices().filter { $0.is64Bit && $0.cpuType == MachO.cpuTypeARM64 }
        guard !slices.isEmpty else { throw MachOError.unsupported("no 64-bit ARM slice") }

        for slice in slices {
            warnings.formUnion(
                try patch(slice: slice, in: &bytes, name: name, injectTweakLoader: injectTweakLoader))
        }
        return (Data(bytes.bytes), warnings)
    }

    /// Marks arm64e slices of a fat library as `LIB64`, in both the slice
    /// header and the fat header, as the container's loader expects.
    public static func fixUpARM64eSlices(_ file: Data) throws -> Data {
        var bytes = MachOBytes(bytes: Array(file))
        for slice in try bytes.slices() {
            guard let fatArchOffset = slice.fatArchOffset, slice.is64Bit, slice.cpuType == MachO.cpuTypeARM64 else {
                continue
            }
            guard try bytes.uint32BigEndian(at: fatArchOffset + 4) == MachO.cpuSubtypeARM64E else { continue }

            let marked = try bytes.uint32(at: slice.offset + 8) | MachO.cpuSubtypeLib64
            try bytes.setUInt32(marked, at: slice.offset + 8)
            try bytes.setUInt32BigEndian(marked, at: fatArchOffset + 4)
            // The original stops at the first such slice.
            break
        }
        return Data(bytes.bytes)
    }

    // MARK: One slice

    private static func patch(
        slice: MachOBytes.Slice,
        in bytes: inout MachOBytes,
        name: String,
        injectTweakLoader: Bool
    ) throws -> Warnings {
        let base = slice.offset
        let commandsStart = base + MachO.headerSize64
        var warnings: Warnings = []

        // An executable becomes a library.
        try bytes.setUInt32(MachO.fileTypeDylib, at: base + 12)
        let flags = try bytes.uint32(at: base + 24)
        try bytes.setUInt32((flags | MachO.flagNoReexportedDylibs) & ~MachO.flagPIE, at: base + 24)

        var commands = try bytes.loadCommands(of: slice)
        guard let first = commands.first,
              first.command == MachO.Command.segment64 || first.command == MachO.Command.idDylib
        else {
            throw MachOError.unsupported("unexpected first load command")
        }

        // __PAGEZERO reserves the low 4 GB of a process. A library does not
        // get that: shrink it to one page just below 4 GB.
        if first.command == MachO.Command.segment64 {
            guard first.size >= MachO.segmentCommandSize64 else { throw MachOError.truncated }
            if try bytes.uint64(at: first.offset + 24) == 0 {
                try bytes.setUInt64(0x1_0000_0000 - 0x4000, at: first.offset + 24)
                try bytes.setUInt64(0x4000, at: first.offset + 32)
            }
        }

        // Survey the load commands.
        var hasLibraryIdentity = false
        var hasCodeSignature = false
        var loaderSlot: MachOBytes.LoadCommand?
        var dylinker: MachOBytes.LoadCommand?
        var segmentCount: UInt32 = 0
        var textSectionOffset = 0

        for command in commands {
            switch command.command {
            case MachO.Command.idDylib:
                hasLibraryIdentity = true

            case MachO.Command.loadDylib:
                if try libraryPath(of: command, in: bytes).hasPrefix(tweakLoaderPath) {
                    loaderSlot = command
                }

            case placeholderCommand:
                loaderSlot = command

            case MachO.Command.segment64:
                guard command.size >= MachO.segmentCommandSize64 else { throw MachOError.truncated }
                segmentCount += 1
                if try bytes.fixedName(at: command.offset + 8) == "__TEXT" {
                    let sectionCount = Int(try bytes.uint32(at: command.offset + 64))
                    guard MachO.segmentCommandSize64 + sectionCount * MachO.sectionSize64 <= command.size else {
                        throw MachOError.truncated
                    }
                    for index in 0..<sectionCount {
                        let section = command.offset + MachO.segmentCommandSize64 + index * MachO.sectionSize64
                        if try bytes.fixedName(at: section) == "__text" {
                            textSectionOffset = Int(try bytes.uint32(at: section + 48))
                        }
                    }
                }

            case MachO.Command.codeSignature:
                hasCodeSignature = true

            case MachO.Command.loadDylinker:
                dylinker = command

            case MachO.Command.chainedFixups:
                if segmentCount != (try chainedFixupsSegmentCount(command, base: base, in: bytes)) {
                    warnings.insert(.segmentCountMismatch)
                }

            default:
                break
            }
        }

        // New commands go in the padding between the last command and the
        // first code. Leave room for a signature command if there is none.
        let commandsEnd = commandsStart + Int(try bytes.uint32(at: base + 20))
        var freeSpace = (base + textSectionOffset) - commandsEnd
        if !hasCodeSignature {
            freeSpace -= 0x10
        }

        // Give the library an identity.
        let identitySize = MachO.dylibCommandSize + roundedUp(name.utf8.count + 1)
        if !hasLibraryIdentity {
            if freeSpace >= identitySize {
                freeSpace -= identitySize
                try insertLibraryCommand(
                    MachO.Command.idDylib, path: name, atFront: true, base: base, in: &bytes)
                // Everything after the header moved; find the commands again.
                commands = try bytes.loadCommands(of: slice)
                loaderSlot = try commands.first { command in
                    try command.command == placeholderCommand
                        || (command.command == MachO.Command.loadDylib
                            && libraryPath(of: command, in: bytes).hasPrefix(tweakLoaderPath))
                }
            } else if let dylinker {
                // No room: a library has no use for LC_LOAD_DYLINKER, so its
                // space is taken over. The name is cut to what fits.
                try replaceWithLibraryIdentity(dylinker, name: name, in: &bytes)
            }
        }

        // Point the loader slot at the tweak loader, or park it.
        let slotCommand = injectTweakLoader ? MachO.Command.loadDylib : placeholderCommand
        let slotPath = injectTweakLoader ? tweakLoaderPath : placeholderLibraryPath
        if let loaderSlot {
            let nameOffset = Int(try bytes.uint32(at: loaderSlot.offset + 8))
            let room = loaderSlot.size - nameOffset
            if nameOffset >= MachO.dylibCommandSize, slotPath.utf8.count < room {
                try bytes.setUInt32(slotCommand, at: loaderSlot.offset)
                try bytes.setCString(slotPath, at: loaderSlot.offset + nameOffset, length: room)
            } else {
                warnings.insert(.noSpaceForTweakLoader)
            }
        } else if freeSpace >= tweakLoaderCommandSize {
            // Always the tweak loader's size, even when parked, so the slot
            // can be switched on later. (The original sizes a parked slot to
            // the shorter placeholder path and then overruns it.)
            try insertLibraryCommand(
                slotCommand, path: slotPath, size: tweakLoaderCommandSize,
                atFront: false, base: base, in: &bytes)
        } else {
            warnings.insert(.noSpaceForTweakLoader)
        }

        // dyld refuses an image that names the same library twice, which
        // careless tweak injection produces. Neutralise the repeats.
        var seenLibraries = Set<String>()
        for command in try bytes.loadCommands(of: slice) {
            switch command.command {
            case MachO.Command.loadDylib, MachO.Command.loadWeakDylib,
                 MachO.Command.reexportDylib, MachO.Command.loadUpwardDylib:
                let path = try libraryPath(of: command, in: bytes)
                if !seenLibraries.insert(path).inserted {
                    try bytes.setUInt32(neutralisedCommand, at: command.offset)
                }
            default:
                break
            }
        }

        return warnings
    }

    // MARK: Pieces

    private static func roundedUp(_ value: Int, to multiple: Int = 8) -> Int {
        (value + multiple - 1) & ~(multiple - 1)
    }

    private static func libraryPath(of command: MachOBytes.LoadCommand, in bytes: MachOBytes) throws -> String {
        // dylib_command: cmd, cmdsize, name offset, timestamp, current version, compatibility version.
        guard command.size >= MachO.dylibCommandSize else { throw MachOError.truncated }
        let nameOffset = Int(try bytes.uint32(at: command.offset + 8))
        guard nameOffset <= command.size else { throw MachOError.truncated }
        return try bytes.cString(at: command.offset + nameOffset, limit: command.offset + command.size)
    }

    private static func writeLibraryFields(at offset: Int, in bytes: inout MachOBytes) throws {
        try bytes.setUInt32(UInt32(MachO.dylibCommandSize), at: offset + 8)  // name offset
        try bytes.setUInt32(2, at: offset + 12)  // timestamp
        try bytes.setUInt32(0x10000, at: offset + 16)  // current version 1.0.0
        try bytes.setUInt32(0x10000, at: offset + 20)  // compatibility version 1.0.0
    }

    /// Adds a library command at the front of the command list, as dylibify
    /// does (some games break otherwise), or at the end.
    private static func insertLibraryCommand(
        _ command: UInt32,
        path: String,
        size requestedSize: Int? = nil,
        atFront: Bool,
        base: Int,
        in bytes: inout MachOBytes
    ) throws {
        let commandsStart = base + MachO.headerSize64
        let existingSize = Int(try bytes.uint32(at: base + 20))
        let size = requestedSize ?? MachO.dylibCommandSize + roundedUp(path.utf8.count + 1)
        let nameLength = size - MachO.dylibCommandSize

        let offset: Int
        if atFront {
            try bytes.move(from: commandsStart, to: commandsStart + size, length: existingSize)
            offset = commandsStart
        } else {
            offset = commandsStart + existingSize
        }

        try bytes.zero(offset, size)
        try bytes.setUInt32(command, at: offset)
        try bytes.setUInt32(UInt32(size), at: offset + 4)
        try writeLibraryFields(at: offset, in: &bytes)
        try bytes.setCString(path, at: offset + MachO.dylibCommandSize, length: nameLength)

        try bytes.setUInt32(try bytes.uint32(at: base + 16) + 1, at: base + 16)
        try bytes.setUInt32(UInt32(existingSize + size), at: base + 20)
    }

    private static func replaceWithLibraryIdentity(
        _ command: MachOBytes.LoadCommand,
        name: String,
        in bytes: inout MachOBytes
    ) throws {
        let room = command.size - MachO.dylibCommandSize
        guard room > 0 else { return }

        try bytes.setUInt32(MachO.Command.idDylib, at: command.offset)
        try writeLibraryFields(at: command.offset, in: &bytes)
        let fitting = String(decoding: name.utf8.prefix(room - 1), as: UTF8.self)
        try bytes.setCString(fitting, at: command.offset + MachO.dylibCommandSize, length: room)
    }

    /// The number of segments the chained-fixups data describes, or 0 when
    /// it carries none.
    private static func chainedFixupsSegmentCount(
        _ command: MachOBytes.LoadCommand,
        base: Int,
        in bytes: MachOBytes
    ) throws -> UInt32 {
        // linkedit_data_command: cmd, cmdsize, dataoff, datasize.
        guard command.size >= 16 else { throw MachOError.truncated }
        let dataOffset = Int(try bytes.uint32(at: command.offset + 8))
        let dataSize = Int(try bytes.uint32(at: command.offset + 12))
        // dyld_chained_fixups_header is 28 bytes; starts_offset is its second field.
        guard dataOffset != 0, dataSize >= 28 else { return 0 }

        let startsOffset = Int(try bytes.uint32(at: base + dataOffset + 4))
        // dyld_chained_starts_in_image begins with seg_count and one offset.
        guard startsOffset != 0, startsOffset + 8 <= dataSize else { return 0 }
        return try bytes.uint32(at: base + dataOffset + startsOffset)
    }
}
