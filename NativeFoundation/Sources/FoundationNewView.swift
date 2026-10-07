import SwiftUI

/// Recent content reuses the catalog page owners, destinations, menus and player.
struct FoundationNewView<Profile: View>: View {
    let profile: Profile
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    @ObservedObject var tracks: FoundationBrowseModel
    @ObservedObject var albums: FoundationBrowseModel
    let isActive: Bool
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var trackRevision = 0
    @State private var albumRevision = 0
    @State private var openedItem: FoundationItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                trackSection
                albumSection
                genreSection
                if let error = actions.pinErrorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }.padding()
        }
        .foundationHeader("New", profile: profile)
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=new appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            #if DEBUG
                FoundationTrace.event("ui origin=new disappeared")
            #endif
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } }
            )
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive
                )
                #if os(iOS)
                    .toolbar(.visible, for: .navigationBar)
                #endif
            }
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("New Tracks", model: tracks) {
                try await library.recentTracks(startIndex: $0)
            }
            ForEach(Array(tracks.items.prefix(6).enumerated()), id: \.offset) { index, item in
                FoundationLibraryItemRow(
                    item: item, library: library, isActive: isActive && isVisible,
                    open: {},
                    play: {
                        guard let selection = tracks.trackQueue(selecting: index) else { return }
                        player.setQueue(selection.items, selectedIndex: selection.index)

                    }, player: player, showsTrackArtwork: true)
                if index < min(5, tracks.items.count - 1) { Divider() }
            }
            sectionState(tracks) {
                tracks.request(tracks.retryRequest)
                trackRevision += 1
            }
        }
        .task(id: isActive && isVisible ? trackRevision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await tracks.loadPending(ifActive: isActive && isVisible) {
                        try await library.recentTracks(startIndex: $0)
                    }
                }
            #else
                await tracks.loadPending(ifActive: isActive && isVisible) {
                    try await library.recentTracks(startIndex: $0)
                }
            #endif
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recently Added", model: albums) {
                try await library.recentAlbums(startIndex: $0)
            }
            if !albums.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(albums.items.prefix(5).enumerated()), id: \.offset) {
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
            sectionState(albums) {
                albums.request(albums.retryRequest)
                albumRevision += 1
            }
        }
        .task(id: isActive && isVisible ? albumRevision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await albums.loadPending(ifActive: isActive && isVisible) {
                        try await library.recentAlbums(startIndex: $0)
                    }
                }
            #else
                await albums.loadPending(ifActive: isActive && isVisible) {
                    try await library.recentAlbums(startIndex: $0)
                }
            #endif
        }
    }

    /// Most recent occurrence wins; only the existing first 24 albums contribute.
    private var recentGenres: [(genre: FoundationItem, artwork: FoundationItem)] {
        var seen = Set<String>()
        var result: [(genre: FoundationItem, artwork: FoundationItem)] = []
        for album in albums.items.prefix(24) {
            for reference in album.genres where seen.insert(reference.id).inserted {
                result.append(
                    (
                        FoundationItem(
                            id: reference.id, title: reference.title, subtitle: "",
                            kind: .genre, duration: nil), album
                    ))
                if result.count == 6 { return result }
            }
        }
        return result
    }

    @ViewBuilder private var genreSection: some View {
        let entries = recentGenres
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Genres with New Music").font(.title2.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(entries, id: \.genre.id) { entry in
                            FoundationGenreCard(
                                genre: entry.genre, library: library,
                                isActive: isActive && isVisible,
                                open: { openedItem = entry.genre }, artworkItem: entry.artwork
                            ).frame(width: 180)
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func sectionHeader(
        _ title: String, model: FoundationBrowseModel,
        loader: @escaping (Int) async throws -> FoundationPage
    ) -> some View {
        HStack(spacing: 6) {
            if model.items.count > (model === tracks ? 6 : 5) || model.nextStartIndex != nil {
                NavigationLink {
                    FoundationCatalogView(
                        title: title, model: model, library: library, player: player,
                        isActive: isActive, showsTrackArtwork: true,
                        loader: loader
                    )
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #endif
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.title2.bold())
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("See all " + title.lowercased())
            } else {
                Text(title).font(.title2.bold()).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func sectionState(
        _ model: FoundationBrowseModel, retry: @escaping () -> Void
    ) -> some View {
        if model.isLoading {
            FoundationLoadingPlaceholder(layout: model === albums ? .albumShelf : .rows)
        }
        if let error = model.errorMessage {
            Text(error).foregroundStyle(.red)
            Button("Retry", action: retry)
        } else if model.loaded, model.items.isEmpty {
            Text("No recently added items.").foregroundStyle(.secondary)
        }
    }

}

/// A retained, bounded album ranking independent of New and Home.
struct FoundationLibraryMostPlayedAlbums: View {
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Played Albums").font(.title2.bold())
            Text("From your 100 most-played tracks").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 144, maximum: 180), spacing: 16)],
                alignment: .leading, spacing: 20
            ) {
                ForEach(Array(model.items.prefix(12).enumerated()), id: \.offset) { _, item in
                    FoundationAlbumShelfCard(
                        item: item, library: library, player: player,
                        isActive: isActive && isVisible, open: { openedItem = item },
                        navigate: { openedItem = $0 })
                }
            }
            if model.isLoading { FoundationLoadingPlaceholder(layout: .albumGrid) }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    model.request(model.retryRequest)
                    revision += 1
                }
            } else if model.loaded, model.items.isEmpty {
                Text("No album listening history yet.").foregroundStyle(.secondary)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .navigationDestination(
            isPresented: Binding(get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive
                )
                #if os(iOS)
                    .toolbar(.visible, for: .navigationBar)
                #endif
            }
        }
        .task(id: isActive && isVisible ? revision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: .library, page: .shelf) {
                    await model.loadPending(ifActive: isActive && isVisible) { _ in
                        try await library.mostPlayedAlbums()
                    }
                }
            #else
                await model.loadPending(ifActive: isActive && isVisible) { _ in
                    try await library.mostPlayedAlbums()
                }
            #endif
        }
    }
}
