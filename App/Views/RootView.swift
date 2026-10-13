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

    enum ImportKind {
        case pairing, app

        var contentTypes: [UTType] {
            switch self {
            case .pairing:
                [.propertyList, .xml, UTType(filenameExtension: "mobiledevicepairing") ?? .data, .data]
            case .app:
                [UTType(filenameExtension: "ipa") ?? .data]
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
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
                }
            }
        }
        .sheet(isPresented: $showingSignIn) {
            SignInView(model: model)
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

    private static func describe(_ prompt: VerificationPrompt) -> String {
        switch prompt {
        case .trustedDeviceCode(let error):
            [error, "Enter the code shown on your other Apple devices."].compactMap { $0 }.joined(separator: "\n")
        case .phoneCode(let number, let error):
            [error, "Enter the code sent to \(number ?? "your phone")."].compactMap { $0 }.joined(separator: "\n")
        }
    }
}
