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

    var body: some View {
        HStack(spacing: 10) {
            queueArtworkContent
                .frame(width: 46, height: 46)
                .opacity(showsArtwork ? 1 : 0)

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
    let showsCurrentItemArtwork: Bool
    let showsModeControls: Bool
    let onInitialPositioned: () -> Void

    @State private var currentItemMinY: CGFloat?
    @State private var queueContentBottomY: CGFloat?

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { availableSpace in
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 0,
                        pinnedViews: [.sectionHeaders]
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

                        if let currentItem = playback.currentItem {
                            QueueTrackRow(
                                item: currentItem,
                                jellyfin: jellyfin,
                                isCurrentItem: true,
                                showsArtwork: showsCurrentItemArtwork
                            )
                            .id(currentItemScrollID)
                            .queueScrollRowStyle()
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: QueueCurrentItemMinYPreferenceKey.self,
                                        value: geometry.frame(
                                            in: .named("queueContent")
                                        ).minY
                                    )
                                }
                            }
                            .onTapGesture {
                                playback.playQueueItem(currentItem)
                            }
                        }

                        Section {
                            if playback.upcomingItems.isEmpty {
                                Text("End of Queue")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 18)
                            } else {
                                QueueSectionHeader("Up Next")
                                    .queueScrollSectionHeaderStyle()

                                ForEach(playback.upcomingItems, id: \.queueIdentity) { item in
                                    QueueTrackRow(
                                        item: item,
                                        jellyfin: jellyfin
                                    )
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
                            }

                            Color.clear
                                .frame(height: 1)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: QueueContentBottomYPreferenceKey.self,
                                            value: geometry.frame(
                                                in: .named("queueContent")
                                            ).maxY
                                        )
                                    }
                                }

                            Color.clear
                                .frame(
                                    height: queueEndSpacerHeight(
                                        viewportHeight: availableSpace.size.height
                                    )
                                )
                                .accessibilityHidden(true)
                        } header: {
                            if showsModeControls {
                                modeControls
                                    .zIndex(2)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                    .frame(minHeight: availableSpace.size.height, alignment: .top)
                    .coordinateSpace(name: "queueContent")
                    #if compiler(>=6.4)
                        .reorderContainer(
                            for: PlaybackItem.self,
                            itemID: \.queueIdentity
                        ) { difference in
                            reorderUpcomingItems(difference)
                        }
                    #endif
                }
                .scrollIndicators(.hidden)
                .onPreferenceChange(QueueCurrentItemMinYPreferenceKey.self) { minY in
                    currentItemMinY = minY
                }
                .onPreferenceChange(QueueContentBottomYPreferenceKey.self) { maxY in
                    queueContentBottomY = maxY
                }
                .task(id: currentItemScrollID) {
                    await Task.yield()
                    scrollToCurrentItem(using: scrollProxy)
                    onInitialPositioned()
                }
            }
        }
        .accessibilityLabel("Playback queue")
    }

    private var modeControls: some View {
        QueueModeControlPills(playback: playback)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.35)
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
        Self.currentItemScrollID(for: playback.currentItem)
    }

    private static func currentItemScrollID(for item: PlaybackItem?) -> String {
        guard let item else { return "queue-current" }
        return "queue-current-\(item.source.rawValue)|\(item.id)"
    }

    private func scrollToCurrentItem(using proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(currentItemScrollID, anchor: .top)
        }
    }

    private func queueEndSpacerHeight(viewportHeight: CGFloat) -> CGFloat {
        guard
            !historyItems.isEmpty,
            let currentItemMinY,
            let queueContentBottomY
        else {
            return 0
        }
        let contentBelowCurrent = max(0, queueContentBottomY - currentItemMinY)
        return min(viewportHeight, max(0, viewportHeight - contentBelowCurrent))
    }

}

private struct QueueCurrentItemMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct QueueContentBottomYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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
                    .frame(maxWidth: .infinity)
            }
            .disabled(playback.upcomingItems.count < 2)
            .accessibilityLabel("Shuffle Up Next")

            Button {
                playback.cycleRepeatMode()
            } label: {
                Label(repeatTitle, systemImage: repeatSymbol)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(repeatAccessibilityLabel)
        }
        .font(.callout.weight(.medium))
        .labelStyle(.titleAndIcon)
        .buttonStyle(QueueModePillButtonStyle())
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

private struct QueueModePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : 0.05))
            }
            .contentShape(Capsule())
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
