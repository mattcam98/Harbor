import AppIntents
import Foundation

/// Harbor's own action in Shortcuts, so a daily automation can renew it
/// without the user building a shortcut: it is there as soon as Harbor is
/// installed, under Harbor, and is what Automatic Renewal sets up.
///
/// It runs in the background. Harbor renews only what expires within two
/// days, retries problems that pass by themselves, checks the new end date,
/// and fails the action with the reason, which Shortcuts shows.
struct RenewHarborIntent: AppIntent {
    static var title: LocalizedStringResource { "Renew Harbor" }
    static var description: IntentDescription {
        IntentDescription(
            "Renews Harbor, and the apps it installed, when they expire within 2 days. Needs LocalDevVPN connected.",
            categoryName: "Renewal")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard case .ready(let model) = Launch.shared.state else {
            throw RenewalFailure(message: "Harbor couldn't start. Open Harbor to see why.")
        }
        switch await model.renewFromShortcut() {
        case .renewed(let summary):
            return .result(value: summary.message, dialog: IntentDialog(stringLiteral: summary.message))
        case .cancelled:
            throw RenewalFailure(message: "Renewal was cancelled.")
        case .failed(_, let message):
            throw RenewalFailure(message: message)
        }
    }
}

/// Why a renewal failed, in the words Shortcuts shows.
struct RenewalFailure: Error, CustomLocalizedStringResourceConvertible {
    var message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Puts Renew Harbor in Shortcuts, Spotlight and Siri with nothing to set up.
struct HarborShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RenewHarborIntent(),
            phrases: [
                "Renew \(.applicationName)",
                "Renew apps in \(.applicationName)",
            ],
            shortTitle: "Renew Harbor",
            systemImageName: "arrow.clockwise"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .navy }
}
