import HarborCore
import HarborSigning
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
                guestsSection
                deviceSection
                accountSection
                appsSection
            }
            .navigationTitle("Harbor")
            .overlay(alignment: .bottom) { activityBanner }
            .disabled(model.isBusy)
        }
        .task { await model.start() }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guest.name).font(.headline)
                        Text(guest.version.isEmpty ? guest.bundleIdentifier : "Version \(guest.version)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { model.removeGuest(guest) }
                }
            }
            Button("Add an app to Harbor") { pick(.guest) }
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
            Text("These apps run inside Harbor and do not use one of the three sideloaded app slots. Tap one to open it; Harbor restarts as that app.")
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
            }
            .padding()
            .background(.regularMaterial, in: Capsule())
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
