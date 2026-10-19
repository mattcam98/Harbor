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
    /// Renew whatever is close to expiring. `callback` is where to report
    /// back, when a shortcut asked through x-callback-url.
    case refreshAll(callback: XCallback?)
}

/// Where to report the result of an x-callback-url request.
///
/// Only Shortcuts' own reply addresses are accepted
/// (`shortcuts://x-callback-url/ic-success/<id>` and the like), which do
/// nothing but resume the shortcut waiting for them. Anything else, such as
/// `shortcuts://run-shortcut`, would let a web page use Harbor to open an
/// address of its choosing, so it is ignored.
public struct XCallback: Equatable, Sendable {
    /// `shortcuts-production` is what earlier versions of Shortcuts sent.
    public static let allowedSchemes: Set<String> = ["shortcuts", "shortcuts-production"]
    static let replyActions: Set<String> = ["ic-success", "ic-error", "ic-cancel"]

    /// Whether `url` is one of Shortcuts' reply addresses.
    public static func isReplyAddress(_ url: URL) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), allowedSchemes.contains(scheme),
            components.host?.lowercased() == "x-callback-url",
            components.user == nil, components.password == nil, components.port == nil
        else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.count == 2, let action = parts.first, let id = parts.last else { return false }
        return replyActions.contains(action.lowercased())
            && !id.isEmpty
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    public let success: URL
    public let failure: URL?
    public let cancel: URL?

    public init(success: URL, failure: URL?, cancel: URL?) {
        self.success = success
        self.failure = failure
        self.cancel = cancel
    }

    /// The success address with `values` added to its query.
    public func succeeded(_ values: [String: String]) -> URL {
        Self.adding(values, to: success)
    }

    /// The error address with the message added, as x-callback-url
    /// describes. Falls back to the success address with `status=failed`
    /// for callers that gave none.
    public func failed(_ message: String, values: [String: String] = [:]) -> URL {
        guard let failure else {
            return Self.adding(values.merging(["status": "failed", "message": message]) { $1 }, to: success)
        }
        return Self.adding(values.merging(["errorMessage": message]) { $1 }, to: failure)
    }

    static func adding(_ values: [String: String], to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let added = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = (components.queryItems ?? []) + added
        return components.url ?? url
    }
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

        var action = (components.host ?? "").lowercased()
        if action == "x-callback-url" {
            // harbor://x-callback-url/renew?x-success=…
            action = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
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
        case "refresh", "renew":
            // A reply address that is not Shortcuts' own is dropped, not
            // refused: renewing is harmless, opening the address is not.
            return .refreshAll(callback: try? parameters.callback())
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

    /// The x-callback-url addresses, or `nil` when none were given.
    func callback() throws -> XCallback? {
        func address(_ name: String) throws -> URL? {
            guard let string = try value(name), !string.isEmpty else { return nil }
            guard let url = URL(string: string), XCallback.isReplyAddress(url) else {
                throw DeepLinkError.invalidParameter(name)
            }
            return url
        }
        let success = try address("x-success")
        let failure = try address("x-error")
        let cancel = try address("x-cancel")
        guard let success else {
            if failure != nil || cancel != nil { throw DeepLinkError.missingParameter("x-success") }
            return nil
        }
        return XCallback(success: success, failure: failure, cancel: cancel)
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
