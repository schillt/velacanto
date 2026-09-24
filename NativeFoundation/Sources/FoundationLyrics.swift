import Combine
import SwiftUI

struct FoundationLyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let id: Int
        let text: String
        let start: Double?
    }
    let lines: [Line]
    var text: String {
        lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var hasTiming: Bool { lines.contains { $0.start != nil } }

    init(lines: [Line]) { self.lines = lines }
    init(text: String) { lines = [Line(id: 0, text: text, start: nil)] }

    /// Select the latest eligible timestamp; equal timestamps use the last source row.
    /// Blank timed rows remain boundaries, clearing the previous sung line.
    func activeLine(at elapsed: Double, duration: Double) -> Int? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return lines.filter {
            guard let start = $0.start, start.isFinite, start >= 0 else { return false }
            return start <= elapsed && (duration <= 0 || start < duration)
        }.max {
            if $0.start == $1.start { return $0.id < $1.id }
            return ($0.start ?? 0) < ($1.start ?? 0)
        }?.id
    }

    /// A row from an obsolete queue occurrence can never seek the new selection.
    func seekTarget(lineID: Int, entryID: UUID, currentEntryID: UUID?, duration: Double) -> Double?
    {
        guard entryID == currentEntryID, duration.isFinite, duration > 0,
            let line = lines.first(where: { $0.id == lineID }), !line.text.isEmpty,
            let start = line.start, start.isFinite, start >= 0, start < duration
        else { return nil }
        return start
    }
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
                    if lyrics.hasTiming {
                        FoundationTimedLyricsView(lyrics: lyrics, entryID: entryID, player: player)
                    } else {
                        ScrollView {
                            Text(lyrics.text)
                                .font(.title3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding()
                        }
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

private struct FoundationTimedLyricsView: View {
    let lyrics: FoundationLyrics
    let entryID: UUID
    @ObservedObject var player: FoundationPlayer
    @State private var followsPlayback = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var activeLine: Int? {
        guard player.selectedEntryID == entryID else { return nil }
        return lyrics.activeLine(at: player.elapsed, duration: player.duration)
    }

    var body: some View {
        let activeLine = activeLine
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(lyrics.lines) { line in
                        let target = lyrics.seekTarget(
                            lineID: line.id, entryID: entryID,
                            currentEntryID: player.selectedEntryID, duration: player.duration)
                        Group {
                            if let target {
                                Button {
                                    player.seek(to: target, entryID: entryID)
                                } label: {
                                    row(line, isCurrent: activeLine == line.id)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Seek to this lyric")
                                .accessibilityValue(activeLine == line.id ? "Current lyric" : "")
                                .accessibilityAddTraits(activeLine == line.id ? .isSelected : [])
                            } else {
                                row(line, isCurrent: activeLine == line.id)
                                    .accessibilityHidden(line.text.isEmpty)
                            }
                        }
                        .id(line.id)
                    }
                }
                .padding()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { followsPlayback = false }
            }
            .onChange(of: activeLine, initial: true) { _, line in
                guard followsPlayback, !voiceOver, let line else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !followsPlayback || voiceOver {
                    Button("Follow current lyric") {
                        followsPlayback = true
                        if let activeLine {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                proxy.scrollTo(activeLine, anchor: .center)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding()
                }
            }
        }
    }

    private func row(_ line: FoundationLyrics.Line, isCurrent: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.title3)
            .fontWeight(isCurrent ? .bold : .regular)
            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
