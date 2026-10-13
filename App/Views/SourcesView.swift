import HarborCore
import SwiftUI

/// The sources the user has added.
struct SourcesView: View {
    @Bindable var model: AppModel

    @State private var isAdding = false
    @State private var address = ""

    var body: some View {
        List {
            Section {
                if model.sources.isEmpty {
                    Text("No sources yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sources) { source in
                    NavigationLink {
                        SourceView(model: model, source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.headline)
                            Text(source.url.host ?? source.url.absoluteString)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { model.removeSource(source) }
                    }
                }
                Button("Add a source") { isAdding = true }
            } footer: {
                Text("A source is a web address that lists apps, in the format AltStore and SideStore use. Harbor does not check or endorse what a source offers: whoever runs it decides what you download.")
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("Sources")
        .alert("Add a source", isPresented: $isAdding) {
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
            Text("Enter the source's address.")
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
                        Text("\(catalogue.skippedEntries) entries were left out: malformed, or not offered over a secure connection.")
                    }
                }
            } else if let failure {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.title).font(.headline)
                        Text(failure.detail).foregroundStyle(.secondary)
                    }
                    Button("Try again") { Task { await load(reload: true) } }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the source")
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: catalogue.map { "Search \($0.apps.count) apps" } ?? "Search")
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
                Text(app.name).font(.headline)
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
        guard let newest = app.versions.first else { return "Nothing to download" }
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
                    Text("This source lists the app but offers nothing to download.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.versions) { version in
                    Button {
                        pending = version
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.version.isEmpty ? "Unknown version" : "Version \(version.version)")
                                .font(.headline)
                            Text(Self.caption(version))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Add to Harbor")
            } footer: {
                Text("The app is downloaded, signed on this iPhone and added to the apps that run inside Harbor. Keep Harbor open until it finishes.")
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
            Button("Add to Harbor") { model.startAdding(version, of: app) }
            Button("Cancel", role: .cancel) {}
        } message: { version in
            Text(explanation(of: version))
        }
    }

    private func explanation(of version: SourceCatalogue.Version) -> String {
        var sentences: [String] = []
        if version.sha256 == nil {
            sentences.append("This source publishes no checksum for this download, so Harbor cannot confirm it is the file the source's author published.")
        } else {
            sentences.append("Harbor checks the download against the source's checksum before adding it.")
        }
        sentences.append("Apps inside Harbor run with Harbor's own access, which includes your signing certificate. Only add apps from a source you trust.")
        if model.guests.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            sentences.append("This replaces the copy already in Harbor and keeps its data.")
        }
        return sentences.joined(separator: "\n\n")
    }

    static func caption(_ version: SourceCatalogue.Version) -> String {
        var parts: [String] = []
        if let date = version.date, !date.isEmpty {
            parts.append(date)
        }
        if let size = version.size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        parts.append(version.sha256 == nil ? "no checksum" : "checksum published")
        return parts.joined(separator: " · ")
    }
}
