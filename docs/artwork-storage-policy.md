# Artwork and offline storage policy — issue #14

## Shared catalog artwork implementation — local candidate

Owner clarification on 2026-10-07 authorizes actual app-wide reuse, including artist,
playlist and genre consumers, on the local issue #13 build 116 source `2a41f533`.
This does not claim publication, integration, physical acceptance or #14 completion.

The account-owned `FoundationArtworkCache` shares visible catalog and current-player
reads through the existing provider. Track artwork projects supplied album references;
Home album tiles and Library track rows share kind/ID/tag/rendition without metadata
lookups. Artists share their own Primary identity. New's genre cards intentionally
use a representative recent album ID/tag; Search/Library genre cards use genre Primary
ID/tag. These images use one loading pipeline but are not falsely aliased. The account
avatar uses a distinct internal namespace within the same cache; profile metadata
still uses its existing provider read.

- Scope is a digest of the existing server/account scope. Disk names are opaque
  SHA256 keys; no titles, origins, credentials or request URLs are stored.
- Renditions are 160 and 640 pixels. A larger cached rendition serves smaller requests;
  a tile cannot satisfy a missing hero rendition. Tagged entries expire after 30 days;
  untagged entries after 24 hours. A changed tag has a new identity. Nil/failing reads
  are suppressed for 60 seconds in a bounded in-memory identity table; cancellation
  never installs a failure. No automatic retry, prefetch or metadata scanning.
- LRU memory retention counts encoded bytes plus decoded image row bytes, bounded
  to 16 MiB. Disposable account artwork under Caches is bounded to 64 MiB after each
  operation, with atomic writes and disk LRU eviction. This is a retained-cache
  bound, not peak process memory or write staging usage. SwiftUI/current/system
  image retention and native transport buffers are outside it.
- At most 4 shared image fetch/decode jobs run; pending distinct keys are bounded to 128.
  Consumers of the same identity/rendition share a job. One cancellation releases
  that consumer; the last cancels queued/native work. A cancelled native job holds
  its slot until it ends. Requests for distinct resolution upgrades can be separate.
- Decoding and serial disk I/O run off MainActor. Existing ImageIO validation rejects
  malformed/multi-image/over 2 MiB payloads and source dimensions beyond 2048. Account
  invalidation cancels work, rejects late publication and disables late disk writes.
- Cache roots are backup-excluded. Files use complete-until-first-authentication
  protection on iOS; account directories are owner-only on Mac. Signed physical
  protection/backup behavior remains an acceptance gate.
- Startup/sign-in remove retired disposable account scopes, retaining live directory
  leases. Successful account transition/sign-out retires the cache after credential
  removal succeeds. Cleanup failure remains visible. No credentials are read by
  the cache, and inaccessible saved credentials do not trigger new cache cleanup.

## Retained downloads and offline behavior

Download-owned artwork remains local-first and has its own manifest/reference lifetime.
It may preserve an older valid tag after failed refresh. Those bytes are not recorded
under a new disposable-cache revision. Disposable eviction/cleanup never removes
retained music/artwork. Download artwork transfers retain their existing Wi-Fi/cellular
policy and separate explicit owner; no cache prefetch or second download owner.

Recreated catalog/current-player views can use memory/disk hits offline. A miss uses
its existing deterministic neutral placeholder. Offline readers do not join pending
remote work. Reconnect permits normal visible reads; nil/failure suppression bounds
repeat navigation. Artwork success/failure does not resolve audio, mutate queue state,
activate audio sessions or change native URLSession configuration. The current-player
owner continues sharing its single result with system providers; it may decode cached
encoded bytes separately from the catalog result off-main.

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

Exact local checks and request counts are recorded in the candidate handoff. Synthetic
cases cover album-to-track reuse, artist/playlist/genre identity, concurrent coalescing,
resolution upgrade, memory/disk bounds, eviction, cancellation, changed revisions,
untagged expiry, malformed records, cold offline restore, live-account cleanup and
current-owner queue/intent preservation. Native UI exercises actual shared catalog
components through Home/Library routes with aggregate synthetic fetch counts.

These tests do not prove real-server performance, physical audibility/background routes,
VoiceOver, signed protection or secure erasure. No live account/session was modified.
Existing native audio failures must be compared with the unchanged baseline, and a
failed full suite must remain reported separately from passing focused tests.

## Local continuity refinements — 2026-10-07

The owner additionally authorized local update invalidation, persisted Home/New/genre
shelves, canonical artwork continuity and shared-item transition groundwork. This
extends the unpublished `00b4b931` candidate; it does not update the GitHub contract,
claim integration or authorize installation/publication.

Before opening account cache owners, startup compares app version/build plus cache
schema with a disposable generation marker. A mismatch (including first use of this
policy) removes only `Caches/VelacantoArtwork` and `Caches/VelacantoCatalogPages`.
Downloaded music, download-owned artwork, manifests, pins and playback sessions
remain outside these roots. Cleanup failure prevents opening stale caches and offers
an explicit retry; the marker is written only after successful removal.

Catalog page snapshots retain private titles, provider references and minimal item
metadata under opaque account/server scopes and page filenames. This metadata is
private local cache content, not anonymized merely because paths are digests. The
cache is bounded to 2 MiB, 32 pages, 200 items per page and 256 KiB per record, with
seven-day retention, atomic replacement, backup exclusion and platform protection.
Account teardown revokes writes and releases directory leases before removal. No
credentials, request URLs or request headers are encoded. Visible Home/New/genre
models restore local data before network work, preserve shelves through refresh,
refresh at most once per minute automatically and stop that loop after an error.
Explicit refresh and reconnect use the view's cancellable task lifetime. Offline
reads make no catalog requests; existing download eligibility still controls offline
playback and collection visibility. A cached page does not claim audio availability.

A bounded artwork revision index allows omitted image tags to reuse a previously
observed explicit revision without a metadata fetch. Explicit tags retain separate
keys; known tags accompany resolution upgrades. A local smaller rendition appears
while the visible consumer owns the larger request. Cancellation or optional failure
preserves the usable image for the same identity. System artwork identity remains
stable; each displayed result has a separate publication revision so upgrades update
SwiftUI. The native player presentation uses canonical kind/item identity and respects
Reduce Motion. This groundwork adds no custom animation or playback authority.

Synthetic tests establish local cache/update/cancellation behavior and request counts.
Native simulator flows and local builds establish only their recorded scope. Real-server
contention, physical audibility/background routes, VoiceOver and signed storage/backup
verification remain separate acceptance gates. Build 117 and its phone data remain
unchanged by this local refinement task.
