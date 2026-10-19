import HarborCore
import SwiftUI

/// The Apps tab: what's left to set up, how long Harbor has, and the apps.
struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(Router.self) private var router
    @State private var removing: GuestApp?

    var body: some View {
        List {
            Group {
                setupSection
                statusSection
            }
            .disabled(model.isBusy)
            // Apps already open stay reachable during a long download.
            runningSection
            Group {
                guestsSection
                installedSection
            }
            .disabled(model.isBusy)
        }
        .navigationTitle("Harbor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addMenu.disabled(model.isBusy) }
        }
        .animation(.default, value: model.guests.map(\.folderName))
        .confirmationDialog(
            "Remove \(removing?.name ?? "app")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { guest in
            Button("Remove", role: .destructive) { model.removeGuest(guest) }
        } message: { _ in
            Text("Its data is deleted too.")
        }
    }

    // MARK: Getting started

    private enum SetupStep: CaseIterable {
        case pair, signIn, certificate, automation
    }

    private var setupSteps: [SetupStep] {
        SetupStep.allCases.filter { step in
            switch step {
            case .pair: model.pairing == .missing
            case .signIn: model.appleID == nil
            case .certificate: AppModel.signedGuestsRequired && !model.hasSigningIdentity
            case .automation: model.harborExpiry != nil && model.automationHealth == .notSetUp
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        let steps = setupSteps
        if !steps.isEmpty {
            Section("Get Started") {
                ForEach(steps, id: \.self) { step in
                    setupRow(step)
                }
            }
        }
    }

    @ViewBuilder
    private func setupRow(_ step: SetupStep) -> some View {
        switch step {
        case .pair:
            if PhonePairing.isSupported {
                NavigationLink {
                    PairingView(model: model)
                } label: {
                    SetupRow(symbol: "link", color: .blue, title: "Pair This iPhone", detail: "Lets Harbor install and renew apps.")
                }
            } else {
                Button {
                    router.pick(.pairing)
                } label: {
                    SetupRow(symbol: "link", color: .blue, title: "Import Pairing File", detail: "Harbor Setup on a Mac makes one.")
                }
            }
        case .signIn:
            Button {
                router.showingSignIn = true
            } label: {
                SetupRow(symbol: "person.fill", color: .gray, title: "Sign In", detail: "Your Apple ID signs the apps you install.")
            }
        case .certificate:
            Button {
                router.pick(.certificate)
            } label: {
                SetupRow(symbol: "checkmark.seal.fill", color: .green, title: "Add Signing Certificate", detail: "Needed to open apps. Import a .p12 file.")
            }
        case .automation:
            NavigationLink {
                AutomationView(model: model)
            } label: {
                SetupRow(symbol: "clock.arrow.circlepath", color: .indigo, title: "Renew Automatically", detail: "Keep Harbor running with a daily shortcut.")
            }
        }
    }

    // MARK: Harbor's own expiry

    @ViewBuilder
    private var statusSection: some View {
        if let expiry = model.harborExpiry {
            Section("Renewal") {
                ExpiryRow(expiry: expiry, canRenew: model.appleID != nil) {
                    Task { await model.renewHarbor() }
                }
                if let note = model.renewalNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Apps

    @ViewBuilder
    private var runningSection: some View {
        if !model.sessions.running.isEmpty {
            Section("Open") {
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

    private var guestsSection: some View {
        Section {
            if model.guests.isEmpty {
                VStack(spacing: 6) {
                    Text("No Apps Yet")
                        .font(.headline)
                    Text("Add an app from Files or find one in Sources.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ViewThatFits {
                        HStack { emptyActions }
                        VStack { emptyActions }
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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
                        Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                            Task { await model.launch(guest, mode: .wholeApp) }
                        }
                    }
                    Button("Add to Home Screen", systemImage: "plus.app") {
                        Task { await model.offerShortcut(for: guest) }
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        removing = guest
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("Remove", role: .destructive) { removing = guest }
                }
                .swipeActions(edge: .leading) {
                    Button("Home Screen", systemImage: "plus.app") {
                        Task { await model.offerShortcut(for: guest) }
                    }
                    .tint(.blue)
                }
            }
        } header: {
            if !model.guests.isEmpty { Text("In Harbor") }
        } footer: {
            if !model.guests.isEmpty {
                Text("These don't count toward your 3-app limit. Touch and hold an app for more options.")
            }
        }
    }

    @ViewBuilder
    private var emptyActions: some View {
        Button("Add from Files") { router.pick(.guest) }
        Button("Browse Sources") { router.tab = .sources }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !model.apps.isEmpty {
            Section {
                ForEach(model.apps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.body.weight(.medium))
                        Text("Version \(app.version) · \(app.expiry < model.clock ? "Expired" : "Expires \(app.expiry.relative)")")
                            .font(.subheadline)
                            .foregroundStyle(app.expiry < model.clock ? Color.red : Color.secondary)
                        if let unavailable = app.unavailableCapabilities, !unavailable.isEmpty {
                            Text("Unavailable with a free Apple ID: \(unavailable.joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        Button("Renew") { Task { await model.refresh(app) } }
                            .tint(.blue)
                    }
                }
            } header: {
                Text("On Home Screen")
            } footer: {
                Text("Swipe an app to renew it.")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Add from Files", systemImage: "folder") { router.pick(.guest) }
            Button("Browse Sources", systemImage: "tray.full") { router.tab = .sources }
            Divider()
            Button("Install on Home Screen", systemImage: "apps.iphone") { router.pick(.app) }
                .disabled(model.appleID == nil || model.pairing == .missing)
        } label: {
            Label("Add", systemImage: "plus")
        }
    }
}

private struct SetupRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Color.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

/// How long until Harbor stops opening, and the button that renews it.
struct ExpiryRow: View {
    let expiry: Date
    let canRenew: Bool
    let renew: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Redrawn every minute so "in 3 hours" stays true.
        TimelineView(.everyMinute) { context in
            let left = expiry.timeIntervalSince(context.date)
            // At the largest text sizes the button goes underneath.
            let stacked = typeSize.isAccessibilitySize
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    SymbolTile(
                        systemName: left <= 0 ? "exclamationmark.triangle.fill" : "clock.fill",
                        color: left < 48 * 3600 ? .orange : .green,
                        side: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(left <= 0 ? "Harbor has expired" : "Expires \(expiry.relative)")
                            .font(.body.weight(.medium))
                        Text(expiry.dayAndTime(relativeTo: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !stacked { Spacer(minLength: 8) }
                Button("Renew", action: renew)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(!canRenew)
            }
            .padding(.vertical, 4)
        }
    }
}
