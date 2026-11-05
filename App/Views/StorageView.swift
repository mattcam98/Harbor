import HarborCore
import SwiftUI

/// Settings › Storage: how much space Harbor takes, what can be given back
/// safely, and each app's share.
///
/// Laid out like iPhone Storage: the total and a bar first, then the
/// clean-ups worth doing, then the apps, largest first. Clearing what can
/// be made again takes one tap; deleting data asks first.
struct StorageView: View {
    @Bindable var model: AppModel
    @State private var confirmingUnusedData = false

    /// Below this a clean-up is not worth suggesting.
    static let worthSuggesting: Int64 = 1_000_000

    var body: some View {
        List {
            if let report = model.storage {
                summarySection(report)
                suggestionsSection(report)
                appsSection(report)
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Calculating…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .disabled(model.isBusy)
        .task { await model.measureStorage() }
        .refreshable { await model.measureStorage() }
        .onDisappear { model.forgetStorageFreed() }
    }

    // MARK: Total

    private func summarySection(_ report: StorageReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(report.total.bytes)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("used")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // Over the row, so it doesn't move the row when it comes and goes.
                .overlay(alignment: .trailing) {
                    if model.isMeasuringStorage {
                        ProgressView()
                            .accessibilityLabel("Updating")
                    }
                }
                StorageBar(categories: StorageCategory.all(in: report), total: report.total)
                if let available = Self.availableOnDevice {
                    Text("\(available.bytes) available on this \(UIDevice.current.model)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            ForEach(StorageCategory.all(in: report).filter { $0.bytes > 0 }) { category in
                LabeledContent {
                    Text(category.bytes.bytes)
                        .monospacedDigit()
                } label: {
                    Label {
                        Text(category.name)
                    } icon: {
                        Circle()
                            .fill(category.color)
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
    }

    /// Space left on the device for things the user asks for.
    private static var availableOnDevice: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Suggestions

    @ViewBuilder
    private func suggestionsSection(_ report: StorageReport) -> some View {
        let skippedOpen = report.apps.contains { usage in
            usage.caches > 0 && usage.containers.contains(where: model.containersInUse.contains)
        }
        let temporary = report.temporaryFiles >= Self.worthSuggesting
        let caches = report.caches >= Self.worthSuggesting
        let unused = !report.unusedContainers.isEmpty

        Section {
            if temporary {
                SuggestionRow(
                    title: "Temporary Files",
                    detail: "Left over from downloads and installs. Nothing you need is in them.",
                    bytes: report.temporaryFiles,
                    action: "Clear Temporary Files"
                ) {
                    Task { await model.cleanUp(.temporaryFiles) }
                }
            }
            if caches {
                SuggestionRow(
                    title: "Caches",
                    detail: skippedOpen
                        ? "Files apps keep to open faster, and fetch again when needed. Apps that are open now are skipped."
                        : "Files apps keep to open faster, and fetch again when needed.",
                    bytes: report.caches,
                    action: "Clear Caches"
                ) {
                    Task { await model.cleanUp(.caches) }
                }
            }
            if unused {
                SuggestionRow(
                    title: "Data from Removed Apps",
                    detail: report.unusedContainers.count == 1
                        ? "Documents and settings left by an app that's no longer in Harbor."
                        : "Documents and settings left by \(report.unusedContainers.count) apps that are no longer in Harbor.",
                    bytes: report.unusedData,
                    action: "Delete…",
                    role: .destructive
                ) {
                    confirmingUnusedData = true
                }
                // On the row, so that where it shows as a popover it points here.
                .confirmationDialog(
                    "Delete Data from Removed Apps?",
                    isPresented: $confirmingUnusedData,
                    titleVisibility: .visible
                ) {
                    Button("Delete Data", role: .destructive) {
                        Task { await model.cleanUp(.unusedData) }
                    }
                } message: {
                    Text("The documents and settings these apps left behind will be deleted. This can't be undone.")
                }
            }
            if !temporary && !caches && !unused {
                Label("Nothing to clean up", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recommendations")
        } footer: {
            if let freed = model.storageFreed {
                Text(freed > 0 ? "Freed \(freed.bytes)." : "There was nothing to free.")
            }
        }
    }

    // MARK: Apps

    @ViewBuilder
    private func appsSection(_ report: StorageReport) -> some View {
        if !report.apps.isEmpty {
            Section {
                ForEach(report.apps) { usage in
                    NavigationLink {
                        StorageAppView(model: model, folderName: usage.app.folderName)
                    } label: {
                        HStack(spacing: 12) {
                            AppIcon(image: model.icon(for: usage.app), side: 36)
                            Text(usage.app.name)
                            Spacer()
                            Text(usage.total.bytes)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Each app's size includes its documents, settings and caches.")
            }
        }
    }
}

/// One app's share, and what can be done about it.
private struct StorageAppView: View {
    @Bindable var model: AppModel
    let folderName: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    private var usage: StorageReport.AppUsage? {
        model.storage?.apps.first { $0.app.folderName == folderName }
    }

    var body: some View {
        List {
            if let usage {
                let isOpen = usage.containers.contains(where: model.containersInUse.contains)
                Section {
                    HStack(spacing: 14) {
                        AppIcon(image: model.icon(for: usage.app), side: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usage.app.name)
                                .font(.headline)
                            if !usage.app.version.isEmpty {
                                Text("Version \(usage.app.version)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("App", value: usage.bundle.bytes)
                    LabeledContent("Documents & Data", value: usage.data.bytes)
                    LabeledContent("Caches", value: usage.caches.bytes)
                    LabeledContent("Total", value: usage.total.bytes)
                        .fontWeight(.semibold)
                }
                .monospacedDigit()

                Section {
                    Button("Clear Cache") {
                        Task { await model.cleanUp(.cachesOf(usage.app)) }
                    }
                    .disabled(usage.caches == 0 || isOpen)
                } footer: {
                    if isOpen {
                        Text("Close \(usage.app.name) to clear its cache.")
                    } else {
                        Text("\(usage.app.name) fetches these files again when it needs them, so it may open more slowly next time.")
                    }
                }

                Section {
                    Button("Remove App", role: .destructive) { confirmingRemoval = true }
                } footer: {
                    Text("Removes \(usage.app.name) and its documents and data from Harbor.")
                }
            }
        }
        .navigationTitle(usage?.app.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isBusy)
        .confirmationDialog(
            "Remove \(usage?.app.name ?? "app")?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible,
            presenting: usage?.app
        ) { app in
            Button("Remove", role: .destructive) {
                model.removeGuest(app)
                dismiss()
                Task { await model.measureStorage() }
            }
        } message: { _ in
            Text("Its data is deleted too.")
        }
    }
}

/// One kind of storage, as the bar and its legend show it.
struct StorageCategory: Identifiable {
    let name: String
    let bytes: Int64
    let color: Color
    var id: String { name }

    static func all(in report: StorageReport) -> [StorageCategory] {
        [
            StorageCategory(name: "Apps", bytes: report.appBundles, color: .blue),
            StorageCategory(name: "Documents & Data", bytes: report.appData, color: .green),
            StorageCategory(name: "Caches", bytes: report.caches, color: .orange),
            StorageCategory(name: "Temporary Files", bytes: report.temporaryFiles, color: .yellow),
            StorageCategory(name: "Harbor", bytes: report.harbor, color: .gray),
        ]
    }
}

/// A bar split by category, as iPhone Storage draws it.
private struct StorageBar: View {
    let categories: [StorageCategory]
    let total: Int64

    var body: some View {
        GeometryReader { geometry in
            let shown = categories.filter { $0.bytes > 0 }
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown) { category in
                    // Anything there at all stays visible.
                    category.color
                        .frame(width: max(3, (geometry.size.width - gaps) * fraction(category)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Storage by kind")
        .accessibilityValue(categories.filter { $0.bytes > 0 }.map { "\($0.name), \($0.bytes.bytes)" }.joined(separator: "; "))
    }

    private func fraction(_ category: StorageCategory) -> CGFloat {
        total > 0 ? CGFloat(category.bytes) / CGFloat(total) : 0
    }
}

/// A clean-up: what it is, how much it frees, and the button that does it.
private struct SuggestionRow: View {
    let title: String
    let detail: String
    let bytes: Int64
    let action: String
    var role: ButtonRole?
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(bytes.bytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action, role: role, action: perform)
                .buttonStyle(.borderless)
                .padding(.top, 4)
        }
        .padding(.vertical, 2)
    }
}

extension Int64 {
    /// "1.2 GB", as Files and iPhone Storage write sizes.
    var bytes: String { formatted(.byteCount(style: .file)) }
}
