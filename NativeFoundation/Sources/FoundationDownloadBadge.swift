import SwiftUI

/// Transfer feedback precedes availability so partial collections still show active work.
struct FoundationDownloadBadge: View {
    let item: FoundationItem
    var showsTransferStatus = true
    @Environment(\.foundationShowsDownloadBadges) private var showsBadges

    var body: some View {
        if showsBadges {
            FoundationDownloadIndicator(item: item, showsTransferStatus: showsTransferStatus)
        }
    }
}

/// Shared by catalog badges and download controls. Only a measured track has a percentage.
struct FoundationDownloadIndicator: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let item: FoundationItem
    var showsTransferStatus = true
    var showsUnavailable = false

    private var transfer: FoundationDownloadOwner? {
        guard showsTransferStatus else { return nil }
        return downloads.transferOwner(for: item)
    }

    var body: some View {
        Group {
            if let transfer {
                transferIndicator(transfer)
            } else {
                availabilityIndicator
            }
        }
        .font(.caption)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func transferIndicator(_ owner: FoundationDownloadOwner) -> some View {
        switch owner.state {
        case .queued:
            statusSymbol("clock", label: "Download queued", state: "queued")
        case .waitingForWiFi:
            statusSymbol("wifi", label: "Download waiting for Wi-Fi", state: "waiting")
        case .expanding:
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Preparing download, reading tracks")
                .accessibilityIdentifier("download-state-preparing")
        case .downloading:
            if item.kind == .track, owner.activeTrackID != item.id {
                statusSymbol("clock", label: "Download queued", state: "queued")
            } else if item.kind == .track, owner.activeTrackID == item.id,
                let fraction = owner.activeTrackProgress
            {
                measuredProgress(fraction)
            } else {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Downloading")
                    .accessibilityIdentifier("download-state-active-indeterminate")
            }
        case .failed:
            statusSymbol("exclamationmark.circle", label: owner.status, state: "failed")
        case .cancelled:
            statusSymbol("pause.circle", label: owner.status, state: "cancelled")
        case .ready:
            availabilityIndicator
        }
    }

    private func measuredProgress(_ fraction: Double) -> some View {
        let bounded = min(1, max(0, fraction))
        return ZStack {
            Circle().stroke(.primary.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: bounded)
                .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int(bounded * 100)) percent")
        .accessibilityIdentifier("download-state-active-measured")
    }

    @ViewBuilder
    private var availabilityIndicator: some View {
        switch downloads.availability(for: item) {
        case .unavailable:
            if showsUnavailable {
                statusSymbol("arrow.down.circle", label: "Download", state: "unavailable")
            }
        case .ready:
            statusSymbol("arrow.down.circle.fill", label: "Available offline", state: "complete")
        case .partial(let ready, let total):
            statusSymbol(
                "arrow.down.circle.dotted",
                label: "Partially available offline, \(ready) of \(total) known track occurrences",
                state: "partial")
        }
    }

    private func statusSymbol(_ symbol: String, label: String, state: String) -> some View {
        Image(systemName: symbol)
            .accessibilityLabel(label)
            .accessibilityIdentifier("download-state-" + state)
    }
}

private struct FoundationDownloadBadgesKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
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

/// Connection recovery stays visible alongside usable saved content.
struct FoundationOfflineNotice: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationOpenLibrary) private var openLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(connectivity.localOnly ? "Offline" : "No Connection", systemImage: "wifi.slash")
                .font(.subheadline.weight(.semibold))
            Text(
                connectivity.statusMessage
                    ?? (connectivity.localOnly
                        ? "Offline. Downloaded music is in Library."
                        : "The server could not be reached. Saved music remains available.")
            )
            .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if let openLibrary { Button("Open Library", action: openLibrary) }
                Button("Retry") { Task { await connectivity.retryOnline() } }
                    .disabled(connectivity.isRetrying)
                    .accessibilityIdentifier("offline-retry")
                if connectivity.isRetrying { ProgressView().controlSize(.small) }
            }.font(.subheadline).buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-notice")
    }
}
