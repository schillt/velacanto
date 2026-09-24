import Combine
import SwiftUI

struct FoundationLyrics: Equatable, Sendable {
    let text: String
}

@MainActor
final class FoundationLyricsModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, missing
        case loaded(FoundationLyrics)
        case failed(FoundationLibraryError)
    }

    @Published private(set) var state: State = .idle
    private var generation = 0

    /// The visible sheet owns the task. Repeated appearances do not reload a completed result.
    func load(
        item: FoundationItem, library: any FoundationLibrary,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard state == .idle, isCurrent(), !Task.isCancelled else { return }
        generation += 1
        let request = generation
        state = .loading
        do {
            let lyrics = try await library.lyrics(for: item)
            guard request == generation, isCurrent(), !Task.isCancelled else { return }
            state = lyrics.map(State.loaded) ?? .missing
        } catch {
            guard request == generation, isCurrent(), !Task.isCancelled else { return }
            let failure = FoundationLibraryError.category(error)
            state = failure == .cancelled ? .idle : .failed(failure)
        }
    }

    /// Invalidate before dismissal so a provider that ignores cancellation cannot publish.
    func cancel() {
        generation += 1
        state = .idle
    }

    func prepareRetry() {
        guard case .failed = state else { return }
        state = .idle
    }
}

struct FoundationLyricsView: View {
    let item: FoundationItem
    let entryID: UUID
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    @StateObject private var model = FoundationLyricsModel()
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    ProgressView("Loading lyrics…")
                case .missing:
                    ContentUnavailableView("Lyrics unavailable", systemImage: "quote.bubble")
                case .failed(let error):
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Couldn’t load lyrics", systemImage: "exclamationmark.bubble",
                            description: Text(error.localizedDescription))
                        Button("Retry") {
                            model.prepareRetry()
                            retry += 1
                        }
                    }
                case .loaded(let lyrics):
                    ScrollView {
                        Text(lyrics.text)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Lyrics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 480, minHeight: 420, idealHeight: 600)
        #endif
        .task(id: retry) {
            await model.load(item: item, library: library) { player.selectedEntryID == entryID }
        }
        .onChange(of: player.selectedEntryID) { _, selection in
            guard selection != entryID else { return }
            model.cancel()
            dismiss()
        }
        .onDisappear { model.cancel() }
    }
}
