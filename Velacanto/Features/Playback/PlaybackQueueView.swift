import SwiftUI
import UniformTypeIdentifiers

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
                        ForEach(playback.upcomingItems) { item in
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
                        .onMove(perform: moveUpcomingItems)
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
            #if os(iOS)
                .environment(\.editMode, .constant(.active))
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

    private func moveUpcomingItems(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        let destinationIndex = destination > sourceIndex ? destination - 1 : destination
        playback.moveUpcomingItem(from: sourceIndex, to: destinationIndex)
    }

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
    var reorderItemKey: String?
    var onReorderDragStart: ((String) -> Void)?
    @State private var reorderPreviewWidth: CGFloat = 320

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

            if let reorderItemKey {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
                    .onDrag {
                        onReorderDragStart?(reorderItemKey)
                        return NSItemProvider(object: reorderItemKey as NSString)
                    } preview: {
                        QueueReorderDragPreview(
                            item: item,
                            jellyfin: jellyfin,
                            width: reorderPreviewWidth
                        )
                    }
                    .accessibilityLabel("Reorder \(item.title)")
            }
        }
        .padding(.vertical, 1)
        .background {
            if reorderItemKey != nil {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: QueueTrackRowWidthPreferenceKey.self,
                        value: geometry.size.width
                    )
                }
            }
        }
        .onPreferenceChange(QueueTrackRowWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            reorderPreviewWidth = width
        }
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

private struct QueueReorderDragPreview: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let width: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            PlaybackArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 7,
                maxWidth: 160
            )
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 7)
        .scaleEffect(1.015)
    }
}

private struct QueueTrackRowWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

private struct NowPlayingQueueContent: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    let showsCurrentItemArtwork: Bool
    let onInitialPositioned: () -> Void

    @State private var draggedUpcomingItemKey: String?
    @State private var reorderDestinationItemKey: String?
    @State private var isReorderingAtQueueEnd = false
    @State private var hasPositionedInitialCurrentItem = false
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

                                ForEach(playback.upcomingItems) { item in
                                    VStack(spacing: 0) {
                                        if reorderDestinationItemKey == itemKey(item) {
                                            QueueReorderDestinationGap()
                                                .transition(
                                                    .opacity.combined(
                                                        with: .scale(
                                                            scale: 0.9,
                                                            anchor: .top
                                                        )
                                                    )
                                                )
                                        }

                                        QueueTrackRow(
                                            item: item,
                                            jellyfin: jellyfin,
                                            reorderItemKey: itemKey(item),
                                            onReorderDragStart: { key in
                                                draggedUpcomingItemKey = key
                                            }
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
                                    .onDrop(
                                        of: [UTType.plainText.identifier],
                                        delegate: QueueReorderDropDelegate(
                                            destinationKey: itemKey(item),
                                            items: playback.upcomingItems,
                                            draggedItemKey: $draggedUpcomingItemKey,
                                            hoveredDestinationKey: $reorderDestinationItemKey,
                                            isHoveringQueueEnd: $isReorderingAtQueueEnd,
                                            move: { source, destination in
                                                moveUpcomingItem(
                                                    from: source,
                                                    to: destination
                                                )
                                            }
                                        )
                                    )
                                }

                                VStack(spacing: 0) {
                                    if isReorderingAtQueueEnd {
                                        QueueReorderDestinationGap()
                                            .transition(
                                                .opacity.combined(
                                                    with: .scale(
                                                        scale: 0.9,
                                                        anchor: .top
                                                    )
                                                )
                                            )
                                    }

                                    Color.clear
                                        .frame(height: 24)
                                }
                                .onDrop(
                                    of: [UTType.plainText.identifier],
                                    delegate: QueueReorderDropDelegate(
                                        destinationKey: nil,
                                        items: playback.upcomingItems,
                                        draggedItemKey: $draggedUpcomingItemKey,
                                        hoveredDestinationKey: $reorderDestinationItemKey,
                                        isHoveringQueueEnd: $isReorderingAtQueueEnd,
                                        move: moveUpcomingItem(from:to:)
                                    )
                                )
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
                            modeControls
                                .zIndex(2)
                        }
                    }
                    .padding(.bottom, 12)
                    .frame(minHeight: availableSpace.size.height, alignment: .top)
                    .coordinateSpace(name: "queueContent")
                }
                .scrollIndicators(.hidden)
                .opacity(hasPositionedInitialCurrentItem ? 1 : 0)
                .onPreferenceChange(QueueCurrentItemMinYPreferenceKey.self) { minY in
                    currentItemMinY = minY
                }
                .onPreferenceChange(QueueContentBottomYPreferenceKey.self) { maxY in
                    queueContentBottomY = maxY
                }
                .task(id: currentItemScrollID) {
                    hasPositionedInitialCurrentItem = false
                    await Task.yield()
                    scrollToCurrentItem(using: scrollProxy)
                    try? await Task.sleep(for: .milliseconds(50))
                    scrollToCurrentItem(using: scrollProxy)
                    hasPositionedInitialCurrentItem = true
                    try? await Task.sleep(for: .milliseconds(20))
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

    private func moveUpcomingItem(from source: Int, to destination: Int) {
        playback.moveUpcomingItem(from: source, to: destination)
    }

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

private struct QueueReorderDropDelegate: DropDelegate {
    let destinationKey: String?
    let items: [PlaybackItem]
    @Binding var draggedItemKey: String?
    @Binding var hoveredDestinationKey: String?
    @Binding var isHoveringQueueEnd: Bool
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard
            let draggedItemKey,
            items.contains(where: { itemKey($0) == draggedItemKey })
        else {
            return
        }
        withAnimation(.smooth(duration: 0.2, extraBounce: 0)) {
            hoveredDestinationKey = destinationKey
            isHoveringQueueEnd = destinationKey == nil
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.12)) {
            if hoveredDestinationKey == destinationKey {
                hoveredDestinationKey = nil
            }
            if destinationKey == nil {
                isHoveringQueueEnd = false
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedItemKey = nil
            hoveredDestinationKey = nil
            isHoveringQueueEnd = false
        }
        guard
            let draggedItemKey,
            let source = items.firstIndex(where: { itemKey($0) == draggedItemKey })
        else {
            return false
        }

        let destination =
            destinationKey.flatMap { key in
                items.firstIndex(where: { itemKey($0) == key })
            } ?? items.count
        let insertionIndex = source < destination ? destination - 1 : destination
        guard source != insertionIndex else { return false }
        withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
            move(source, insertionIndex)
        }
        return true
    }

    private func itemKey(_ item: PlaybackItem) -> String {
        "\(item.source.rawValue)|\(item.id)"
    }
}

private struct QueueReorderDestinationGap: View {
    var body: some View {
        ZStack {
            Color.clear

            Capsule()
                .fill(.tint.opacity(0.85))
                .frame(height: 3)
                .padding(.leading, 76)
                .padding(.trailing, 32)
        }
        .frame(height: 54)
        .accessibilityLabel("Move here")
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
            .background(.ultraThinMaterial, in: Capsule())
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
