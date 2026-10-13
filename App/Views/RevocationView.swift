import HarborSigning
import SideSign
import SwiftUI

/// Asks what to do about development certificates already on the team.
/// Revoking is the one destructive thing Harbor can do to an account, so it
/// is never chosen for the user.
struct RevocationView: View {
    let certificates: [X509Certificate]
    let decide: (RevocationDecision) -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(certificates) { certificate in
                        Toggle(isOn: binding(for: certificate)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(certificate.machineName ?? certificate.name)
                                Text(Self.detail(for: certificate))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Existing certificates")
                } footer: {
                    Text("""
                    Your Apple ID already has these development certificates. They may belong to \
                    iloader, SideStore, Xcode or another device.

                    Apps signed with a certificate you revoke stop opening until they are signed \
                    again. Keep them all if you are not sure; Apple may then refuse to issue \
                    another one.
                    """)
                }

                Section {
                    Button("Revoke selected and continue", role: .destructive) {
                        decide(.revoke(certificates.filter { selected.contains($0.id) }))
                    }
                    .disabled(selected.isEmpty)

                    Button("Keep all and continue") {
                        decide(.keepExisting)
                    }
                }
            }
            .navigationTitle("Signing certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { decide(.cancel) }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func binding(for certificate: X509Certificate) -> Binding<Bool> {
        Binding(
            get: { selected.contains(certificate.id) },
            set: { isOn in
                if isOn { selected.insert(certificate.id) } else { selected.remove(certificate.id) }
            }
        )
    }

    private static func detail(for certificate: X509Certificate) -> String {
        var parts = [certificate.name]
        if let expires = certificate.notAfter {
            parts.append("expires \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("serial …\(certificate.serialNumber.suffix(6))")
        return parts.joined(separator: " · ")
    }
}
