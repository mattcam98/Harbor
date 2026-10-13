import Foundation

/// A source the user has added.
public struct SavedSource: Codable, Equatable, Sendable, Identifiable {
    public var url: URL
    /// The name the source gave itself when it was last read.
    public var name: String

    public var id: String { url.absoluteString }

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

public enum SourceListError: Error, Equatable, Sendable {
    /// Not a web address, or not one served over HTTPS.
    case notASecureAddress(String)
}

/// The sources the user has added, kept in one file.
public struct SourceList: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Turns what a user typed or pasted into a source address. A missing
    /// scheme is taken to be HTTPS; plain HTTP is refused, because the
    /// catalogue decides what gets downloaded and run.
    public static func address(from text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, host.contains("."),
              url.user == nil, url.password == nil
        else {
            throw SourceListError.notASecureAddress(text)
        }
        return url
    }

    public func all() throws -> [SavedSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedSource].self, from: Data(contentsOf: fileURL))
    }

    /// Adds a source, or updates the name of one that is already there.
    @discardableResult
    public func save(_ source: SavedSource) throws -> [SavedSource] {
        var sources = try all()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        try write(sources)
        return sources
    }

    @discardableResult
    public func remove(_ source: SavedSource) throws -> [SavedSource] {
        let sources = try all().filter { $0.id != source.id }
        try write(sources)
        return sources
    }

    private func write(_ sources: [SavedSource]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources).write(to: fileURL, options: .atomic)
    }
}
