import Foundation
import Testing

@testable import HarborCore

@Suite struct StorageTests {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-storage-\(UUID().uuidString)", isDirectory: true)

    var library: GuestLibrary {
        GuestLibrary(documents: home.appendingPathComponent("Documents", isDirectory: true), keychainGroupCount: 4)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func write(_ path: String, bytes: Int = 10_000) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
    }

    /// Installs a guest through the library, as Harbor does.
    func install(_ bundleIdentifier: String) throws -> GuestApp {
        let bundle = home.appendingPathComponent("staging-\(UUID().uuidString)/Guest.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "GuestBinary",
            "CFBundleDisplayName": bundleIdentifier,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        try MachOBuilder.executable().build().write(to: bundle.appendingPathComponent("GuestBinary"))
        let app = try library.install(appBundleAt: bundle)
        try FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        return app
    }

    @Test func sortsEveryFileIntoOneCategory() throws {
        defer { cleanUp() }
        let small = try install("com.example.small")
        let large = try install("com.example.large")
        let data = "Documents/Data/Application"
        try write("Documents/Applications/\(large.folderName)/Payload.bin", bytes: 400_000)
        try write("\(data)/\(large.defaultContainer)/Documents/save.dat", bytes: 50_000)
        try write("\(data)/\(large.defaultContainer)/Library/Caches/images/1.png", bytes: 30_000)
        try write("\(data)/\(small.defaultContainer)/Library/Caches/a", bytes: 20_000)
        try write("\(data)/LEFTOVER/Documents/old.dat", bytes: 60_000)
        try write("tmp/harbor-download-1", bytes: 70_000)
        try write("Library/Caches/com.example.harbor/Cache.db", bytes: 80_000)
        try write("Library/Application Support/Harbor/disk-images/DDI.dmg", bytes: 90_000)

        let report = try StorageInventory(home: home).measure()

        #expect(report.apps.map(\.app) == [large, small])
        let first = try #require(report.apps.first)
        #expect(first.bundle >= 400_000)
        #expect(first.data >= 50_000 && first.data < 80_000)
        #expect(first.caches >= 30_000 && first.caches < 40_000)
        #expect(report.apps[1].caches >= 20_000 && report.apps[1].caches < 30_000)
        #expect(report.unusedContainers == ["LEFTOVER"])
        #expect(report.unusedData >= 60_000 && report.unusedData < 70_000)
        #expect(report.temporaryFiles >= 70_000 && report.temporaryFiles < 80_000)
        #expect(report.harborCaches >= 80_000 && report.harborCaches < 90_000)
        #expect(report.harbor >= 90_000)

        // Nothing is counted twice.
        #expect(report.total == (try DiskUsage.size(of: home)))
    }

    @Test func countsEveryContainerAnAppHas() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        let infoURL = library.bundleURL(of: app).appendingPathComponent("LCAppInfo.plist")
        var info = try GuestLibrary.readPropertyList(infoURL)
        info["LCContainers"] = [["folderName": app.defaultContainer], ["folderName": "SECOND"], ["folderName": "../escape"]]
        try GuestLibrary.writePropertyList(info, to: infoURL)
        try write("Documents/Data/Application/SECOND/Documents/x", bytes: 40_000)

        #expect(library.containerFolders(of: app) == [app.defaultContainer, "SECOND"])
        let report = try StorageInventory(home: home).measure()
        #expect(report.apps.first?.data ?? 0 >= 40_000)
        #expect(report.unusedContainers.isEmpty)
    }

    @Test func linksAreNotFollowed() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        try write("tmp/big", bytes: 100_000)
        // The engine links a guest's tmp to the process's temporary folder.
        let link = home.appendingPathComponent("Documents/Data/Application/\(app.defaultContainer)/tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("tmp"))

        let report = try StorageInventory(home: home).measure()
        #expect(report.apps.first?.data ?? .max < 100_000)
        #expect(report.temporaryFiles >= 100_000)
    }

    @Test func anAppThatCannotBeListedKeepsItsData() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        try FileManager.default.removeItem(at: library.bundleURL(of: app).appendingPathComponent("Info.plist"))

        #expect(try library.apps().isEmpty)
        #expect(try library.unusedContainers().isEmpty)
    }

    @Test func removesOnlyTheContainersNamed() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        try write("Documents/Data/Application/LEFTOVER/Documents/old.dat")
        try write("Documents/keep.txt")

        try library.removeContainers(try library.unusedContainers() + ["..", "../Applications"])

        #expect(!exists("Documents/Data/Application/LEFTOVER"))
        #expect(exists("Documents/Data/Application/\(app.defaultContainer)"))
        #expect(exists("Documents/Applications/\(app.folderName)"))
        #expect(exists("Documents/keep.txt"))
    }

    @Test func clearingCachesKeepsDataAndTheFolder() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        let container = "Documents/Data/Application/\(app.defaultContainer)"
        try write("\(container)/Library/Caches/a/b.bin")
        try write("\(container)/Library/Caches/.hidden")
        try write("\(container)/Library/Preferences/settings.plist")
        try write("\(container)/Documents/save.dat")

        try library.clearCaches(inContainer: app.defaultContainer)

        let left = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("\(container)/Library/Caches").path)
        #expect(left.isEmpty)
        #expect(exists("\(container)/Library/Preferences/settings.plist"))
        #expect(exists("\(container)/Documents/save.dat"))
    }

    @Test func clearingCachesDoesNotFollowALinkOutOfTheContainer() throws {
        defer { cleanUp() }
        let app = try install("com.example.guest")
        try write("Library/Application Support/Harbor/apps.json")
        let library = home.appendingPathComponent("Documents/Data/Application/\(app.defaultContainer)/Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Caches"),
            withDestinationURL: home.appendingPathComponent("Library/Application Support/Harbor"))

        try self.library.clearCaches(inContainer: app.defaultContainer)

        #expect(exists("Library/Application Support/Harbor/apps.json"))
    }

    @Test func clearsTemporaryFilesButNotLinks() throws {
        defer { cleanUp() }
        let tmp = home.appendingPathComponent("tmp", isDirectory: true)
        try write("tmp/harbor-guest-1/Payload/App.app/App")
        try write("tmp/guest-scratch")
        let target = try write("Documents/Inbox/file")
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("com.example.guest-Inbox"), withDestinationURL: target.deletingLastPathComponent())

        try FolderContents.remove(in: tmp)

        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path) == ["com.example.guest-Inbox"])
        #expect(exists("Documents/Inbox/file"))
    }

    @Test func sweepsOnlyHarborsOwnLeftoversFromBeforeLaunch() throws {
        defer { cleanUp() }
        let tmp = home.appendingPathComponent("tmp", isDirectory: true)
        let old = Date(timeIntervalSinceNow: -3600)
        for name in ["harbor-download-old", "CFNetworkDownload_abc.tmp", "a-guests-file"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: try write("tmp/\(name)").path)
        }
        try write("tmp/harbor-work")
        let launch = Date(timeIntervalSinceNow: -60)

        try FolderContents.remove(in: tmp, prefixes: FolderContents.leftoverPrefixes, changedBefore: launch)

        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted() == ["a-guests-file", "harbor-work"])
    }
}
