import SwiftUI

/// Storage actions change account-local retention, never the server library.
struct FoundationDownloadManagementView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @State private var editing = false
    @State private var selectedOwners: Set<String> = []
    @State private var selectedTracks: Set<String> = []
    @State private var confirmingSelected = false
    @State private var confirmingAll = false
    @State private var removingAll = false

    private var hasSelection: Bool { !selectedOwners.isEmpty || !selectedTracks.isEmpty }
    private var affectsPlaylist: Bool {
        downloads.owners.contains { owner in
            owner.item.kind == .playlist && owner.tracks.contains { selectedTracks.contains($0.id) }
        }
    }

    var body: some View {
        List {
            storageSection
            songsSection
            collectionsSection
            actionsSection
        }
        .navigationTitle("Downloaded Music")
        .toolbar {
            Button(editing ? "Done" : "Edit") {
                editing.toggle()
                if !editing { clearSelection() }
            }.disabled(removingAll)
        }
        .alert("Remove selected downloads?", isPresented: $confirmingSelected) {
            Button("Remove", role: .destructive) {
                downloads.removeSelected(ownerIDs: selectedOwners, trackIDs: selectedTracks)
                clearSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                affectsPlaylist
                    ? "Some selected songs belong to downloaded playlists. Removing them leaves those playlists partially available. They stay removed on this device until you explicitly download them again. Your server playlists are unchanged."
                    : "Selected songs are removed from every local collection that uses them. Files retained by an unselected collection remain when you remove only a collection. Your server library is unchanged."
            )
        }
        .alert("Remove all downloads?", isPresented: $confirmingAll) {
            Button("Remove All Downloads", role: .destructive) {
                removingAll = true
                Task {
                    let removed = await downloads.removeAll()
                    removingAll = false
                    if removed { clearSelection() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes this account’s downloaded music from this device. Your server library, playlists and favorites are unchanged. Music currently playing is removed after playback releases it."
            )
        }
        .onChange(of: downloads.owners.map(\.id)) { _, ids in
            selectedOwners.formIntersection(Set(ids))
        }
        .onChange(of: downloads.downloadedSongs.map(\.id)) { _, ids in
            selectedTracks.formIntersection(Set(ids))
        }
    }

    private var storageSection: some View {
        Section("On This Device") {
            LabeledContent("Downloaded music", value: bytes(downloads.storageBytes))
            LabeledContent("Audio", value: bytes(downloads.audioBytes))
            LabeledContent("Artwork", value: bytes(downloads.artworkBytes))
            LabeledContent("Other files", value: bytes(downloads.otherBytes))
            LabeledContent("Unique songs", value: "\(downloads.downloadedSongs.count)")
            Text(
                "Songs shared by several albums or playlists count once in the total. Collection sizes show their downloaded files and may overlap."
            )
            .font(.caption).foregroundStyle(.secondary)
            if downloads.isLoading { ProgressView("Verifying downloaded files…") }
            if let error = downloads.errorMessage { Text(error).foregroundStyle(.red) }
            if removingAll { ProgressView("Removing downloads…") }
        }
    }

    private var songsSection: some View {
        Section("Songs") {
            ForEach(downloads.downloadedSongs, id: \.id) { item in
                selectionRow(
                    title: item.title, footprint: downloads.itemBytes(item),
                    selected: selectedTracks.contains(item.id)
                ) {
                    toggle(item.id, in: &selectedTracks)
                }
            }
            if downloads.downloadedSongs.isEmpty {
                Text("No downloaded songs.").foregroundStyle(.secondary)
            }
        }
    }

    private var collectionsSection: some View {
        Section("Albums & Playlists") {
            ForEach(downloads.owners.filter { $0.item.kind != .track }) { owner in
                selectionRow(
                    title: owner.item.title, footprint: downloads.itemBytes(owner.item),
                    selected: selectedOwners.contains(owner.id)
                ) {
                    toggle(owner.id, in: &selectedOwners)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if editing {
                LabeledContent(
                    "Reclaimable now",
                    value: bytes(
                        downloads.reclaimableBytes(
                            ownerIDs: selectedOwners, trackIDs: selectedTracks)))
                Button("Remove Selected", role: .destructive) { confirmingSelected = true }
                    .disabled(!hasSelection || removingAll)
            }
            Button("Remove All Downloads", role: .destructive) { confirmingAll = true }
                .disabled(removingAll || (downloads.owners.isEmpty && downloads.storageBytes == 0))
        } footer: {
            Text(
                "Removal affects only this device. Your server library, playlists and favorites stay unchanged. Files in use are deleted after playback releases them."
            )
        }
    }

    private func selectionRow(
        title: String, footprint: Int64, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if editing {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).accessibilityHidden(true)
                }
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(bytes(footprint)).foregroundStyle(.secondary)
            }.padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!editing || removingAll)
        .accessibilityLabel(title + ", " + bytes(footprint))
        .accessibilityValue(editing ? (selected ? "Selected" : "Not selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(
            editing ? "Toggle selection for removal" : "Choose Edit to select downloads")
    }

    private func toggle(_ id: String, in selection: inout Set<String>) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func clearSelection() {
        selectedOwners.removeAll()
        selectedTracks.removeAll()
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
