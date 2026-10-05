# Artwork and offline storage policy — issue #14

## Current implementation and measured boundaries

Baseline: alpha `de7abe9df9ae294184cadbddb01ecc2161038ab1`. This policy
belongs to the maintained NativeFoundation app, not the removed legacy cache.

| Owner | Retention and request boundary |
| --- | --- |
| Visible catalog artwork | One optional image per live view; one view-owned read, cancelled with its task. Requests use 160 pixels for tiles and 640 for heroes. Completed failures remain placeholders until that view lifetime ends. No metadata lookup, prefetch, application disk cache or cross-view coalescer. |
| Current artwork | One account-owned result shared by the player and system metadata. Identity includes account lifetime, album/item and tag. Same identity reuses the result; change cancels the old load and rejects late results. Missing/failing artwork does not retry that identity. |
| Image decode | Shared existing ImageIO decoder rejects empty/malformed, multi-image, over-2 MiB payloads and source dimensions beyond 2048. Tiles downsample to 160 pixels; hero/current result to 640. Catalog views retain only the decoded image; current owner also retains the encoded payload. |
| Native transport | Existing shared ephemeral URLSession, no application-owned disk cache. Request/resource timeouts are 30/60 seconds. Ephemeral does not mean zero in-memory native cache. The app does not presently set an explicit URLCache capacity or clear that shared native cache on account teardown. |

Synthetic decoder tests use a 1024 × 512 JPEG: tile output is 160 × 80;
hero output is 640 × 320. Tests inspect `bytesPerRow × height`, bounded by
102,400 bytes per tile and 1,638,400 bytes per hero (160/640 square RGBA
budgets). Current encoded retention is at most 2 MiB, in addition to the decoded
image. These are retained-result boundaries, not process peak-memory measurements;
encoded responses arrive before decode validation, and native network/decode
buffers, SwiftUI retention and system-media copies remain outside this count.
Total visible catalog retention scales with live views; no global memory limit
or LRU eviction is claimed. No private library or device memory profile was read.

Invalidation clears current ownership/result and rejects retained callbacks. Account
replacement tears down the catalog tree. This establishes application result
isolation; it does not establish immediate erasure of native buffers/caches or
old backups. A future native-cache change needs focused account/response tests;
do not revive historical 16/64 MiB caches as though they already exist.

## Offline and failure presentation

Missing, malformed, rejected and failed images use the same deterministic neutral
shape with `music.mic` for artists or `music.note` otherwise. The view hides decorative
artwork from accessibility. No error text includes provider response contents, and
artwork never changes playback. A currently retained image can remain visible offline;
an unseen/recreated catalog view has no promised persistent artwork. Native response
reuse is optional and must not be labeled offline availability.

Issue #13 may retain optional artwork for explicitly downloaded content through its
single storage owner and existing library reads. Current/system artwork must continue
using FoundationCurrentArtwork with a local-first loader; do not add a second current
owner/downloader. Offline image absence remains a placeholder and does not block an
audio download. Store at most one validated 640-pixel rendition for each retained
artwork identity; share it for tracks with the same album/tag. Reuse a larger rendition
for a smaller display, never enlarge a tile as a guaranteed hero. New tags replace
only owned artwork after success; failed refreshes preserve usable local content.
Artwork disk bytes count in On Device storage; release files when their last retained
collection/track reference disappears. This download artwork policy is specified here,
not implemented by #14. It does not authorize scanning or prefetching the library.

## Download storage integration contract — issue #13

- Use one account-owned Application Support directory for the manifest, original
  native-playable audio, optional artwork and staging files. Apply backup exclusion
  to the root and verify after creation/replacement; exclude recoverable metadata
  as well as media. Do not put the manifest in backed-up UserDefaults or synchronize
  it through iCloud. Existing pin policy remains separate.
- Use an opaque account scope and opaque file keys; never use media titles, origins,
  tokens or raw server/account IDs in paths. The manifest may contain the minimum
  provider IDs, title/artist/album, membership/order and artwork tag needed for offline
  browsing and reconciliation. Treat it as private account data. Do not persist
  authenticated request URLs/headers, credentials or raw errors.
- On iOS apply complete-until-first-authentication file protection to storage,
  including staged/replaced files, so established background playback remains usable
  after first unlock. On macOS keep storage inside the app sandbox with owner-only
  permissions. This is platform protection, not a claim of app-managed encryption
  or access before first unlock. Verify signed-platform behavior separately.
- Atomically publish completed validated files and manifest changes. Partial files
  never appear available. Cancel/failed transfers remove staging bytes or report
  cleanup failure. Relaunch inventories only this owned directory, reconciles stale
  staging/manifest state, and exposes usable complete files truthfully.
- Track retention by explicit tracks, albums and downloaded playlist membership;
  duplicate occurrences/order are distinct from a shared physical audio file. Remove
  files only at zero references, deferring deletion while the player uses the file.
  Cancel work before account cleanup and reject late completion across generations.
- Stop affected transfers on insufficient storage and expose explicit retry/removal.
  Do not silently evict retained audio to enforce a guessed quota. Account for actual
  audio, artwork and staging bytes in storage controls. No fixed artwork cache quota
  is needed while persistence is limited to retained downloads and counted there.
- Sign-out/account replacement removes owned media, manifest, artwork and staging
  only after the credential/account transition permits teardown. If Keychain removal
  fails, preserve the active account and data. If local deletion fails, report the
  residual cleanup honestly, preserve a retryable owned scope, and do not show old
  metadata in a new account. No server-library deletion is implied. Cleanup does
  not erase older backups, revoke server credentials by itself or prove secure erase.

Wi-Fi-default transfers with cellular opt-in and launch/foreground/restored-connectivity
playlist reconciliation are the owner-approved #13 contract. Use no continuous polling
or offline server mutations. Server refresh failure must preserve the last usable local
snapshot and shared retention. #14 adds no offline audio, manifest or download controls.

## Acceptance limits

Focused synthetic tests cover bounded decode, current-result reuse, stale selection/
account rejection and optional failure behavior. Lint/preflight/build results belong
to the exact candidate handoff, not this baseline observation. Physical offline
placeholder, signed file protection/backup exclusion, storage pressure and account
cleanup acceptance remain pending with #13's implemented storage and exact artifact.
An application cache eviction test is inapplicable until such a cache exists; no
historical cache behavior is claimed verified.
