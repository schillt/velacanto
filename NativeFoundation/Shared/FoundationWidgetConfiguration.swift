import AppIntents

extension FoundationWidgetDisplayMode: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Display")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .currentSong: "Current Song",
        .recentCollection: "Recent Album/Playlist",
    ]
}

struct FoundationWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "VelaCanto Playback"
    static let isDiscoverable = false
    @Parameter(title: "Display", default: .currentSong)
    var displayMode: FoundationWidgetDisplayMode
}
