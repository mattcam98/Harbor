import Foundation

/// How much space Harbor takes on the device, and how much of it can be
/// given back without losing anything the user would miss.
public struct StorageReport: Equatable, Sendable {
    /// One app inside Harbor.
    public struct AppUsage: Equatable, Identifiable, Sendable {
        public var app: GuestApp
        /// The app itself.
        public var bundle: Int64
        /// Its documents and settings, in every one of its data containers.
        public var data: Int64
        /// Its `Library/Caches`, which it can make again.
        public var caches: Int64
        /// The data containers the sizes above were counted from.
        public var containers: [String]

        public init(app: GuestApp, bundle: Int64, data: Int64, caches: Int64, containers: [String]) {
            self.app = app
            self.bundle = bundle
            self.data = data
            self.caches = caches
            self.containers = containers
        }

        public var id: String { app.id }
        public var total: Int64 { bundle + data + caches }
    }

    /// Largest first.
    public var apps: [AppUsage]
    /// Data containers that no app in Harbor uses any more.
    public var unusedContainers: [String]
    public var unusedData: Int64
    /// Harbor's temporary folder: what downloads and installs leave when
    /// they are stopped, and the temporary files of apps opened as the
    /// whole app.
    public var temporaryFiles: Int64
    /// Harbor's own `Library/Caches`.
    public var harborCaches: Int64
    /// Everything else: Harbor itself, its settings, the developer disk
    /// images and the container engine's files.
    public var harbor: Int64

    public init(
        apps: [AppUsage],
        unusedContainers: [String],
        unusedData: Int64,
        temporaryFiles: Int64,
        harborCaches: Int64,
        harbor: Int64
    ) {
        self.apps = apps
        self.unusedContainers = unusedContainers
        self.unusedData = unusedData
        self.temporaryFiles = temporaryFiles
        self.harborCaches = harborCaches
        self.harbor = harbor
    }

    public var appBundles: Int64 { apps.reduce(0) { $0 + $1.bundle } }
    /// Data of the apps in Harbor and of those that are gone.
    public var appData: Int64 { apps.reduce(unusedData) { $0 + $1.data } }
    public var caches: Int64 { apps.reduce(harborCaches) { $0 + $1.caches } }
    public var total: Int64 { appBundles + appData + caches + temporaryFiles + harbor }
}

/// Measures the space taken in Harbor's sandbox.
///
/// Sizes are the space files take on disk (allocated, not logical), which is
/// what iOS shows in iPhone Storage. Links are not followed: a guest's `tmp`
/// is a link to the temporary folder of the process it runs in, and is
/// counted there.
public struct StorageInventory: Sendable {
    /// The sandbox. Its `Documents` folder holds the guest library.
    public let home: URL
    /// Places outside the sandbox counted as Harbor's own, such as its app
    /// bundle and its app group.
    public let others: [URL]

    public init(home: URL, others: [URL] = []) {
        self.home = home
        self.others = others
    }

    var library: GuestLibrary {
        GuestLibrary(documents: home.appendingPathComponent("Documents", isDirectory: true), keychainGroupCount: 1)
    }

    public func measure() throws -> StorageReport {
        let library = self.library
        var bundles: [String: Int64] = [:]
        var data: [String: Int64] = [:]
        var caches: [String: Int64] = [:]
        var temporary: Int64 = 0
        var harborCaches: Int64 = 0
        var harbor: Int64 = 0

        let applications = ["Documents"] + GuestLibrary.applicationsPath
        let containers = ["Documents"] + GuestLibrary.containersPath

        try DiskUsage.walk(home) { path, bytes in
            if let folder = path.child(of: applications) {
                bundles[folder, default: 0] += bytes
            } else if let container = path.child(of: containers) {
                if path.dropFirst(containers.count + 1).starts(with: ["Library", "Caches"]), path.count > containers.count + 3 {
                    caches[container, default: 0] += bytes
                } else {
                    data[container, default: 0] += bytes
                }
            } else if path.count > 1, path[0] == "tmp" {
                temporary += bytes
            } else if path.count > 2, path[0] == "Library", path[1] == "Caches" {
                harborCaches += bytes
            } else {
                harbor += bytes
            }
        }
        for other in others {
            try DiskUsage.walk(other) { _, bytes in harbor += bytes }
        }

        var apps: [StorageReport.AppUsage] = []
        for app in try library.apps() {
            let folders = library.containerFolders(of: app)
            let appData: Int64 = folders.reduce(0) { $0 + (data[$1] ?? 0) }
            let appCaches: Int64 = folders.reduce(0) { $0 + (caches[$1] ?? 0) }
            let bundle: Int64 = bundles.removeValue(forKey: app.folderName) ?? 0
            apps.append(StorageReport.AppUsage(
                app: app, bundle: bundle, data: appData, caches: appCaches, containers: folders))
        }
        apps.sort { $0.total != $1.total ? $0.total > $1.total : $0.app.name < $1.app.name }

        // Folders that are not a readable app are left alone, and counted
        // as Harbor's.
        harbor += bundles.values.reduce(0, +)
        let unused = try library.unusedContainers()
        let unusedData: Int64 = unused.reduce(0) { $0 + (data[$1] ?? 0) + (caches[$1] ?? 0) }
        return StorageReport(
            apps: apps,
            unusedContainers: unused,
            unusedData: unusedData,
            temporaryFiles: temporary,
            harborCaches: harborCaches,
            harbor: harbor
        )
    }
}

extension Array where Element == String {
    /// The name of the folder directly inside `parent` that this path is
    /// within, when it is below that folder and not the folder itself.
    fileprivate func child(of parent: [String]) -> String? {
        guard count > parent.count + 1, starts(with: parent) else { return nil }
        return self[parent.count]
    }
}

public enum DiskUsage {
    /// Calls `visit` with the path, relative to `root`, and the size of
    /// every file below it. Links are neither followed nor counted.
    static func walk(_ root: URL, visit: (_ path: [String], _ bytes: Int64) -> Void) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return
        }
        // The path is kept from each entry's depth and name, not from its
        // URL, which can start with another spelling of `root` (`/private`).
        var path: [String] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen % 512 == 0, Task.isCancelled {
                throw CancellationError()
            }
            path.removeLast(Swift.max(0, path.count - (enumerator.level - 1)))
            path.append(url.lastPathComponent)

            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            visit(path, Int64(bytes))
        }
    }

    /// The size of everything below `url`.
    public static func size(of url: URL) throws -> Int64 {
        var total: Int64 = 0
        try walk(url) { _, bytes in total += bytes }
        return total
    }
}

/// Emptying a folder Harbor owns, such as its temporary folder.
public enum FolderContents {
    /// What Harbor's own work leaves in its temporary folder when it is
    /// stopped half way: downloads, imported and unpacked apps, and the
    /// system's partial downloads.
    public static let leftoverPrefixes = ["harbor-", "CFNetworkDownload_"]

    /// Removes what is in `directory`. Links are left: they take no space,
    /// and the container engine puts some there on purpose.
    ///
    /// - Parameters:
    ///   - prefixes: when given, only items whose names start with one of them.
    ///   - before: when given, only items last changed before then, so work
    ///     started since is not touched.
    public static func remove(in directory: URL, prefixes: [String]? = nil, changedBefore before: Date? = nil) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .contentModificationDateKey]
        for item in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if let prefixes, !prefixes.contains(where: item.lastPathComponent.hasPrefix) { continue }
            if let before, let changed = values?.contentModificationDate, changed >= before { continue }
            try? fileManager.removeItem(at: item)
        }
    }
}

extension GuestLibrary {
    /// The folders of the guest library, below `Documents`.
    static let applicationsPath = ["Applications"]
    static let containersPath = ["Data", "Application"]

    /// The data containers the app has, its default one first.
    public func containerFolders(of app: GuestApp) -> [String] {
        let info = try? Self.readPropertyList(bundleURL(of: app).appendingPathComponent("LCAppInfo.plist"))
        return Self.containerFolders(in: info, default: app.defaultContainer)
    }

    static func containerFolders(in engineInfo: [String: Any]?, default first: String?) -> [String] {
        var folders: [String] = []
        let named = (engineInfo?["LCContainers"] as? [[String: Any]])?.compactMap { $0["folderName"] as? String } ?? []
        for folder in [first, engineInfo?["LCDataUUID"] as? String].compactMap({ $0 }) + named
        where Identifier.isPathComponent(folder) && !folders.contains(folder) {
            folders.append(folder)
        }
        return folders
    }

    /// Data containers that no app in the library names: left by an app
    /// removed while keeping its data, or by an install that did not finish.
    ///
    /// Every app folder counts, even one too damaged to list, so that no
    /// app loses its data to this.
    public func unusedContainers() throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: containers.path) else { return [] }

        var used = Set<String>()
        if fileManager.fileExists(atPath: applications.path) {
            for folder in try fileManager.contentsOfDirectory(atPath: applications.path) {
                let infoURL = applications.appendingPathComponent(folder).appendingPathComponent("LCAppInfo.plist")
                used.formUnion(Self.containerFolders(in: try? Self.readPropertyList(infoURL), default: nil))
            }
        }
        return try fileManager.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !used.contains($0) }
            .sorted()
    }

    /// Deletes data containers, with everything in them.
    public func removeContainers(_ folders: [String]) throws {
        let fileManager = FileManager.default
        for folder in folders where Identifier.isPathComponent(folder) {
            let container = containers.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: container.path) {
                try fileManager.removeItem(at: container)
            }
        }
    }

    /// Empties a data container's `Library/Caches`. The folder itself stays,
    /// as apps expect it to be there.
    public func clearCaches(inContainer folder: String) throws {
        guard Identifier.isPathComponent(folder) else { return }
        let fileManager = FileManager.default
        let library = containers.appendingPathComponent(folder).appendingPathComponent("Library", isDirectory: true)
        let caches = library.appendingPathComponent("Caches", isDirectory: true)

        // A guest could make either a link to somewhere else of Harbor's.
        for url in [library, caches] {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true
            else {
                return
            }
        }
        for item in try fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: item)
        }
    }
}
