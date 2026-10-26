import HarborCore
import UIKit

/// What touching and holding Harbor's Home Screen icon offers: the apps
/// opened in Harbor most recently, and Harbor's own interface.
///
/// Harbor's icon and its place in the app switcher are shared with every
/// guest drawn inside it, and tapping the icon brings back whatever was on
/// screen, as it does for any app. This menu is the one place iOS gives an
/// app to offer more than that from the Home Screen.
///
/// Each item carries the link a Home Screen icon would open, so choosing it
/// is the same as following that link. iOS keeps the items after Harbor
/// quits, which makes them a list of recent apps rather than running ones.
@MainActor
enum QuickActions {
    private static let guestType = "harbor.guest"
    private static let harborType = "harbor.show"
    private static let linkKey = "link"
    /// iOS shows four items; one of them is Harbor's own.
    private static let recentLimit = 3

    /// The link an item opens.
    static func link(of item: UIApplicationShortcutItem) -> URL? {
        (item.userInfo?[linkKey] as? String).flatMap(URL.init(string:))
    }

    /// Puts `guest` first among the recent apps.
    static func opened(_ guest: GuestApp, container: String?, scheme: String) {
        let link = EngineURL.launch(scheme: scheme, folderName: guest.folderName, container: container)
        let item = UIApplicationShortcutItem(
            type: guestType,
            localizedTitle: guest.name,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "app"),
            userInfo: [linkKey: link.absoluteString as NSString]
        )
        update(recent: [item] + recent().filter { Self.link(of: $0) != link }, scheme: scheme)
    }

    /// Drops the apps that are no longer in Harbor.
    static func keep(_ guests: [GuestApp], scheme: String) {
        let router = DeepLinkRouter(scheme: scheme)
        let present = Set(guests.map(\.bundleIdentifier))
        update(recent: recent().filter { item in
            guard let link = link(of: item),
                  case .launchApp(let bundleIdentifier, _) = try? router.route(link)
            else { return false }
            return present.contains(bundleIdentifier)
        }, scheme: scheme)
    }

    private static func recent() -> [UIApplicationShortcutItem] {
        (UIApplication.shared.shortcutItems ?? []).filter { $0.type == guestType }
    }

    private static func update(recent: [UIApplicationShortcutItem], scheme: String) {
        let recent = Array(recent.prefix(recentLimit))
        // With no app opened yet, Harbor's icon already does what this
        // would.
        guard !recent.isEmpty else {
            UIApplication.shared.shortcutItems = []
            return
        }
        let harbor = UIApplicationShortcutItem(
            type: harborType,
            localizedTitle: "Show Harbor",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2"),
            userInfo: [linkKey: EngineURL.showHost(scheme: scheme).absoluteString as NSString]
        )
        let items = recent + [harbor]
        if UIApplication.shared.shortcutItems != items {
            UIApplication.shared.shortcutItems = items
        }
    }
}
