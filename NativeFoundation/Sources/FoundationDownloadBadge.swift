import SwiftUI

/// Availability comes from verified local resources, independently of transfer state.
struct FoundationDownloadBadge: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let item: FoundationItem
    var showsTransferStatus = true

    var body: some View {
        switch downloads.availability(for: item) {
        case .unavailable:
            if showsTransferStatus,
                let owner = downloads.owners.first(where: {
                    $0.item.id == item.id && $0.item.kind == item.kind
                }),
                owner.state != .ready
            {
                Label(
                    owner.status,
                    systemImage: owner.state == .failed
                        ? "exclamationmark.circle" : "arrow.down.circle"
                )
                .font(.caption).foregroundStyle(.primary)
                .accessibilityLabel(owner.status + ", not yet available offline")
            } else if downloads.owners.contains(where: {
                $0.item.id == item.id && $0.item.kind == item.kind
            }) {
                Label("No tracks downloaded", systemImage: "circle")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityLabel("No tracks available offline")
            }
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.primary)
                .accessibilityLabel("Available offline")
        case .partial(let ready, let total):
            Label(
                ready == total
                    ? "Partially downloaded, \(ready) tracks" : "\(ready) of \(total) downloaded",
                systemImage: "circle.lefthalf.filled"
            )
            .font(.caption).foregroundStyle(.primary)
            .accessibilityLabel(
                "Partially available offline, \(ready) tracks in the saved snapshot of \(total)")
            if showsTransferStatus,
                let owner = downloads.owners.first(where: {
                    $0.item.id == item.id && $0.item.kind == item.kind
                }), owner.state != .ready
            {
                Text(owner.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
