# System-wide duplicate visibility and Mac pinned navigation

Base: `862d490`; VelaCanto Alpha 0.4.0 build 169, local development only.
Supersedes build 168's album-only presentation and CarPlay browsing limitations.

## Duplicate visibility

The existing Library setting now controls shared account-scoped visibility.
Album identity, disc number (missing means one), positive track number and
normalized title identify alternate file copies. Unknown tags stay visible.
Known canonical IDs and aliases are learned only from bounded supplied metadata,
without catalog scans, and cleared on account retirement. Identical canonical-song
IDs may retain intentional occurrence identities; alternate copy IDs are hidden.

Raw browse membership, provider offsets, page caches, playlist mutation snapshots,
queue persistence and downloaded owner/file manifests remain intact. Presentation
projects browsing, search/discovery, playlists/editor, downloaded music, CarPlay
pages/shelves and queues. Search filters before result caps. Hidden-only CarPlay
pages retain raw continuation. The toggle restores raw candidates without a refetch.
Existing native current playback retains its occurrence; hidden upcoming copies
are excluded. Restored queues remain paused and retain disc/track tags.

Album-to-playlist additions filter before batching and revalidate before each
write. Removal retains exact membership IDs and rechecks visibility after the
before-snapshot await. Hidden individual download/favorite/queue intents are
rejected; collection download transfer demand is filtered while raw ownership and
saved files remain intact. Visibility is rechecked after download URL lookup.
No server copies or existing audio files are deleted by hiding duplicates.

## Mac navigation

Pinned is an expandable native sidebar submenu. Its header only expands/collapses;
Favorites is its first child, followed by local pinned items opening their existing
shared detail destinations. The former top-level Favorites row is removed on Mac.
Mobile navigation is unchanged. Repo instructions now require a fresh subagent for
each distinct topic/issue, with follow-ups limited to that original task.

## Verification

Independent read-only review identified and verified corrections for raw queue/file
retention, optional persisted tags, rendering purity and per-write policy guards.
170 focused Mac policy, action, download, playlist and player tests passed. Strict
formatting and diff checks passed. Later bounded stale-download guards and iOS
weak-capture compiler correction are verified by the remaining platform checks.
Signed builds, simulator result and installed app checks will be recorded below.
Synthetic checks do not prove correctness of every personal server metadata tag,
physical audibility, production CarPlay session behavior or TestFlight distribution.

## Frozen installation and platform evidence

Runtime candidate: `78076a9`; instruction change: `336ede5`. Later evidence-only
commits do not alter runtime. The final offline availability/default-projection
adjustment and stale individual download guards passed 68 policy/download tests.
Two iOS UI tests passed on the frozen source: duplicate toggle/rows/numbers/queue,
and offline alphabetical song/related navigation preserving playback.

Signed Mac and iOS Release builds succeeded. Alpha 169 installed and launched on
Mac and the authorized iPhone 13 mini; device installed-version verification passed.
Bundle identities/data were preserved, previous Mac bundle backed up, executable
hashes recorded privately. Actual Mac native Pinned collapse/expand preserves Home;
Favorites disappears when collapsed, returns when expanded and opens its existing
Favorites destination. No Mac personal pinned item was present for an actual leaf
navigation check; those leaves retain the existing shared item route. No personal
playlist mutation was performed. Owner confirmation on actual tagged duplicates
and production CarPlay content remains a data-specific acceptance check; no second
CarPlay session was opened and no physical audibility is claimed. Source remains
local; no GitHub publication, beta promotion or TestFlight upload was performed.

## Pinned artwork follow-up (build 170)

Runtime: `36c12ac`, a Mac-only sidebar thumbnail change plus build metadata.
Pinned items reuse the shared cached artwork loader at 24 points; artists are
circular and album/other covers have rounded square corners. Track artwork resolves
the catalog album identity. Favorites retains the existing native star icon.
No new image provider or request on redraw is introduced.

Strict formatting/diff checks and signed Mac/iOS Release builds passed. Alpha 170
installed on both devices with stored data preserved. Actual Mac screenshot now
verifies two existing pinned album thumbnails and the Favorites star; an artist
pin was not available for that visual check. The phone installed-version check
passed; its first automatic launch was blocked by the lock screen. After the owner
unlocked the iPhone on 2026-10-14, the launch-only retry succeeded without
reinstalling (exit 0). Shared iOS behavior is unchanged from verified build 169; no
new UI tests were added for this Mac-only presentation edit.
