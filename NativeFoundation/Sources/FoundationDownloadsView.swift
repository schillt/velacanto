import SwiftUI

/// Reads account-owned download metadata without requesting server catalog data.
struct FoundationDownloadsView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let player: FoundationPlayer
    @State private var confirmingRemoveAll = false
    @State private var removingAll = false

    var body: some View {
        List {
            Section("Storage") {
                if downloads.isLoading { ProgressView("Verifying downloaded files…") }
                LabeledContent(
                    "Downloaded music",
                    value: ByteCountFormatter.string(
                        fromByteCount: downloads.storageBytes, countStyle: .file))
                Toggle(
                    "Use Cellular Data",
                    isOn: Binding(
                        get: { downloads.allowsCellular },
                        set: { downloads.setAllowsCellular($0) }))
                Text("Downloads use Wi-Fi unless cellular data is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = downloads.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("Remove All Downloads", role: .destructive) {
                    confirmingRemoveAll = true
                }.disabled(removingAll)
                if removingAll { ProgressView("Removing downloads…") }
            }
            Section("Downloads") {
                if downloads.owners.isEmpty {
                    Text("Choose Download from a song, album, or playlist’s Actions menu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(downloads.owners, id: \.id) { owner in
                    FoundationDownloadRow(owner: owner, player: player)
                }
            }
        }
        .navigationTitle("On Device")
        .confirmationDialog(
            "Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible
        ) {
            Button("Remove All Downloads", role: .destructive) {
                removingAll = true
                Task {
                    _ = await downloads.removeAll()
                    removingAll = false
                }
            }
        } message: {
            Text(
                "This removes this account’s downloaded music from this device. Your server library is unchanged. Music currently playing is removed after playback releases it."
            )
        }
        #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }
}

private struct FoundationDownloadRow: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let owner: FoundationDownloadOwner
    let player: FoundationPlayer
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                FoundationDownloadedTracks(ownerID: owner.id, player: player)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(owner.item.title).font(.headline)
                    Text(owner.status).font(.subheadline).foregroundStyle(.secondary)
                    Text(availability).font(.caption).foregroundStyle(.secondary)
                }
            }
            if isWorking {
                ProgressView(value: min(1, max(0, owner.progress))) {
                    Text("Download progress")
                }
            }
            HStack {
                switch owner.state {
                case .queued, .expanding, .waitingForWiFi, .downloading:
                    Button("Cancel") { downloads.cancel(ownerID: owner.id) }
                case .cancelled, .failed:
                    Button("Retry") { downloads.retry(ownerID: owner.id) }
                case .ready:
                    EmptyView()
                }
                Spacer()
                Button("Remove Download", role: .destructive) { confirmingRemoval = true }
            }.buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove this download?", isPresented: $confirmingRemoval, titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) { downloads.remove(ownerID: owner.id) }
        } message: {
            Text(
                "Music retained by another download stays on this device. Your server library is unchanged."
            )
        }
    }

    private var availability: String {
        let count = downloads.readyTracks(ownerID: owner.id).count
        guard !owner.tracks.isEmpty else { return "No tracks available offline yet" }
        return "\(count) of \(owner.tracks.count) tracks available offline"
    }

    private var isWorking: Bool {
        switch owner.state {
        case .queued, .expanding, .waitingForWiFi, .downloading: true
        case .ready, .cancelled, .failed: false
        }
    }
}

private struct FoundationDownloadedTracks: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let ownerID: String
    let player: FoundationPlayer

    var body: some View {
        Group {
            if let owner = downloads.owners.first(where: { $0.id == ownerID }) {
                List {
                    Section {
                        Text(owner.status).foregroundStyle(.secondary)
                        Button("Play Available Tracks", systemImage: "play.fill") {
                            let available = downloads.readyTracks(ownerID: ownerID)
                            guard !available.isEmpty else { return }
                            player.setQueue(available, selectedIndex: 0)
                        }.disabled(downloads.readyTracks(ownerID: ownerID).isEmpty)
                    }
                    Section("Tracks") {
                        ForEach(Array(owner.tracks.enumerated()), id: \.offset) { index, item in
                            let available = downloads.isReady(item)
                            Button {
                                let ready = downloads.readyTracks(ownerID: ownerID)
                                let selected = owner.tracks.prefix(index).filter {
                                    downloads.isReady($0)
                                }.count
                                guard downloads.isReady(item), ready.indices.contains(selected)
                                else {
                                    return
                                }
                                player.setQueue(ready, selectedIndex: selected)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                    Text(available ? "Available offline" : "Not available offline")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(!available)
                        }
                    }
                }
                .navigationTitle(owner.item.title)
            } else {
                ContentUnavailableView(
                    "Download Removed", systemImage: "arrow.down.circle",
                    description: Text("This download is no longer on this device."))
            }
        }
    }
}
