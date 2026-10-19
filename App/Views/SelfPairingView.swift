#if HARBOR_SELF_PAIRING
import HarborCore
import SwiftUI
import UIKit

/// The iOS 27 self-pairing spike's screen: start, the PIN, the proof and
/// a report to send back. docs/DEVICE-TEST.md, Test 6, walks through it.
struct SelfPairingView: View {
    @Bindable var model: AppModel
    let spike: SelfPairingSpike

    @State private var confirmingReplace = false

    var body: some View {
        List {
            Section {
                Label("Connect to Wi-Fi. Turn LocalDevVPN on.", systemImage: "1.circle")
                Label("Open Settings › Privacy & Security › Developer Mode and leave it open.", systemImage: "2.circle")
                Label("Come back here and tap Start. Allow Local Network and notifications.", systemImage: "3.circle")
                Label("Go straight back to Settings. Tap Pair with \(SelfPairing.hostName) and type the PIN from the notification.", systemImage: "4.circle")
                Label("Come back here and tap Install a profile with it.", systemImage: "5.circle")
            } footer: {
                Text("Harbor keeps running for about half a minute after you leave it, so do step 4 promptly. Anyone on this Wi-Fi can see Harbor while it is advertising; the PIN is what keeps them out.")
            }

            Section("Pairing") {
                LabeledContent("State", value: Self.describe(spike.phase))
                if let pin = spike.pin {
                    Text(pin)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
                }
                if [.starting, .advertising, .waitingForPIN].contains(spike.phase) {
                    Button("Stop", role: .destructive) { spike.stop() }
                } else {
                    Button("Start") {
                        if model.pairing == .missing {
                            spike.start()
                        } else {
                            confirmingReplace = true
                        }
                    }
                    .disabled(spike.isRunning || model.isBusy)
                }
            }

            Section {
                Button("Install a profile with it") {
                    Task { await spike.prove() }
                }
                .disabled(spike.isRunning || model.isBusy || model.pairing == .missing)
            } header: {
                Text("Proof")
            } footer: {
                Text("Connects through LocalDevVPN with the stored record and installs this copy of Harbor's own provisioning profile again. Nothing on the phone changes.")
            }

            if !spike.steps.isEmpty {
                Section {
                    ForEach(spike.steps) { step in
                        Label {
                            Text(step.text).font(.footnote)
                        } icon: {
                            Image(systemName: Self.symbol(step.outcome))
                                .foregroundStyle(step.outcome == .failed ? Color.red : Color.secondary)
                        }
                    }
                    Button("Copy report") { UIPasteboard.general.string = spike.report }
                } header: {
                    Text("What happened")
                } footer: {
                    Text("The report has no PIN, key or full device identifier in it.")
                }
            }
        }
        .navigationTitle("Pair this iPhone")
        .confirmationDialog(
            "Replace the stored pairing record?",
            isPresented: $confirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Pair and replace it", role: .destructive) { spike.start() }
        } message: {
            Text(spike.storedRecordIsSelfMade
                ? "The stored record was made on this iPhone earlier. Pairing again makes a new host, so the old record stops being the one Harbor uses."
                : "The stored record came from a computer. If this pairing works it takes its place; Harbor Setup can give you one again.")
        }
    }

    private static func describe(_ phase: SelfPairingSpike.Phase) -> String {
        switch phase {
        case .idle: "Not started"
        case .starting: "Starting"
        case .advertising: "Waiting for Settings"
        case .waitingForPIN: "Type this PIN in Settings"
        case .paired: "Paired and stored"
        case .proving: "Installing a profile"
        case .proved: "Profile installed with it"
        case .failed: "Failed, see below"
        }
    }

    private static func symbol(_ outcome: SelfPairingSpike.Step.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .note: "info.circle"
        }
    }
}
#endif
