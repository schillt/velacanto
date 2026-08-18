import SwiftUI

struct JellyfinAccessView: View {
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        Group {
            switch jellyfin.phase {
            case .restoring:
                ProgressView("Restoring Jellyfin session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn:
                signedInView
            case .signedOut, .connecting, .awaitingCredentials, .authenticating:
                JellyfinSignInView(jellyfin: jellyfin)
            }
        }
        .progressivePageHeader("Jellyfin Account")
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 560)
        #endif
    }

    private var signedInView: some View {
        List {
            if let session = jellyfin.session {
                Section("Connection") {
                    LabeledContent("Server", value: session.serverName)
                    LabeledContent("User", value: session.username)

                    if jellyfin.usesInsecureLocalHTTP {
                        Label(
                            "This local connection uses unencrypted HTTP.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Button("Log Out", role: .destructive) {
                        Task {
                            await jellyfin.logout()
                        }
                    }
                }
            }

            if let errorMessage = jellyfin.errorMessage {
                Section {
                    ErrorMessageView(message: errorMessage)
                }
            }
        }
        #if os(macOS)
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        #endif
    }
}

private struct JellyfinSignInView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""

    private var hasConnectedServer: Bool {
        jellyfin.serverInfo != nil
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    "https://jellyfin.example.com",
                    text: $serverAddress
                )
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .disabled(hasConnectedServer || jellyfin.isWorking)

                if let serverInfo = jellyfin.serverInfo {
                    Label {
                        VStack(alignment: .leading) {
                            Text(serverInfo.serverName)
                            Text("Jellyfin \(serverInfo.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button("Use a Different Server") {
                        jellyfin.editServer()
                        password = ""
                    }
                } else {
                    Button(jellyfin.phase == .connecting ? "Connecting…" : "Connect") {
                        Task {
                            await jellyfin.connect(to: serverAddress)
                        }
                    }
                    .disabled(serverAddress.isEmpty || jellyfin.isWorking)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(
                    "HTTPS is required for remote servers. Explicit HTTP addresses "
                        + "are accepted only on your local network."
                )
            }

            if hasConnectedServer {
                Section("Account") {
                    TextField("Username", text: $username)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .disabled(jellyfin.isWorking)

                    SecureField("Password", text: $password)
                        .disabled(jellyfin.isWorking)

                    Button(
                        jellyfin.phase == .authenticating
                            ? "Signing In…"
                            : "Sign In"
                    ) {
                        Task {
                            await jellyfin.signIn(
                                username: username,
                                password: password
                            )
                            password = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty || jellyfin.isWorking)

                    Text("Your password is sent to this server once and is never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if jellyfin.usesInsecureLocalHTTP {
                    Section {
                        Label(
                            "HTTP does not encrypt your password or music traffic. "
                                + "Use it only on a network you trust.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }

            if jellyfin.isWorking {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }

            if let errorMessage = jellyfin.errorMessage {
                Section {
                    ErrorMessageView(message: errorMessage)
                }
            }
        }
    }
}

struct JellyfinTracksView: View {
    let album: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    var transitionNamespace: Namespace.ID?
    @StateObject private var model = PagedMusicCatalogModel()
    @State private var preparingTrackID: MusicCatalogItemID?
    @State private var playbackErrorMessage: String?
    @State private var collectionPalette = MusicCollectionPalette.fallback

    var body: some View {
        Group {
            #if os(macOS)
                macOSContent
            #else
                iOSContent
            #endif
        }
        .collectionDetailNavigationChrome()
        .albumArtworkZoomTransition(
            sourceID: album.artworkTransitionID,
            in: transitionNamespace
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(macOS)
                    MusicFavoriteButton(item: album, presentation: .icon)
                #endif
                MusicLibraryPinMenu(item: album)
            }
        }
        #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(
                collectionPalette.usesLightForeground ? .dark : .light,
                for: .navigationBar
            )
        #endif
        .task(id: album.id) {
            await reset()
        }
    }

    private var iOSContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if !model.isInitialLoading {
                    albumHeader
                        .padding(.bottom, 22)
                }

                if model.isInitialLoading {
                    ProgressView("Loading tracks…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 88)
                } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                    VStack(spacing: 14) {
                        ErrorMessageView(message: errorMessage)
                        Button("Retry") {
                            Task {
                                await retry()
                            }
                        }
                    }
                    .padding(.vertical, 48)
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "No Tracks",
                        systemImage: "music.note",
                        description: Text("This album did not return any audio tracks.")
                    )
                    .padding(.vertical, 48)
                } else {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, track in
                        trackButton(track, position: index)
                            .padding(.vertical, 10)
                        if index < model.items.count - 1 {
                            Divider()
                        }
                    }

                    paginationFooter
                }

                if let playbackErrorMessage {
                    ErrorMessageView(message: playbackErrorMessage)
                        .padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .background {
            MusicCollectionArtworkBackdrop(
                item: album,
                jellyfin: jellyfin,
                palette: $collectionPalette
            )
        }
    }

    #if os(macOS)
        private var macOSContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.isInitialLoading {
                        albumHeader
                    }

                    Group {
                        if model.isInitialLoading {
                            ProgressView("Loading tracks…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                            VStack(spacing: 12) {
                                ErrorMessageView(message: errorMessage)
                                Button("Retry") {
                                    Task {
                                        await retry()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else if model.items.isEmpty {
                            ContentUnavailableView(
                                "No Tracks",
                                systemImage: "music.note",
                                description: Text(
                                    "This album did not return any audio tracks."
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(
                                    Array(model.items.enumerated()),
                                    id: \.element.id
                                ) { index, track in
                                    trackButton(track, position: index)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)

                                    if index < model.items.count - 1 {
                                        Divider()
                                            .padding(.leading, 48)
                                    }
                                }
                            }
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: .rect(cornerRadius: 14)
                            )

                            paginationFooter
                        }
                    }

                    if let playbackErrorMessage {
                        ErrorMessageView(message: playbackErrorMessage)
                    }
                }
                .frame(maxWidth: 1_000, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    #endif

    private var albumHeader: some View {
        #if os(iOS)
            MusicCollectionHero(
                item: album,
                jellyfin: jellyfin,
                collectionLabel: nil,
                subtitle: album.displayArtist,
                detail: nil,
                metadata: album.collectionMetadata,
                palette: collectionPalette,
                isPreparing: preparingTrackID != nil,
                play: { playQueue(shuffled: false) },
                shuffle: { playQueue(shuffled: true) }
            )
        #else
            VStack(alignment: .leading, spacing: 16) {
                MusicDetailHeader(
                    item: album,
                    jellyfin: jellyfin,
                    subtitle: album.displayArtist,
                    detail:
                        "\(model.totalRecordCount) \(model.totalRecordCount == 1 ? "track" : "tracks")",
                    artworkSize: 180
                )

                MusicQueuePlaybackControls(
                    capabilities: album.capabilities,
                    isPreparing: preparingTrackID != nil,
                    play: { playQueue(shuffled: false) },
                    shuffle: { playQueue(shuffled: true) }
                )
            }
        #endif
    }

    private func trackButton(_ track: MusicCatalogItem, position: Int) -> some View {
        Button {
            play(track)
        } label: {
            MusicSongRow(
                song: track,
                leadingNumber: track.indexNumber ?? position + 1,
                jellyfin: jellyfin,
                playback: playback,
                isPreparing: preparingTrackID == track.id,
                foreground: collectionPalette.foreground,
                secondaryForeground: collectionPalette.secondaryForeground
            )
            .frame(minHeight: 38)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(preparingTrackID != nil)
        .onAppear {
            loadMoreIfNeeded(track.id)
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 8)
        } else if let errorMessage = model.errorMessage {
            MusicPaginationErrorView(message: errorMessage) {
                Task {
                    await retry()
                }
            }
        }
    }

    private func reset() async {
        await model.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .albumTracks,
                    contextID: album.id
                )
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

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.tracksPage(in: album, cursor: cursor)
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .albumTracks,
                contextID: album.id
            )
        }
    }

    private func play(_ track: MusicCatalogItem) {
        preparingTrackID = track.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(
                    for: playbackItem(for: track)
                )
                playback.play(
                    request,
                    queueItems: model.items.map {
                        playbackItem(for: $0)
                    },
                    context: .album(id: album.id.opaqueID),
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(
                            loader: pageLoader,
                            cacheWriter: cacheWriter
                        )
                        return model.items.map {
                            playbackItem(for: $0)
                        }
                    }
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }

    private func playQueue(shuffled: Bool) {
        guard !model.items.isEmpty else { return }
        let tracks = shuffled ? model.items.shuffled() : model.items
        guard let track = tracks.first else { return }

        preparingTrackID = track.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(
                    for: playbackItem(for: track)
                )
                if shuffled {
                    playback.play(
                        request,
                        queueItems: tracks.map(playbackItem(for:)),
                        context: .album(id: album.id.opaqueID),
                        account: jellyfin.playbackAccount
                    )
                } else {
                    playback.play(
                        request,
                        queueItems: tracks.map(playbackItem(for:)),
                        context: .album(id: album.id.opaqueID),
                        account: jellyfin.playbackAccount,
                        queueExpansion: {
                            await model.loadNextPage(
                                loader: pageLoader,
                                cacheWriter: cacheWriter
                            )
                            return model.items.map {
                                playbackItem(for: $0)
                            }
                        }
                    )
                }
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }

    private func playbackItem(for track: MusicCatalogItem) -> PlaybackItem {
        JellyfinPlaybackAdapter.playbackItem(
            for: track,
            fallbackArtistID: album.artistIDs.first
        )
    }

}

struct ErrorMessageView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
    }
}
