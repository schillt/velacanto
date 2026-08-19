import SwiftUI

// Xcode 26.6 does not expose the OS 27 reorder APIs. Keep those references
// compiled only by the toolchain that ships their SDK, while preserving the
// native implementation for the OS 27 product build.
struct PlaybackQueueView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    var close: (() -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !historyItems.isEmpty {
                    Section("History") {
                        ForEach(historyItems) { item in
                            QueueTrackRow(item: item, jellyfin: jellyfin)
                                .foregroundStyle(.secondary)
                                .onTapGesture {
                                    playback.playQueueItem(item)
                                }
                        }
                    }
                }

                if let currentItem = playback.currentItem {
                    Section("Now Playing") {
                        QueueTrackRow(
                            item: currentItem,
                            jellyfin: jellyfin,
                            isCurrentItem: true
                        )
                        .id(currentItemScrollID)
                        .onTapGesture {
                            playback.playQueueItem(currentItem)
                        }
                    }
                }

                if !playback.upcomingItems.isEmpty {
                    Section {
                        ForEach(playback.upcomingItems, id: \.queueIdentity) { item in
                            QueueTrackRow(item: item, jellyfin: jellyfin)
                                .queueContextMenu(item: item, playback: playback)
                                .onTapGesture {
                                    playback.playQueueItem(item)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        playback.removeUpcomingItem(item)
                                    } label: {
                                        Label("Remove from Queue", systemImage: "trash")
                                    }
                                }
                        }
                        #if compiler(>=6.4)
                            .reorderable()
                        #endif
                    } header: {
                        HStack {
                            Text("Up Next")
                            Spacer()
                            PlaybackQueueControls(playback: playback)
                        }
                    }
                }

                if playback.currentItem == nil,
                    playback.upcomingItems.isEmpty,
                    historyItems.isEmpty
                {
                    ContentUnavailableView(
                        "Queue Is Empty",
                        systemImage: "text.line.last.and.arrowtriangle.forward",
                        description: Text("Play music to start a queue.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 40)
                }
            }
            .listStyle(.plain)
            #if compiler(>=6.4)
                .reorderContainer(for: PlaybackItem.self, itemID: \.queueIdentity) { difference in
                    reorderUpcomingItems(difference)
                }
            #endif
            #if os(iOS)
                .scrollContentBackground(.hidden)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Queue")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if let close {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close Queue")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onAppear {
                scrollToCurrentItem(using: proxy)
            }
            .onChange(of: playback.currentItem?.id) { _, _ in
                scrollToCurrentItem(using: proxy)
            }
        }
    }

    private var historyItems: [PlaybackItem] {
        if !playback.playedQueueItems.isEmpty {
            return playback.playedQueueItems
        }
        let currentKey = playback.currentItem.map(itemKey)
        return Array(
            playback.recentItems
                .filter { itemKey($0) != currentKey }
                .reversed()
        )
    }

    #if compiler(>=6.4)
        private func reorderUpcomingItems(
            _ difference: ReorderDifference<
                PlaybackItemQueueIdentity,
                ReorderableSingleCollectionIdentifier
            >
        ) {
            let destinationID: PlaybackItemQueueIdentity?
            switch difference.destination.position {
            case .before(let itemID):
                destinationID = itemID
            case .end:
                destinationID = nil
            }
            playback.reorderUpcomingItems(
                withIDs: difference.sources,
                before: destinationID
            )
        }
    #endif

    private func itemKey(_ item: PlaybackItem) -> String {
        "\(item.source.rawValue)|\(item.id)"
    }

    private var currentItemScrollID: String {
        guard let currentItem = playback.currentItem else { return "queue-current" }
        return "queue-current-\(itemKey(currentItem))"
    }

    private func scrollToCurrentItem(using proxy: ScrollViewProxy) {
        guard playback.currentItem != nil else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(currentItemScrollID, anchor: .center)
        }
    }
}

private struct QueueTrackRow: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var isCurrentItem = false
    var showsArtwork = true
    var artworkTransitionNamespace: Namespace.ID?

    var body: some View {
        HStack(spacing: 10) {
            if showsArtwork {
                queueArtworkContent
                    .frame(width: 46, height: 46)
                    .queueArtworkTransition(in: artworkTransitionNamespace)
            } else {
                Color.clear
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(isCurrentItem ? .semibold : .regular))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrentItem {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Currently playing")
            }

        }
        .padding(.vertical, 1)
    }

    private var queueArtworkContent: some View {
        PlaybackArtworkView(
            item: item,
            jellyfin: jellyfin,
            cornerRadius: 7,
            maxWidth: 160
        )
    }
}

private struct PlaybackQueueControls: View {
    @ObservedObject var playback: AudioPlaybackCoordinator

    var body: some View {
        HStack(spacing: 18) {
            Button {
                playback.shuffleUpcoming()
            } label: {
                Label("Shuffle Up Next", systemImage: "shuffle")
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(playback.upcomingItems.count < 2)
            .accessibilityLabel("Shuffle Up Next")

            Button {
                playback.cycleRepeatMode()
            } label: {
                Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(
                playback.repeatMode == .off ? Color.secondary : Color.velacantoAccent
            )
            .accessibilityLabel(repeatAccessibilityLabel)
        }
    }

    private var repeatAccessibilityLabel: String {
        switch playback.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

struct NowPlayingQueueContent: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    let artworkTransitionNamespace: Namespace.ID
    @State private var scrollPosition = ScrollPosition(
        id: QueuePresentation.initialAnchorID,
        anchor: .top
    )

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: 0
            ) {
                if !historyItems.isEmpty {
                    QueueSectionHeader("History")
                        .queueScrollSectionHeaderStyle()

                    ForEach(historyItems) { item in
                        QueueTrackRow(item: item, jellyfin: jellyfin)
                            .foregroundStyle(.secondary)
                            .queueScrollRowStyle()
                            .onTapGesture {
                                playback.playQueueItem(item)
                            }
                    }
                }

                currentItemSummary

                modeControls

                QueueSectionHeader("Up Next")
                    .queueScrollSectionHeaderStyle()

                if QueuePresentation.showsEmptyUpcoming(
                    upcomingCount: playback.upcomingItems.count
                ) {
                    ContentUnavailableView(
                        "Nothing Up Next",
                        systemImage: "text.line.last.and.arrowtriangle.forward",
                        description: Text("Add music to keep the queue going.")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    // Keep enough content below the initial anchor for the
                    // current item to remain at the top even when Up Next is empty.
                    .containerRelativeFrame(.vertical)
                } else {
                    ForEach(playback.upcomingItems, id: \.queueIdentity) { item in
                        QueueTrackRow(item: item, jellyfin: jellyfin)
                            .queueScrollRowStyle()
                            .queueContextMenu(
                                item: item,
                                playback: playback,
                                canRemove: true
                            )
                            .onTapGesture {
                                playback.playQueueItem(item)
                            }
                    }
                    #if compiler(>=6.4)
                        .reorderable()
                    #endif

                    // A short queue still needs enough trailing scroll range
                    // for the current-item anchor to sit at the top on open.
                    Color.clear
                        .containerRelativeFrame(.vertical) { length, _ in
                            max(length - 180, 0)
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 12)
            .scrollTargetLayout()
            #if compiler(>=6.4)
                .reorderContainer(
                    for: PlaybackItem.self,
                    itemID: \.queueIdentity
                ) { difference in
                    reorderUpcomingItems(difference)
                }
            #endif
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityLabel("Playback queue")
    }

    @ViewBuilder
    private var currentItemSummary: some View {
        if let currentItem = playback.currentItem {
            VStack(alignment: .leading, spacing: 0) {
                QueueSectionHeader("Now Playing")
                    .queueScrollSectionHeaderStyle()
                QueueTrackRow(
                    item: currentItem,
                    jellyfin: jellyfin,
                    isCurrentItem: true,
                    artworkTransitionNamespace: artworkTransitionNamespace
                )
                .id(QueuePresentation.initialAnchorID)
                .queueScrollRowStyle()
                .onTapGesture {
                    playback.playQueueItem(currentItem)
                }
            }
        }
    }

    private var modeControls: some View {
        QueueModeControlPills(playback: playback)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
    }

    private var historyItems: [PlaybackItem] {
        if !playback.playedQueueItems.isEmpty {
            return playback.playedQueueItems
        }
        let currentKey = playback.currentItem.map(itemKey)
        return Array(
            playback.recentItems
                .filter { itemKey($0) != currentKey }
                .reversed()
        )
    }

    #if compiler(>=6.4)
        private func reorderUpcomingItems(
            _ difference: ReorderDifference<
                PlaybackItemQueueIdentity,
                ReorderableSingleCollectionIdentifier
            >
        ) {
            let destinationID: PlaybackItemQueueIdentity?
            switch difference.destination.position {
            case .before(let itemID):
                destinationID = itemID
            case .end:
                destinationID = nil
            }
            playback.reorderUpcomingItems(
                withIDs: difference.sources,
                before: destinationID
            )
        }
    #endif

    private func itemKey(_ item: PlaybackItem) -> String {
        "\(item.source.rawValue)|\(item.id)"
    }

}

private struct QueueModeControlPills: View {
    @ObservedObject var playback: AudioPlaybackCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playback.shuffleUpcoming()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
            }
            .disabled(playback.upcomingItems.count < 2)
            .accessibilityLabel("Shuffle Up Next")

            Button {
                playback.cycleRepeatMode()
            } label: {
                Label(repeatTitle, systemImage: repeatSymbol)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(
                        playback.repeatMode == .off
                            ? Color.secondary : Color.velacantoAccent
                    )
                    .background(
                        playback.repeatMode == .off
                            ? Color.clear : Color.velacantoAccent.opacity(0.12),
                        in: .capsule
                    )
            }
            .accessibilityLabel(repeatAccessibilityLabel)
        }
        .font(.callout.weight(.medium))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
    }

    private var repeatTitle: String {
        playback.repeatMode == .off ? "Repeat" : "Repeating"
    }

    private var repeatSymbol: String {
        playback.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatAccessibilityLabel: String {
        switch playback.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }
}

struct QueuePresentation {
    static let initialAnchorID = "queue-current"

    static func showsEmptyUpcoming(upcomingCount: Int) -> Bool {
        upcomingCount == 0
    }
}

private struct QueueSectionHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    @ViewBuilder
    fileprivate func queueArtworkTransition(
        in namespace: Namespace.ID?
    ) -> some View {
        if let namespace {
            matchedGeometryEffect(
                id: "now-playing-queue-artwork",
                in: namespace
            )
        } else {
            self
        }
    }

    fileprivate func queueListRowStyle() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 16))
    }

    fileprivate func queueScrollRowStyle() -> some View {
        padding(.horizontal, 20)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    fileprivate func queueScrollSectionHeaderStyle() -> some View {
        padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    fileprivate func queueContextMenu(
        item: PlaybackItem,
        playback: AudioPlaybackCoordinator,
        canRemove: Bool = false
    ) -> some View {
        contextMenu {
            Button {
                playback.playNext(item)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                playback.playLast(item)
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            if canRemove {
                Divider()
                Button(role: .destructive) {
                    playback.removeUpcomingItem(item)
                } label: {
                    Label("Remove from Queue", systemImage: "trash")
                }
            }
        }
    }
}
