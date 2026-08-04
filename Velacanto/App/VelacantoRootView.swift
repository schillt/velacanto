import SwiftUI
import UniformTypeIdentifiers
import os

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

struct ArtworkKey: Hashable, Sendable {
    let serverID: String
    let userID: String
    let itemID: String
    let imageTag: String
    let sizeBucket: Int

    var identifier: String {
        [serverID, userID, itemID, imageTag, String(sizeBucket)]
            .joined(separator: "|")
    }

    static func sizeBucket(for requestedWidth: Int) -> Int {
        for bucket in [128, 256, 512, 1_024] where requestedWidth <= bucket {
            return bucket
        }
        return 1_024
    }
}

private actor ArtworkDiskCache {
    private struct Entry: Codable {
        let fileName: String
        let byteCount: Int
        var lastAccess: Date
        let serverID: String
        let userID: String
    }

    private let limit = 64 * 1_024 * 1_024
    private let directory: URL
    private let indexURL: URL
    private var entries: [String: Entry]

    init(fileManager: FileManager = .default) {
        let caches =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = caches.appendingPathComponent(
            "VelacantoArtwork-v1",
            isDirectory: true
        )
        indexURL = directory.appendingPathComponent("index.json")
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode(
                [String: Entry].self,
                from: data
            )
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func data(for key: ArtworkKey) -> Data? {
        guard var entry = entries[key.identifier] else { return nil }
        let fileURL = directory.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            entries[key.identifier] = nil
            persistIndex()
            return nil
        }
        entry.lastAccess = Date()
        entries[key.identifier] = entry
        persistIndex()
        return data
    }

    func store(_ data: Data, for key: ArtworkKey) {
        let fileName = encodedFileName(for: key.identifier)
        let fileURL = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            entries[key.identifier] = Entry(
                fileName: fileName,
                byteCount: data.count,
                lastAccess: Date(),
                serverID: key.serverID,
                userID: key.userID
            )
            evictIfNeeded()
            persistIndex()
        } catch {
            return
        }
    }

    func clear(serverID: String, userID: String) {
        let matches = entries.filter {
            $0.value.serverID == serverID && $0.value.userID == userID
        }
        for (identifier, entry) in matches {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(entry.fileName)
            )
            entries[identifier] = nil
        }
        persistIndex()
    }

    private func evictIfNeeded() {
        var total = entries.values.reduce(0) { $0 + $1.byteCount }
        guard total > limit else { return }
        for (identifier, entry) in entries.sorted(
            by: { $0.value.lastAccess < $1.value.lastAccess }
        ) {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(entry.fileName)
            )
            entries[identifier] = nil
            total -= entry.byteCount
            if total <= limit {
                break
            }
        }
    }

    private func encodedFileName(for identifier: String) -> String {
        Data(identifier.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".image"
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

private actor ArtworkDownloadLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(limit, 1)
    }

    func acquire() async {
        guard availablePermits == 0 else {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
protocol ArtworkLoading: AnyObject {
    func cachedImage(for key: ArtworkKey) -> PlatformImage?
    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor () async -> URLRequest?
    ) async -> PlatformImage?
    func clear(serverID: String, userID: String) async
}

@MainActor
final class ArtworkRepository: ArtworkLoading {
    static let shared = ArtworkRepository()

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Artwork"
    )
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let diskCache = ArtworkDiskCache()
    private let downloadLimiter = ArtworkDownloadLimiter(limit: 4)
    private let session: URLSession
    private var memoryKeys: [ArtworkKey: NSString] = [:]
    private var inFlight: [ArtworkKey: Task<PlatformImage?, Never>] = [:]
    private(set) var requestCounts: [ArtworkKey: Int] = [:]

    init(session: URLSession? = nil) {
        memoryCache.totalCostLimit = 16 * 1_024 * 1_024
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func cachedImage(for key: ArtworkKey) -> PlatformImage? {
        memoryCache.object(forKey: key.identifier as NSString)
    }

    func image(
        for key: ArtworkKey,
        request: @escaping @MainActor () async -> URLRequest?
    ) async -> PlatformImage? {
        if let cached = cachedImage(for: key) {
            Self.logger.debug("Artwork memory cache hit")
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Artwork Cache Hit"
            )
            return cached
        }
        if let existing = inFlight[key] {
            Self.logger.debug("Artwork request coalesced")
            return await existing.value
        }

        let task = Task<PlatformImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let data = await diskCache.data(for: key),
                let decoded = Self.decode(data)
            {
                insert(decoded, for: key)
                Self.logger.debug("Artwork disk cache hit")
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "Artwork Cache Hit"
                )
                return decoded
            }

            guard let urlRequest = await request() else { return nil }
            await downloadLimiter.acquire()
            defer {
                Task {
                    await self.downloadLimiter.release()
                }
            }
            requestCounts[key, default: 0] += 1
            Self.logger.debug("Artwork network request")
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Artwork Request"
            )
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard
                    let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode),
                    let decoded = Self.decode(data)
                else {
                    return nil
                }
                await diskCache.store(data, for: key)
                insert(decoded, for: key)
                return decoded
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func clear(serverID: String, userID: String) async {
        for (key, cacheKey) in memoryKeys
        where key.serverID == serverID && key.userID == userID {
            memoryCache.removeObject(forKey: cacheKey)
            memoryKeys[key] = nil
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
        await diskCache.clear(serverID: serverID, userID: userID)
    }

    private func insert(_ image: PlatformImage, for key: ArtworkKey) {
        let cacheKey = key.identifier as NSString
        let cost = max(Int(image.size.width * image.size.height * 4), 1)
        memoryCache.setObject(image, forKey: cacheKey, cost: cost)
        memoryKeys[key] = cacheKey
    }

    private static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
            UIImage(data: data)
        #elseif os(macOS)
            NSImage(data: data)
        #endif
    }
}

@MainActor
private final class ArtworkViewLoader: ObservableObject {
    @Published private(set) var image: PlatformImage?
    @Published private(set) var isLoading = false

    private var key: ArtworkKey?

    func load(
        key newKey: ArtworkKey,
        repository: any ArtworkLoading = ArtworkRepository.shared,
        request: @escaping @MainActor () async -> URLRequest?
    ) async {
        if key != newKey {
            key = newKey
            image = repository.cachedImage(for: newKey)
        } else if image != nil {
            return
        }

        isLoading = image == nil
        let result = await repository.image(for: newKey, request: request)
        guard key == newKey else { return }
        if let result {
            image = result
        }
        isLoading = false
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

    @StateObject private var loader = ArtworkViewLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkPlaceholder(
                    cornerRadius: cornerRadius,
                    showsProgress: loader.isLoading
                )
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .contentShape(.rect(cornerRadius: cornerRadius))
        .task(id: taskID) {
            guard let key = artworkKey else { return }
            await loader.load(key: key) {
                await jellyfin.artworkRequest(
                    itemID: itemID,
                    imageTag: imageTag,
                    maxWidth: key.sizeBucket
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var artworkKey: ArtworkKey? {
        guard let session = jellyfin.session else { return nil }
        return ArtworkKey(
            serverID: session.serverID,
            userID: session.userID,
            itemID: itemID,
            imageTag: imageTag ?? "no-tag",
            sizeBucket: ArtworkKey.sizeBucket(for: maxWidth)
        )
    }

    private var taskID: String {
        artworkKey?.identifier ?? "signed-out"
    }
}

extension Image {
    fileprivate init(platformImage: PlatformImage) {
        #if os(iOS)
            self.init(uiImage: platformImage)
        #elseif os(macOS)
            self.init(nsImage: platformImage)
        #endif
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
        NowPlayingArtwork(
            item: item,
            jellyfin: jellyfin
        )
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
                Button {
                    playback.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoPrevious)
                .accessibilityLabel("Previous")

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

                Button {
                    playback.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoNext)
                .accessibilityLabel("Next")
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

private struct NowPlayingArtwork: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        PlaybackArtworkView(
            item: item,
            jellyfin: jellyfin,
            maxWidth: 1_024
        )
        .id(artworkIdentity)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: artworkIdentity)
    }

    private var artworkIdentity: String {
        [
            item.id,
            item.artworkItemID ?? "no-artwork",
            item.artworkTag ?? "no-tag",
            "1024",
        ].joined(separator: "|")
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
