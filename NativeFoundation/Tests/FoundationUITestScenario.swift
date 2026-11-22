import Foundation

/// Test-only launch configuration. Validation precedes any application launch.
struct FoundationUITestScenario {
    var failOnce: Bool = false
    var heldFirstPlaylistTracks: Bool = false
    var account: Bool = false
    var delayedAuth: Bool = false
    var productionShell: Bool = false
    var largeText: Bool = false
    var canonicalDownloadState: String? = nil
    var artworkCache: Bool = false
    var membership: String? = nil
    var slowTransfer: Bool = false
    var longPlayback: Bool = false
    var unknownRelatedItems: Bool = false
    var missingArtwork: Bool = false
    var reducedAccessibilityEffects: Bool = false
    var signInFailure: String? = nil
    var colorScheme: String? = nil
    var pagedCatalog: Bool = false
    var catalogPageFailOnce: Bool = false
    var playlistPresentation: Bool = false
    var librarySelection: Bool = false
    var alphabetCatalog: Bool = false
    var alphabetFailOnce: Bool = false
    var delayedAlphabetCapability: Bool = false
    var heldArtistAlbums: Bool = false
    var partialGridRow: Bool = false
    var compactFixtureControls: Bool = false
    var queuePresentation: Bool = false
    var alphabetCapabilityFailOnce: Bool = false
    var detachedPlayerArtwork: Bool = false
    var holdPlayerGlass: Bool = false
    var heldAlphabetPage: Bool = false
    var favoritesCatalog: Bool = false
    var extendedSongsCatalog: Bool = false
    var heldAlphabetRange: Bool = false
    var emptyFavoritePreview: Bool = false
    var duplicateAlbumTracks: Bool = false
    var overview: Bool = false
    var heldArtistTracks: Bool = false
    var relatedRecommendations: Bool = false
    var collectionOutcome: String? = nil
    var homeScrollBoundary: Bool = false
    var homeNativeViewportDiagnostic: Bool = false
    var heldHomeGenres: Bool = false
    var playlistReorder: Bool = false
    var playlistReorderFailOnce: Bool = false
    var primaryGenres: Bool = false
    var heldPrimaryGenreMetadata: Bool = false
    var primaryGenreScopedQuery: Bool = false
    var sharedChromeEvidence: Bool = false
    var remoteListening: Bool = false
    var queueArtworkTransition: Bool = false
    var lyricsPresentation: Bool = false
    var missingLyrics: Bool = false
    var remoteFavoriteRefresh: Bool = false
    var automaticGenres: Bool = false
    var progressivePlaylistSearch: Bool = false
    var boundedSearchCoverage: Bool = false
    var trackedPlaylistRoute: Bool = false

    static let downloads = Self()
    static let searchCoverage = Self(
        productionShell: true, compactFixtureControls: true, boundedSearchCoverage: true)
    static let playlistSearch = Self(
        productionShell: true, compactFixtureControls: true, progressivePlaylistSearch: true)
    static let downloadFailures = Self(failOnce: true, trackedPlaylistRoute: true)
    static let signIn = Self(account: true)
    static let delayedSignIn = Self(account: true, delayedAuth: true)
    static let playbackQueue = Self(
        productionShell: true, canonicalDownloadState: "full", longPlayback: true,
        queuePresentation: true)

    enum Invalid: Error { case incompatible(String) }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Invalid.incompatible(message) }
        }
        try require(
            !account || !productionShell, "Account sign-in and signed-in shell are separate roots")
        try require(!delayedAuth || account, "Delayed authentication requires the sign-in root")
        try require(
            signInFailure == nil || account, "Authentication failures require the sign-in root")
        try require(
            [boundedSearchCoverage, progressivePlaylistSearch, alphabetCatalog, pagedCatalog].filter
            { $0 }.count <= 1,
            "Choose one catalog/search provider scenario")
        try require(!catalogPageFailOnce || pagedCatalog, "Catalog failure requires paged catalog")
        try require(
            !alphabetFailOnce && !alphabetCapabilityFailOnce && !delayedAlphabetCapability
                && !heldAlphabetPage && !heldAlphabetRange || alphabetCatalog,
            "Alphabet failure/holds require alphabet catalog")
        try require(
            !playlistReorderFailOnce || playlistReorder,
            "Playlist move failure requires playlist reordering")
        try require(
            !missingLyrics || lyricsPresentation, "Missing lyrics requires the lyrics scenario")
        try require(
            !queueArtworkTransition || queuePresentation,
            "Queue artwork requires queue presentation")
        try require(
            !heldPrimaryGenreMetadata && !primaryGenreScopedQuery || primaryGenres,
            "Genre metadata/query controls require primary genres")
        try require(
            canonicalDownloadState.map { ["none", "partial", "full"].contains($0) } ?? true,
            "Unknown canonical download state")
        try require(
            membership.map { ["track", "album"].contains($0) } ?? true,
            "Unknown membership scenario")
        try require(
            collectionOutcome.map { ["fail-once", "empty"].contains($0) } ?? true,
            "Unknown collection outcome")
        try require(
            colorScheme.map { ["light", "dark"].contains($0) } ?? true, "Unknown appearance")
        try require(
            signInFailure.map {
                ["-fixtureInvalidServer", "-fixtureUnreachableServer"].contains($0)
            } ?? true,
            "Unknown authentication failure")
    }

    struct LaunchConfiguration {
        let arguments: [String]
        let environment: [String: String]
    }

    func configuration(runID: String = UUID().uuidString) throws -> LaunchConfiguration {
        try validate()
        guard UUID(uuidString: runID) != nil else {
            throw Invalid.incompatible("Fixture run identity must be a UUID")
        }
        var arguments: [String] = []
        var environment: [String: String] = [:]
        arguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if progressivePlaylistSearch {
            arguments.append("-fixtureProgressivePlaylistSearch")
        }
        if boundedSearchCoverage {
            arguments.append("-fixtureBoundedSearchCoverage")
        }
        if trackedPlaylistRoute {
            arguments.append("-fixtureTrackedPlaylistRoute")
        }
        if lyricsPresentation { arguments.append("-fixtureLyricsPresentation") }
        if remoteFavoriteRefresh { arguments.append("-fixtureRemoteFavoriteRefresh") }
        if missingLyrics { arguments.append("-fixtureMissingLyrics") }
        if sharedChromeEvidence { arguments.append("-fixtureSharedChromeEvidence") }
        if remoteListening { arguments.append("-fixtureRemoteListening") }
        if primaryGenres { arguments.append("-fixturePrimaryGenres") }
        if automaticGenres { arguments.append("-fixtureAutomaticGenres") }
        if heldPrimaryGenreMetadata {
            arguments.append("-fixtureHoldPrimaryGenreMetadata")
        }
        if primaryGenreScopedQuery { arguments.append("-fixturePrimaryGenreScopedQuery") }
        if overview { arguments.append("-fixtureOverview") }
        if relatedRecommendations { arguments.append("-fixtureRelatedRecommendations") }
        if homeScrollBoundary { arguments.append("-fixtureHomeScrollBoundary") }
        if playlistReorder { arguments.append("-fixturePlaylistReorder") }
        if playlistReorderFailOnce { arguments.append("-fixturePlaylistReorderFailOnce") }
        if homeNativeViewportDiagnostic { arguments.append("-diagnosticHomeRebound") }
        if heldHomeGenres { arguments.append("-fixtureHoldHomeGenres") }
        if duplicateAlbumTracks { arguments.append("-fixtureDuplicateAlbumTracks") }
        if heldArtistTracks { arguments.append("-fixtureHoldArtistTracks") }
        if let collectionOutcome {
            arguments += ["-fixtureCollectionOutcome", collectionOutcome]
        }
        if heldFirstPlaylistTracks { arguments.append("-fixtureHoldFirstPlaylistTracks") }
        if extendedSongsCatalog { arguments.append("-fixtureExtendedSongsCatalog") }
        if productionShell { arguments.append("-fixtureProductionShell") }
        if favoritesCatalog { arguments.append("-fixtureFavoritesCatalog") }
        if emptyFavoritePreview { arguments.append("-fixtureEmptyFavoritePreview") }
        if queuePresentation { arguments.append("-fixtureQueuePresentation") }
        if queueArtworkTransition { arguments.append("-fixtureQueueArtworkTransition") }
        if detachedPlayerArtwork { arguments.append("-fixtureDetachedPlayerArtwork") }
        if holdPlayerGlass { arguments.append("-fixtureHoldPlayerGlass") }
        if heldAlphabetPage { arguments.append("-fixtureHoldOrdinaryAlphabetPage") }
        if compactFixtureControls { arguments.append("-fixtureCompactControls") }
        if heldArtistAlbums { arguments.append("-fixtureHoldArtistAlbums") }
        if partialGridRow { arguments.append("-fixtureGridPartialRow") }
        if artworkCache { arguments.append("-fixtureArtworkCache") }
        if pagedCatalog {
            arguments += ["-fixturePagedCatalog", "-fixtureHoldInitialCatalog"]
        }
        if catalogPageFailOnce { arguments.append("-fixtureCatalogPageFailOnce") }
        if playlistPresentation { arguments.append("-fixturePlaylistPresentation") }
        if librarySelection { arguments.append("-fixtureLibrarySelection") }
        if alphabetCatalog {
            arguments.append("-fixtureAlphabetCatalog")
        }
        if heldAlphabetRange { arguments.append("-fixtureHoldAlphabetA") }
        if alphabetFailOnce { arguments.append("-fixtureAlphabetFailOnce") }
        if alphabetCapabilityFailOnce {
            arguments.append("-fixtureAlphabetCapabilityFailOnce")
        }
        if delayedAlphabetCapability {
            arguments.append("-fixtureDelayedAlphabetCapability")
        }
        if let canonicalDownloadState {
            arguments += [
                "-fixtureCanonicalCollections", "-fixtureDownloadState", canonicalDownloadState,
            ]
        }
        if failOnce { arguments.append("-fixtureFailOnce") }
        if slowTransfer { arguments.append("-fixtureSlowTransfer") }
        if longPlayback { arguments.append("-fixtureLongPlayback") }
        if unknownRelatedItems { arguments.append("-fixtureUnknownRelatedItems") }
        if missingArtwork { arguments.append("-fixtureMissingArtwork") }
        if reducedAccessibilityEffects {
            environment["FOUNDATION_UI_REDUCE_MOTION"] = "1"
            environment["FOUNDATION_UI_REDUCE_TRANSPARENCY"] = "1"
        }
        if let membership { arguments += ["-fixtureMembership", membership] }
        if account { arguments.append("-fixtureAccount") }
        if let signInFailure { arguments.append(signInFailure) }
        if let colorScheme { environment["FOUNDATION_UI_COLOR_SCHEME"] = colorScheme }
        if delayedAuth { arguments.append("-fixtureDelayedAuth") }
        environment["FOUNDATION_UI_RUN_ID"] = runID
        if largeText { environment["FOUNDATION_UI_LARGE_TEXT"] = "1" }
        return .init(arguments: arguments, environment: environment)
    }
}
