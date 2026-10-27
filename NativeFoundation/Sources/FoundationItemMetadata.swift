import SwiftUI

/// Display-only metadata. Provider person identifiers never become catalog artist links.
struct FoundationItemMetadata: Equatable, Sendable {
    struct Credit: Hashable, Sendable {
        let name: String
        let role: String
        let detail: String?
    }
    let credits: [Credit]
    let year: Int?
    let genres: [String]
    let hasAdditionalCredits: Bool
    let hasAdditionalGenres: Bool
    var isEmpty: Bool {
        credits.isEmpty && year == nil && genres.isEmpty && !hasAdditionalCredits
            && !hasAdditionalGenres
    }

}

struct FoundationItemMetadataView: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: FoundationItemMetadata?
    @State private var failure: FoundationLibraryError?
    @State private var loaded = false
    @State private var resultScope: String?
    @State private var retry = 0
    @State private var requestID = UUID()

    private var taskID: String {
        library.metadataScopeID + "." + item.id + ".\(connectivity.localOnly).\(retry)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.title).font(.headline)
                    if !item.subtitle.isEmpty { Text(item.subtitle).foregroundStyle(.secondary) }
                }
                if !library.supportsItemMetadata {
                    message(
                        "Credits unavailable", "This music source does not support song credits.")
                } else if connectivity.localOnly {
                    message(
                        "Connect to view credits", "Song credits are not stored for offline use.")
                } else if resultScope == taskID, let failure {
                    Section {
                        Text("Couldn’t load credits").font(.headline)
                        Text(failure.localizedDescription).foregroundStyle(.secondary)
                        Button("Try Again") { retry += 1 }
                    }
                } else if !loaded || resultScope != taskID {
                    ProgressView("Loading credits…")
                } else if let metadata, !metadata.isEmpty {
                    if !metadata.credits.isEmpty || metadata.hasAdditionalCredits {
                        Section("Credits") {
                            ForEach(metadata.credits, id: \.self) { credit in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(credit.name).font(.headline)
                                    Text(credit.role).foregroundStyle(.secondary)
                                    if let detail = credit.detail, detail != credit.role {
                                        Text(detail).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if metadata.hasAdditionalCredits {
                                Text(
                                    "Some credit entries supplied by your music source are omitted from this view."
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if metadata.year != nil || !metadata.genres.isEmpty {
                        Section("Song Information") {
                            if let year = metadata.year {
                                LabeledContent("Year", value: String(year))
                            }
                            if !metadata.genres.isEmpty {
                                if let titles = primaryGenres.primaryGenreTitles(for: item) {
                                    LabeledContent(
                                        "Genres",
                                        value: titles.isEmpty
                                            ? "No genre tags" : titles.joined(separator: ", "))
                                } else {
                                    LabeledContent("Genres", value: "Primary genres not indexed")
                                }
                                DisclosureGroup("All source genres") {
                                    Text(metadata.genres.joined(separator: ", "))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if metadata.hasAdditionalGenres {
                                Text(
                                    "Some genres supplied by your music source are omitted from this view."
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    message(
                        "No credits provided",
                        "Your music source has no additional metadata for this song.")
                }
            }
            .foregroundStyle(.primary)
            .tint(.accentColor)
            .navigationTitle("Song Credits")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 460, minHeight: 360, idealHeight: 520)
        #endif
        .task(id: taskID) { await load() }
        .onDisappear { requestID = UUID() }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        Section {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }

    @MainActor private func load() async {
        let request = UUID()
        let scope = taskID
        requestID = request
        metadata = nil
        failure = nil
        loaded = false
        resultScope = nil
        guard library.supportsItemMetadata, !connectivity.localOnly else { return }
        do {
            let result = try await library.itemMetadata(for: item)
            guard !Task.isCancelled, request == requestID else { return }
            resultScope = scope
            metadata = result
            loaded = true
        } catch {
            guard !Task.isCancelled, request == requestID else { return }
            resultScope = scope
            failure = FoundationLibraryError.category(error)
        }
    }
}
