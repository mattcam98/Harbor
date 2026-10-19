import Foundation
import Testing

@testable import HarborCore

@Suite struct DeepLinkRouterTests {
    let router = DeepLinkRouter()

    func route(_ string: String) throws -> DeepLink {
        try router.route(try #require(URL(string: string)))
    }

    @Test func routesInstall() throws {
        let link = try route("harbor://install?url=https://example.com/App.ipa")
        #expect(link == .installApp(from: URL(string: "https://example.com/App.ipa")!))
        #expect(link.confirmation == .required)
    }

    @Test func routesSource() throws {
        let link = try route("harbor://source?url=https%3A%2F%2Fexample.com%2Fapps.json%3Fa%3D1")
        #expect(link == .addSource(URL(string: "https://example.com/apps.json?a=1")!))
        #expect(link.confirmation == .required)
    }

    @Test func routesLaunchAndRefreshWithoutConfirmation() throws {
        let launch = try route("harbor://launch?id=com.example.app&container=Work")
        #expect(launch == .launchApp(bundleIdentifier: "com.example.app", container: "Work"))
        #expect(launch.confirmation == .notRequired)

        #expect(try route("harbor://launch?id=com.example.app")
            == .launchApp(bundleIdentifier: "com.example.app", container: nil))
        #expect(try route("harbor://refresh").confirmation == .notRequired)
    }

    @Test func routesRenewalWithAndWithoutCallback() throws {
        #expect(try route("harbor://refresh") == .refreshAll(callback: nil))
        #expect(try route("harbor://renew") == .refreshAll(callback: nil))

        let link = try route(
            "harbor://x-callback-url/renew?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%2F1"
                + "&x-error=shortcuts%3A%2F%2Fx-callback-url%2Fic-error%2F1")
        guard case .refreshAll(let callback?) = link else {
            Issue.record("expected a callback, got \(link)")
            return
        }
        #expect(link.confirmation == .notRequired)
        #expect(callback.succeeded(["status": "renewed"]).absoluteString
            == "shortcuts://x-callback-url/ic-success/1?status=renewed")
        #expect(callback.failed("Turn on LocalDevVPN").absoluteString
            == "shortcuts://x-callback-url/ic-error/1?errorMessage=Turn%20on%20LocalDevVPN")
    }

    @Test(arguments: [
        "harbor://renew?x-success=https%3A%2F%2Fevil.example%2F",
        "harbor://renew?x-success=javascript%3Aalert(1)",
        "harbor://renew?x-error=shortcuts%3A%2F%2Fx-callback-url%2Fic-error%2F1",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fa&x-success=shortcuts%3A%2F%2Fb",
        "harbor://renew?x-success=shortcuts%3A%2F%2Frun-shortcut%3Fname%3DAnything%26input%3Dtext",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fimport-shortcut%3Furl%3Dhttps%3A%2F%2Fevil.example",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fx-callback-url%2Frun-shortcut%3Fname%3DAnything",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%2F1%2Fextra",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%2F",
        "harbor://renew?x-success=shortcuts%3A%2F%2Fx-callback-url%2Fic-success%2F1"
            + "&x-error=shortcuts%3A%2F%2Fopen-shortcut%3Fname%3DX",
    ])
    func ignoresAddressesThatAreNotShortcutsReplies(_ string: String) throws {
        // Still renews, but reports nowhere.
        #expect(try route(string) == .refreshAll(callback: nil))
    }

    @Test(arguments: [
        "shortcuts://x-callback-url/ic-success/2D5E1A0C-9F3B-4C2A-8E21-6B0E7C1D4F55",
        "shortcuts-production://x-callback-url/ic-error/2D5E1A0C",
        "SHORTCUTS://X-Callback-URL/IC-Cancel/1",
    ])
    func acceptsShortcutsReplies(_ string: String) throws {
        #expect(XCallback.isReplyAddress(try #require(URL(string: string))))
    }

    @Test func failureWithoutErrorAddressReportsThroughSuccess() throws {
        let callback = XCallback(
            success: URL(string: "shortcuts://x-callback-url/ic-success/1")!, failure: nil, cancel: nil)
        #expect(callback.failed("No").absoluteString
            == "shortcuts://x-callback-url/ic-success/1?message=No&status=failed")
    }

    @Test func jitNeedsConfirmation() throws {
        let link = try route("harbor://jit?id=com.example.app")
        #expect(link == .enableJIT(bundleIdentifier: "com.example.app"))
        #expect(link.confirmation == .required)
    }

    @Test(arguments: [
        "harbor://pairing?urlName=evil",
        "harbor://certificate?callback_template=evil%3A%2F%2Fcert",
        "HARBOR://Pairing?urlName=evil",
    ])
    func neverExportsSecrets(_ string: String) {
        #expect(throws: DeepLinkError.self) { try route(string) }
        do {
            _ = try route(string)
        } catch let error as DeepLinkError {
            guard case .secretExportRefused = error else {
                Issue.record("expected secretExportRefused, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: [
        "harbor://install?url=http://example.com/App.ipa",
        "harbor://source?url=ftp://example.com/apps.json",
        "harbor://install?url=file:///private/var/App.ipa",
    ])
    func refusesInsecureRemoteContent(_ string: String) {
        #expect(throws: DeepLinkError.self) { try route(string) }
    }

    @Test func refusesCredentialsInURLs() {
        #expect(throws: DeepLinkError.invalidParameter("url")) {
            try route("harbor://install?url=https://apple.com@evil.example/App.ipa")
        }
    }

    @Test func rejectsOtherSchemesAndActions() {
        #expect(throws: DeepLinkError.unsupportedScheme) { try route("sidestore://install?url=https://e.com/a.ipa") }
        #expect(throws: DeepLinkError.unknownAction("format-disk")) { try route("harbor://format-disk") }
        #expect(throws: DeepLinkError.unknownAction("")) { try route("harbor:///") }
    }

    @Test func requiresParameters() {
        #expect(throws: DeepLinkError.missingParameter("url")) { try route("harbor://install") }
        #expect(throws: DeepLinkError.missingParameter("id")) { try route("harbor://launch?id=") }
    }

    @Test func rejectsRepeatedParameters() {
        #expect(throws: DeepLinkError.invalidParameter("url")) {
            try route("harbor://install?url=https://a.example/a.ipa&url=https://b.example/b.ipa")
        }
    }

    @Test(arguments: ["..", "a/b", "a%5Cb", "."])
    func rejectsContainerTraversal(_ container: String) {
        #expect(throws: DeepLinkError.invalidParameter("container")) {
            try route("harbor://launch?id=com.example.app&container=\(container)")
        }
    }

    @Test(arguments: ["com..app", ".com.app", "com.app.", "com.ex ample", "com/app", "com.app;rm"])
    func rejectsMalformedBundleIdentifiers(_ identifier: String) {
        #expect(!Identifier.isBundleIdentifier(identifier))
    }

    @Test func acceptsOrdinaryBundleIdentifiers() {
        #expect(Identifier.isBundleIdentifier("com.example.My-App2"))
        #expect(Identifier.isBundleIdentifier("app"))
    }
}

@Suite struct EngineURLTests {
    let router = DeepLinkRouter()

    static let app = GuestApp(
        folderName: "com.example.player.app",
        bundleIdentifier: "com.example.player",
        name: "Player",
        version: "3.0",
        executableName: "Player",
        defaultContainer: "A1B2",
        tweakLoaderInjected: true
    )

    @Test func buildsTheLaunchAddressTheEngineUnderstands() {
        #expect(EngineURL.launch(scheme: "harbor", folderName: "com.example.player.app").absoluteString
            == "harbor://livecontainer-launch?bundle-name=com.example.player.app")
        #expect(EngineURL.launch(scheme: "harbor", folderName: "com.example.player.app", container: "A1B2").absoluteString
            == "harbor://livecontainer-launch?bundle-name=com.example.player.app&container-folder-name=A1B2")
        #expect(EngineURL.showHost(scheme: "harbor").absoluteString == "harbor://livecontainer-launch?bundle-name=ui")
    }

    @Test func harborRoutesTheSameAddresses() throws {
        #expect(try router.route(EngineURL.launch(scheme: "harbor", folderName: "com.example.player.app"))
            == .launchApp(bundleIdentifier: "com.example.player", container: nil))
        #expect(try router.route(EngineURL.launch(scheme: "harbor", folderName: "com.example.player.app", container: "A1B2"))
            == .launchApp(bundleIdentifier: "com.example.player", container: "A1B2"))
        #expect(try router.route(EngineURL.showHost(scheme: "harbor")) == .showHarbor)
        #expect(DeepLink.showHarbor.confirmation == .notRequired)
    }

    @Test(arguments: [
        "harbor://livecontainer-launch",
        "harbor://livecontainer-launch?bundle-name=",
        "harbor://livecontainer-launch?bundle-name=com.example.player",
        "harbor://livecontainer-launch?bundle-name=..%2F..%2Fevil.app",
        "harbor://livecontainer-launch?bundle-name=bad%20id.app",
        "harbor://livecontainer-launch?bundle-name=a.app&bundle-name=b.app",
        "harbor://livecontainer-launch?bundle-name=com.example.player.app&container-folder-name=..%2Fx",
    ])
    func refusesLaunchAddressesThatDoNotNameAnApp(_ address: String) {
        #expect(throws: DeepLinkError.self) {
            try router.route(URL(string: address)!)
        }
    }

    // MARK: Home Screen shortcuts

    func shortcut(container: String? = nil) -> HomeScreenShortcut {
        HomeScreenShortcut(
            app: Self.app, container: container, hostScheme: "harbor", hostBundleIdentifier: "me.example.harbor")
    }

    func decode(_ profile: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
    }

    @Test func theProfileHoldsOneWebClipThatOpensTheApp() throws {
        let icon = Data([0x89, 0x50, 0x4e, 0x47])
        let profile = try decode(try shortcut().profile(icon: icon))

        #expect(profile["PayloadType"] as? String == "Configuration")
        #expect(profile["PayloadIdentifier"] as? String == "me.example.harbor.shortcut.com.example.player")
        #expect(profile["PayloadRemovalDisallowed"] as? Bool == false)

        let content = try #require(profile["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        let clip = try #require(content.first)
        #expect(clip["PayloadType"] as? String == "com.apple.webClip.managed")
        #expect(clip["Label"] as? String == "Player")
        #expect(clip["URL"] as? String == "harbor://livecontainer-launch?bundle-name=com.example.player.app")
        #expect(clip["Icon"] as? Data == icon)
        #expect(clip["IsRemovable"] as? Bool == true)
        #expect(clip["FullScreen"] as? Bool == true)
        // The route this address takes in Harbor needs no confirmation.
        #expect(try router.route(URL(string: try #require(clip["URL"] as? String))!).confirmation == .notRequired)
    }

    @Test func aShortcutCanPointAtOneContainer() throws {
        let profile = try decode(try shortcut(container: "A1B2").profile(icon: nil))
        let clip = try #require((profile["PayloadContent"] as? [[String: Any]])?.first)

        #expect(profile["PayloadIdentifier"] as? String == "me.example.harbor.shortcut.com.example.player.A1B2")
        #expect((clip["URL"] as? String)?.hasSuffix("&container-folder-name=A1B2") == true)
        #expect(clip["Icon"] == nil)
    }

    @Test func makingTheSameShortcutAgainGivesTheSameProfile() throws {
        let first = try decode(try shortcut().profile(icon: nil))
        let second = try decode(try shortcut().profile(icon: nil))
        let other = try decode(try shortcut(container: "A1B2").profile(icon: nil))

        let identity = try #require(first["PayloadUUID"] as? String)
        #expect(UUID(uuidString: identity) != nil)
        #expect(second["PayloadUUID"] as? String == identity)
        #expect(other["PayloadUUID"] as? String != identity)
        // The profile and the clip inside it are different payloads.
        let clip = try #require((first["PayloadContent"] as? [[String: Any]])?.first)
        #expect(clip["PayloadUUID"] as? String != identity)
    }
}
