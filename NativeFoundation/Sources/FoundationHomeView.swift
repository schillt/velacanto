import SwiftUI

/// Home composes independently owned, visible catalog sections around the existing player.
struct FoundationHomeView<Profile: View>: View {
    let profile: Profile
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @ObservedObject var recentTracks: FoundationBrowseModel
    @ObservedObject var favorites: FoundationBrowseModel
    @ObservedObject var recentAlbums: FoundationBrowseModel
    @ObservedObject var genres: FoundationBrowseModel
    let isActive: Bool
    @State private var isVisible = false
    @State private var genreRetryRevision = 0
    @State private var showingPlayer = false
    @State private var openedItem: FoundationItem?
    @EnvironmentObject private var actions: FoundationLibraryActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                FoundationContinueListening(
                    player: player, library: library, isActive: isActive && isVisible,
                    showingPlayer: $showingPlayer)
                FoundationHomeShelf(
                    title: "Recently Played", model: recentTracks, library: library, player: player,
                    isActive: isActive, showsTracks: true,
                    openedItem: $openedItem
                ) { try await library.recentlyPlayed(startIndex: $0) }
                FoundationHomeShelf(
                    title: "Favorites", model: favorites, library: library, player: player,
                    isActive: isActive, isFavorites: true,
                    openedItem: $openedItem
                ) { try await library.favoriteAlbums(startIndex: $0) }
                FoundationHomeShelf(
                    title: "Recently Added", model: recentAlbums, library: library, player: player,
                    isActive: isActive,
                    openedItem: $openedItem
                ) { try await library.recentAlbums(startIndex: $0) }
                genreShelves
                if let error = actions.pinErrorMessage { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=home appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            #if DEBUG
                FoundationTrace.event("ui origin=home disappeared")
            #endif
        }
        .foundationHeader("Home", profile: profile)
        #if DEBUG
            .onChange(of: showingPlayer) { _, presented in
                FoundationTrace.event(
                    presented
                        ? "ui origin=home player=presented" : "ui origin=home player=dismissed")
            }
        #endif
        .foundationPlayerCover(isPresented: $showingPlayer) {
            FoundationPlayerView(player: player, library: library)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } }
            )
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive)
            }
        }
    }

    private var genreShelves: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(Array(genres.items.prefix(5).enumerated()), id: \.element.id) { _, genre in
                FoundationHomeGenreShelf(
                    genre: genre, library: library, player: player,
                    isActive: isActive,
                    openedItem: $openedItem)
            }
            if genres.isLoading { FoundationLoadingPlaceholder(layout: .albumShelf) }
            if let error = genres.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry genres") {
                    genres.request(genres.retryRequest)
                    genreRetryRevision += 1
                }
            }
        }
        .task(id: isActive && isVisible ? genreRetryRevision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .genreIndex) {
                    await genres.loadPending(ifActive: isActive && isVisible) { _ in
                        try await library.homeGenres()
                    }
                }
            #else
                await genres.loadPending(ifActive: isActive && isVisible) { _ in
                    try await library.homeGenres()
                }
            #endif
        }
    }
}

private struct FoundationContinueListening: View {
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    @ObservedObject var player: FoundationPlayer
    let library: any FoundationLibrary
    let isActive: Bool
    @Binding var showingPlayer: Bool

    var body: some View {
        if let item = player.queue.first(where: { $0.id == player.selectedEntryID })?.item {
            continueListening(item)
        }
    }

    private var playbackProgress: Double {
        guard player.duration.isFinite, player.duration > 0, player.elapsed.isFinite else {
            return 0
        }
        return min(1, max(0, player.elapsed / player.duration))
    }

    private func continueListening(_ item: FoundationItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Listening")
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase).tracking(1)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Button {
                    showingPlayer = true
                } label: {
                    HStack(spacing: 12) {
                        FoundationCatalogArtwork(
                            source: .current(currentArtwork.result(for: item)),
                            item: item.catalogArtworkItem, library: library,
                            isActive: isActive, size: 64
                        ).id(
                            item.catalogArtworkItem.id
                                + (item.catalogArtworkItem.primaryImageTag ?? ""))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(
                                player.state == .playing || player.state == .paused
                                    ? item.subtitle : player.state.label
                            )
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                .accessibilityValue(item.title + ", " + item.subtitle + ", " + player.state.label)
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                        .overlay {
                            Circle()
                                .trim(from: 0, to: playbackProgress)
                                .stroke(
                                    .primary.opacity(0.75),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .padding(2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
    }

}

private struct FoundationHomeGenreShelf: View {
    let genre: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @Binding var openedItem: FoundationItem?
    @StateObject private var albums = FoundationBrowseModel()

    var body: some View {
        FoundationHomeShelf(
            title: genre.title, model: albums, library: library, player: player,
            isActive: isActive,
            openedItem: $openedItem
        ) { try await library.albums(genreID: genre.id, startIndex: $0) }
    }
}

private struct FoundationHomeShelf: View {
    let title: String
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var showsTracks = false
    var isFavorites = false
    @Binding var openedItem: FoundationItem?
    let loader: (Int) async throws -> FoundationPage
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var retryRevision = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if !model.items.isEmpty {
                    NavigationLink {
                        FoundationCatalogView(
                            title: title, model: model, library: library, player: player,
                            isActive: isActive, isFavorites: isFavorites, loader: loader)
                    } label: {
                        HStack(spacing: 6) {
                            Text(title).font(.title2.bold())
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all " + title.lowercased())
                    .accessibilityAddTraits(.isHeader)
                } else {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
            }
            if showsTracks {
                if usesVerticalRecentRows {
                    VStack(spacing: 12) {
                        recentRows
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: [GridItem(.fixed(64)), GridItem(.fixed(64))], spacing: 16) {
                            recentRows
                        }
                        .frame(height: 136)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .accessibilityLabel("Recently Played carousel")
                }
            } else if !model.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(model.items.prefix(5).enumerated()), id: \.offset) {
                            _, item in
                            FoundationAlbumShelfCard(
                                item: item, library: library, player: player,
                                isActive: isActive && isVisible, open: { openedItem = item },
                                navigate: { openedItem = $0 })
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
            if model.isLoading {
                FoundationLoadingPlaceholder(layout: showsTracks ? .rows : .albumShelf)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    model.request(model.retryRequest)
                    retryRevision += 1
                }
            } else if model.loaded, model.items.isEmpty {
                Text("No items yet.").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=home appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            #if DEBUG
                FoundationTrace.event("ui origin=home disappeared")
            #endif
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            if isFavorites, isActive, isVisible {
                model.request(.refresh)
                retryRevision += 1
            }
        }
        .task(id: isActive && isVisible ? retryRevision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .shelf) {
                    guard isActive, isVisible, !Task.isCancelled else { return }
                    await model.loadPending(using: loader)
                }
            #else
                guard isActive, isVisible, !Task.isCancelled else { return }
                await model.loadPending(using: loader)
            #endif
        }
    }

    private var usesVerticalRecentRows: Bool {
        dynamicTypeSize.isAccessibilitySize
            || model.items.prefix(6).contains { actions.errorMessage(for: $0) != nil }
    }

    private var recentRows: some View {
        ForEach(Array(model.items.prefix(6).enumerated()), id: \.offset) { index, item in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        playRecent(index)
                    } label: {
                        HStack(spacing: 10) {
                            homeArtwork(
                                item, library: library, isActive: isActive && isVisible, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.body.weight(.medium))
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Menu {
                        recentMenu(item, index: index)
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Actions for " + item.title)
                }
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(width: usesVerticalRecentRows ? nil : 276)
            .contextMenu { recentMenu(item, index: index) }
        }
    }

    private func playRecent(_ index: Int) {
        guard let selection = model.trackQueue(selecting: index) else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func recentMenu(_ item: FoundationItem, index: Int) -> some View {
        FoundationItemMenu(
            item: item, actions: actions, initialFavorite: item.isFavorite,
            play: { playRecent(index) }, player: player, navigate: { openedItem = $0 })
    }

}

/// Display supplied album artwork without resolving metadata or changing the source item.
@MainActor private func homeArtwork(
    _ item: FoundationItem, library: any FoundationLibrary, isActive: Bool, size: CGFloat
) -> some View {
    let artworkItem = item.catalogArtworkItem
    return FoundationCatalogArtwork(
        item: artworkItem, library: library, isActive: isActive, size: size
    ).id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
}
