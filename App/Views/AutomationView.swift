import AppIntents
import SwiftUI
import UIKit

/// Sets up a daily Shortcuts automation that renews Harbor.
///
/// Harbor puts its own Renew Harbor action in Shortcuts (`RenewHarborIntent`),
/// so there is no shortcut to build. Apple doesn't let an app make an
/// automation, so the user creates that; this walks them through it and
/// checks it ran.
struct AutomationView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            statusSection

            Section {
                StepRow(number: 1, text: "In Shortcuts, open **Automation** and tap **+**.")
                StepRow(number: 2, text: "Choose **Time of Day**. Pick a time, **Daily** and **Run Immediately**, then tap **Next**.")
                StepRow(number: 3, text: "Tap **New Blank Automation**, then **Add Action**. Search for **Renew Harbor**, tap it, then tap **Done**.")
                Button {
                    open("shortcuts://")
                } label: {
                    Text("Open Shortcuts")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text("Run It Every Day")
            } footer: {
                Text("Renew Harbor is already in Shortcuts, under Harbor: there's nothing to add. Pick a time your iPhone is usually on Wi-Fi. Times follow your iPhone's time zone.")
            }

            Section {
                StepRow(number: 1, text: "In the automation, tap **+** above **Renew Harbor** and add **Set VPN**.")
                StepRow(number: 2, text: "Set it to **Connect** and **LocalDevVPN**.")
            } header: {
                Text("Turn On LocalDevVPN First")
            } footer: {
                Text("Renewing needs LocalDevVPN. Harbor waits for it to connect before giving up.")
            }

            Section {
                // Opens Harbor's page in Shortcuts, where Renew Harbor runs
                // with a tap. Drawn by the system, so it stands outside a card.
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Check It Works")
            } footer: {
                Text("Tap **Renew Harbor** there once: the status above changes to Working.")
            }

            Section {
                Toggle("Notify When Renewed", isOn: Binding(
                    get: { model.notifiesAfterRenewal },
                    set: { wanted in
                        guard wanted else { model.notifiesAfterRenewal = false; return }
                        Task {
                            let allowed = await Notices.requestPermission()
                            model.notifiesAfterRenewal = allowed
                            if !allowed {
                                model.problem = Problem(
                                    title: "Notifications are off",
                                    detail: "Turn on notifications for Harbor in Settings, then try again.")
                            }
                        }
                    }
                ))
            } footer: {
                Text("Harbor only renews within 2 days of expiring, so most runs finish straight away. If one fails, Shortcuts says why.")
            }
        }
        .navigationTitle("Automatic Renewal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                SymbolTile(systemName: status.symbol, color: status.color, side: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title).font(.body.weight(.medium))
                    Text(status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var status: (symbol: String, color: Color, title: String, detail: String) {
        let lastRun = model.lastAutomaticRenewal
        let last = lastRun.map { $0.dayAndTime(relativeTo: model.clock, midSentence: true) } ?? ""
        switch model.automationHealth {
        case .notSetUp:
            return ("clock.arrow.circlepath", .indigo, "Not set up yet", "Takes about a minute.")
        case .working:
            return ("checkmark", .green, "Working", "Last ran \(last)")
        case .failing:
            return ("exclamationmark.triangle.fill", .orange, "Last run failed",
                    "Ran \(last). \(model.lastAutomaticFailure ?? "")")
        case .stopped:
            return ("pause.fill", .orange, "Not running", "Hasn't run since \(last). Check the automation in Shortcuts.")
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        UIApplication.shared.open(url)
    }
}
