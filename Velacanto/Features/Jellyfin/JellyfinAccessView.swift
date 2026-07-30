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
    @State private var tracks: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var preparingTrackID: String?
    @State private var errorMessage: String?

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
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private var iOSContent: some View {
        List {
            if !isLoading {
                Section {
                    albumHeader
                }
            }

            if isLoading {
                ProgressView("Loading tracks…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage, tracks.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await load()
                    }
                }
            } else if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("This album did not return any audio tracks.")
                )
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackButton(track, position: index)
                }
            }

            if let errorMessage, !tracks.isEmpty {
                ErrorMessageView(message: errorMessage)
            }

        }
    }

    #if os(macOS)
        private var macOSContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !isLoading {
                        albumHeader
                    }

                    Group {
                        if isLoading {
                            ProgressView("Loading tracks…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        } else if let errorMessage, tracks.isEmpty {
                            VStack(spacing: 12) {
                                ErrorMessageView(message: errorMessage)
                                Button("Retry") {
                                    Task {
                                        await load()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else if tracks.isEmpty {
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
                                    Array(tracks.enumerated()),
                                    id: \.element.id
                                ) { index, track in
                                    trackButton(track, position: index)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)

                                    if index < tracks.count - 1 {
                                        Divider()
                                            .padding(.leading, 48)
                                    }
                                }
                            }
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: .rect(cornerRadius: 14)
                            )
                        }
                    }

                    if let errorMessage, !tracks.isEmpty {
                        ErrorMessageView(message: errorMessage)
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
            detail: "\(tracks.count) \(tracks.count == 1 ? "track" : "tracks")"
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
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            tracks = try await jellyfin.tracks(in: album)
        } catch {
            tracks = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func play(_ track: JellyfinItem) {
        preparingTrackID = track.id
        errorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: track)
                playback.play(request)
            } catch {
                errorMessage = error.localizedDescription
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
