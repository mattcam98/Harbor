import HarborCore
import SwiftUI

/// The Settings tab: renewal, the Apple ID, this iPhone and the certificate.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(Router.self) private var router
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            renewalSection
            accountSection
            deviceSection
            certificateSection
            aboutSection
        }
        .navigationTitle("Settings")
        .disabled(model.isBusy)
        .confirmationDialog("Sign out of your Apple ID?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        } message: {
            Text("You'll need to sign in again to install or renew apps.")
        }
    }

    @ViewBuilder
    private var renewalSection: some View {
        if let expiry = model.harborExpiry {
            Section {
                LabeledContent("Expires", value: expiry.dayAndTime(relativeTo: model.clock))
                Button("Renew Now") { Task { await model.renewHarbor() } }
                    .disabled(model.appleID == nil)
                NavigationLink {
                    AutomationView(model: model)
                } label: {
                    LabeledContent("Automatic Renewal", value: Self.describe(model.automationHealth))
                }
                Toggle("Remind Me Before It Expires", isOn: Binding(
                    get: { model.expiryReminders },
                    set: { wanted in Task { await model.setExpiryReminders(wanted) } }
                ))
            } header: {
                Text("Renewal")
            } footer: {
                Text("A free Apple ID keeps Harbor working for 7 days at a time. Renewing needs LocalDevVPN turned on.")
            }
        }
    }

    private var accountSection: some View {
        Section("Apple ID") {
            if let appleID = model.appleID {
                LabeledContent("Signed In", value: appleID)
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
            } else {
                Button("Sign In") { router.showingSignIn = true }
            }
        }
    }

    private var deviceSection: some View {
        Section {
            switch model.pairing {
            case .missing:
                LabeledContent("Status", value: "Not Paired")
            case .stored:
                LabeledContent("Status", value: "Paired")
                Button("Connect") { Task { await model.connect() } }
            case .connected:
                LabeledContent("Status") {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if PhonePairing.isSupported {
                NavigationLink(model.pairing == .missing ? "Pair This iPhone" : "Pair Again") {
                    PairingView(model: model)
                }
            }
            Button(model.pairing == .missing ? "Import Pairing File" : "Replace Pairing File") {
                router.pick(.pairing)
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text("Harbor needs to be paired with this iPhone to install and renew apps. The pairing file stays in this iPhone's keychain.")
        }
    }

    private var certificateSection: some View {
        Section {
            if let identity = model.signingIdentity {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.name)
                    if let expires = identity.expires {
                        Text("Expires \(expires.day)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Replace Certificate") { router.pick(.certificate) }
            } else {
                Button("Import Certificate") { router.pick(.certificate) }
            }
        } header: {
            Text("Signing Certificate")
        } footer: {
            Text("Signs the apps that run inside Harbor. Harbor Setup adds it for you.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.version)
        } footer: {
            Text("Harbor is free software under the GNU AGPL 3.0.")
        }
    }

    private static func describe(_ health: AppModel.AutomationHealth) -> String {
        switch health {
        case .notSetUp: "Off"
        case .working: "On"
        case .failing: "Failed"
        case .stopped: "Not Running"
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
