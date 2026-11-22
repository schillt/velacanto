import AppIntents

/// AudioPlaybackIntent is performed in the containing app, which owns the one player.
struct FoundationWidgetPlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control VelaCanto Playback"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Account") var scope: String
    @Parameter(title: "Queue occurrence") var occurrence: String
    @Parameter(title: "Collection") var collectionID: String
    @Parameter(title: "Action") var action: String
    @Parameter(title: "Collection kind", default: "") var collectionKind: String
    @Parameter(title: "Display", default: .currentSong) var mode: FoundationWidgetDisplayMode

    init() {}
    init(
        snapshot: FoundationWidgetSnapshot, mode: FoundationWidgetDisplayMode,
        action: FoundationWidgetSnapshot.Action
    ) {
        let display = snapshot.display(mode)
        scope = snapshot.scope ?? ""
        occurrence = display.occurrence?.uuidString ?? ""
        collectionID = display.collection?.id ?? ""
        collectionKind = display.collection?.kind ?? ""
        self.mode = mode
        self.action = action.rawValue
    }

    func perform() async throws -> some IntentResult {
        try await performInApplication()
        return .result()
    }

    @MainActor private func performInApplication() async throws {
        #if VELACANTO_WIDGET_EXTENSION
            // This branch must never perform playback in an extension process.
            throw FoundationWidgetIntentFailure.applicationRequired
        #else
            guard let action = FoundationWidgetSnapshot.Action(rawValue: action),
                scope.utf8.count == 64, occurrence.utf8.count <= 36,
                collectionID.utf8.count <= 256,
                collectionKind.isEmpty || ["album", "playlist"].contains(collectionKind),
                occurrence.isEmpty || UUID(uuidString: occurrence) != nil
            else { throw FoundationWidgetIntentFailure.unavailable }
            // Publication failure must not turn an already accepted playback request into an error.
            _ = try await FoundationAppRuntime.model.performWidgetCommand(
                .init(
                    scope: scope, occurrence: UUID(uuidString: occurrence),
                    collectionID: collectionID.isEmpty ? nil : collectionID, action: action,
                    mode: mode, collectionKind: collectionKind.isEmpty ? nil : collectionKind))
        #endif
    }
}

enum FoundationWidgetIntentFailure: Error, LocalizedError {
    case unavailable, applicationRequired
    var errorDescription: String? { "Open VelaCanto to update playback, then try again." }
}
