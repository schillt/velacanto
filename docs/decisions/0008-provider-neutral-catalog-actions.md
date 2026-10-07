# 0008 — Provider-neutral catalog items and actions

- Status: Accepted
- Date: 2026-08-11

## Context

Playback already receives source-neutral requests, but general Home, library,
search, and navigation views still consume `JellyfinItem`. Adding favorites,
queue actions, richer Home collections, and a later CarPlay browse surface on
that model would make each presentation depend on Jellyfin response semantics.

A full plugin framework is unnecessary. Velacanto needs one small catalog and
action seam that reflects product behavior while Jellyfin remains the only
functional server provider.

## Decision

- Introduce `MusicCatalogItem` as the general presentation value for albums,
  artists, songs, and playlists.
- Keep identity opaque and scoped to its source/connection.
- Describe supported behavior with `MusicItemCapabilities`; presentation never
  infers actions from a provider name.
- Introduce a focused `MusicLibraryProviding` boundary for paged library,
  search, detail, Home collection, and supported mutation operations.
- Map Jellyfin API models and favorite state inside the Jellyfin catalog boundary.
- Sequence optimistic mutations through one account-scoped state owner so all
  visible representations reconcile or roll back together.
- Keep provider connection and account-management presentation explicitly
  provider-specific.
- Do not introduce runtime plugins, a service locator, a generic endpoint DSL,
  or protocols that have no second consumer or test seam.

## Consequences

- Native iPhone, iPad, Mac, and future CarPlay presentation can share item and
  action behavior without importing Jellyfin transport types.
- Jellyfin mapping gains explicit tests and remains the only functional provider
  in 0.3.
- Catalog migration must preserve paging, ordering, cache identity, cancellation,
  and stale-result behavior.
- Favorite updates require a central reconciliation owner rather than isolated
  per-view toggles.
- Future providers implement the same product capabilities honestly instead of
  pretending unsupported actions exist.
