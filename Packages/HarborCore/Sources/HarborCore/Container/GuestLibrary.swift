import Foundation

/// An app installed inside Harbor's container, to be run in Harbor's process.
public struct GuestApp: Equatable, Identifiable, Sendable {
    /// The app's folder under `Applications`. This is also what the engine
    /// is told to launch.
    public var folderName: String
    public var bundleIdentifier: String
    public var name: String
    public var version: String
    public var executableName: String
    /// The data container used unless another is chosen at launch.
    public var defaultContainer: String
    /// `false` when the executable had no room for the tweak loader's load
    /// command. The app still runs; tweaks and some launch options do not.
    public var tweakLoaderInjected: Bool

    public var id: String { folderName }
}

public enum GuestLibraryError: Error, Equatable, Sendable {
    /// No readable Info.plist with a bundle identifier and executable name.
    case notAnApp
    case missingExecutable
    /// Still FairPlay-encrypted; it cannot run outside the App Store.
    case encrypted
    /// No 64-bit ARM code to run.
    case unsupportedArchitecture
}

/// Guest apps and their data on disk, in the layout LiveContainer's engine
/// reads (pinned at `4dbe0f9`):
///
///     Documents/Applications/<bundle id>.app/        the app, executable patched
///         LCAppInfo.plist                            engine settings for the app
///     Documents/Data/Application/<UUID>/             one data container
///         LCContainerInfo.plist                      engine settings for the container
public struct GuestLibrary: Sendable {
    /// The patch level the engine expects (`currentPatchRev` in LCAppInfo.m).
    static let patchRevision = 7

    public let documents: URL
    /// How many keychain access groups Harbor's entitlements set aside for
    /// guests. Each container is given one, so guests do not share a keychain
    /// with each other or with Harbor.
    public let keychainGroupCount: Int

    public init(documents: URL, keychainGroupCount: Int) {
        self.documents = documents
        self.keychainGroupCount = max(1, keychainGroupCount)
    }

    var applications: URL { documents.appendingPathComponent("Applications", isDirectory: true) }
    var containers: URL { documents.appendingPathComponent("Data/Application", isDirectory: true) }
    var tweaks: URL { documents.appendingPathComponent("Tweaks", isDirectory: true) }

    /// Creates the folders the engine expects to exist when a guest starts.
    ///
    /// A patched guest loads the tweak loader from `Tweaks/TweakLoader.dylib`.
    /// The engine puts a link to its own copy there at every launch, but it
    /// does not create the folder, and without the link the guest fails to
    /// load at all.
    public func prepareForLaunch() throws {
        try FileManager.default.createDirectory(at: tweaks, withIntermediateDirectories: true)
    }

    /// The same, and brings the settings of an app added by an earlier
    /// version of Harbor up to date.
    public func prepareForLaunch(_ app: GuestApp) throws {
        try prepareForLaunch()

        let bundle = bundleURL(of: app)
        let infoURL = bundle.appendingPathComponent("LCAppInfo.plist")
        var engineInfo = try Self.readPropertyList(infoURL)
        guard engineInfo[Self.sdkVersionKey] == nil,
              let version = Self.sdkVersionToReport(forExecutableAt: bundle.appendingPathComponent(app.executableName))
        else {
            return
        }
        engineInfo[Self.sdkVersionKey] = version
        try Self.writePropertyList(engineInfo, to: infoURL)
    }

    // MARK: The SDK a guest was built with

    /// The engine setting that makes iOS treat the process as built with the
    /// guest's SDK, not Harbor's.
    ///
    /// iOS reads the SDK version from the process's main executable, which
    /// is Harbor, built with the newest SDK. A guest built with an older one
    /// would be held to rules it was never written for: on iOS 27 an app
    /// that does not use scenes is stopped at launch if it claims the iOS 27
    /// SDK. LiveContainer turns this on for every app it adds.
    static let sdkVersionKey = "spoofSDKVersion"

    /// Below iOS 11, LiveContainer found UIKit's own compatibility code
    /// crashes, so nothing older is reported.
    static let oldestReportedSDK: UInt32 = 0x000b_0000

    static func sdkVersionToReport(forExecutableAt url: URL) -> Int? {
        guard let version = try? GuestExecutable.sdkVersion(fileAt: url) else { return nil }
        return Int(max(version, oldestReportedSDK))
    }

    public func bundleURL(of app: GuestApp) -> URL {
        applications.appendingPathComponent(app.folderName, isDirectory: true)
    }

    // MARK: Install

    /// Installs an unpacked `.app`. The source is moved into the library.
    /// Installing over an existing app replaces its code and keeps its data.
    public func install(appBundleAt source: URL) throws -> GuestApp {
        let fileManager = FileManager.default
        guard
            let info = try? Self.readPropertyList(source.appendingPathComponent("Info.plist")),
            let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            Identifier.isBundleIdentifier(bundleIdentifier),
            let executableName = info["CFBundleExecutable"] as? String,
            Identifier.isPathComponent(executableName)
        else {
            throw GuestLibraryError.notAnApp
        }

        let executable = source.appendingPathComponent(executableName)
        guard fileManager.fileExists(atPath: executable.path) else {
            throw GuestLibraryError.missingExecutable
        }
        if try GuestExecutable.isEncrypted(fileAt: executable) {
            throw GuestLibraryError.encrypted
        }

        // Writing a new file, not editing in place, also gives it a new
        // inode: the kernel caches code signatures per file and kills a
        // process that maps one whose contents changed underneath it.
        let patched: (file: Data, warnings: GuestExecutable.Warnings)
        do {
            patched = try GuestExecutable.patch(
                Data(contentsOf: executable), name: executableName, injectTweakLoader: true)
        } catch MachOError.unsupported {
            throw GuestLibraryError.unsupportedArchitecture
        }
        try patched.file.write(to: executable, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try Self.fixUpARM64eLibraries(in: source)

        let folderName = "\(bundleIdentifier).app"
        let destination = applications.appendingPathComponent(folderName, isDirectory: true)

        // Keep the containers of an app that is being replaced.
        var engineInfo: [String: Any] = [:]
        if let existing = try? Self.readPropertyList(destination.appendingPathComponent("LCAppInfo.plist")) {
            for key in ["LCDataUUID", "LCContainers"] {
                engineInfo[key] = existing[key]
            }
        }

        let container: String
        if let existing = engineInfo["LCDataUUID"] as? String, Identifier.isPathComponent(existing) {
            container = existing
        } else {
            container = UUID().uuidString
            engineInfo["LCDataUUID"] = container
            engineInfo["LCContainers"] = [["folderName": container, "name": container]]
        }

        let canInject = !patched.warnings.contains(.noSpaceForTweakLoader)
        engineInfo["LCPatchRevision"] = Self.patchRevision
        if !canInject {
            engineInfo["LCTweakLoaderCantInject"] = true
            engineInfo["dontInjectTweakLoader"] = true
        }
        if patched.warnings.contains(.segmentCountMismatch) {
            engineInfo["segCountMismatch"] = true
        }
        if let version = Self.sdkVersionToReport(forExecutableAt: executable) {
            engineInfo[Self.sdkVersionKey] = version
        }
        try Self.writePropertyList(engineInfo, to: source.appendingPathComponent("LCAppInfo.plist"))

        try createContainerIfNeeded(container, bundleIdentifier: bundleIdentifier)
        try prepareForLaunch()

        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)

        return GuestApp(
            folderName: folderName,
            bundleIdentifier: bundleIdentifier,
            name: Self.displayName(from: info, fallback: executableName),
            version: info["CFBundleShortVersionString"] as? String ?? "",
            executableName: executableName,
            defaultContainer: container,
            tweakLoaderInjected: canInject
        )
    }

    // MARK: Listing and removal

    public func apps() throws -> [GuestApp] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: applications.path) else { return [] }

        return try fileManager.contentsOfDirectory(atPath: applications.path)
            .filter { $0.hasSuffix(".app") }
            .sorted()
            .compactMap { folderName in
                let bundle = applications.appendingPathComponent(folderName, isDirectory: true)
                guard
                    let info = try? Self.readPropertyList(bundle.appendingPathComponent("Info.plist")),
                    let engineInfo = try? Self.readPropertyList(bundle.appendingPathComponent("LCAppInfo.plist")),
                    let bundleIdentifier = info["CFBundleIdentifier"] as? String,
                    let executableName = info["CFBundleExecutable"] as? String,
                    let container = engineInfo["LCDataUUID"] as? String
                else {
                    return nil
                }
                return GuestApp(
                    folderName: folderName,
                    bundleIdentifier: bundleIdentifier,
                    name: Self.displayName(from: info, fallback: executableName),
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    executableName: executableName,
                    defaultContainer: container,
                    tweakLoaderInjected: engineInfo["dontInjectTweakLoader"] as? Bool != true
                )
            }
    }

    /// Removes the app. Its data containers go too unless `keepingData`.
    public func remove(_ app: GuestApp, keepingData: Bool = false) throws {
        let fileManager = FileManager.default
        let bundle = bundleURL(of: app)

        if !keepingData,
           let engineInfo = try? Self.readPropertyList(bundle.appendingPathComponent("LCAppInfo.plist")),
           let records = engineInfo["LCContainers"] as? [[String: Any]] {
            for record in records {
                // Folder names come from a file inside the guest's own bundle.
                guard let folder = record["folderName"] as? String, Identifier.isPathComponent(folder) else {
                    continue
                }
                let container = containers.appendingPathComponent(folder, isDirectory: true)
                if fileManager.fileExists(atPath: container.path) {
                    try fileManager.removeItem(at: container)
                }
            }
        }
        if fileManager.fileExists(atPath: bundle.path) {
            try fileManager.removeItem(at: bundle)
        }
    }

    // MARK: Containers

    private func createContainerIfNeeded(_ folder: String, bundleIdentifier: String) throws {
        let fileManager = FileManager.default
        let container = containers.appendingPathComponent(folder, isDirectory: true)
        let infoURL = container.appendingPathComponent("LCContainerInfo.plist")
        guard !fileManager.fileExists(atPath: infoURL.path) else { return }

        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        try Self.writePropertyList([
            "appIdentifier": bundleIdentifier,
            "name": folder,
            "keychainGroupId": try leastUsedKeychainGroup(),
            "isolateAppGroup": false,
            "spoofIdentifierForVendor": false,
        ], to: infoURL)
    }

    /// The keychain group with the fewest containers on it, lowest first.
    func leastUsedKeychainGroup() throws -> Int {
        let fileManager = FileManager.default
        var use = [Int](repeating: 0, count: keychainGroupCount)

        if fileManager.fileExists(atPath: containers.path) {
            for folder in try fileManager.contentsOfDirectory(atPath: containers.path) {
                let infoURL = containers.appendingPathComponent(folder).appendingPathComponent("LCContainerInfo.plist")
                if let info = try? Self.readPropertyList(infoURL),
                   let group = info["keychainGroupId"] as? Int,
                   use.indices.contains(group) {
                    use[group] += 1
                }
            }
        }
        return use.indices.min { use[$0] < use[$1] } ?? 0
    }

    // MARK: Pieces

    /// Fat libraries with an arm64e slice need it marked before the
    /// container's loader accepts them.
    private static func fixUpARM64eLibraries(in bundle: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return }

        for case let url as URL in enumerator {
            let library: URL
            switch url.pathExtension {
            case "dylib":
                library = url
            case "framework":
                let info = try? readPropertyList(url.appendingPathComponent("Info.plist"))
                let name = info?["CFBundleExecutable"] as? String ?? url.deletingPathExtension().lastPathComponent
                guard Identifier.isPathComponent(name) else { continue }
                library = url.appendingPathComponent(name)
            default:
                continue
            }

            // Not every such file is a fat Mach-O; those are left as they are.
            guard
                let original = try? Data(contentsOf: library),
                let fixed = try? GuestExecutable.fixUpARM64eSlices(original),
                fixed != original
            else {
                continue
            }
            let permissions = try? fileManager.attributesOfItem(atPath: library.path)[.posixPermissions]
            try fixed.write(to: library, options: .atomic)
            if let permissions {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: library.path)
            }
        }
    }

    private static func displayName(from info: [String: Any], fallback: String) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String, !name.isEmpty {
                return name
            }
        }
        return fallback
    }

    static func readPropertyList(_ url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw GuestLibraryError.notAnApp
        }
        return dictionary
    }

    static func writePropertyList(_ dictionary: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            .write(to: url, options: .atomic)
    }
}
