import Foundation

/// Stable presentation identity for the canonical genre and its completed census.
/// Newly authored during source recovery; this does not recreate provider genre policy.
struct FoundationGenreIdentity: Hashable, Sendable {
    let source: FoundationCatalogSource?
    let itemID: String
    let censusID: UUID?
}

extension FoundationItem {
    /// Mutable display metadata does not replace a row; another source or census does.
    var genreIdentity: FoundationGenreIdentity {
        .init(source: catalogSource, itemID: id, censusID: primaryGenreCensusID)
    }
}
