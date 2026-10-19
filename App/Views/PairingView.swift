import HarborCore
import SwiftUI

/// Pairs this iPhone with Harbor, with no computer (iOS 27 and later).
struct PairingView: View {
    @Bindable var model: AppModel
    @State private var confirmingReplace = false

    private var pairing: PhonePairing { model.phonePairing }

    var body: some View {
        List {
            Section {
                StepRow(number: 1, text: "Connect to Wi-Fi and turn on **LocalDevVPN**.")
                StepRow(number: 2, text: "Tap **Start** below.")
                StepRow(number: 3, text: "Open **Settings › Privacy & Security › Developer Mode** and tap **Pair with \(SelfPairing.hostName)**.")
                StepRow(number: 4, text: "Enter the code Harbor shows in its notification.")
            } footer: {
                Text("Harbor keeps running for about 30 seconds after you leave it, so go straight to Settings.")
            }

            Section {
                statusRow
                if let pin = pairing.pin {
                    Text(pin)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Code \(pin.map(String.init).joined(separator: " "))")
                }
                if pairing.isRunning {
                    Button("Stop", role: .destructive) { pairing.stop() }
                } else if pairing.needsRelaunch {
                    Text("To try again, close Harbor from the app switcher and open it again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if pairing.phase != .paired {
                    Button {
                        if model.pairing == .missing {
                            pairing.start()
                        } else {
                            confirmingReplace = true
                        }
                    } label: {
                        Text("Start").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .disabled(model.isBusy)
                }
            }
        }
        .onAppear { pairing.reset() }
        .navigationTitle("Pair This iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Replace the current pairing?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Pair Again", role: .destructive) { pairing.start() }
        } message: {
            Text("If pairing works, the new record replaces the one Harbor uses now.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .starting:
            Label { Text("Starting…") } icon: { ProgressView() }
        case .waitingForSettings:
            Label { Text("Waiting for Settings…") } icon: { ProgressView() }
        case .showingPIN:
            Label("Enter this code in Settings", systemImage: "number")
        case .paired:
            Label("Paired", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("Pairing didn't finish", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
