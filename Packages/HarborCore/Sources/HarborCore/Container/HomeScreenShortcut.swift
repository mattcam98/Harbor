import Foundation

/// The URLs the container engine acts on.
///
/// The format is the engine's, not Harbor's choice: while a guest is running
/// it is the engine's code inside that guest which receives URLs sent to
/// Harbor, and this is the only form it understands. Anything else with
/// Harbor's scheme is dropped there.
public enum EngineURL {
    static let launchAction = "livecontainer-launch"
    static let folderParameter = "bundle-name"
    static let containerParameter = "container-folder-name"
    /// The folder name that means Harbor's own interface.
    static let hostFolderName = "ui"

    /// Opens a guest, or switches to it from whichever guest is running.
    public static func launch(scheme: String, folderName: String, container: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = launchAction
        components.queryItems = [URLQueryItem(name: folderParameter, value: folderName)]
        if let container {
            components.queryItems?.append(URLQueryItem(name: containerParameter, value: container))
        }
        // The parts are a scheme, a fixed word and validated names.
        return components.url!
    }

    /// Leaves the running guest and shows Harbor's own interface.
    public static func showHost(scheme: String) -> URL {
        launch(scheme: scheme, folderName: hostFolderName)
    }
}

/// A Home Screen icon that opens one app inside Harbor.
///
/// iOS has no public way for an app to add icons for things inside it. An
/// App Clip needs App Store distribution and a domain, which a sideloaded
/// app has neither of. What does work is a web clip: a bookmark with its own
/// name and icon, installed through a configuration profile the user
/// approves in Settings. Tapping it opens a URL, and that URL is Harbor's.
public struct HomeScreenShortcut: Equatable, Sendable {
    public var name: String
    /// The guest's folder under `Documents/Applications`.
    public var folderName: String
    public var bundleIdentifier: String
    /// A particular data container, or `nil` for the app's default.
    public var container: String?
    public var hostScheme: String
    public var hostBundleIdentifier: String

    public init(
        app: GuestApp,
        container: String? = nil,
        hostScheme: String,
        hostBundleIdentifier: String
    ) {
        name = app.name
        folderName = app.folderName
        bundleIdentifier = app.bundleIdentifier
        self.container = container
        self.hostScheme = hostScheme
        self.hostBundleIdentifier = hostBundleIdentifier
    }

    public var url: URL {
        EngineURL.launch(scheme: hostScheme, folderName: folderName, container: container)
    }

    /// Identifies the profile to iOS. Installing a shortcut for the same app
    /// and container again replaces the old one instead of adding a second.
    public var profileIdentifier: String {
        let suffix = container.map { ".\($0)" } ?? ""
        return "\(hostBundleIdentifier).shortcut.\(bundleIdentifier)\(suffix)"
    }

    /// The configuration profile, as an XML property list.
    ///
    /// - Parameter icon: a PNG. Without one iOS draws a blank icon with the
    ///   first letter of the name.
    public func profile(icon: Data?) throws -> Data {
        var clip: [String: Any] = [
            "PayloadType": "com.apple.webClip.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(profileIdentifier).clip",
            "PayloadUUID": Self.stableUUID(for: "\(profileIdentifier).clip"),
            "PayloadDisplayName": name,
            "PayloadDescription": "Opens \(name) inside Harbor.",
            "PayloadOrganization": "Harbor",
            "Label": name,
            "URL": url.absoluteString,
            // No browser bars: the tap goes straight to Harbor.
            "FullScreen": true,
            "IgnoreManifestScope": true,
            "IsRemovable": true,
            // The icon is used as drawn.
            "Precomposed": true,
        ]
        clip["Icon"] = icon

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": profileIdentifier,
            "PayloadUUID": Self.stableUUID(for: profileIdentifier),
            "PayloadDisplayName": "\(name) in Harbor",
            "PayloadDescription": "Adds a Home Screen icon that opens \(name) inside Harbor. It changes no settings.",
            "PayloadOrganization": "Harbor",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [clip],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A UUID that is always the same for the same text, so a profile made
    /// twice is the same profile.
    static func stableUUID(for text: String) -> String {
        var bytes = Array(ContentDigest(hashing: Data(text.utf8)).bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50  // a name-based UUID
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = Hex.encode(bytes).uppercased()
        func part(_ from: Int, _ length: Int) -> Substring {
            let start = hex.index(hex.startIndex, offsetBy: from)
            return hex[start..<hex.index(start, offsetBy: length)]
        }
        return "\(part(0, 8))-\(part(8, 4))-\(part(12, 4))-\(part(16, 4))-\(part(20, 12))"
    }
}
