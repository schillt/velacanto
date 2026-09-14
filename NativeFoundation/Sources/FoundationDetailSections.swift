import SwiftUI

/// Optional item text owns one visible-page read; presenting it adds no work.
struct FoundationOverviewSection: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    @State private var overview: String?
    @State private var loaded = false
    @State private var showingOverview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let overview, !overview.isEmpty {
                Button {
                    showingOverview = true
                } label: {
                    HStack(alignment: .bottom, spacing: 6) {
                        Text(overview).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("… MORE").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline).multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal).padding(.bottom, 8)
                .accessibilityLabel("Overview: " + overview)
                .accessibilityHint("Opens the complete overview")
                .sheet(isPresented: $showingOverview) {
                    NavigationStack {
                        ScrollView {
                            Text(overview).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled).padding()
                        }
                        .navigationTitle("About " + item.title)
                        #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                        #else
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingOverview = false }
                                }
                            }
                        #endif
                    }
                    #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .accessibilityAction(.escape) { showingOverview = false }
                    #else
                        .frame(minWidth: 360, idealWidth: 480, minHeight: 320, idealHeight: 520)
                        .background(.regularMaterial)
                    #endif
                }
            }
        }
        .task(id: isActive) {
            guard isActive, item.kind == .artist || item.kind == .album, !loaded else { return }
            do {
                let text = try await library.overview(for: item)
                try Task.checkCancellation()
                overview = text
                loaded = true
            } catch {
                if !Task.isCancelled { loaded = true }
            }
        }
    }
}

/// Reuses catalog ownership and cards; each optional shelf fails independently.
struct FoundationRelatedSection<Card: View>: View {
    let title: String
    let isActive: Bool
    var twoRows = false
    let loader: (Int) async throws -> FoundationPage
    @ViewBuilder let card: (FoundationItem) -> Card
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty || model.errorMessage != nil {
                Text(title).font(.title2.bold()).padding(.horizontal)
            }
            if !model.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        let rows = twoRows ? 2 : 1
                        ForEach(0..<((model.items.count + rows - 1) / rows), id: \.self) { column in
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(
                                    column * rows..<min(column * rows + rows, model.items.count),
                                    id: \.self
                                ) { index in
                                    card(model.items[index]).frame(width: 150)
                                }
                            }
                        }
                    }.padding(.horizontal)
                }.scrollIndicators(.hidden)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Button("Retry") { request(model.retryRequest) }.padding(.horizontal)
            }
            if model.isLoading {
                VStack(spacing: 20) {
                    FoundationLoadingPlaceholder(layout: .albumShelf)
                    if twoRows { FoundationLoadingPlaceholder(layout: .albumShelf) }
                }.padding(.horizontal)
            }
            if model.nextStartIndex != nil {
                Button("Load more") { request(.more) }.disabled(model.isLoading).padding(
                    .horizontal)
            }
        }
        .padding(.vertical, model.items.isEmpty && model.errorMessage == nil ? 0 : 12)
        .task(id: isActive ? revision : nil) {
            await model.loadPending(ifActive: isActive, using: loader)
        }
    }

    private func request(_ request: FoundationBrowseModel.Request) {
        model.request(request)
        revision += 1
    }
}

/// A bounded personal-history shelf; it never expands the artist's catalog.
struct FoundationArtistMostPlayed: View {
    let artist: FoundationItem
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    let navigate: (FoundationItem) -> Void
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty || model.errorMessage != nil {
                Text("Most Played").font(.title2.bold()).padding(.horizontal)
            }
            if !model.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(0..<((model.items.count + 1) / 2), id: \.self) { column in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(
                                    column * 2..<min(column * 2 + 2, model.items.count), id: \.self
                                ) { index in
                                    FoundationLibraryItemRow(
                                        item: model.items[index], library: library,
                                        isActive: isActive,
                                        open: {}, play: { play(index) }, player: player,
                                        showsTrackArtwork: true, navigate: navigate,
                                        currentPageKind: .artist,
                                        subtitleOverride: model.items[index].album?.title ?? "")
                                }
                            }.frame(width: 300)
                        }
                    }.padding(.horizontal)
                }.scrollIndicators(.hidden)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Button("Retry") {
                    model.request(model.retryRequest)
                    revision += 1
                }.padding(.horizontal)
            }
            if model.isLoading {
                FoundationLoadingPlaceholder().padding(.horizontal)
            }
        }
        .padding(.vertical, model.items.isEmpty && model.errorMessage == nil ? 0 : 12)
        .task(id: isActive ? revision : nil) {
            await model.loadPending(ifActive: isActive) { _ in
                try await library.mostPlayed(artistID: artist.id)
            }
        }
    }

    private func play(_ index: Int) {
        guard let selection = model.trackQueue(selecting: index) else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)

    }
}
