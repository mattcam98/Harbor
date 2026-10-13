import HarborCore
import HarborSigning
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

/// The development interface: device, account and apps on one screen. The
/// designed interface replaces this in phase 4.
struct RootView: View {
    @Bindable var model: AppModel

    @State private var isImporting = false
    @State private var importKind = ImportKind.app
    @State private var showingSignIn = false
    @State private var code = ""
    @State private var pendingCertificate: URL?
    @State private var certificatePassword = ""
    @Environment(\.scenePhase) private var scenePhase

    enum ImportKind {
        case pairing, app, guest, certificate

        var contentTypes: [UTType] {
            switch self {
            case .pairing:
                [.propertyList, .xml, UTType(filenameExtension: "mobiledevicepairing") ?? .data, .data]
            case .app, .guest:
                [UTType(filenameExtension: "ipa") ?? .data]
            case .certificate:
                [.pkcs12, UTType(filenameExtension: "p12") ?? .data]
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                runningSection
                guestsSection
                expirySection
                deviceSection
                accountSection
                appsSection
            }
            .navigationTitle("Harbor")
            .disabled(model.isBusy)
        }
        // Over every screen, and never disabled: it holds the Cancel button.
        .overlay(alignment: .bottom) { activityBanner }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.cameToFront() }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importKind.contentTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                switch importKind {
                case .pairing: await model.importPairing(from: url)
                case .app: await model.install(ipaAt: url)
                case .guest: await model.addGuest(ipaAt: url)
                case .certificate: pendingCertificate = url
                }
            }
        }
        .sheet(isPresented: $showingSignIn) {
            SignInView(model: model)
        }
        .sheet(item: $model.shortcutOffer) { offer in
            ShortcutSheet(offer: offer)
        }
        .alert(
            "Certificate password",
            isPresented: Binding(get: { pendingCertificate != nil }, set: { if !$0 { pendingCertificate = nil } }),
            presenting: pendingCertificate
        ) { url in
            SecureField("Password", text: $certificatePassword)
            Button("Import") {
                let password = certificatePassword
                certificatePassword = ""
                Task { await model.importIdentity(from: url, password: password) }
            }
            Button("Cancel", role: .cancel) { certificatePassword = "" }
        } message: { _ in
            Text("Enter the password you set when exporting the certificate.")
        }
        .sheet(item: Binding(get: { model.revocationRequest }, set: { _ in })) { request in
            RevocationView(certificates: request.certificates) { decision in
                model.answerRevocation(decision)
            }
        }
        .alert(item: $model.problem) { problem in
            Alert(title: Text(problem.title), message: Text(problem.detail))
        }
        .alert(
            "Verification code",
            isPresented: Binding(get: { model.codeRequest != nil }, set: { if !$0 { model.answerCode(nil) } }),
            presenting: model.codeRequest
        ) { _ in
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button("Continue") {
                model.answerCode(code)
                code = ""
            }
            Button("Cancel", role: .cancel) {
                model.answerCode(nil)
                code = ""
            }
        } message: { request in
            Text(Self.describe(request.prompt))
        }
    }

    private func pick(_ kind: ImportKind) {
        importKind = kind
        isImporting = true
    }

    // MARK: Sections

    private var guestsSection: some View {
        Section {
            if model.guests.isEmpty {
                Text("No apps in Harbor yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.guests) { guest in
                Button {
                    Task { await model.launch(guest) }
                } label: {
                    GuestRow(
                        guest: guest,
                        icon: model.icon(for: guest),
                        caption: guest.version.isEmpty ? guest.bundleIdentifier : "Version \(guest.version)")
                }
                .contextMenu {
                    Button("Open", systemImage: "play") {
                        Task { await model.launch(guest) }
                    }
                    if GuestSessions.isAvailable {
                        Button("Open as the whole app", systemImage: "rectangle.portrait.and.arrow.forward") {
                            Task { await model.launch(guest, mode: .wholeApp) }
                        }
                    }
                    Button("Add to Home Screen", systemImage: "plus.app") {
                        Task { await model.offerShortcut(for: guest) }
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        model.removeGuest(guest)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { model.removeGuest(guest) }
                }
                .swipeActions(edge: .leading) {
                    Button("Home Screen", systemImage: "plus.app") {
                        Task { await model.offerShortcut(for: guest) }
                    }
                        .tint(.blue)
                }
            }
            Button("Add an app from Files") { pick(.guest) }
            NavigationLink("Browse sources") { SourcesView(model: model) }
            if let identity = model.signingIdentity {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Signing certificate imported", systemImage: "checkmark.seal")
                    Text(Self.describe(identity))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Replace signing certificate") { pick(.certificate) }
            } else {
                Button("Import signing certificate") { pick(.certificate) }
            }
        } header: {
            Text("Run inside Harbor")
        } footer: {
            Text(GuestSessions.isAvailable
                ? "These apps run inside Harbor and do not use one of the three sideloaded app slots. Tap one to open it; the button at the edge of the screen brings you back here. Touch and hold an app for more."
                : "These apps run inside Harbor and do not use one of the three sideloaded app slots. Tap one to open it; Harbor restarts as that app.")
        }
    }

    /// How long this copy of Harbor has left.
    @ViewBuilder
    private var expirySection: some View {
        if let expiry = model.harborExpiry {
            Section {
                LabeledContent("Harbor works until", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(expiry < Date().addingTimeInterval(48 * 3600) ? Color.red : Color.primary)
                Toggle("Remind me before then", isOn: Binding(
                    get: { model.expiryReminders },
                    set: { wanted in Task { await model.setExpiryReminders(wanted) } }
                ))
            } footer: {
                Text("A free Apple ID signs an app for seven days. After that Harbor will not open, and nor will the apps inside it, until it is renewed. For now that means running it from Xcode again; the apps and their data stay.")
            }
        }
    }

    /// The apps open beside Harbor right now.
    @ViewBuilder
    private var runningSection: some View {
        if !model.sessions.running.isEmpty {
            Section("Open now") {
                ForEach(model.sessions.running) { session in
                    Button {
                        model.sessions.show(session.id)
                    } label: {
                        GuestRow(guest: session.guest, icon: model.icon(for: session.guest), caption: "Running")
                    }
                    .swipeActions {
                        Button("Close", role: .destructive) { model.sessions.close(session.id) }
                    }
                }
            }
        }
    }

    private var deviceSection: some View {
        Section("This device") {
            switch model.pairing {
            case .missing:
                Label("No pairing file", systemImage: "link.badge.plus")
                Button("Import pairing file") { pick(.pairing) }
            case .stored:
                Label("Pairing file stored, not connected", systemImage: "link")
                Button("Connect") { Task { await model.connect() } }
                Button("Replace pairing file") { pick(.pairing) }
            case .connected(let identifier):
                Label("Connected", systemImage: "checkmark.circle")
                LabeledContent("Device", value: "…" + identifier.suffix(6))
                Button("Replace pairing file") { pick(.pairing) }
            }
        }
    }

    private var accountSection: some View {
        Section("Apple ID") {
            if let appleID = model.appleID {
                LabeledContent("Signed in", value: appleID)
                Button("Sign out", role: .destructive) { model.signOut() }
            } else {
                Button("Sign in") { showingSignIn = true }
            }
        }
    }

    private var appsSection: some View {
        Section {
            if model.apps.isEmpty {
                Text("No apps installed yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.headline)
                    Text("Version \(app.version) · expires \(app.expiry.formatted(.relative(presentation: .named)))")
                        .font(.subheadline)
                        .foregroundStyle(app.expiry < Date() ? Color.red : Color.secondary)
                    if let unavailable = app.unavailableCapabilities, !unavailable.isEmpty {
                        Text("Not available with this Apple ID: \(unavailable.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Refresh") { Task { await model.refresh(app) } }
                }
            }
            Button("Install an app") { pick(.app) }
                .disabled(model.appleID == nil)
        } header: {
            Text("Apps")
        } footer: {
            Text("Installing needs LocalDevVPN connected, a pairing file and an Apple ID. Swipe an app to refresh it.")
        }
    }

    @ViewBuilder
    private var activityBanner: some View {
        if let activity = model.activity {
            HStack(spacing: 12) {
                ProgressView()
                Text(activity)
                    .monospacedDigit()
                if model.isDownloading {
                    Button("Cancel") { model.cancelDownload() }
                }
            }
            .padding()
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private static func describe(_ identity: IdentitySummary) -> String {
        var parts = [identity.name]
        if let expires = identity.expires {
            parts.append("expires \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("serial …\(identity.serialSuffix)")
        return parts.joined(separator: " · ")
    }

    private static func describe(_ prompt: VerificationPrompt) -> String {
        switch prompt {
        case .trustedDeviceCode(let error):
            [error, "Enter the code shown on your other Apple devices."].compactMap { $0 }.joined(separator: "\n")
        case .phoneCode(let number, let error):
            [error, "Enter the code sent to \(number ?? "your phone")."].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

/// One app in a list: its own icon, its name and a line underneath.
private struct GuestRow: View {
    let guest: GuestApp
    let icon: UIImage?
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(uiImage: icon).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name).font(.headline)
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Hands a Home Screen shortcut to iOS and says what happens next.
///
/// iOS only installs a profile that Safari shows it, and only after the user
/// approves it in Settings. Neither step can be skipped by an app.
private struct ShortcutSheet: View {
    let offer: AppModel.ShortcutOffer
    @Environment(\.dismiss) private var dismiss
    @State private var showingSafari = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Tap Continue, then Allow when iOS asks to download a profile.", systemImage: "1.circle")
                    Label("Open Settings. Tap Profile Downloaded near the top, then Install.", systemImage: "2.circle")
                    Label("\(offer.name) appears on your Home Screen and opens inside Harbor.", systemImage: "3.circle")
                } footer: {
                    Text("The profile adds one bookmark and changes no settings. Deleting the icon removes it. iOS shows a warning that the profile is not signed: that is expected, because it is made on this iPhone.")
                }
                Section {
                    Button("Continue") { showingSafari = true }
                }
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
    }
}

private struct SafariPage: UIViewControllerRepresentable {
    let address: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: address)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
