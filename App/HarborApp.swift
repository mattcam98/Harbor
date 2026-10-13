import SwiftUI

@main
struct HarborApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Placeholder until the unified interface lands (phase 4). It claims nothing
/// the build cannot do yet.
struct RootView: View {
    var body: some View {
        ContentUnavailableView(
            "Harbor",
            systemImage: "shippingbox",
            description: Text("This development build has no features yet.")
        )
    }
}

#Preview {
    RootView()
}
