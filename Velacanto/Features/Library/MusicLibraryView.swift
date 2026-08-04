import SwiftUI

@MainActor
final class PagedJellyfinItemsModel: ObservableObject {
    typealias Loader = (JellyfinCatalogCursor?) async throws -> JellyfinCatalogPage
    typealias CacheLoader = () async -> [JellyfinItem]
    typealias CacheWriter = ([JellyfinItem]) async -> Void

    @Published private(set) var items: [JellyfinItem] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var totalRecordCount = 0
    @Published private(set) var errorMessage: String?

    private var cursor: JellyfinCatalogCursor?
    private var generation = UUID()
    private var paginationTask: Task<Void, Never>?
    private var paginationTaskID: UUID?

    func reset(
        debounce: Duration? = nil,
        cachedItems: CacheLoader? = nil,
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        paginationTask?.cancel()
        paginationTask = nil
        paginationTaskID = nil
        isLoadingMore = false
        let currentGeneration = UUID()
        generation = currentGeneration
        cursor = nil
        hasMore = true
        totalRecordCount = 0
        errorMessage = nil

        if let cachedItems {
            let cached = await cachedItems()
            guard generation == currentGeneration else { return }
            items = cached
        } else {
            items = []
        }
        isInitialLoading = items.isEmpty

        if let debounce {
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
        }
        guard generation == currentGeneration else { return }
        await loadNext(
            generation: currentGeneration,
            replacing: true,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    @discardableResult
    func loadMoreIfNeeded(
        itemID: String,
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) -> Task<Void, Never>? {
        guard
            hasMore,
            let index = items.firstIndex(where: { $0.id == itemID }),
            index >= max(items.count - 10, 0)
        else {
            return paginationTask
        }
        guard paginationTask == nil else { return paginationTask }

        let currentGeneration = generation
        let taskID = UUID()
        paginationTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadNext(
                generation: currentGeneration,
                replacing: false,
                loader: loader,
                cacheWriter: cacheWriter
            )
            guard paginationTaskID == taskID else { return }
            paginationTask = nil
            paginationTaskID = nil
        }
        paginationTask = task
        return task
    }

    func retry(
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        await loadNext(
            generation: generation,
            replacing: items.isEmpty,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    func loadNextPage(
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        await loadNext(
            generation: generation,
            replacing: false,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    private func loadNext(
        generation currentGeneration: UUID,
        replacing: Bool,
        loader: @escaping Loader,
        cacheWriter: CacheWriter?
    ) async {
        guard !isLoadingMore, replacing || hasMore else { return }
        isLoadingMore = true
        if replacing, items.isEmpty {
            isInitialLoading = true
        }
        errorMessage = nil
        defer {
            if generation == currentGeneration {
                isLoadingMore = false
                isInitialLoading = false
            }
        }

        var retryCount = 0
        while true {
            do {
                let page = try await loader(replacing ? nil : cursor)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }

                if replacing {
                    items = page.items
                } else {
                    var seen = Set(items.map(\.id))
                    items.append(
                        contentsOf: page.items.filter {
                            seen.insert($0.id).inserted
                        }
                    )
                }
                cursor = page.cursor
                hasMore = page.hasMore
                totalRecordCount = max(page.totalRecordCount, items.count)
                if let cacheWriter {
                    await cacheWriter(items)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else {
                    return
                }
                guard retryCount < 2, Self.isTransient(error) else {
                    errorMessage = error.localizedDescription
                    return
                }
                retryCount += 1
                do {
                    try await Task.sleep(
                        for: .milliseconds(250 * retryCount)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? JellyfinAPIError else {
            return error is URLError
        }
        switch error {
        case .unreachable, .offline, .network:
            return true
        case .httpStatus(let status):
            return status == 408
                || status == 425
                || status == 429
                || (500...504).contains(status)
        case .unauthorized, .transportSecurity, .invalidResponse:
            return false
        }
    }
}

struct MusicLibraryView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let showProfile: () -> Void

    var body: some View {
        List {
            if jellyfin.isSignedIn {
                Section {
                    ForEach(MusicLibraryCategory.allCases) { category in
                        NavigationLink {
                            destination(for: category)
                        } label: {
                            MusicLibraryCategoryRow(category: category)
                        }
                    }
                } header: {
                    Text("Your Music")
                } footer: {
                    if let session = jellyfin.session {
                        Text(
                            "Music from every library available to \(session.username) is combined here."
                        )
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label(
                            "Connect Your Music Library",
                            systemImage: "music.note.house"
                        )
                    } description: {
                        Text(
                            jellyfin.phase == .restoring
                                ? "Restoring your saved Jellyfin session…"
                                : "Add a Jellyfin server from your profile to browse albums, artists, songs, and playlists."
                        )
                    } actions: {
                        Button("Open Profile", action: showProfile)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }

            Section("Local Music") {
                Button(action: openLocalFile) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Open Audio File")
                                .foregroundStyle(.primary)
                            Text("Play a file directly from this device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SourceIcon(symbolName: "folder")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showProfile) {
                    AccountAvatar(jellyfin: jellyfin)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile and settings")
            }
        }
    }

    @ViewBuilder
    private func destination(for category: MusicLibraryCategory) -> some View {
        MusicLibraryCategoryView(
            category: category,
            playback: playback,
            jellyfin: jellyfin
        )
    }
}

enum MusicLibraryCategory: String, CaseIterable, Identifiable {
    case albums
    case artists
    case songs
    case playlists

    var id: Self { self }

    var title: String {
        switch self {
        case .albums:
            "Albums"
        case .artists:
            "Artists"
        case .songs:
            "Songs"
        case .playlists:
            "Playlists"
        }
    }

    var subtitle: String {
        switch self {
        case .albums:
            "Browse your collection by album"
        case .artists:
            "Find music by artist"
        case .songs:
            "See every song in your library"
        case .playlists:
            "Collections you’ve created and saved"
        }
    }

    var symbolName: String {
        switch self {
        case .albums:
            "opticaldisc.fill"
        case .artists:
            "music.mic"
        case .songs:
            "music.note"
        case .playlists:
            "music.note.list"
        }
    }
}

struct MusicLibraryCategoryView: View {
    let category: MusicLibraryCategory
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @ViewBuilder
    var body: some View {
        switch category {
        case .albums:
            MusicAlbumsView(jellyfin: jellyfin, playback: playback)
        case .artists:
            MusicArtistsView(jellyfin: jellyfin, playback: playback)
        case .songs:
            MusicSongsView(jellyfin: jellyfin, playback: playback)
        case .playlists:
            MusicPlaylistsView(jellyfin: jellyfin, playback: playback)
        }
    }
}

private struct MusicLibraryCategoryRow: View {
    let category: MusicLibraryCategory

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .foregroundStyle(.primary)
                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: category.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(.cyan)
                .frame(width: 36, height: 36)
                .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct MusicDetailHeader: View {
    let item: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let subtitle: String
    let detail: String?

    @ViewBuilder
    var body: some View {
        #if os(macOS)
            HStack(alignment: .bottom, spacing: 26) {
                artwork(size: 220, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
                metadata
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        #else
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(size: 116, cornerRadius: 14)
                    metadata
                }

                VStack(alignment: .leading, spacing: 12) {
                    artwork(size: 116, cornerRadius: 14)
                    metadata
                }
            }
            .padding(.vertical, 6)
        #endif
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        JellyfinArtworkView(
            item: item,
            jellyfin: jellyfin,
            cornerRadius: cornerRadius,
            maxWidth: 480
        )
        .frame(width: size, height: size)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(titleFont)
            Text(subtitle)
                .font(subtitleFont)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleFont: Font {
        #if os(macOS)
            .largeTitle.weight(.bold)
        #else
            .title2.weight(.semibold)
        #endif
    }

    private var subtitleFont: Font {
        #if os(macOS)
            .title3
        #else
            .body
        #endif
    }
}

private struct MusicAlbumsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            if model.isInitialLoading {
                ProgressView("Loading albums…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                MusicCatalogErrorView(message: errorMessage) {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.stack",
                    description: Text(
                        "Jellyfin did not return any albums from your music libraries."
                    )
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 138, maximum: 210),
                            spacing: 18,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(model.items) { album in
                        NavigationLink {
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            MusicAlbumCard(album: album, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            loadMoreIfNeeded(album.id)
                        }
                    }
                }
                .padding(20)

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Albums and artists")
        .task(id: taskID) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private var taskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    private func reset() async {
        await model.reset(
            debounce: query.isEmpty ? nil : .milliseconds(250),
            cachedItems: query.isEmpty
                ? {
                    await jellyfin.cachedCatalogItems(kind: .albums)
                }
                : nil,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func retry() async {
        await model.retry(
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .albums)
        }
    }
}

private struct MusicAlbumCard: View {
    let album: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtworkView(
                item: album,
                jellyfin: jellyfin,
                cornerRadius: 14,
                maxWidth: 480
            )
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct MusicArtistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading artists…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.mic",
                    description: Text(
                        "Jellyfin did not return any artists from your music libraries."
                    )
                )
            } else {
                ForEach(model.items) { artist in
                    NavigationLink {
                        MusicArtistView(
                            artist: artist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: artist,
                                jellyfin: jellyfin,
                                cornerRadius: 28,
                                maxWidth: 180
                            )
                            .frame(width: 54, height: 54)
                            .clipShape(Circle())

                            Text(artist.name)
                                .font(.body.weight(.medium))
                        }
                    }
                    .onAppear {
                        loadMoreIfNeeded(artist.id)
                    }
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Artists")
        .task(id: taskID) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private var taskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    private func reset() async {
        await model.reset(
            debounce: query.isEmpty ? nil : .milliseconds(250),
            cachedItems: query.isEmpty
                ? {
                    await jellyfin.cachedCatalogItems(kind: .artists)
                }
                : nil,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func retry() async {
        await model.retry(
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicArtistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .artists)
        }
    }
}

struct MusicArtistView: View {
    let artist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 14) {
                    JellyfinArtworkView(
                        item: artist,
                        jellyfin: jellyfin,
                        cornerRadius: 90,
                        maxWidth: 420
                    )
                    .frame(width: 172, height: 172)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                    Text(artist.name)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                if model.isInitialLoading {
                    ProgressView("Loading albums…")
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                    MusicCatalogErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "square.stack",
                        description: Text(
                            "No albums are currently associated with this artist."
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Albums")
                            .font(.title2.weight(.semibold))

                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 138, maximum: 210),
                                    spacing: 18,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 24
                        ) {
                            ForEach(model.items) { album in
                                NavigationLink {
                                    JellyfinTracksView(
                                        album: album,
                                        jellyfin: jellyfin,
                                        playback: playback
                                    )
                                } label: {
                                    MusicAlbumCard(
                                        album: album,
                                        jellyfin: jellyfin
                                    )
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    loadMoreIfNeeded(album.id)
                                }
                            }
                        }

                        if model.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else if let errorMessage = model.errorMessage {
                            MusicPaginationErrorView(message: errorMessage) {
                                Task {
                                    await retry()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.id) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private func reset() async {
        await model.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .albums,
                    contextID: artist.id
                )
            },
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                artist: artist
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .albums,
                contextID: artist.id
            )
        }
    }
}

private struct MusicSongsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var preparingTrackID: String?
    @State private var playbackErrorMessage: String?
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading songs…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text(
                        "Jellyfin did not return any songs from your music libraries."
                    )
                )
            } else {
                Section {
                    ForEach(model.items) { song in
                        Button {
                            play(song)
                        } label: {
                            MusicSongRow(
                                song: song,
                                jellyfin: jellyfin,
                                playback: playback,
                                isPreparing: preparingTrackID == song.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                        .onAppear {
                            loadMoreIfNeeded(song.id)
                        }
                    }
                } header: {
                    Text("\(model.totalRecordCount.formatted()) Songs")
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                }
            }

            if let playbackErrorMessage {
                ErrorMessageView(message: playbackErrorMessage)
            }
        }
        .navigationTitle("Songs")
        .searchable(text: $searchText, prompt: "Songs, artists, and albums")
        .task(id: taskID) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private var taskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    private func reset() async {
        await model.reset(
            debounce: query.isEmpty ? nil : .milliseconds(250),
            cachedItems: query.isEmpty
                ? {
                    await jellyfin.cachedCatalogItems(kind: .songs)
                }
                : nil,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func retry() async {
        await model.retry(
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicSongsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .songs)
        }
    }

    private func play(_ song: JellyfinItem) {
        preparingTrackID = song.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    queueItems: model.items.map(
                        JellyfinPlaybackAdapter.playbackItem(for:)
                    ),
                    context: .songs,
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(
                            loader: pageLoader,
                            cacheWriter: query.isEmpty ? cacheWriter : nil
                        )
                        return model.items.map {
                            JellyfinPlaybackAdapter.playbackItem(for: $0)
                        }
                    }
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }
}

private struct MusicPlaylistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading playlists…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text(
                        "Your Jellyfin playlists will appear here."
                    )
                )
            } else {
                ForEach(model.items) { playlist in
                    NavigationLink {
                        MusicPlaylistView(
                            playlist: playlist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: playlist,
                                jellyfin: jellyfin,
                                cornerRadius: 11,
                                maxWidth: 180
                            )
                            .frame(width: 58, height: 58)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.body.weight(.medium))
                                if let childCount = playlist.childCount {
                                    Text(
                                        "\(childCount) \(childCount == 1 ? "song" : "songs")"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("Playlist")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onAppear {
                        loadMoreIfNeeded(playlist.id)
                    }
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .searchable(text: $searchText, prompt: "Playlists")
        .task(id: taskID) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private var taskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    private func reset() async {
        await model.reset(
            debounce: query.isEmpty ? nil : .milliseconds(250),
            cachedItems: query.isEmpty
                ? {
                    await jellyfin.cachedCatalogItems(kind: .playlists)
                }
                : nil,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func retry() async {
        await model.retry(
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicPlaylistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .playlists)
        }
    }
}

struct MusicPlaylistView: View {
    let playlist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var preparingTrackID: String?
    @State private var playbackErrorMessage: String?

    var body: some View {
        List {
            if !model.isInitialLoading {
                Section {
                    MusicDetailHeader(
                        item: playlist,
                        jellyfin: jellyfin,
                        subtitle: "Playlist",
                        detail: model.items.isEmpty
                            ? nil
                            : "\(model.totalRecordCount) \(model.totalRecordCount == 1 ? "song" : "songs")"
                    )
                }
            }

            if model.isInitialLoading {
                ProgressView("Loading playlist…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("This playlist does not contain any songs.")
                )
            } else {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, song in
                    Button {
                        play(song)
                    } label: {
                        MusicSongRow(
                            song: song,
                            leadingNumber: index + 1,
                            jellyfin: jellyfin,
                            playback: playback,
                            isPreparing: preparingTrackID == song.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(preparingTrackID != nil)
                    .onAppear {
                        loadMoreIfNeeded(song.id)
                    }
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                }
            }

            if let playbackErrorMessage {
                ErrorMessageView(message: playbackErrorMessage)
            }
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private func reset() async {
        await model.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .playlistTracks,
                    contextID: playlist.id
                )
            },
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.tracksPage(
                inPlaylist: playlist,
                cursor: cursor
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .playlistTracks,
                contextID: playlist.id
            )
        }
    }

    private func play(_ song: JellyfinItem) {
        preparingTrackID = song.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    queueItems: model.items.map(
                        JellyfinPlaybackAdapter.playbackItem(for:)
                    ),
                    context: .playlist(id: playlist.id),
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(
                            loader: pageLoader,
                            cacheWriter: cacheWriter
                        )
                        return model.items.map {
                            JellyfinPlaybackAdapter.playbackItem(for: $0)
                        }
                    }
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }
}

struct MusicSongRow: View {
    let song: JellyfinItem
    var leadingNumber: Int?
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let isPreparing: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let leadingNumber {
                Text(leadingNumber.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            } else {
                JellyfinArtworkView(
                    item: song,
                    jellyfin: jellyfin,
                    cornerRadius: 8,
                    maxWidth: 140
                )
                .frame(width: 46, height: 46)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(songSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else if playback.currentItem?.id == song.id {
                Image(
                    systemName: playback.showsPauseControl
                        ? "speaker.wave.2.fill"
                        : "pause.circle"
                )
                .foregroundStyle(.cyan)
            } else if let duration = song.duration {
                Text(PlaybackTimeFormatter.format(seconds: duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "play.circle")
                    .foregroundStyle(.cyan)
            }
        }
        .contentShape(Rectangle())
    }

    private var songSubtitle: String {
        if let album = song.album, !album.isEmpty {
            return "\(song.displayArtist) · \(album)"
        }
        return song.displayArtist
    }
}

private struct MusicCatalogErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Music", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
}

struct MusicPaginationErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(.vertical, 8)
    }
}
