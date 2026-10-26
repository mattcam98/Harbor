import HarborCore
import HarborSigning
import SwiftUI
import UniformTypeIdentifiers

/// Interface state shared by the tabs: which tab is showing, and the file
/// picker and sign-in sheet any of them can open.
@MainActor
@Observable
final class Router {
    enum Tab: Hashable {
        case apps, sources, settings
    }

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

    var tab = Tab.apps
    var importKind = ImportKind.guest
    var isImporting = false
    var showingSignIn = false

    func pick(_ kind: ImportKind) {
        importKind = kind
        isImporting = true
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    @State private var router = Router()
    @State private var code = ""
    @State private var pendingCertificate: URL?
    @State private var certificatePassword = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $router.tab) {
            screen { LibraryView(model: model) }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                .tag(Router.Tab.apps)
            screen { SourcesView(model: model) }
                .tabItem { Label("Sources", systemImage: "tray.full.fill") }
                .tag(Router.Tab.sources)
            screen { SettingsView(model: model) }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Router.Tab.settings)
        }
        .environment(router)
        .overlay {
            // Opening a guest from its Home Screen icon: the user sees its
            // icon, as the guest itself shows while it starts, not Harbor.
            if let opening = model.openingFromLink {
                LaunchCover(icon: model.guests.first { $0.bundleIdentifier == opening }.flatMap(model.icon(for:)))
                    .ignoresSafeArea()
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.tick()
                Task { await model.cameToFront() }
            }
        }
        // Midnight, a clock change or a new time zone.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.tick()
        }
        .fileImporter(isPresented: $router.isImporting, allowedContentTypes: router.importKind.contentTypes) { result in
            guard case .success(let url) = result else { return }
            let kind = router.importKind
            Task {
                switch kind {
                case .pairing: await model.importPairing(from: url)
                case .app: await model.install(ipaAt: url)
                case .guest: await model.addGuest(ipaAt: url)
                case .certificate: pendingCertificate = url
                }
            }
        }
        .alert(
            "Add This Source?",
            isPresented: Binding(get: { model.linkedSource != nil }, set: { if !$0 { model.linkedSource = nil } }),
            presenting: model.linkedSource
        ) { address in
            Button("Add") {
                router.tab = .sources
                Task { await model.addSource(address.absoluteString) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { address in
            Text("\(address.host ?? address.absoluteString) will be able to offer apps for you to download. Only add sources you trust.")
        }
        .sheet(isPresented: $router.showingSignIn) {
            SignInView(model: model)
        }
        .sheet(item: $model.shortcutOffer) { offer in
            HomeScreenIconSheet(offer: offer)
        }
        .alert(
            "Certificate Password",
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
            Text("Enter the password you chose when you exported it.")
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
            "Verification Code",
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

    /// One tab: its own navigation, with the progress banner above the tab
    /// bar. The banner stays usable while the screen is busy; it holds Cancel.
    private func screen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
        }
        .safeAreaInset(edge: .bottom) {
            ActivityBanner(model: model)
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

/// What covers Harbor's interface while it gets a guest on screen.
private struct LaunchCover: UIViewRepresentable {
    let icon: UIImage?

    func makeUIView(context: Context) -> LaunchPlaceholder {
        LaunchPlaceholder(icon: icon)
    }

    func updateUIView(_ view: LaunchPlaceholder, context: Context) {
        view.icon = icon
    }
}
