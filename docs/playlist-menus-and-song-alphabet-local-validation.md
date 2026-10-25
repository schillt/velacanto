# Playlist menus and Songs alphabet local validation

Base: `cd24b67`; runtime candidate: `98d0388a086cfbfe276104a2e1c50cd6fc9fc5b4`.
VelaCanto Alpha 0.4.0 build 167; local development, no remote publication.

## Context menus

Shared native Mac/iOS item menus group favorite/pin actions, positive/playback
and navigation actions, then destructive actions. Removal uses native destructive
button roles. Download removal is present only for supported items with downloaded
data; its existing confirmation flow is retained. Toolbar icons retain their prior
role styling.

Remove from Playlist is supplied only by a playlist content view, never by a
track's incidental membership in another surface. The selected server membership
identity is retained in optional item metadata. Explicit removal checks edit
permissions and uses the existing bounded mutation reconciliation, preserving
other occurrences of the same song. Uncertain outcomes invalidate the playlist
without automatically retrying a write. Offline/disappearance cancellation is
view-owned and does not create a cancellation notice when no operation ran.

## Songs

All Songs requests server Name ascending order. The former metadata SortName
order can encode disc/track information. Letter selection owns a separate retained
range model and can fetch an unloaded title range, preserving its canonical queue
selection and absolute continuation cursor. Offline selection uses local data.

Jellyfin's name boundary filters constrain metadata SortName, so a track-title
range uses a bounded binary offset seek over Name-ordered one-row responses.
The helper verifies counts, offsets, unique identities, normalized ordering and
boundary/predecessor, with at most 24 probes for at most one million tracks, then
one page of at most 50 songs. Incompatible ordering or catalog drift fails with
an actionable error; it does not claim an unsupported title filter succeeded.
Other typed catalog indexes keep their existing SortName capability path.

Primary source contracts:
- [Jellyfin song-title ordering](https://github.com/jellyfin/jellyfin-web/blob/master/src/apps/legacy/controllers/music/songs.js)
- [Jellyfin Name ordering](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Server.Implementations/Item/OrderMapper.cs)
- [Jellyfin name-filter semantics](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Server.Implementations/Item/BaseItemRepository.QueryBuilding.cs)
- [Jellyfin CleanName normalization](https://github.com/jellyfin/jellyfin/blob/master/src/Jellyfin.Extensions/StringExtensions.cs)

## Verification

139 Mac catalog, playlist and presentation tests passed, including duplicate
membership safety, read-only rejection, missing membership rejection, unloaded
title seek, absolute cursors, bounds, cancellation and normalization. Strict lint,
diff checks and preflight passed (two environment/probe warnings).
Independent read-only review of the exact candidate found no remaining scoped
blocker. Signed builds, installation and remaining iOS/physical checks are recorded
when completed; this record does not claim private playlist content was deleted.

## Final installation and app checks

- Five retained iOS UI tests passed: cold Z range/no prefix scan plus canonical F
  selection, missing letters, selected-range retry, supersession/cancellation,
  and offline related navigation with playback identity retained.
- Signed macOS and iOS Release builds passed. Build 167 installed and launched on
  Mac and the authorized iPhone 13 mini, preserving app data and prior Mac bundle.
- Actual Mac right-click menus verified: a downloaded playlist track shows both
  removal actions together below a divider; a non-downloaded playlist track shows
  Download among positive actions and only playlist removal among destructive
  actions; a downloaded album track shows download removal without playlist
  removal. Native Mac menus keep their system text appearance; no custom red-text
  implementation is claimed. No personal playlist entry or download was removed.
- Actual Mac Songs first page confirmed server title ordering with numerical titles
  leading. Owner reported the requested physical iPhone check looks good so far;
  this records initial acceptance, alongside the passed simulator and provider
  tests, rather than exhaustive catalog or server-collation coverage.
- New Tracks build 166 ordering was subsequently accepted by the owner. This build
  preserves that ascending Date Added feed unchanged.
