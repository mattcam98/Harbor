import Foundation
import SafariServices
import Testing
import UIKit

/// A Home Screen shortcut reaches iOS as a profile shown in an in-app Safari
/// page. That page takes web addresses only: given the profile inside a
/// `data:` address, as LiveContainer's own interface does it, it raises an
/// exception that takes the app down. So Harbor serves the profile from the
/// device to itself and gives Safari that address. This checks the form of
/// address Harbor uses is one Safari's page accepts.
@MainActor
@Suite struct ShortcutProfileTests {
    @Test func safariAcceptsALoopbackAddress() throws {
        let address = try #require(URL(string: "http://127.0.0.1:49152/token/Player.mobileconfig"))
        let page = SFSafariViewController(url: address)
        #expect(page.view != nil)
    }
}
