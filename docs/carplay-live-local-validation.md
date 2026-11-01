# Live CarPlay local validation

## Candidate

Local build 164, VelaCanto Alpha, runtime source
`f1eefc373ea398552b51b5bad64edde3b2948a18`, based on the owner-tested
build160 checkpoint `47e2b96`. Signed Release builds were installed on the
authorized iPhone 13 mini and the existing Mac alpha. Bundle identities and
stored data were preserved; previous Mac app bundles were retained.
No remote publication or release promotion was performed. The initial alpha
fetch failed; publication must fetch and reconcile current alpha before integration.

## Implemented behavior

- Native Home, New, Library and a List-backed Search tab.
- Larger leading square pins with rounded corners, populated from shared pins.
- Four-item native shelf previews, without forced six-item row groups.
  Home includes Recently Played and Favorites; New shows recently added music;
  Library includes Most Played Albums. Heading routes expose bounded snapshots.
- Server-backed playlists, favorites, albums, artists, songs and genres, plus
  ready downloads. Category icons use semantic light/dark image variants.
- Native Search uses the shared resolver and metadata relationships. Results
  are ranked before the CarPlay cap, preserving exact playlist matches and
  useful partial results. Keyboard submission opens a full native results list
  from the same query snapshot rather than issuing a second lookup.
- Native mini-player and Now Playing retain the shared phone player. Shuffle,
  repeat, queue and search use four supported native extra buttons. The native
  text-only Up Next button is replaced by a queue image button.
- Queue viewing and occurrence-UUID selection only. Move/remove/edit controls
  were removed following the owner's revised scope; phone editing is unchanged.
- Compact lists use at most 12 native rows, with explicit continuation. Vehicle
  restriction notifications reproject cached pages and preserve first-omitted
  offsets without new catalog reads; corresponding artwork refresh is cache-only.
- Scene routing preserves build160's fresh phone-scene configuration fix.
  Disconnect cancels CarPlay-owned work and leaves phone playback ownership intact.

## Verification

- Signed iOS and macOS Release builds passed on final runtime source; strict
  signature checks passed. The audio entitlement/profile was verified locally.
- Final core candidate `8957fb2`: 21 iOS tests passed (12 catalog and nine
  startup/routing tests). Catalog tests also passed on Mac. The subsequent
  `84392b4` change affects navigation icon contrast only; final builds and
  physical dark-mode checks cover that delta.
- Earlier focused validation passed 36 existing collection ownership/action
  tests. Those production paths were not modified by this work.
- Strict formatting, diff checks and preflight passed (preflight retained its
  environment warnings). Independent source review reported no scoped blocker.
- Physical phone plus one Apple CarPlay Simulator session: live tabs, pins,
  artwork shelves, playlist index and first-load tracks were observed.
- Playlist Play opened Now Playing and advanced elapsed time; the owner
  confirmed audible output. Final build164 queue selection changed the selected
  song, and Pause returned playback to paused.
- Build163 native keyboard submission opened Search Results with the exact
  existing playlist first and artwork loaded. Search logic is unchanged in164.
- Build164 opened after reconnect; the reported dark Search glyph is now readable.
  Queue and Search icons are visible in native Now Playing, and Up Next contains
  no editing button. Raw logs, app backups and installation receipts stay local.

## CarPlay boundaries and remaining acceptance

The June 8, 2026 [CarPlay Developer Guide](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)
permits Search for audio apps on iOS27. Search is supplementary to browsing;
its template is pushed from an allowed List tab root. The system controls
keyboard availability and vehicle-dependent list restrictions. The app does
not infer driving status or implement a custom keyboard. Native navigation,
list/section counts and playback-button limits are respected. The 12-row budget
is a compact presentation choice, not a universal minimum vehicle limit.

Real-vehicle acceptance remains pending: driving/parked keyboard transitions,
dynamic limit transitions (including very small limits), rotary/Voice Control
access, locked-phone reconnect, varied display sizes and extended playback.
This local evidence does not constitute App Store review or a release approval.
