import HarborCore
import SwiftUI

/// The Sources tab: the app lists the user has added.
struct SourcesView: View {
    @Bindable var model: AppModel

    @State private var isAdding = false
    @State private var address = ""

    var body: some View {
        List {
            if model.sources.isEmpty {
                VStack(spacing: 6) {
                    Text("No Sources")
                        .font(.headline)
                    Text("A source is a web address that lists apps, like the ones AltStore and SideStore use.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Source") { isAdding = true }
                        .buttonStyle(.bordered)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                Section {
                    ForEach(model.sources) { source in
                        NavigationLink {
                            SourceView(model: model, source: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(.body.weight(.medium))
                                Text(source.url.host ?? source.url.absoluteString)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { model.removeSource(source) }
                        }
                    }
                } footer: {
                    Text("Sources are run by other people. Only add ones you trust.")
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Source", systemImage: "plus") { isAdding = true }
            }
        }
        .alert("Add Source", isPresented: $isAdding) {
            TextField("https://", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                let typed = address
                address = ""
                Task { await model.addSource(typed) }
            }
            Button("Cancel", role: .cancel) { address = "" }
        } message: {
            Text("Enter the source's web address.")
        }
    }
}

/// The apps one source lists.
struct SourceView: View {
    @Bindable var model: AppModel
    let source: SavedSource

    @State private var catalogue: SourceCatalogue?
    @State private var failure: Problem?
    @State private var search = ""

    private var matches: [SourceCatalogue.App] {
        guard let catalogue else { return [] }
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return catalogue.apps }
        return catalogue.apps.filter {
            $0.name.localizedCaseInsensitiveContains(wanted)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(wanted)
        }
    }

    var body: some View {
        List {
            if let catalogue {
                if let failure {
                    // A refresh failed; what was read before is still shown.
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Couldn't refresh").font(.body.weight(.medium))
                                Text(failure.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    ForEach(matches) { app in
                        NavigationLink {
                            SourceAppView(model: model, app: app)
                        } label: {
                            SourceAppRow(app: app)
                        }
                    }
                } footer: {
                    if catalogue.skippedEntries > 0 {
                        Text("^[\(catalogue.skippedEntries) app](inflect: true) left out because \(catalogue.skippedEntries == 1 ? "it's" : "they're") incomplete or not offered securely.")
                    }
                }
            } else if let failure {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.title).font(.headline)
                        Text(failure.detail).foregroundStyle(.secondary)
                    }
                    Button("Try Again") { Task { await load(reload: true) } }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: catalogue.map { $0.apps.count == 1 ? "Search 1 app" : "Search \($0.apps.count) apps" } ?? "Search")
        .overlay {
            if catalogue != nil, matches.isEmpty, !search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .task { await load(reload: false) }
        .refreshable { await load(reload: true) }
    }

    private func load(reload: Bool) async {
        if catalogue != nil, !reload { return }
        do {
            catalogue = try await model.catalogue(of: source, reload: reload)
            failure = nil
        } catch is CancellationError {
            // The view went away.
        } catch {
            failure = Problem(error)
        }
    }
}

private struct SourceAppRow: View {
    let app: SourceCatalogue.App

    var body: some View {
        HStack(spacing: 12) {
            SourceAppIcon(url: app.iconURL, side: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.medium))
                Text(Self.caption(app))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let summary = app.summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    static func caption(_ app: SourceCatalogue.App) -> String {
        guard let newest = app.versions.first else { return "No download" }
        var parts = [newest.version.isEmpty ? "Unknown version" : "Version \(newest.version)"]
        if let size = newest.size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}

struct SourceAppIcon: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One app from a source, and the versions it can be added in.
struct SourceAppView: View {
    @Bindable var model: AppModel
    let app: SourceCatalogue.App

    @State private var pending: SourceCatalogue.Version?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SourceAppIcon(url: app.iconURL, side: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.bold())
                        if let developer = app.developerName {
                            Text(developer).foregroundStyle(.secondary)
                        }
                        Text(app.bundleIdentifier)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = app.subtitle {
                    Text(subtitle)
                }
                if let summary = app.summary {
                    Text(summary)
                }
            }

            Section {
                if app.versions.isEmpty {
                    Text("This source doesn't offer a download for this app.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.versions) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.version.isEmpty ? "Unknown version" : "Version \(version.version)")
                                .font(.body.weight(.medium))
                            Text(Self.caption(version))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Get") { pending = version }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
            } header: {
                Text("Versions")
            } footer: {
                Text("Harbor downloads the app, signs it on this iPhone and adds it to your apps. Keep Harbor open until it's done.")
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Add \(app.name)?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { version in
            Button("Add") { model.startAdding(version, of: app) }
            Button("Cancel", role: .cancel) {}
        } message: { version in
            Text(explanation(of: version))
        }
    }

    private func explanation(of version: SourceCatalogue.Version) -> String {
        var sentences: [String] = []
        if model.guests.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            sentences.append("This replaces the copy you have and keeps its data.")
        }
        if version.sha256 == nil {
            sentences.append("The source doesn't publish a checksum, so Harbor can't confirm the download is genuine.")
        }
        sentences.append("Apps in Harbor run with Harbor's access. Only add apps you trust.")
        return sentences.joined(separator: "\n\n")
    }

    static func caption(_ version: SourceCatalogue.Version) -> String {
        var parts: [String] = []
        if let date = version.date, !date.isEmpty {
            parts.append(PublishedDate.display(date))
        }
        if let size = version.size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if version.sha256 != nil {
            parts.append("Checksum")
        }
        return parts.joined(separator: " · ")
    }
}
