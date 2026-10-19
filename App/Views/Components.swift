import HarborCore
import HarborSigning
import SafariServices
import SwiftUI

/// What Harbor is doing right now, with Cancel for downloads.
struct ActivityBanner: View {
    let model: AppModel

    var body: some View {
        if let activity = model.activity {
            HStack(spacing: 10) {
                ProgressView()
                Text(activity)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(2)
                if model.isDownloading {
                    Button("Cancel") { model.cancelDownload() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// An app's icon, rounded the way iOS rounds them.
struct AppIcon: View {
    let image: UIImage?
    var side: CGFloat = 44
    /// Grows with the text size, up to half again.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = side * min(scale, 1.5)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: side * 0.4))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A symbol on a small coloured tile, as Settings shows them.
struct SymbolTile: View {
    let systemName: String
    var color: Color = .accentColor
    var side: CGFloat = 30
    /// Grows with the text size, up to half again.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = side * min(scale, 1.5)
        Image(systemName: systemName)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

// Colours in rows that are buttons are spelled out as `Color`: there, the
// hierarchical `.primary` and `.secondary` take the button's tint.

/// One app in a list: its icon, its name and a line underneath.
struct GuestRow: View {
    let guest: GuestApp
    let icon: UIImage?
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(image: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A numbered instruction.
struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey
    @ScaledMetric(relativeTo: .footnote) private var diameter: CGFloat = 22

    var body: some View {
        // The number's own baseline lines up with the step's first line.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Color.accentColor, in: Circle())
                .accessibilityLabel("Step \(number)")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

extension IdentitySummary {
    /// "Apple Development: … · expires 26 Oct 2026".
    var caption: String {
        var parts = [name]
        if let expires {
            parts.append("Expires \(expires.day)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Hands a Home Screen icon to iOS and says what happens next.
///
/// iOS only installs a profile that Safari shows it, and only after the user
/// approves it in Settings. Neither step can be skipped by an app.
struct HomeScreenIconSheet: View {
    let offer: AppModel.ShortcutOffer
    @Environment(\.dismiss) private var dismiss
    @State private var showingSafari = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StepRow(number: 1, text: "Tap **Continue**, then **Allow** to download the profile.")
                    StepRow(number: 2, text: "Open **Settings**, tap **Profile Downloaded**, then **Install**.")
                    StepRow(number: 3, text: "**\(offer.name)** appears on your Home Screen and opens in Harbor.")
                } footer: {
                    Text("The profile only adds the icon. iOS calls it unsigned because it was made on this iPhone. Delete the icon to remove it.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingSafari = true
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showingSafari) {
                SafariPage(address: offer.address).ignoresSafeArea()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SafariPage: UIViewControllerRepresentable {
    let address: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: address)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
