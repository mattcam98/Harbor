import SwiftUI

@main
struct HarborApp: App {
    @State private var launch = Launch()

    var body: some Scene {
        WindowGroup {
            switch launch.state {
            case .ready(let model):
                RootView(model: model)
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
@MainActor
@Observable
final class Launch {
    enum State {
        case ready(AppModel)
        case failed(String)
    }

    let state: State

    init() {
        do {
            state = .ready(AppModel(services: try Services.live()))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
