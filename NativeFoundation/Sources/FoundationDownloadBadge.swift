import SwiftUI

/// Availability comes from verified local resources, independently of transfer state.
struct FoundationDownloadBadge: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let item: FoundationItem
    var showsTransferStatus = true
    @Environment(\.foundationShowsDownloadBadges) private var showsBadges

    var body: some View {
        if showsBadges {
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
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityLabel("Available offline")
            case .partial(let ready, let total):
                Label(
                    ready == total
                        ? "\(ready) saved \(ready == 1 ? "track" : "tracks")"
                        : "\(ready) of \(total) available",
                    systemImage: "circle.lefthalf.filled"
                )
                .font(.caption).foregroundStyle(.primary)
                .accessibilityLabel(
                    "Partially available offline, \(ready) tracks in the saved snapshot of \(total)"
                )
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
}

private struct FoundationDownloadedBrowsingKey: EnvironmentKey {
    static let defaultValue = false
}
private struct FoundationDownloadBadgesKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var foundationDownloadedBrowsing: Bool {
        get { self[FoundationDownloadedBrowsingKey.self] }
        set { self[FoundationDownloadedBrowsingKey.self] = newValue }
    }
    var foundationShowsDownloadBadges: Bool {
        get { self[FoundationDownloadBadgesKey.self] }
        set { self[FoundationDownloadBadgesKey.self] = newValue }
    }
}

private struct FoundationOpenLibraryKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}
extension EnvironmentValues {
    var foundationOpenLibrary: (@MainActor @Sendable () -> Void)? {
        get { self[FoundationOpenLibraryKey.self] }
        set { self[FoundationOpenLibraryKey.self] = newValue }
    }
}

/// Brief recovery belongs to unavailable content, not to every offline page.
struct FoundationOfflineNotice: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationOpenLibrary) private var openLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(connectivity.statusMessage ?? "Offline. Downloaded music is in Library.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if let openLibrary { Button("Open Library", action: openLibrary) }
                Button("Retry Online") { Task { await connectivity.retryOnline() } }
                    .disabled(connectivity.isRetrying)
            }.font(.subheadline).buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
