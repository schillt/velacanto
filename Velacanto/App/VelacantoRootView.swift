import SwiftUI
import UniformTypeIdentifiers
import os

#if os(iOS)
    import UIKit
#endif

struct VelacantoRootView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @State private var selectedDestination = AppDestination.home
    @State private var globalSearchText = ""
    #if os(macOS)
        @State private var selectedMacDestination = MacDestination.home
    #endif
    @State private var isChoosingLocalFile = false
    @State private var isPreparingTestTone = false
    @State private var isShowingProfile = false
    @State private var isShowingNowPlaying = false
    #if os(iOS)
        @Namespace private var nowPlayingArtworkNamespace
    #endif
    #if os(macOS)
        @State private var isShowingMacQueue = false
    #endif
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
        .modifier(MusicItemActionFailurePresenter(actions: jellyfin.itemActions))
        .tint(.velacantoAccent)
        .fileImporter(
            isPresented: $isChoosingLocalFile,
            allowedContentTypes: [.audio]
        ) { result in
            handleLocalFileSelection(result)
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $isShowingNowPlaying) {
                NowPlayingView(playback: playback, jellyfin: jellyfin)
                .navigationTransition(
                    .zoom(
                        sourceID: "now-playing-artwork",
                        in: nowPlayingArtworkNamespace
                    )
                )
            }
        #endif
        .sheet(isPresented: $isShowingProfile) {
            NavigationStack {
                ProfileView(
                    jellyfin: jellyfin,
                    isPreparingPlaybackCheck: isPreparingTestTone,
                    runPlaybackCheck: playTestTone,
                    dismiss: { isShowingProfile = false }
                )
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
        .task(id: jellyfinAccountTaskID) {
            guard let session = jellyfin.session else { return }
            playback.configureRequestResolver { item in
                try await jellyfin.playbackRequest(for: item)
            }
            playback.configureArtworkResolver { item in
                guard
                    item.source == .jellyfin,
                    let artworkItemID = item.artworkItemID,
                    let activeSession = jellyfin.session,
                    activeSession.serverID == session.serverID,
                    activeSession.userID == session.userID
                else {
                    return nil
                }
                let key = ArtworkKey(
                    serverID: session.serverID,
                    userID: session.userID,
                    itemID: artworkItemID,
                    imageTag: item.artworkTag ?? "no-tag",
                    sizeBucket: 1_024
                )
                guard
                    let image = await ArtworkRepository.shared.image(
                        for: key,
                        request: {
                            await jellyfin.artworkRequest(
                                itemID: artworkItemID,
                                imageTag: item.artworkTag,
                                maxWidth: 1_024
                            )
                        }
                    )
                else {
                    return nil
                }
                return ResolvedNowPlayingArtwork(
                    identifier: key.identifier,
                    image: image
                )
            }
            playback.restoreSavedState(
                serverID: session.serverID,
                userID: session.userID
            )
        }
        .onChange(of: jellyfin.session) { oldSession, newSession in
            guard
                let oldSession,
                oldSession.serverID != newSession?.serverID
                    || oldSession.userID != newSession?.userID
            else {
                return
            }
            Task {
                await ArtworkRepository.shared.clear(
                    serverID: oldSession.serverID,
                    userID: oldSession.userID
                )
            }
            if newSession == nil {
                playback.clearSavedState(
                    serverID: oldSession.serverID,
                    userID: oldSession.userID
                )
                playback.stop()
            }
        }
        .environmentObject(jellyfin.itemActions)
    }

    #if os(iOS)
        @ViewBuilder
        private var iOSRoot: some View {
            iOSTabs
                .tabViewBottomAccessory(
                    // Keep the source available behind the cover for both directions
                    // of the native transition.
                    isEnabled: playback.hasPlayableItem
                ) {
                    ModernPlaybackAccessory(
                        playback: playback,
                        jellyfin: jellyfin,
                        showNowPlaying: {
                            isShowingNowPlaying = true
                        },
                        nowPlayingTransitionNamespace: nowPlayingArtworkNamespace
                    )
                }
                .tabBarMinimizeBehavior(.onScrollDown)
        }

        private var iOSTabs: some View {
            TabView(selection: $selectedDestination) {
                Tab(value: AppDestination.home) {
                    NavigationStack {
                        home
                    }
                } label: {
                    Label {
                        Text(AppDestination.home.title)
                    } icon: {
                        RoundedHomeTabIcon()
                    }
                }

                Tab(
                    AppDestination.new.title,
                    systemImage: AppDestination.new.symbolName,
                    value: AppDestination.new
                ) {
                    NavigationStack {
                        newMusic
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
            .tabViewStyle(.sidebarAdaptable)
        }
    #endif

    #if os(macOS)
        private var macOSRoot: some View {
            ZStack {
                HStack(spacing: 0) {
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        macOSSidebar
                            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                            .toolbar(removing: .sidebarToggle)
                    } detail: {
                        macOSContent
                    }
                    .searchable(text: $globalSearchText, prompt: "Search your library")

                    if isShowingMacQueue, !isShowingNowPlaying {
                        Divider()
                        PlaybackQueueView(
                            playback: playback,
                            jellyfin: jellyfin,
                            close: { isShowingMacQueue = false }
                        )
                        .frame(width: 360)
                        .background(.regularMaterial)
                    }
                }
                .frame(minWidth: 700, minHeight: 500)

                if isShowingNowPlaying {
                    NowPlayingView(
                        playback: playback,
                        jellyfin: jellyfin,
                        dismissAction: { isShowingNowPlaying = false }
                    )
                    .background(.background)
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isShowingNowPlaying)
        }

        private var macOSSidebar: some View {
            VStack(spacing: 0) {
                List(selection: $selectedMacDestination) {
                    Label("Home", systemImage: "house.fill")
                        .tag(MacDestination.home)

                    Section("Library") {
                        ForEach(
                            MusicLibraryCategory.allCases.filter {
                                $0 != .playlists
                            }
                        ) { category in
                            Label(category.title, systemImage: category.symbolName)
                                .tag(MacDestination.library(category))
                        }
                    }

                    MacPlaylistSidebarSection(
                        jellyfin: jellyfin,
                        selection: $selectedMacDestination
                    )
                }
                .navigationTitle("Velacanto")
                .onChange(of: selectedMacDestination) { _, _ in
                    globalSearchText = ""
                }

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
        }

        private var macOSContent: some View {
            NavigationStack {
                if isSearchingLibrary {
                    search
                } else {
                    switch selectedMacDestination {
                    case .home:
                        home
                    case .library(let category):
                        MusicLibraryCategoryView(
                            category: category,
                            playback: playback,
                            jellyfin: jellyfin
                        )
                    case .playlist(let playlist):
                        MusicPlaylistView(
                            playlist: playlist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    }
                }
            }
            .id(macOSContentIdentity)
            .macOSPlaybackAccessoryInset(
                playback: playback,
                jellyfin: jellyfin,
                isVisible: playback.hasPlayableItem
                    && !isShowingNowPlaying,
                showNowPlaying: {
                    isShowingNowPlaying = true
                },
                showQueue: {
                    isShowingMacQueue = true
                }
            )
        }

        private var isSearchingLibrary: Bool {
            !globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var macOSContentIdentity: AnyHashable {
            if isSearchingLibrary {
                AnyHashable("global-search")
            } else {
                AnyHashable(selectedMacDestination)
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
            }
        )
    }

    private var newMusic: some View {
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
            presentation: .new
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
            searchText: $globalSearchText,
            showProfile: {
                isShowingProfile = true
            },
            isSearchTabSelected: selectedDestination == .search
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
                        transportKind: localRequest.transportKind,
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
                playback.play(
                    request,
                    account: playbackAccount
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var playbackAccount: PlaybackAccount? {
        guard let session = jellyfin.session else { return nil }
        return PlaybackAccount(
            serverID: session.serverID,
            userID: session.userID
        )
    }

    private var jellyfinAccountTaskID: String {
        guard let account = playbackAccount else { return "signed-out" }
        return "\(account.serverID)|\(account.userID)"
    }

}

extension View {
    /// Provides the root catalog chrome without asking the system navigation
    /// bar to render a second title. `navigationTitle` remains the single
    /// semantic title for VoiceOver, UI tests, and the window title.
    func progressiveScreenHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        modifier(
            ProgressiveScreenHeaderModifier(
                title: title,
                accessory: accessory()
            )
        )
    }

    func progressivePageHeader(_ title: String?) -> some View {
        modifier(ProgressivePageHeaderModifier(title: title))
    }

    /// Collection detail pages provide their own artwork-backed navigation
    /// treatment.
    func collectionDetailNavigationChrome() -> some View {
        scrollContentBackground(.hidden)
    }

    /// Detail pages use the system title treatment; root screens provide their
    /// own visible title with `progressiveScreenHeader`.
    func progressiveSemanticNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
            navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
        #else
            navigationTitle(title)
        #endif
    }
}

private struct ProgressiveScreenHeaderModifier<Accessory: View>: ViewModifier {
    let title: String
    let accessory: Accessory

    @StateObject private var scrollTracker = ProgressiveHeaderScrollTracker()

    private let headerHeight: CGFloat = 56
    private let headerBackdropExtension: CGFloat = 84

    func body(content: Content) -> some View {
        #if os(iOS)
            let presentation = scrollTracker.presentation

            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.hidden, for: .navigationBar)
                .contentMargins(.top, headerHeight, for: .scrollContent)
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(.regularMaterial)
                            .overlay {
                                Color(uiColor: .systemBackground)
                                    .opacity(0.24)
                            }
                            .frame(height: headerHeight + headerBackdropExtension)
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.58),
                                        .init(color: .black.opacity(0.62), location: 0.84),
                                        .init(color: .clear, location: 1),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .ignoresSafeArea(edges: .top)

                        HStack(spacing: 12) {
                            Text(title)
                                .font(.largeTitle.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .accessibilityHidden(true)

                            Spacer(minLength: 12)

                            accessory
                        }
                        .padding(.horizontal, 16)
                        .frame(height: headerHeight)
                    }
                    .frame(
                        height: headerHeight + headerBackdropExtension,
                        alignment: .top
                    )
                    .opacity(presentation.isVisible ? 1 : 0)
                    .allowsHitTesting(presentation.isVisible)
                    .accessibilityHidden(!presentation.isVisible)
                    .animation(.easeOut(duration: 0.18), value: presentation)
                }
                .onScrollGeometryChange(
                    for: CGFloat.self,
                    of: { geometry in
                        let offset = max(
                            0,
                            geometry.contentOffset.y + geometry.contentInsets.top
                        )
                        // The tracker publishes only meaningful visibility
                        // transitions, not each quantized scroll sample.
                        return (offset / 4).rounded() * 4
                    },
                    action: { _, offset in
                        scrollTracker.update(for: offset)
                    }
                )
        #else
            content.navigationTitle(title)
        #endif
    }
}

enum ProgressiveHeaderPresentation: Equatable {
    case visible
    case hidden

    var isVisible: Bool {
        self != .hidden
    }
}

/// Keeps high-frequency scroll distance private and reports only whether the
/// native navigation header should be visible for the current scroll direction.
struct ProgressiveHeaderScrollState {
    private(set) var presentation = ProgressiveHeaderPresentation.visible
    private var previousOffset: CGFloat = 0

    @discardableResult
    mutating func update(for newOffset: CGFloat) -> Bool {
        let previousPresentation = presentation
        let clampedOffset = max(0, newOffset)
        let delta = clampedOffset - previousOffset
        previousOffset = clampedOffset

        if clampedOffset == 0 {
            presentation = .visible
        } else if delta < 0 {
            presentation = .visible
        } else if delta > 0 {
            presentation = .hidden
        }

        return presentation != previousPresentation
    }
}

@MainActor
final class ProgressiveHeaderScrollTracker: ObservableObject {
    @Published private(set) var presentation = ProgressiveHeaderPresentation.visible
    private var scrollState = ProgressiveHeaderScrollState()

    func update(for offset: CGFloat) {
        guard scrollState.update(for: offset) else { return }
        presentation = scrollState.presentation
    }
}

private struct ProgressivePageHeaderModifier: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .progressiveSemanticNavigationTitle(title ?? "")
    }
}

#if os(iOS)
    /// Public SF Symbols do not include Apple Music's private rounded Home
    /// glyph. This compact, chimney-free outline keeps the tab visually close
    /// without relying on private assets or APIs.
    private struct RoundedHomeTabIcon: View {
        var body: some View {
            Image(uiImage: Self.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .accessibilityHidden(true)
        }

        private static let image = UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 24)
        ).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3, y: 11))
            path.addQuadCurve(
                to: CGPoint(x: 12, y: 3),
                controlPoint: CGPoint(x: 7.2, y: 6.5)
            )
            path.addQuadCurve(
                to: CGPoint(x: 21, y: 11),
                controlPoint: CGPoint(x: 16.8, y: 6.5)
            )
            path.addLine(to: CGPoint(x: 21, y: 18))
            path.addQuadCurve(
                to: CGPoint(x: 18, y: 21),
                controlPoint: CGPoint(x: 21, y: 21)
            )
            path.addLine(to: CGPoint(x: 6, y: 21))
            path.addQuadCurve(
                to: CGPoint(x: 3, y: 18),
                controlPoint: CGPoint(x: 3, y: 21)
            )
            path.close()
            UIColor.black.setFill()
            path.fill()
        }
    }
#endif

#if os(macOS)
    private struct MacPlaylistSidebarSection: View {
        @ObservedObject var jellyfin: JellyfinSessionController
        @Binding var selection: MacDestination

        @StateObject private var model = PagedMusicCatalogModel()
        @State private var isExpanded = true

        var body: some View {
            DisclosureGroup(isExpanded: $isExpanded) {
                Label("All Playlists", systemImage: "music.note.list")
                    .tag(MacDestination.library(.playlists))

                ForEach(model.items) { playlist in
                    Text(playlist.name)
                        .lineLimit(1)
                        .tag(MacDestination.playlist(playlist))
                        .onAppear {
                            loadMoreIfNeeded(playlist.id)
                        }
                }

                if model.isInitialLoading || model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                }
            } label: {
                Label("Playlists", systemImage: "music.note.list")
            }
            .task(id: jellyfin.session?.serverID) {
                await reset()
            }
        }

        private func reset() async {
            await model.reset(
                cachedItems: {
                    await jellyfin.cachedCatalogItems(kind: .playlists)
                },
                loader: pageLoader,
                cacheWriter: cacheWriter
            )
        }

        private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
            model.loadMoreIfNeeded(
                itemID: itemID,
                loader: pageLoader,
                cacheWriter: cacheWriter
            )
        }

        private var pageLoader: PagedMusicCatalogModel.Loader {
            { cursor in
                try await jellyfin.musicPlaylistsPage(cursor: cursor)
            }
        }

        private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
            { items in
                await jellyfin.cacheCatalogItems(items, kind: .playlists)
            }
        }
    }
#endif

struct AccountAvatar: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    var size: CGFloat = 28

    @StateObject private var loader = ArtworkViewLoader()

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
            guard let key = artworkKey else { return }
            await loader.load(key: key) {
                await jellyfin.userImageRequest(maxWidth: key.sizeBucket)
            }
        }
        .accessibilityHidden(true)
    }

    private var avatar: some View {
        Group {
            if let image = loader.image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.velacantoAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.velacantoAccent.opacity(0.12))
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
        artworkKey?.identifier ?? "signed-out"
    }

    private var artworkKey: ArtworkKey? {
        guard let session = jellyfin.session else { return nil }
        return ArtworkKey(
            serverID: session.serverID,
            userID: session.userID,
            itemID: "user-\(session.userID)",
            imageTag: session.userPrimaryImageTag ?? "no-tag",
            sizeBucket: 128
        )
    }
}

#Preview {
    VelacantoRootView(
        playback: AudioPlaybackCoordinator(),
        jellyfin: JellyfinSessionController(autoRestore: false)
    )
}
