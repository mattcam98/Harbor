import Crypto
import Foundation

/// A SHA-256 digest, always exactly 32 bytes.
public struct ContentDigest: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32

    public let bytes: [UInt8]

    /// Parses a 64-character hexadecimal string. Returns `nil` for anything else.
    public init?(hex: String) {
        guard let bytes = Hex.decode(hex), bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public init(hashing data: Data) {
        self.bytes = Array(SHA256.hash(data: data))
    }

    /// Hashes a file without loading it into memory.
    public init(hashingFileAt url: URL, chunkSize: Int = 1 << 20) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        self.bytes = Array(hasher.finalize())
    }

    public var hex: String { Hex.encode(bytes) }
    public var description: String { hex }
}

extension ContentDigest: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let digest = ContentDigest(hex: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a 64-character hexadecimal SHA-256 digest."
            )
        }
        self = digest
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

enum Hex {
    private static let alphabet = Array("0123456789abcdef".utf8)

    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var out = [UInt8]()
        for byte in bytes {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ string: String) -> [UInt8]? {
        let utf8 = Array(string.utf8)
        guard utf8.count.isMultiple(of: 2) else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(utf8.count / 2)
        for index in stride(from: 0, to: utf8.count, by: 2) {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
