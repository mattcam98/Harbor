import Foundation

/// Everything another app, a web page or a shortcut can ask Harbor to do.
///
/// There is no route that returns a secret. The pairing record and the signing
/// identity never leave through a URL.
public enum DeepLink: Equatable, Sendable {
    case installApp(from: URL)
    case addSource(URL)
    case launchApp(bundleIdentifier: String, container: String?)
    /// Leave whatever is running and show Harbor's own interface.
    case showHarbor
    case enableJIT(bundleIdentifier: String)
    case refreshAll
}

public enum DeepLinkConfirmation: Equatable, Sendable {
    /// Safe to perform immediately.
    case notRequired
    /// The user must approve after seeing what will happen and where the
    /// request points.
    case required
}

extension DeepLink {
    public var confirmation: DeepLinkConfirmation {
        switch self {
        // These fetch or trust remote content, or change a process's security state.
        case .installApp, .addSource, .enableJIT: .required
        // Launching an installed app and refreshing are what tapping in the UI does.
        case .launchApp, .showHarbor, .refreshAll: .notRequired
        }
    }
}

public enum DeepLinkError: Error, Equatable, Sendable {
    case unsupportedScheme
    case unknownAction(String)
    case missingParameter(String)
    case invalidParameter(String)
    /// Remote content must be fetched over HTTPS.
    case insecureURL
    /// The action would hand a secret to the caller. Harbor does not do that.
    case secretExportRefused(String)
}

public struct DeepLinkRouter: Sendable {
    public let scheme: String

    /// Actions that other sideloading tools expose and Harbor deliberately does not.
    static let refusedActions: Set<String> = ["pairing", "certificate"]

    public init(scheme: String = "harbor") {
        self.scheme = scheme
    }

    public func route(_ url: URL) throws -> DeepLink {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme
        else {
            throw DeepLinkError.unsupportedScheme
        }

        let action = (components.host ?? "").lowercased()
        let parameters = Parameters(components.queryItems ?? [])

        if Self.refusedActions.contains(action) {
            throw DeepLinkError.secretExportRefused(action)
        }

        switch action {
        case "install":
            return .installApp(from: try parameters.secureURL("url"))
        case "source":
            return .addSource(try parameters.secureURL("url"))
        case "launch":
            return .launchApp(
                bundleIdentifier: try parameters.bundleIdentifier("id"),
                container: try parameters.optionalName("container")
            )
        case EngineURL.launchAction:
            // The form Home Screen shortcuts use, because it is the one the
            // container engine also understands while a guest is running.
            let folder = try parameters.requiredName(EngineURL.folderParameter)
            if folder == EngineURL.hostFolderName {
                return .showHarbor
            }
            guard folder.hasSuffix(".app"), Identifier.isBundleIdentifier(String(folder.dropLast(4))) else {
                throw DeepLinkError.invalidParameter(EngineURL.folderParameter)
            }
            return .launchApp(
                bundleIdentifier: String(folder.dropLast(4)),
                container: try parameters.optionalName(EngineURL.containerParameter)
            )
        case "jit":
            return .enableJIT(bundleIdentifier: try parameters.bundleIdentifier("id"))
        case "refresh":
            return .refreshAll
        default:
            throw DeepLinkError.unknownAction(action)
        }
    }
}

private struct Parameters {
    private let items: [URLQueryItem]

    init(_ items: [URLQueryItem]) {
        self.items = items
    }

    /// A parameter given more than once is ambiguous, so it is rejected.
    private func value(_ name: String) throws -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count <= 1 else { throw DeepLinkError.invalidParameter(name) }
        return matches.first?.value
    }

    private func required(_ name: String) throws -> String {
        guard let value = try value(name), !value.isEmpty else {
            throw DeepLinkError.missingParameter(name)
        }
        return value
    }

    func secureURL(_ name: String) throws -> URL {
        let string = try required(name)
        guard
            let url = URL(string: string),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty
        else {
            throw DeepLinkError.invalidParameter(name)
        }
        guard components.scheme?.lowercased() == "https" else { throw DeepLinkError.insecureURL }
        // Credentials embedded in a URL are a classic way to disguise the real host.
        guard components.user == nil, components.password == nil else {
            throw DeepLinkError.invalidParameter(name)
        }
        return url
    }

    func bundleIdentifier(_ name: String) throws -> String {
        let value = try required(name)
        guard Identifier.isBundleIdentifier(value) else { throw DeepLinkError.invalidParameter(name) }
        return value
    }

    func requiredName(_ name: String) throws -> String {
        let value = try required(name)
        guard Identifier.isPathComponent(value) else { throw DeepLinkError.invalidParameter(name) }
        return value
    }

    /// A single path component: no separators, no traversal.
    func optionalName(_ name: String) throws -> String? {
        guard let value = try value(name) else { return nil }
        guard Identifier.isPathComponent(value) else { throw DeepLinkError.invalidParameter(name) }
        return value
    }
}

enum Identifier {
    /// Letters, digits, hyphens and dots; no empty segments.
    static func isBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 155 else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "-"):
                    true
                default:
                    false
                }
            }
        }
    }

    static func isPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255 else { return false }
        return !value.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
    }
}
