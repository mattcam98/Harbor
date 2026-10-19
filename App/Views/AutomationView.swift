import SwiftUI
import UIKit

/// Sets up a daily Shortcuts automation that renews Harbor.
///
/// Apple lets an app hand over a shortcut, but not an automation: the user
/// has to create that in Shortcuts. So this adds the shortcut in as few taps
/// as iOS allows, then walks through the automation and checks it ran.
///
/// The shortcut is one action, Open X-Callback URL with Harbor's renewal
/// link. Harbor does the work: it renews only what expires within two days,
/// retries problems that pass by themselves, checks the new end date, and
/// reports back so Shortcuts shows a failure.
struct AutomationView: View {
    @Bindable var model: AppModel
    @State private var copied = false

    private var shared: URL? { AppModel.sharedShortcut }

    var body: some View {
        List {
            statusSection

            Section {
                Button {
                    addShortcut()
                } label: {
                    Label("Add to Shortcuts", systemImage: "square.2.layers.3d.top.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                if shared == nil {
                    StepRow(number: 1, text: "In the new shortcut, add the **Open X-Callback URL** action.")
                    StepRow(number: 2, text: "Paste the link Harbor copied into it.")
                    StepRow(number: 3, text: "Name it **\(AppModel.shortcutName)** and tap **Done**.")
                }
            } header: {
                Text("Add the Shortcut")
            } footer: {
                if shared == nil {
                    Button(copied ? "Copied" : "Copy the link again") { copyLink() }
                        .font(.footnote)
                } else {
                    Text("Shortcuts opens. Tap **Add Shortcut**.")
                }
            }

            Section {
                StepRow(number: 1, text: "In Shortcuts, open **Automation** and tap **+**.")
                StepRow(number: 2, text: "Choose **Time of Day**, pick a time and **Daily**, then **Run Immediately**.")
                StepRow(number: 3, text: "Tap **Next** and choose **\(AppModel.shortcutName)**.")
                Button("Open Shortcuts", systemImage: "arrow.up.forward.app") {
                    open("shortcuts://")
                }
            } header: {
                Text("Run It Every Day")
            } footer: {
                Text("Pick a time your iPhone is usually unlocked and on Wi-Fi. Times follow your iPhone's time zone. Tip: add **Set VPN** › **Connect** › **LocalDevVPN** before the shortcut, so renewal works even when the VPN is off.")
            }

            Section {
                Button("Run Now", systemImage: "play.fill") {
                    open("shortcuts://run-shortcut?name=\(AppModel.shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                }
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
            } header: {
                Text("Check It Works")
            } footer: {
                Text("Harbor only renews when it's within 2 days of expiring, so most runs finish straight away. If a renewal fails, Shortcuts tells you why.")
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
        let last = model.lastAutomaticRenewal.map { $0.dayAndTime(relativeTo: model.clock) } ?? ""
        switch model.automationHealth {
        case .notSetUp:
            return ("clock.arrow.circlepath", .indigo, "Not set up yet", "Takes about a minute.")
        case .working:
            return ("checkmark", .green, "Working", "Last ran \(last)")
        case .failing:
            return ("exclamationmark.triangle.fill", .orange, "Last run failed",
                    "\(last). \(model.lastAutomaticFailure ?? "")")
        case .stopped:
            return ("pause.fill", .orange, "Not running", "Hasn't run since \(last). Check the automation in Shortcuts.")
        }
    }

    private func addShortcut() {
        if let shared {
            UIApplication.shared.open(shared)
        } else {
            copyLink()
            open("shortcuts://create-shortcut")
        }
    }

    private func copyLink() {
        UIPasteboard.general.string = AppModel.renewalLink
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        UIApplication.shared.open(url)
    }
}
