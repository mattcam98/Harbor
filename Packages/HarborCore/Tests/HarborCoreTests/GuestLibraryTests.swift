import Foundation
import Testing

@testable import HarborCore

@Suite struct GuestLibraryTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("harbor-guests-\(UUID().uuidString)", isDirectory: true)

    var library: GuestLibrary {
        GuestLibrary(documents: root.appendingPathComponent("Documents", isDirectory: true), keychainGroupCount: 4)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an unpacked app to a staging folder, as unzipping an IPA would.
    func stage(
        bundleIdentifier: String = "com.example.guest",
        name: String? = "Guest",
        executable: Data? = MachOBuilder.executable().build(),
        extraFiles: [String: Data] = [:]
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundle = root.appendingPathComponent("staging-\(UUID().uuidString)/Guest.app", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "GuestBinary",
            "CFBundleShortVersionString": "2.5",
        ]
        info["CFBundleDisplayName"] = name
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Info.plist"))
        try executable?.write(to: bundle.appendingPathComponent("GuestBinary"))

        for (path, data) in extraFiles {
            let url = bundle.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return bundle
    }

    func plist(_ url: URL) throws -> [String: Any] {
        try GuestLibrary.readPropertyList(url)
    }

    @Test func installsAnAppInTheLayoutTheEngineReads() throws {
        defer { cleanUp() }
        let source = try stage()

        let app = try library.install(appBundleAt: source)

        #expect(app.folderName == "com.example.guest.app")
        #expect(app.bundleIdentifier == "com.example.guest")
        #expect(app.name == "Guest")
        #expect(app.version == "2.5")
        #expect(app.tweakLoaderInjected)
        #expect(UUID(uuidString: app.defaultContainer) != nil)

        // Moved, not copied.
        let bundle = library.bundleURL(of: app)
        #expect(bundle.path.hasSuffix("Documents/Applications/com.example.guest.app")
            || bundle.path.hasSuffix("Documents\\Applications\\com.example.guest.app"))
        #expect(!FileManager.default.fileExists(atPath: source.path))

        // The executable is now a loadable library carrying the tweak loader.
        let executable = try Inspection(Data(contentsOf: bundle.appendingPathComponent("GuestBinary")))
        #expect(try executable.fileType == 6)
        #expect(try executable.libraryPath(executable.commands[0]) == "GuestBinary")
        #expect(try executable.libraryPaths(of: 0xc).contains("@loader_path/../../Tweaks/TweakLoader.dylib"))

        let engineInfo = try plist(bundle.appendingPathComponent("LCAppInfo.plist"))
        #expect(engineInfo["LCPatchRevision"] as? Int == 7)
        #expect(engineInfo["LCDataUUID"] as? String == app.defaultContainer)
        #expect((engineInfo["LCContainers"] as? [[String: String]])?.first?["folderName"] == app.defaultContainer)
        #expect(engineInfo["dontInjectTweakLoader"] == nil)

        // The folder the tweak loader's path points into exists, so the
        // engine can link its copy there.
        var isDirectory: ObjCBool = false
        let tweaks = bundle.appendingPathComponent("../../Tweaks").standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: tweaks.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let container = try plist(
            library.containers.appendingPathComponent(app.defaultContainer).appendingPathComponent("LCContainerInfo.plist"))
        #expect(container["appIdentifier"] as? String == "com.example.guest")
        #expect(container["keychainGroupId"] as? Int == 0)
        #expect(container["isolateAppGroup"] as? Bool == false)
    }

    @Test func listsWhatIsInstalled() throws {
        defer { cleanUp() }
        #expect(try library.apps().isEmpty)

        let second = try library.install(appBundleAt: stage(bundleIdentifier: "com.example.zeta", name: nil))
        let first = try library.install(appBundleAt: stage(bundleIdentifier: "com.example.alpha"))

        #expect(try library.apps() == [first, second])
        // With no display name the executable's name stands in.
        #expect(second.name == "GuestBinary")
    }

    @Test func reinstallingKeepsTheAppsData() throws {
        defer { cleanUp() }
        let original = try library.install(appBundleAt: stage())
        let saved = library.containers
            .appendingPathComponent(original.defaultContainer).appendingPathComponent("Documents/save.dat")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: saved)

        let updated = try library.install(appBundleAt: stage(extraFiles: ["new-in-update.txt": Data("x".utf8)]))

        #expect(updated.defaultContainer == original.defaultContainer)
        #expect(try Data(contentsOf: saved) == Data("progress".utf8))
        #expect(FileManager.default.fileExists(
            atPath: library.bundleURL(of: updated).appendingPathComponent("new-in-update.txt").path))
        #expect(try library.apps().count == 1)
    }

    @Test func givesEachContainerItsOwnKeychainGroupWhileTheyLast() throws {
        defer { cleanUp() }
        var groups: [Int] = []
        for index in 0..<5 {
            let app = try library.install(appBundleAt: stage(bundleIdentifier: "com.example.app\(index)"))
            let info = try plist(
                library.containers.appendingPathComponent(app.defaultContainer).appendingPathComponent("LCContainerInfo.plist"))
            groups.append(try #require(info["keychainGroupId"] as? Int))
        }
        // Four groups: the first four apps get one each, the fifth shares the first.
        #expect(groups == [0, 1, 2, 3, 0])
    }

    @Test func removingAnAppRemovesItsDataUnlessAsked() throws {
        defer { cleanUp() }
        let fileManager = FileManager.default
        let kept = try library.install(appBundleAt: stage(bundleIdentifier: "com.example.kept"))
        let gone = try library.install(appBundleAt: stage(bundleIdentifier: "com.example.gone"))

        try library.remove(gone)
        try library.remove(kept, keepingData: true)

        #expect(try library.apps().isEmpty)
        #expect(!fileManager.fileExists(atPath: library.containers.appendingPathComponent(gone.defaultContainer).path))
        #expect(fileManager.fileExists(atPath: library.containers.appendingPathComponent(kept.defaultContainer).path))
    }

    @Test func marksTheARM64eSlicesOfBundledLibraries() throws {
        defer { cleanUp() }
        var arm64e = MachOBuilder.executable()
        arm64e.cpuSubtype = 2
        let fat = MachOBuilder.fat([(0, MachOBuilder.executable().build()), (2, arm64e.build())])
        let frameworkInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Kit"], format: .xml, options: 0)

        let app = try library.install(appBundleAt: stage(extraFiles: [
            "Frameworks/libthing.dylib": fat,
            "Frameworks/Kit.framework/Info.plist": frameworkInfo,
            "Frameworks/Kit.framework/Kit": fat,
            "Frameworks/readme.dylib": Data("not a library".utf8),
        ]))

        let bundle = library.bundleURL(of: app)
        for path in ["Frameworks/libthing.dylib", "Frameworks/Kit.framework/Kit"] {
            let bytes = MachOBytes(bytes: Array(try Data(contentsOf: bundle.appendingPathComponent(path))))
            let slice = try bytes.slices()[1]
            #expect(try bytes.uint32(at: slice.offset + 8) == 0x8000_0002)
        }
        // A file that only looks like a library by name is left alone.
        #expect(try Data(contentsOf: bundle.appendingPathComponent("Frameworks/readme.dylib"))
            == Data("not a library".utf8))
    }

    // MARK: The SDK version reported to iOS

    func executable(sdk: UInt32?) -> Data {
        var builder = MachOBuilder.executable()
        if let sdk {
            builder.commands.insert(MachOBuilder.buildVersion(sdk: sdk), at: 4)
        }
        return builder.build()
    }

    func engineInfo(of app: GuestApp) throws -> [String: Any] {
        try plist(library.bundleURL(of: app).appendingPathComponent("LCAppInfo.plist"))
    }

    @Test func recordsTheSDKTheAppWasBuiltWith() throws {
        defer { cleanUp() }
        let app = try library.install(appBundleAt: stage(executable: executable(sdk: 0x0011_0400)))
        #expect(try engineInfo(of: app)["spoofSDKVersion"] as? Int == 0x0011_0400)
    }

    @Test func neverReportsAnSDKOlderThanIOS11() throws {
        defer { cleanUp() }
        let app = try library.install(appBundleAt: stage(executable: executable(sdk: 0x0008_0000)))
        #expect(try engineInfo(of: app)["spoofSDKVersion"] as? Int == 0x000b_0000)
    }

    @Test func leavesTheSettingOutWhenTheAppDoesNotSay() throws {
        defer { cleanUp() }
        let app = try library.install(appBundleAt: stage(executable: executable(sdk: nil)))
        #expect(try engineInfo(of: app)["spoofSDKVersion"] == nil)
    }

    @Test func launchPreparationAddsTheSettingToAnAppFromAnEarlierVersion() throws {
        defer { cleanUp() }
        let app = try library.install(appBundleAt: stage(executable: executable(sdk: 0x0010_0000)))
        let infoURL = library.bundleURL(of: app).appendingPathComponent("LCAppInfo.plist")

        // As an earlier version of Harbor left it.
        var earlier = try plist(infoURL)
        earlier["spoofSDKVersion"] = nil
        try GuestLibrary.writePropertyList(earlier, to: infoURL)

        try library.prepareForLaunch(app)
        #expect(try engineInfo(of: app)["spoofSDKVersion"] as? Int == 0x0010_0000)
        // Everything else is as it was.
        #expect(try engineInfo(of: app)["LCDataUUID"] as? String == app.defaultContainer)
    }

    @Test func launchPreparationKeepsASettingThatIsAlreadyThere() throws {
        defer { cleanUp() }
        let app = try library.install(appBundleAt: stage(executable: executable(sdk: 0x0010_0000)))
        let infoURL = library.bundleURL(of: app).appendingPathComponent("LCAppInfo.plist")

        var changed = try plist(infoURL)
        changed["spoofSDKVersion"] = 0
        try GuestLibrary.writePropertyList(changed, to: infoURL)

        try library.prepareForLaunch(app)
        #expect(try engineInfo(of: app)["spoofSDKVersion"] as? Int == 0)
    }

    @Test func recordsWhenTheTweakLoaderDoesNotFit() throws {
        defer { cleanUp() }
        // An executable whose code starts right after its load commands.
        var builder = MachOBuilder.executable()
        let end = 32 + builder.commands.reduce(0) { $0 + $1.count }
        builder.commands[1] = MachOBuilder.segment(
            "__TEXT", vmaddr: 0x1_0000_0000, vmsize: 0x4000, sections: [("__text", UInt32(end))])
        builder.textOffset = end
        builder.fileSize = end + 0x100

        let app = try library.install(appBundleAt: stage(executable: builder.build()))

        #expect(!app.tweakLoaderInjected)
        let engineInfo = try plist(library.bundleURL(of: app).appendingPathComponent("LCAppInfo.plist"))
        #expect(engineInfo["dontInjectTweakLoader"] as? Bool == true)
        #expect(engineInfo["LCTweakLoaderCantInject"] as? Bool == true)
        #expect(try library.apps().first?.tweakLoaderInjected == false)
    }

    @Test func refusesAnEncryptedAppAndInstallsNothing() throws {
        defer { cleanUp() }
        var builder = MachOBuilder.executable()
        builder.commands.insert(MachOBuilder.encryptionInfo(cryptid: 1), at: 5)
        let source = try stage(executable: builder.build())

        #expect(throws: GuestLibraryError.encrypted) {
            try library.install(appBundleAt: source)
        }
        #expect(try library.apps().isEmpty)
        // The staged executable was not touched.
        #expect(try Data(contentsOf: source.appendingPathComponent("GuestBinary")) == builder.build())
    }

    @Test func refusesWhatItCannotRun() throws {
        defer { cleanUp() }
        var intel = Array(MachOBuilder.executable().build())
        intel.replaceSubrange(4..<8, with: MachOBuilder.u32(0x0100_0007))

        #expect(throws: GuestLibraryError.unsupportedArchitecture) {
            try library.install(appBundleAt: stage(executable: Data(intel)))
        }
        #expect(throws: GuestLibraryError.missingExecutable) {
            try library.install(appBundleAt: stage(executable: nil))
        }
        #expect(throws: MachOError.notMachO) {
            try library.install(appBundleAt: stage(executable: Data("#!/bin/sh".utf8)))
        }
        #expect(try library.apps().isEmpty)
    }

    @Test(arguments: ["../../evil", "com/example", "", "com..example"])
    func refusesABundleIdentifierThatIsNotOne(_ identifier: String) throws {
        defer { cleanUp() }
        #expect(throws: GuestLibraryError.notAnApp) {
            try library.install(appBundleAt: stage(bundleIdentifier: identifier))
        }
        // Nothing was created outside the staging area.
        #expect(!FileManager.default.fileExists(atPath: library.applications.path))
    }

    @Test func aFolderThatIsNotAnAppIsRefused() throws {
        defer { cleanUp() }
        let empty = root.appendingPathComponent("empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(throws: GuestLibraryError.notAnApp) {
            try library.install(appBundleAt: empty)
        }
    }
}
