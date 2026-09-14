# Home refinement — issue 147

Base: 9cd74253c5fc37877a48e4b70397f43f222a6733 (recovered UI lineage).
Branch: codex/foundation-home-refinement.
Owned production path: Sources/FoundationHomeView.swift only.

Continue Listening uses supplied album artwork and separate native buttons for
opening the player and toggling playback. Recently Played preserves the six
preview entries in a two-row horizontal snapping carousel. Accessibility sizes
and action errors use vertical rows. Album menus have semantic foregrounds and
a material backing, with 44-point control targets. Removed the explanatory
history caption and redundant below-card menu layout. Old app is reference only.

## Request and ownership budget

Metadata calls, paging state, load tasks, refresh and queue selection indices
are unchanged. Each instantiated shelf uses its existing single pending page
load; retained loaded/empty reentry performs zero metadata reads. Explicit
refresh retains the original behavior. Compact layout may expose additional
existing shelves sooner; no claim that viewport-wide counts are identical.

Up to seven additional tagged 160-pixel artwork reads (one current card plus
six history entries) use supplied neutral album references. Missing tags make
zero requests. A retained completed view repeats zero reads; recreated views
may read again. Existing native cancellation applies on disappearance. No
metadata resolution, global cache, coalescing guarantee or automatic retry added.

## Boundaries and acceptance

Playback, transport, credentials, catalog models, actions, diagnostics, project
and existing tests are unchanged. No new dependencies or test scaffolding.
Lyrics remain excluded. Local build/visual evidence and exact source commit
are recorded in the persistent candidate manifest. Owner device acceptance is
a separate gate; a successful compile is not network-reliability evidence.
