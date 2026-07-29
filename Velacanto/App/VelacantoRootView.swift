import SwiftUI
import UniformTypeIdentifiers

enum AppDestination: String, Hashable, Identifiable, CaseIterable {
    case home
    case library

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library:
            "Library"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            "house"
        case .library:
            "rectangle.stack"
        }
    }
}

struct VelacantoRootView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @State private var selectedDestination = AppDestination.home
    @State private var isChoosingLocalFile = false
    @State private var isPreparingTestTone = false
    @State private var isShowingAccount = false
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
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                JellyfinAccessView(
                    jellyfin: jellyfin,
                    playback: playback
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isShowingAccount = false
                        }
                    }
                }
            }
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
            }
        }
    #endif

    #if os(macOS)
        private var macOSRoot: some View {
            NavigationSplitView {
                List(AppDestination.allCases, selection: $selectedDestination) {
                    destination in
                    Label(destination.title, systemImage: destination.symbolName)
                        .tag(destination)
                }
                .navigationTitle("Velacanto")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if playback.hasPlayableItem {
                        PlaybackAccessory(
                            playback: playback,
                            jellyfin: jellyfin,
                            showNowPlaying: {
                                isShowingNowPlaying = true
                            }
                        )
                        .padding(10)
                    }
                }
            } detail: {
                NavigationStack {
                    switch selectedDestination {
                    case .home:
                        home
                    case .library:
                        library
                    }
                }
            }
            .frame(minWidth: 820, minHeight: 620)
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
            showAccount: {
                isShowingAccount = true
            },
            showNowPlaying: {
                isShowingNowPlaying = true
            }
        )
    }

    private var library: some View {
        MusicLibraryView(
            playback: playback,
            jellyfin: jellyfin,
            isPreparingTestTone: isPreparingTestTone,
            openLocalFile: {
                isChoosingLocalFile = true
            },
            playTestTone: playTestTone,
            showAccount: {
                isShowingAccount = true
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
                let request = try await localFiles.playbackRequest(
                    for: LocalFileSelection(
                        url: url,
                        title: "Velacanto playback check",
                        artist: "440 Hz local tone"
                    )
                )
                playback.play(request)
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let playRecentItem: (PlaybackItem) -> Void
    let showAccount: () -> Void
    let showNowPlaying: () -> Void

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
            ToolbarItem(placement: .primaryAction) {
                Button(action: showAccount) {
                    AccountAvatar(username: jellyfin.session?.username)
                }
                .accessibilityLabel(
                    jellyfin.isSignedIn
                        ? "Jellyfin account"
                        : "Connect Jellyfin account"
                )
            }
        }
    }

    @ViewBuilder
    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow("Continue Listening")

            if let item = playback.currentItem {
                Group {
                    if horizontalSizeClass == .compact {
                        VStack(alignment: .leading, spacing: 16) {
                            Button(action: showNowPlaying) {
                                PlaybackArtworkView(
                                    item: item,
                                    jellyfin: jellyfin
                                )
                                .aspectRatio(1.55, contentMode: .fill)
                                .contentShape(.rect(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)

                            NowPlayingSummary(
                                playback: playback,
                                showsTransportButton: true
                            )
                        }
                    } else {
                        HStack(spacing: 24) {
                            Button(action: showNowPlaying) {
                                PlaybackArtworkView(
                                    item: item,
                                    jellyfin: jellyfin
                                )
                                .aspectRatio(1.55, contentMode: .fill)
                                .contentShape(.rect(cornerRadius: 18))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: 600)

                            NowPlayingSummary(
                                playback: playback,
                                showsTransportButton: true
                            )
                            .frame(minWidth: 230, idealWidth: 290)
                        }
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
                            Text(
                                "Choose a local file or connect your Jellyfin library to begin."
                            )
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
                NavigationLink {
                    JellyfinAccessView(
                        jellyfin: jellyfin,
                        playback: playback
                    )
                } label: {
                    SourceRow(
                        title: "Jellyfin",
                        subtitle: jellyfinSubtitle,
                        symbolName: "server.rack"
                    )
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.leading, 58)

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

    private var jellyfinSubtitle: String {
        if let session = jellyfin.session {
            return "Connected to \(session.serverName)"
        }
        if jellyfin.phase == .restoring {
            return "Restoring your session"
        }
        return "Connect your personal music server"
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

private struct SourceIcon: View {
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

    var body: some View {
        Group {
            if item.source == .jellyfin,
                let artworkItemID = item.artworkItemID
            {
                RemoteArtworkView(
                    itemID: artworkItemID,
                    imageTag: item.artworkTag,
                    jellyfin: jellyfin,
                    cornerRadius: 18,
                    maxWidth: 1_200
                )
            } else {
                ArtworkPlaceholder(cornerRadius: 18)
            }
        }
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

private struct PlaybackAccessory: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    let showNowPlaying: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: showNowPlaying) {
                HStack(spacing: 10) {
                    if let item = playback.currentItem {
                        PlaybackArtworkView(item: item, jellyfin: jellyfin)
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
        .padding(8)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
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
                showNowPlaying: showNowPlaying
            )
            .padding(.horizontal, placement == .inline ? 2 : 8)
        }
    }
#endif

private struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let item = playback.currentItem {
                    PlaybackArtworkView(item: item, jellyfin: jellyfin)
                        .aspectRatio(1, contentMode: .fill)
                        .frame(maxWidth: 440, maxHeight: 440)
                        .shadow(color: .black.opacity(0.16), radius: 28, y: 14)

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
                            Text(
                                PlaybackTimeFormatter.format(
                                    seconds: playback.elapsed
                                )
                            )
                            Spacer()
                            Text(
                                PlaybackTimeFormatter.format(
                                    seconds: playback.duration
                                )
                            )
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
                        Label(
                            errorMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.red)
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
            .frame(maxWidth: 520)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

private struct AccountAvatar: View {
    let username: String?

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.10), in: Circle())
            .overlay {
                Circle()
                    .stroke(.cyan.opacity(0.18), lineWidth: 0.5)
            }
    }

    private var initials: String {
        guard let username, !username.isEmpty else { return "VC" }
        let words = username.split(separator: " ")
        let characters = words.prefix(2).compactMap(\.first)
        let value = String(characters)
        return value.isEmpty ? "VC" : value.uppercased()
    }
}

struct VelacantoSettingsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        Form {
            Section("Jellyfin") {
                if let session = jellyfin.session {
                    LabeledContent("Server", value: session.serverName)
                    LabeledContent("Account", value: session.username)
                    Button("Log Out", role: .destructive) {
                        Task {
                            await jellyfin.logout()
                        }
                    }
                } else {
                    Text("No Jellyfin account is connected.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Velacanto", value: "0.1.0")
                Text("Native music playback for your personal library.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
            .frame(width: 460, height: 290)
        #endif
    }
}

#Preview {
    VelacantoRootView(
        playback: AudioPlaybackCoordinator(),
        jellyfin: JellyfinSessionController(autoRestore: false)
    )
}
