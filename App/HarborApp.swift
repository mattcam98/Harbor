import SwiftUI
import UIKit

@main
struct HarborApp: App {
    @UIApplicationDelegateAdaptor private var delegate: HarborAppDelegate
    @State private var launch = Launch.shared

    var body: some Scene {
        WindowGroup {
            switch launch.state {
            case .ready(let model):
                RootView(model: model)
                    .onOpenURL { url in
                        model.expect(url)
                        Task { await model.open(url) }
                    }
            case .failed(let message):
                ContentUnavailableView(
                    "Harbor could not start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
    }
}

/// Builds the services once. A failure here (no Application Support
/// directory, for instance) is shown instead of crashing.
///
/// Shared, because a shortcut can run Harbor in the background, where no
/// window, and so no `HarborApp.body`, is ever made.
@MainActor
@Observable
final class Launch {
    static let shared = Launch()

    enum State {
        case ready(AppModel)
        case failed(String)
    }

    let state: State

    private init() {
        do {
            state = .ready(AppModel(services: try Services.live()))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Hears what Harbor was opened for before its interface is first drawn,
/// and gives each window the scene delegate that hears Home Screen quick
/// actions, which SwiftUI has no other way to receive.
final class HarborAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if case .ready(let model) = Launch.shared.state {
            // Opened from a guest's Home Screen icon: the guest goes on
            // screen without Harbor's interface being drawn first.
            if let url = options.urlContexts.first?.url {
                model.expect(url)
            }
            if let item = options.shortcutItem {
                model.handle(item)
            }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = HarborSceneDelegate.self
        return configuration
    }
}

/// A quick action chosen on Harbor's Home Screen icon while Harbor was
/// already running. SwiftUI's own scene delegate passes it on to this one.
final class HarborSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard case .ready(let model) = Launch.shared.state else {
            completionHandler(false)
            return
        }
        completionHandler(model.handle(shortcutItem))
    }
}
