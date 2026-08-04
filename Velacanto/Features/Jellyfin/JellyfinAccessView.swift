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
        .navigationTitle("Jellyfin Account")
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
    let album: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var preparingTrackID: String?
    @State private var playbackErrorMessage: String?

    var body: some View {
        Group {
            #if os(macOS)
                macOSContent
            #else
                iOSContent
            #endif
        }
        .navigationTitle(album.name)
        .task(id: album.id) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private var iOSContent: some View {
        List {
            if !model.isInitialLoading {
                Section {
                    albumHeader
                }
            }

            if model.isInitialLoading {
                ProgressView("Loading tracks…")
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
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("This album did not return any audio tracks.")
                )
            } else {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, track in
                    trackButton(track, position: index)
                }

                paginationFooter
            }

            if let playbackErrorMessage {
                ErrorMessageView(message: playbackErrorMessage)
            }

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
        MusicDetailHeader(
            item: album,
            jellyfin: jellyfin,
            subtitle: album.displayArtist,
            detail:
                "\(model.totalRecordCount) \(model.totalRecordCount == 1 ? "track" : "tracks")"
        )
    }

    private func trackButton(_ track: JellyfinItem, position: Int) -> some View {
        Button {
            play(track)
        } label: {
            MusicSongRow(
                song: track,
                leadingNumber: track.indexNumber ?? position + 1,
                jellyfin: jellyfin,
                playback: playback,
                isPreparing: preparingTrackID == track.id
            )
            .frame(minHeight: 38)
        }
        .buttonStyle(.plain)
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
            try await jellyfin.tracksPage(in: album, cursor: cursor)
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .albumTracks,
                contextID: album.id
            )
        }
    }

    private func play(_ track: JellyfinItem) {
        preparingTrackID = track.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: track)
                playback.play(
                    request,
                    queueItems: model.items.map {
                        JellyfinPlaybackAdapter.playbackItem(for: $0)
                    },
                    context: .album(id: album.id),
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

struct ErrorMessageView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
    }
}
