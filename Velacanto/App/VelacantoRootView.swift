import SwiftUI
import UniformTypeIdentifiers

enum AppDestination: String, Hashable, Identifiable, CaseIterable {
    case home
    case library
    case search

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library:
            "Library"
        case .search:
            "Search"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            "house"
        case .library:
            "rectangle.stack"
        case .search:
            "magnifyingglass"
        }
    }
}

#if os(macOS)
    private enum MacDestination: Hashable {
        case home
        case library(MusicLibraryCategory)
    }
#endif

struct VelacantoRootView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @State private var selectedDestination = AppDestination.home
    #if os(macOS)
        @State private var selectedMacDestination = MacDestination.home
    #endif
    @State private var isChoosingLocalFile = false
    @State private var isPreparingTestTone = false
    @State private var isShowingProfile = false
    @State private var isShowingNowPlaying = false
    @State private var actionError: String?

    private let localFiles = LocalFilePlaybackAdapter()

    var body: some View {
        Group {
            #if os(iOS)
                iOSRoot
            #elseif os(macOS)
                macOSRoot
            #endif
        }
        .tint(.cyan)
        .fileImporter(
            isPresented: $isChoosingLocalFile,
            allowedContentTypes: [.audio]
        ) { result in
            handleLocalFileSelection(result)
        }
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView(
                playback: playback,
                jellyfin: jellyfin
            )
            #if os(macOS)
                .frame(
                    minWidth: 680,
                    idealWidth: 820,
                    minHeight: 520,
                    idealHeight: 620
                )
            #endif
        }
        .sheet(isPresented: $isShowingProfile) {
            NavigationStack {
                ProfileView(
                    jellyfin: jellyfin,
                    isPreparingPlaybackCheck: isPreparingTestTone,
                    runPlaybackCheck: playTestTone
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isShowingProfile = false
                        }
                    }
                }
            }
            #if os(macOS)
                .frame(minWidth: 500, minHeight: 480)
            #endif
        }
        .alert(
            "Couldn’t Play Audio",
            isPresented: Binding(
                get: { actionError != nil },
                set: { isPresented in
                    if !isPresented {
                        actionError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "An unknown playback error occurred.")
        }
    }

    #if os(iOS)
        @ViewBuilder
        private var iOSRoot: some View {
            if #available(iOS 26.0, *) {
                if playback.hasPlayableItem {
                    iOSTabs
                        .tabViewBottomAccessory {
                            ModernPlaybackAccessory(
                                playback: playback,
                                jellyfin: jellyfin,
                                showNowPlaying: {
                                    isShowingNowPlaying = true
                                }
                            )
                        }
                        .tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    iOSTabs
                        .tabBarMinimizeBehavior(.onScrollDown)
                }
            } else {
                iOSTabs
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if playback.hasPlayableItem {
                            PlaybackAccessory(
                                playback: playback,
                                jellyfin: jellyfin,
                                showNowPlaying: {
                                    isShowingNowPlaying = true
                                }
                            )
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        }
                    }
            }
        }

        private var iOSTabs: some View {
            TabView(selection: $selectedDestination) {
                Tab(
                    AppDestination.home.title,
                    systemImage: AppDestination.home.symbolName,
                    value: AppDestination.home
                ) {
                    NavigationStack {
                        home
                    }
                }

                Tab(
                    AppDestination.library.title,
                    systemImage: AppDestination.library.symbolName,
                    value: AppDestination.library
                ) {
                    NavigationStack {
                        library
                    }
                }

                Tab(
                    AppDestination.search.title,
                    systemImage: AppDestination.search.symbolName,
                    value: AppDestination.search,
                    role: .search
                ) {
                    NavigationStack {
                        search
                    }
                }
            }
        }
    #endif

    #if os(macOS)
        private var macOSRoot: some View {
            NavigationSplitView {
                List(selection: $selectedMacDestination) {
                    Label("Home", systemImage: "house")
                        .tag(MacDestination.home)

                    Section("Library") {
                        ForEach(MusicLibraryCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbolName)
                                .tag(MacDestination.library(category))
                        }
                    }
                }
                .navigationTitle("Velacanto")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button {
                        isShowingProfile = true
                    } label: {
                        HStack(spacing: 10) {
                            AccountAvatar(jellyfin: jellyfin)
                            Text(jellyfin.session?.username ?? "Profile")
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Profile and settings")
                }
            } detail: {
                NavigationStack {
                    switch selectedMacDestination {
                    case .home:
                        home
                    case .library(let category):
                        MusicLibraryCategoryView(
                            category: category,
                            playback: playback,
                            jellyfin: jellyfin
                        )
                    }
                }
            }
            .frame(minWidth: 700, minHeight: 500)
            .overlay(alignment: .bottom) {
                if playback.hasPlayableItem {
                    HStack(alignment: .bottom, spacing: 0) {
                        Color.clear
                            .frame(width: 220)
                            .allowsHitTesting(false)
                        PlaybackAccessory(
                            playback: playback,
                            jellyfin: jellyfin,
                            appearance: .floating,
                            showNowPlaying: {
                                isShowingNowPlaying = true
                            }
                        )
                        .frame(maxWidth: 620)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    #endif

    private var home: some View {
        HomeView(
            playback: playback,
            jellyfin: jellyfin,
            openLocalFile: {
                isChoosingLocalFile = true
            },
            playRecentItem: playRecentItem,
            showProfile: {
                isShowingProfile = true
            },
            showNowPlaying: {
                isShowingNowPlaying = true
            },
            showLibrary: {
                #if os(macOS)
                    selectedMacDestination = .library(.albums)
                #else
                    selectedDestination = .library
                #endif
            }
        )
    }

    private var library: some View {
        MusicLibraryView(
            playback: playback,
            jellyfin: jellyfin,
            openLocalFile: {
                isChoosingLocalFile = true
            },
            showProfile: {
                isShowingProfile = true
            }
        )
    }

    private var search: some View {
        MusicSearchView(
            playback: playback,
            jellyfin: jellyfin,
            showProfile: {
                isShowingProfile = true
            }
        )
    }

    private func handleLocalFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                do {
                    let request = try await localFiles.playbackRequest(
                        for: LocalFileSelection(url: url)
                    )
                    actionError = nil
                    playback.play(request)
                } catch {
                    actionError = error.localizedDescription
                }
            }
        case .failure(let error):
            actionError = error.localizedDescription
        }
    }

    private func playTestTone() {
        isPreparingTestTone = true
        actionError = nil

        Task { @MainActor in
            defer {
                isPreparingTestTone = false
            }
            do {
                let url = try await DemoToneFactory.makeURL()
                let localRequest = try await localFiles.playbackRequest(
                    for: LocalFileSelection(
                        url: url,
                        title: "Velacanto playback check",
                        artist: "440 Hz local tone"
                    )
                )
                playback.play(
                    PlaybackRequest(
                        item: localRequest.item,
                        asset: localRequest.asset,
                        recordsHistory: false
                    )
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func playRecentItem(_ item: PlaybackItem) {
        Task { @MainActor in
            do {
                let request = try await jellyfin.playbackRequest(for: item)
                actionError = nil
                playback.play(request)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct HomeView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let playRecentItem: (PlaybackItem) -> Void
    let showProfile: () -> Void
    let showNowPlaying: () -> Void
    let showLibrary: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                continueListening

                if !playback.recentItems.isEmpty {
                    recentlyPlayed
                }

                librarySources
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: showProfile) {
                        AccountAvatar(jellyfin: jellyfin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile and settings")
                }
            #endif
        }
    }

    @ViewBuilder
    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow("Continue Listening")

            if let item = playback.currentItem {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(
                                item: item,
                                jellyfin: jellyfin
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 260, maxWidth: 600)

                        NowPlayingSummary(
                            playback: playback,
                            showsTransportButton: true
                        )
                        .frame(minWidth: 230, idealWidth: 290)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(
                                item: item,
                                jellyfin: jellyfin
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        NowPlayingSummary(
                            playback: playback,
                            showsTransportButton: true
                        )
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        Image(systemName: "waveform")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.cyan)
                            .frame(width: 58, height: 58)
                            .background(.cyan.opacity(0.12), in: .rect(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your music, ready when you are")
                                .font(.title3.weight(.semibold))
                            Text(emptyStateDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Open Audio File", systemImage: "folder") {
                        openLocalFile()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(
                    Color.secondary.opacity(0.07),
                    in: .rect(cornerRadius: 22)
                )
            }
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.title2.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playback.recentItems.prefix(8)) { item in
                        RecentItemCard(
                            item: item,
                            jellyfin: jellyfin,
                            canReplay: item.source == .jellyfin
                                && jellyfin.isSignedIn
                        ) {
                            playRecentItem(item)
                        }
                    }
                }
            }
        }
    }

    private var librarySources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From Your Library")
                .font(.title2.weight(.semibold))

            VStack(spacing: 0) {
                if let session = jellyfin.session {
                    Button(action: showLibrary) {
                        SourceRow(
                            title: "Jellyfin",
                            subtitle: "Browse music on \(session.serverName)",
                            symbolName: "server.rack"
                        )
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 58)
                }

                Button(action: openLocalFile) {
                    SourceRow(
                        title: "Local Files",
                        subtitle: "Play audio directly from this device",
                        symbolName: "folder"
                    )
                }
                .buttonStyle(.plain)
            }
            .background(
                Color.secondary.opacity(0.06),
                in: .rect(cornerRadius: 18)
            )
        }
    }

    private var emptyStateDescription: String {
        if jellyfin.isSignedIn {
            return "Choose music from your library or open a local audio file."
        }
        return "Open a local audio file, or add a music server from your profile."
    }
}

private struct SourceRow: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(symbolName: symbolName)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SourceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.medium))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}

private struct SectionEyebrow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.cyan)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NowPlayingSummary: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    let showsTransportButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playback.currentItem?.title ?? "Nothing Playing")
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            Text(playback.currentItem?.artist ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let albumTitle = playback.currentItem?.albumTitle {
                Text(albumTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(value: playback.progress)
                .tint(.cyan)
                .padding(.top, 5)

            HStack {
                Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                Spacer()
                Text(PlaybackTimeFormatter.format(seconds: playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if showsTransportButton {
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(
                        playback.showsPauseControl ? "Pause" : "Play",
                        systemImage: playback.showsPauseControl
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

private struct RecentItemCard: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let canReplay: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                PlaybackArtworkView(item: item, jellyfin: jellyfin)
                    .frame(width: 142, height: 142)

                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 142, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReplay)
        .opacity(canReplay || item.source == .localFiles ? 1 : 0.65)
        .accessibilityHint(
            canReplay
                ? "Plays this item again"
                : "Open this item again from its source to play it"
        )
    }
}

struct JellyfinArtworkView: View {
    let item: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var cornerRadius: CGFloat = 12
    var maxWidth = 640

    var body: some View {
        RemoteArtworkView(
            itemID: item.artworkItemID,
            imageTag: item.primaryImageTag,
            jellyfin: jellyfin,
            cornerRadius: cornerRadius,
            maxWidth: maxWidth
        )
    }
}

private struct PlaybackArtworkView: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var cornerRadius: CGFloat = 18
    var maxWidth = 1_200

    var body: some View {
        Group {
            if item.source == .jellyfin,
                let artworkItemID = item.artworkItemID
            {
                RemoteArtworkView(
                    itemID: artworkItemID,
                    imageTag: item.artworkTag,
                    jellyfin: jellyfin,
                    cornerRadius: cornerRadius,
                    maxWidth: maxWidth
                )
            } else {
                ArtworkPlaceholder(cornerRadius: cornerRadius)
            }
        }
    }
}

private struct HomePlaybackArtwork: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        Color.clear
            .aspectRatio(1.55, contentMode: .fit)
            .overlay {
                PlaybackArtworkView(item: item, jellyfin: jellyfin)
            }
            .clipShape(.rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
    }
}

private struct RemoteArtworkView: View {
    let itemID: String
    let imageTag: String?
    @ObservedObject var jellyfin: JellyfinSessionController
    let cornerRadius: CGFloat
    let maxWidth: Int

    @State private var artworkURL: URL?

    var body: some View {
        AsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty:
                ArtworkPlaceholder(
                    cornerRadius: cornerRadius,
                    showsProgress: artworkURL != nil
                )
            case .failure:
                ArtworkPlaceholder(cornerRadius: cornerRadius)
            @unknown default:
                ArtworkPlaceholder(cornerRadius: cornerRadius)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .contentShape(.rect(cornerRadius: cornerRadius))
        .task(id: taskID) {
            artworkURL = await jellyfin.artworkURL(
                itemID: itemID,
                imageTag: imageTag,
                maxWidth: maxWidth
            )
        }
        .accessibilityHidden(true)
    }

    private var taskID: String {
        [
            jellyfin.session?.serverID ?? "signed-out",
            itemID,
            imageTag ?? "no-tag",
            String(maxWidth),
        ].joined(separator: "|")
    }
}

private struct ArtworkPlaceholder: View {
    let cornerRadius: CGFloat
    var showsProgress = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .cyan.opacity(0.38),
                    .blue.opacity(0.26),
                    .indigo.opacity(0.34),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

private enum PlaybackAccessoryAppearance {
    case embedded
    case floating
}

private struct PlaybackAccessory: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    var appearance = PlaybackAccessoryAppearance.floating
    let showNowPlaying: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: showNowPlaying) {
                HStack(spacing: 10) {
                    if let item = playback.currentItem {
                        PlaybackArtworkView(
                            item: item,
                            jellyfin: jellyfin,
                            cornerRadius: 7,
                            maxWidth: 180
                        )
                        .frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.currentItem?.title ?? "Nothing Playing")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(playback.currentItem?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                playback.togglePlayback()
            } label: {
                Image(
                    systemName: playback.showsPauseControl
                        ? "pause.fill"
                        : "play.fill"
                )
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                playback.showsPauseControl ? "Pause" : "Play"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(PlaybackAccessorySurface(appearance: appearance))
    }
}

private struct PlaybackAccessorySurface: ViewModifier {
    let appearance: PlaybackAccessoryAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .embedded:
            content
        case .floating:
            if #available(iOS 26.0, macOS 26.0, *) {
                content.glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 20)
                )
            } else {
                content
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.separator.opacity(0.42), lineWidth: 0.5)
                    }
            }
        }
    }
}

#if os(iOS)
    @available(iOS 26.0, *)
    private struct ModernPlaybackAccessory: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        @ObservedObject var playback: AudioPlaybackCoordinator
        @ObservedObject var jellyfin: JellyfinSessionController
        let showNowPlaying: () -> Void

        var body: some View {
            PlaybackAccessory(
                playback: playback,
                jellyfin: jellyfin,
                appearance: .embedded,
                showNowPlaying: showNowPlaying
            )
            .padding(.horizontal, placement == .inline ? 0 : 6)
        }
    }
#endif

private struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if let item = playback.currentItem {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 32) {
                                    artwork(
                                        for: item,
                                        size: horizontalArtworkSize(in: geometry.size)
                                    )

                                    playbackDetails(for: item)
                                        .frame(minWidth: 260, maxWidth: 420)
                                }
                                .frame(maxWidth: 760)

                                VStack(spacing: 24) {
                                    artwork(
                                        for: item,
                                        size: verticalArtworkSize(in: geometry.size)
                                    )

                                    playbackDetails(for: item)
                                        .frame(maxWidth: 520)
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "Nothing Playing",
                                systemImage: "music.note",
                                description: Text(
                                    "Choose music from your library to begin."
                                )
                            )
                        }
                    }
                    .padding(24)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height
                    )
                }
            }
            .navigationTitle("Now Playing")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func artwork(for item: PlaybackItem, size: CGFloat) -> some View {
        PlaybackArtworkView(item: item, jellyfin: jellyfin)
            .aspectRatio(1, contentMode: .fill)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.16), radius: 28, y: 14)
    }

    private func playbackDetails(for item: PlaybackItem) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 5) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(item.artist)
                    .foregroundStyle(.secondary)
                if let albumTitle = item.albumTitle {
                    Text(albumTitle)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 7) {
                Slider(
                    value: Binding(
                        get: { playback.progress },
                        set: { playback.seek(toProgress: $0) }
                    ),
                    in: 0...1
                )
                .disabled(playback.duration <= 0)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                    Spacer()
                    Text(PlaybackTimeFormatter.format(seconds: playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 38) {
                Button(role: .destructive) {
                    playback.stop()
                    dismiss()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")

                Button {
                    playback.togglePlayback()
                } label: {
                    Image(
                        systemName: playback.showsPauseControl
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 64))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    playback.showsPauseControl ? "Pause" : "Play"
                )

                Color.clear
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }

            if let errorMessage = playback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func verticalArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(
            440,
            max(
                160,
                min(availableSize.width - 48, availableSize.height * 0.48)
            )
        )
    }

    private func horizontalArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(280, max(140, availableSize.height - 48))
    }
}

struct AccountAvatar: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    var size: CGFloat = 28

    @State private var imageURL: URL?

    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                avatar
                    .padding(2)
                    .glassEffect(.clear.interactive(), in: Circle())
            } else {
                avatar
                    .padding(2)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.separator.opacity(0.42), lineWidth: 0.5)
                    }
            }
        }
        .task(id: taskID) {
            imageURL = await jellyfin.userImageURL(maxWidth: 128)
        }
        .accessibilityHidden(true)
    }

    private var avatar: some View {
        AsyncImage(url: imageURL) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.cyan.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.white.opacity(0.38), lineWidth: 0.75)
        }
    }

    private var initials: String {
        guard let username = jellyfin.session?.username, !username.isEmpty else {
            return "VC"
        }
        let words = username.split(separator: " ")
        let characters = words.prefix(2).compactMap(\.first)
        let value = String(characters)
        return value.isEmpty ? "VC" : value.uppercased()
    }

    private var taskID: String {
        guard let session = jellyfin.session else { return "signed-out" }
        return [
            session.serverID,
            session.userID,
            session.userPrimaryImageTag ?? "no-tag",
        ].joined(separator: "|")
    }
}

#Preview {
    VelacantoRootView(
        playback: AudioPlaybackCoordinator(),
        jellyfin: JellyfinSessionController(autoRestore: false)
    )
}
