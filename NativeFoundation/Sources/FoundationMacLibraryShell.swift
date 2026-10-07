#if os(macOS)
    import SwiftUI

    /// Native presentation only. The caller owns loading, playback and destination content.
    struct FoundationMacLibraryShell<Content: View, MiniPlayer: View>: View {
        @Binding var selection: FoundationDestination
        let showsMiniPlayer: Bool
        private let content: (FoundationDestination) -> Content
        private let miniPlayer: () -> MiniPlayer

        init(
            selection: Binding<FoundationDestination>,
            showsMiniPlayer: Bool,
            @ViewBuilder content: @escaping (FoundationDestination) -> Content,
            @ViewBuilder miniPlayer: @escaping () -> MiniPlayer
        ) {
            _selection = selection
            self.showsMiniPlayer = showsMiniPlayer
            self.content = content
            self.miniPlayer = miniPlayer
        }

        var body: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    ForEach(FoundationDestination.allCases, id: \.self) { destination in
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Velacanto")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .accessibilityLabel("Main navigation")
            } detail: {
                NavigationStack {
                    content(selection)
                }
                // Changing top-level sections discards obsolete pushed destinations.
                // Models retained by the caller remain available on Library reentry.
                .id(selection)
                .frame(minWidth: 420)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsMiniPlayer {
                        VStack(spacing: 0) {
                            Divider()
                            miniPlayer()
                        }
                        .background(.regularMaterial)
                    }
                }
            }
            .frame(minWidth: 660, minHeight: 480)
        }
    }
#endif
