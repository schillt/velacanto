import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    @Entry var foundationLocalLibrary: FoundationLocalLibraryModel? = nil
}

/// Index-only presentation: these records never enter server item/action routes.
struct FoundationLocalLibraryView: View {
    let model: FoundationLocalLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var confirmingForget = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Index audio files in a folder you choose. Files stay in place and are read-only. Playback is not available for this index."
                    )
                    Text("Cloud-only files are not downloaded. Refreshing is always manual.")
                        .foregroundStyle(.secondary)
                }
                Section("Selected Folder") {
                    if let activity = model.activity {
                        ProgressView(activityLabel(activity))
                    }
                    Text(status).accessibilityIdentifier("local-library-status")
                    if let message = model.errorMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button(
                        model.catalog == nil ? "Choose Folder" : "Choose Folder Again",
                        systemImage: "folder.badge.plus"
                    ) {
                        choosingFolder = true
                    }
                    .disabled(model.activity != nil)
                    .accessibilityIdentifier("local-library-choose-folder")
                    if model.restorationCancelled {
                        Button("Load Saved Index", systemImage: "arrow.clockwise") {
                            model.restore()
                        }
                        .disabled(model.activity != nil)
                    }
                    if model.catalog != nil {
                        Button("Refresh Index", systemImage: "arrow.clockwise") { model.refresh() }
                            .disabled(model.activity != nil)
                            .accessibilityIdentifier("local-library-refresh")
                    }
                    if model.activity == .refreshing || model.activity == .restoring {
                        Button("Cancel Loading", role: .cancel) { model.cancel() }
                    }
                    if model.catalog != nil || model.corruptSelection || model.restorationCancelled
                    {
                        Button(
                            "Forget Folder", systemImage: "folder.badge.minus", role: .destructive
                        ) {
                            confirmingForget = true
                        }
                        .disabled(model.activity == .selecting || model.activity == .forgetting)
                    }
                }
                if let catalog = model.catalog, !catalog.records.isEmpty {
                    Section("Indexed Files (\(catalog.records.count))") {
                        ForEach(catalog.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).lineLimit(2)
                                Text(
                                    record.missing
                                        ? "Missing at last complete refresh" : "Indexed audio file"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                Text(record.byteCount, format: .byteCount(style: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Local Library")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 600, minHeight: 440, idealHeight: 620)
        #endif
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): model.select(folder)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.importerFailed() }
            }
        }
        .confirmationDialog(
            "Forget this folder?", isPresented: $confirmingForget, titleVisibility: .visible
        ) {
            Button("Forget Folder", role: .destructive) { model.forget() }
        } message: {
            Text(
                "Removes saved folder access and hides its index. Music files are never deleted. Private cached index snapshots remain on this device; this does not erase them or existing backups."
            )
        }
    }

    private var status: String {
        if model.activity == .restoring, model.catalog == nil {
            return "Restoring the saved index without opening the music folder."
        }
        if model.restorationCancelled {
            return
                "Saved-index loading was cancelled. Load it explicitly, or choose a folder again."
        }
        if model.corruptSelection {
            return
                "Saved folder access could not be restored. Choose the folder again, or forget its authorization."
        }
        guard let catalog = model.catalog else {
            return "No folder selected. Choose a folder, then refresh its index."
        }
        switch catalog.state {
        case .ready: return "Showing the saved index. Refresh to check for changes."
        case .empty:
            return "No available files in the saved index. Refresh to inspect the selected folder."
        case .partial:
            return "The last refresh was incomplete. Some files may be absent or out of date."
        case .unavailable:
            return
                "Folder unavailable. Cached records may be out of date. Reconnect the location or choose the folder again."
        case .corrupt:
            return "The saved index is damaged. Refresh to rebuild it, or choose the folder again."
        }
    }

    private func activityLabel(_ activity: FoundationLocalLibraryModel.Activity) -> String {
        switch activity {
        case .restoring: "Loading saved index…"
        case .selecting: "Saving folder access…"
        case .refreshing: "Refreshing index…"
        case .forgetting: "Forgetting folder access…"
        }
    }
}
