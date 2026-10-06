# Basic playlist management — 0.4 scope

The maintained native app provides playlist creation, rename, deletion, and
track addition/removal through the provider-neutral library boundary. Playlist
editing does not alter active playback or the local Up Next queue. Playlist
reordering remains deferred. Creation confirms the returned identity and requested
name against authoritative playlist metadata. Deletion completes only after a
bounded full playlist enumeration confirms that the target is absent.

## Membership and supported operations

The app renders every returned occurrence with a local identity derived from its
source position and server entry identity. It retains the server mutation identity
separately; local display identity is never sent as a removal identifier.

Before a membership change, the app reads a complete, cancellable snapshot, limited
to 10,000 entries and 100 page requests. Exceeding that limit prevents the write and
explains that this playlist should be managed on the server. Removal confirms that
the exact server membership disappeared and that duplicate sibling memberships
still reference the original track. An acknowledgement alone is insufficient.

If the server reuses a mutation identity for repeated tracks, the app preserves and
renders those occurrences but makes track editing read-only for that playlist.
Rename and explicit whole-playlist deletion remain available when permitted.
Cancellation does not claim that the server rolled back an already-sent change.
Failures retain an understandable, privacy-safe outcome and require explicit
refresh/retry; no automatic mutation retries occur.

## Jellyfin compatibility

The inspected Jellyfin 10.10.7 implementation deduplicates additions and returns
the track identity as `PlaylistItemId`. Adding an already-present track therefore
shows an honest already-in-playlist outcome without sending a mutation. Existing
ambiguous repeated memberships cannot be removed individually through this API;
the app does not invent a transport workaround or silently collapse them.

Name-only updates omit membership, share and visibility fields. The tagged DTO,
controller and manager preserve unspecified nullable fields:

- [UpdatePlaylistDto](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Jellyfin.Api/Models/PlaylistDtos/UpdatePlaylistDto.cs)
- [PlaylistsController](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Jellyfin.Api/Controllers/PlaylistsController.cs)
- [PlaylistManager](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Emby.Server.Implementations/Playlists/PlaylistManager.cs)

This source inspection establishes that tagged contract. It does not verify the
actual deployed server or authorize changing a personal library.

## Acceptance boundary

Synthetic tests cover private creation and request construction, metadata-only
rename, membership identity/order, permissions, bounded reconciliation, stale
completion/cancellation, confirmed removal across pages, ambiguous identities,
and already-present additions without writes.

Independent exact-candidate review, simulator/native UI accessibility, authorized
disposable-server lifecycle testing, physical playback isolation and signed
platform/distribution checks remain separate gates. No passing synthetic test
establishes those results. Download lifecycle and successful-edit synchronization
are separately owned by issue #13.
