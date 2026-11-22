# Artwork and offline storage policy — issue #14

## Shared catalog artwork implementation — integrated development

Owner clarification on 2026-10-07 authorizes actual app-wide reuse, including artist,
playlist and genre consumers, on the local issue #13 build 116 source `2a41f533`.
The implementation and subsequent revision-key correction are now integrated in
alpha through `488d0af`. The original local handoff remains historical; physical
acceptance and #14 completion are separate. See the [0.4 record](0.4-development-record.md).

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
- Cache rendition buckets are 160, 640, 1280 and 2048 pixels. The current-player
  default remains 640; higher-resolution artist imagery is an explicit consumer
  request. A larger cached rendition serves smaller requests; a tile cannot satisfy
  a missing hero rendition. Tagged entries expire after 30 days;
  untagged entries after 24 hours. A changed tag has a new identity. Nil/failing reads
  are suppressed for 60 seconds in a bounded in-memory identity table; cancellation
  never installs a failure. No automatic retry, prefetch or metadata scanning.
- LRU memory retention counts encoded bytes plus decoded image row bytes, bounded
  to 16 MiB. Disposable account artwork under Caches is bounded to 64 MiB after each
  operation, with atomic writes and disk LRU eviction. This is a retained-cache
  bound, not peak process memory or write staging usage. SwiftUI/current/system
  image retention and native transport buffers are outside it.
- At most 4 shared fetch/decode workers run; pending distinct network-job keys are
  bounded to 128, with reserved playback capacity. Local preview read/decode jobs
  coalesce separately and have their own 128-key cap; four is not a global bound on
  every decode or retained view image. Consumers of the same identity/rendition share a job. One cancellation releases
  that consumer; the last cancels queued/native work. A cancelled native job holds
  its slot until it ends. Requests for distinct resolution upgrades can be separate.
- Decoding and serial disk I/O run off MainActor. Existing ImageIO validation rejects
  malformed/multi-image/over 2 MiB payloads and source dimensions beyond 2048 before
  image decoding/retention. Production URLSession buffers response data before this
  check, so 2 MiB is not a transfer or peak-allocation ceiling. Account invalidation
  cancels work, rejects late publication and disables late disk writes.
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
Explicit refresh and reconnect use the view's cancellable task lifetime. Catalog
activity also requires an active scene, so background audio does not keep periodic
shelf reads alive. Returning to the app preserves content and resumes visible work.
Offline
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


## v0.6 source audit and remaining acceptance — 2026-10-27

Reviewed exact integration `abd4da785420ef4611a213ac8fe35df74bbcfdb6` and live #14
with all three comments. The source audit establishes no new runtime defect. No
fresh unit, native, performance, server or device check was executed for this audit.
The policy corrections above describe existing behavior, not a cache replacement.

| Boundary | Current source and meaningful existing regression |
| --- | --- |
| Retained cost and rendition selection | `FoundationArtworkCache.swift:6–10,97–110,494–506`; `FoundationCurrentArtwork.swift:24–25,168–195`. Eviction, oversized-hero retention and explicit backdrop-resolution tests cover retained limits and default-player resolution. |
| Protected admission and coalescing | `FoundationArtworkCache.swift:275–338`, `FoundationLibrary.swift:2842–2949`. Actual adapter admission, promoted coalesced artwork, reserved worker and full pending-budget tests exist. |
| Publish before optional persistence | `FoundationArtworkCache.swift:390–486`; `testDecodedArtworkPublishesWhilePersistenceIsHeldAndRetirementRemovesIt` holds persistence at the real cache seam. |
| Offline/account retirement | `FoundationArtworkCache.swift:267–271,509–535,789–850`; cold-offline/account-isolation, delayed invalidation/no-resurrection and live-directory startup-cleanup tests exist. |
| Current and system artwork | `FoundationCurrentArtwork.swift:92–165,211–247`; delayed provider cancellation, changed selection/account and explicit missing-image recovery tests exercise the existing owner. |
| Independent browsing publication | `FoundationBrowseModel.swift:282–295`; `FoundationPresentationTests.testNewAlbumsCompleteWhileTracksStallAndCancelledTrackResultStaysUnpublished` exercises one section completing while another remains held. |

These are named regression seams, not a new passing-suite claim. Use the exact
candidate's existing evidence before deciding which affected suites need execution.
Keep the prior hosted artwork fixture failures and later unchanged-source
nonreproduction distinct; neither establishes a cause or justifies relaxed deadlines.

The 16 MiB value counts retained shared entries, including encoded data and decoded
row bytes. Pending persistence images, preview decoding, current/system artwork,
view-owned images and transport buffers contribute separately to process memory.
There is no claim of automatic memory-pressure purging or a measured process-wide
plateau. A missing pressure notification handler alone does not establish a defect.
The upcoming primary-genre index/cache work is separately reviewed under #211; its
additional catalog storage must not be inferred to fit the older 2 MiB page budget.
This audit changes no catalog-cache code or budget.

Perform the following in the coordinator's serialized lane on an exact signed,
installed candidate. Record platform, version/source, server version, network and
route, window/text size, foreground/background state, debugger/Mirroring state and
cache-generation preparation. Use a sanctioned fixture account/library where
request counts, controlled errors or cleanup need server access. Do not sign out
an unrecoverable real account or delete retained media to manufacture a cold cache.

1. **Cold and warm reuse.** Start a fresh sanctioned fixture scope or an already
   authorized disposable-cache reset. Visit one Home album, the matching Library
   song rows and its detail, then revisit the same surfaces. Record artwork GET
   counts by rendition/role and time to first useful content separately from final
   artwork. Compare identical tag/identity and elapsed freshness windows; a new
   image revision or a larger requested rendition is not an unexplained duplicate.
   Separate initial loading, warm memory reuse and cold-process disk reuse. An app
   update can invalidate disposable caches, so a newer build is not a warm baseline.
2. **Useful content and playback under browsing.** Start audible playback, open
   Home/New/Library/Search and scroll, then expand Now Playing, skip and seek.
   Observe that completed sections and retained images remain usable while a
   sanctioned slow/failed optional read is held. Record audible outcomes and
   action order; a progressing timer or artwork timing event does not prove audio.
   Check background/return and affected output routes. Browsing screens have equal
   admission; do not label a particular screen faster by granting it priority.
3. **Offline and recovery.** Warm selected artwork, end the process, disable the
   fixture's network and relaunch the same build. Revisit warmed and never-warmed
   items; verify retained artwork or deterministic placeholders without remote
   requests. Reconnect and exercise the existing explicit retry/Now Playing-open
   recovery boundary. A usable same-identity preview must survive an optional
   upgrade failure; changed identities must not show the old image.
4. **Pressure and storage accounting.** With a repeatable bounded browsing sequence,
   record cache-retained cost, recognized artwork disk bytes and process memory
   separately at the same checkpoints. Existing Cached Media measurements wait for
   pending persistence and are not peak-process memory. Use controlled fixtures to
   exceed test quotas; do not fill the owner's disk or purge unknown files. Reuse
   the existing eviction/retained-download tests for synthetic pressure. If device
   profiling shows growth, capture the responsible retained owners before changing
   worker budgets or adding a pressure-purge mechanism.
5. **Account and failure boundaries.** On recoverable sanctioned accounts, verify
   failed credential removal preserves the active account/data; successful sign-out
   retires cached/current/system results and does not expose them after another
   account opens. Verify cleanup failures remain explicit. Preserve the pending
   reauthentication quarantine, legacy-Keychain prohibition and retained-download
   ownership contract. No old backups, server-token revocation or secure erasure
   is established by deleting a local cache directory.
6. **Signed storage and accessibility.** Verify directory/file protection and backup
   exclusion on signed physical artifacts after creation and replacement. Record
   locked-after-first-unlock/background behavior separately; Simulator assertions
   do not prove device protection or actual backup exclusion. Check Light/Dark,
   increased text size/contrast, reduced motion/transparency and VoiceOver for the
   touched artwork/placeholder/status surfaces. Do not infer accessibility from a
   cached-image test or one normal-size screenshot.

Existing DEBUG `FoundationLoadTiming` milestones can distinguish cache read,
request, decode, publication and persistence durations when the coordinator chooses
a bounded diagnostic capture. They do not directly measure first meaningful text,
scroll smoothness or audibility. Keep raw traces and account/media mappings private.
Shared evidence uses aliases, aggregate request-kind/rendition counts, durations,
byte deltas and per-row pass/fail/pending. Exclude titles, origins, paths,
credentials/headers, stable account/item IDs and raw request bodies.

#14 remains open until the current physical/performance/account/accessibility and
signed protection/backup criteria are accepted. This packet performs no cleanup,
new instrumentation, native run, policy activation, publication or distribution.
