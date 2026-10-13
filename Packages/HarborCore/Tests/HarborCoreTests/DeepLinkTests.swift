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
