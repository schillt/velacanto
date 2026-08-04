import SwiftUI
import UniformTypeIdentifiers
import os

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
                VStack(spacing: 0) {
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

                    if playback.hasPlayableItem {
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
            .frame(minWidth: 700, minHeight: 500)
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
