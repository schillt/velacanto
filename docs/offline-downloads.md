# Offline downloads — issue #13

This implementation retains Original or verified AAC tracks, albums and playlists under one account-owned download store. Download quality is independent of streaming quality and is captured when a download owner is created. The existing player prefers a complete local file; streaming remains the fallback when online browsing is available. Confirmed unavailable or restricted network paths preserve the familiar tabs, navigation and already-loaded pages, with brief inline guidance to Library where content is unavailable. Useful downloaded pages and playback surfaces keep their normal layouts. An offline cold launch may begin in Library. Remote catalog tasks and mutations are suspended; retained ready tracks remain playable in their original queue order. Path observations are advisory: a normal, explicit Retry Online request can restore browsing even when the observation is stale; a reachable network is not proof the server is reachable. Playback leases prevent removal while a file is installed or being resolved. Playlist occurrences/order are independent of shared physical track storage.

Transfers default to Wi-Fi (or wired networking) with explicit cellular opt-in. A finite sequential native transfer worker exposes progress, cancellation and explicit retry. It does not promise background completion or resume unsupported partial files. Failed/unsupported/incomplete files never appear available. Low storage stops the affected download with an actionable failure; retained files are not silently evicted.

Original transfers are bounded by their advertised original size and sampled free
space on the temporary and destination filesystems, leaving a 256 MiB reserve.
Converted AAC uses its duration/bitrate-derived receive ceiling and validates the
complete output, including format, timing, duration and digest, before publication. Native byte
callbacks cancel responses that exceed the receive budget, including responses
without a known length. Completed-file verification remains required before
publication. Callback timing permits limited overshoot, and sampled capacity is
not a reservation against unrelated applications writing concurrently.

Downloaded playlists refresh on launch, foreground, restored allowed connectivity and successful in-app edits. Refresh triggers coalesce; no continuous polling or offline server mutation occurs. A failed refresh preserves the last usable snapshot. Complete successful snapshots replace membership/order, enqueue additions and release removed references. Files remain until their final track/album/playlist owner and active player lease release them.

The opaque account directory in Application Support holds a versioned JSON manifest, opaque media filenames and staging files. It is backup-excluded; files/directories receive complete-until-first-authentication protection on iOS and owner-only permissions on macOS. The manifest retains bounded browsing/membership metadata, download policy/intent and file size/hash records, never authenticated URLs, headers or credentials. Relaunch verifies size/hash, removes unusable entries and owned orphan/staging files, and truthfully marks incomplete owners. Account cleanup cancels work before deletion and exposes failures; Keychain failure must preserve the active account and downloaded data.

Downloads remains the last Library destination under Your Music. Its Songs, Albums and Playlists are local filters that open the same canonical content destinations as the normal catalog. An account-owned collection model preserves known membership, order and duplicates across both entry points. Online detail refresh uses the normal catalog; offline detail retains every known occurrence, with unavailable songs faded, disabled and described as unavailable to accessibility. A derived album subset is not treated as a complete server snapshot. Previously unknown membership requires connectivity; no general offline library scan or new artist/genre metadata persistence is added.

Availability is an inline native icon: `arrow.down.circle.fill` for complete retention and `arrow.down.circle.dotted` for partial retention. Collection icons sit beside the title; song icons sit immediately left of the ellipsis. Counts and state descriptions are accessibility values, without saved-count prose or an extra badge row. Songs has no additional Play All action; collection Play and Shuffle retain their normal behavior. Continue Listening, mini-player and Now Playing suppress badges. A thin persistent Browsing offline strip sits above the browsing shell, disappears online and preserves the current navigation. Page-specific recovery guidance remains available where local content is absent. Offline catalog and Home cover cards without ready local tracks are hidden.

Downloaded Music in app Settings shows unique audio/artwork/other storage, collection footprints and batch selection with the bytes currently reclaimable. Collection footprints can overlap; active playback leases defer physical deletion. The system Settings link has its own Playback & Downloads section; duplicate quality summaries are omitted.

The collection header places Download or Remove Downloads beside the ellipsis. Playlist Edit lives inside the action menu. Pending or failed owners expose Cancel Download and Retry Download there. Remove Downloads remains available while local bytes or explicit saved intent exist, including partial and excluded collections. Removing a song retained by a downloaded playlist requires Remove/Cancel confirmation. Confirmed song removal releases it from every local owner and records an account-scoped exclusion, preserving known order and duplicates. Automatic reconciliation does not reacquire excluded songs. Removing an explicitly owned collection releases only that owner, preserving shared files used elsewhere. Removing an unowned collection's shared songs uses the same exclusion and playlist-warning rules as song removal. Once retention is removed, Download can explicitly acquire the collection again. A collection already open remains browsable even with no ready tracks; offline cover grids hide it until ready local content exists.

An explicit collection Download persists a bounded reacquisition intent until its full membership expansion succeeds, including across a queued cold relaunch. Only successful complete expansion clears the fetched members' exclusions; failure preserves the last snapshot and retryable intent. Ordinary download/reconciliation keeps deliberate exclusions. A later song removal cancels pending reacquisition so the newer removal wins. Previously retained active playback files are size/hash verified and reused rather than replaced. The optional owner intent is absent/false in older version-two manifests; no catalog metadata or version migration is introduced.

Optional artwork is retained only for downloaded collection/album identities: one validated rendition up to 640 pixels, with bounded decoding and shared album references. Audio succeeds when optional artwork fails; a failed changed-tag read preserves the previous validated image. Last-reference removal and account cleanup release retained art. Local art feeds catalog presentation and the existing sole current-artwork owner; this is not a general catalog cache or prefetch scan. Storage totals include manifest/media/artwork/staging bytes.

Streaming and Downloads have independent cellular preferences. Defaults preserve cellular streaming while downloads require Wi-Fi or wired connectivity. iOS system Settings owns the independent download selector: Original, High (320 kbps AAC), Standard (192 kbps AAC), or Data Saver (128 kbps AAC). Existing download owners retain their captured quality across retry, reconciliation and relaunch; verified ready files are reused rather than silently replaced when the preference changes. Mac streaming and default downloads remain Original; no new Mac download-quality selector is implied.

Detailed inventory and bulk removal currently remain in the in-app Profile settings. Moving storage management to iPhone system Settings is separate unfinished #208 work; neither a Settings.bundle preference nor this AAC conversion backend establishes a system-managed offline-HLS storage surface. General native offline-HLS shipping remains a separately gated #189 dependency. A streaming-policy change detaches an already installed remote asset; explicit Play builds it with the new policy. Pending and installed local playback are preserved; no automatic restart or saved-position promise is added.

Focused automated evidence belongs to the exact candidate handoff. Physical offline playback/seek, lock/background/routes, signed file protection/backup exclusion, actual storage pressure and sign-out/relaunch remain separate acceptance checks. Compiler/test success does not establish those outcomes or distribution availability.

## Repeatable simulator acceptance

Use the existing authorized iOS simulator and run:

```sh
VELACANTO_IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,id=<existing-simulator-id>' ./scripts/test-downloads-ui.sh
```

The dedicated `VelacantoDownloadsUI` scheme uses the `UITesting` configuration and
`com.chameleonenterprise.velacanto.uitesting`, preserving the installed production
app. It exercises the production download views, manager and native player with
injected synthetic playlist entries and generated PCM audio. No server request or
real credential store is used. The suite also covers preserved offline catalog navigation, shared layouts and accessibility-sized icon availability, playback-surface badge exclusions, duplicate saved playlist occurrences, batch song removal with playlist warning/Cancel, durable exclusions across relaunch, and storage management. Retained synthetic screenshot attachments support human review, without proving physical accessibility or playback. Fixture entry requires DEBUG, the simulator, the
isolated bundle identity and a UUID run identifier. Each test cleans only its own
fixture directory, including after failures; relaunch within a test retains it.
Release verification rejects fixture markers.

The ordinary feature suite can also run in this isolated app by selecting the
`VelacantoFoundation` scheme with `-configuration UITesting`. Use simulator signing
(`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) for the disposable Keychain CRUD
check. It uses a unique service and synthetic bytes, deleting the entry afterward;
it never reads the application's session. The historical simulator sign-in failure
was resolved by normal Xcode signing (see the archived UI-STEP-14 record), not by
weakening Keychain accessibility. The generic build script's unsigned default is
not evidence of successful live authentication.

Simulator tests do not establish physical Data Protection. The physical-iOS test
reports an explicit skip in Simulator, where protection attributes are unavailable;
backup-exclusion and persistence assertions still run. Live server acceptance also
requires a separately authorized QA account/session. Enter its credentials directly
in the app; never put them in test launch arguments, fixtures, logs or source.

The same isolated UI suite exercises the production sign-in form with a mocked
in-memory authenticator and synthetic field values, then repeats download/local
playback/sign-out cleanup twice. It covers rejected authentication, explicit retry,
cancelled authentication despite a late successful response, and a fresh form after
teardown. Password-save prompts are dismissed without saving the synthetic values.
The fixture never saves a session to Keychain or
contacts a server. These cases do not establish live password authentication,
server token revocation or real-account separation.


## Partial collection discovery and local search

Verified ready tracks make their known albums and artists discoverable offline.
Previously fetched playlist membership also makes a playlist discoverable when any
of its tracks is locally playable, regardless of which item initiated the download.
No catalog scan runs to find unknown playlist membership. Known collection pages
preserve ordering and repeated occurrences; unavailable tracks remain visible with
an explicit Not downloaded label and cannot start offline playback. An incomplete
page does not establish full server membership. A partial refresh preserves the last
complete saved membership until a complete replacement is available.

Discovery metadata is account/server scoped with the existing private download
manifest, limited to128 collections,10,000 total remembered track occurrences and
2MiB of encoded collection metadata. It does not retain audio or artwork, create
download owners or defeat shared-file removal/exclusions. Account cleanup removes
it. Existing manifests without optional artist/collection metadata remain readable;
unknown relationships require normal visible online browsing to become known.

Offline Search uses verified downloaded songs and known album/artist/playlist
projections containing downloads, matching titles and available related names.
Unavailable songs are shown in known collection previews rather than offered as
playable top-level song results. The existing query remains when returning online;
normal online search resumes. This is a search of saved local knowledge, not the
complete server catalog.

Download controls distinguish queued, preparing, waiting, active, partial and ready
states. A current track with measurable bytes shows circular determinate progress;
unknown-length transfers and active collections show indeterminate activity. No
aggregate collection percentage is inferred from equally weighted tracks.
Connection notices keep usable content visible. Explicit Retry rechecks the server
and refreshes active content even when the advisory path already reports available.

## v0.6 remaining acceptance — issue #13

Source audit base `255d59ddfeb6227ee0fa145866ffaa890979063a`, 2026-10-27.
The live issue and all three comments were reviewed. No new native or live-server
check was run for this audit. Existing regressions cover shared retention, player
leases, failed-refresh snapshots, cellular cancellation/retry, cold manifests,
late account results, explicit exclusions/reacquisition and quality intent. Those
fixtures do not establish physical results.

Owner acceptance from build212 remains scoped to Data Saver completion and audible
offline playback, plus Original completion while another song streamed. Do not
substitute those observations for High/Standard, all codecs, cancellation, routes,
storage pressure or current-candidate acceptance.

Use an exact installed candidate and sanctioned disposable playlist P with repeated
occurrences A/A/B and an album sharing A. Record platform/build/source, selected
preset, network/route, foreground/background, debugger/Mirroring and user-confirmed
audible outcome. Keep identifiers, titles, server origins and raw traces private.

1. On iPhone, independently download High and Standard under Wi-Fi, then disable
   both Wi-Fi and cellular. Cold-launch, open the retained collection, play, seek,
   advance and lock/background. Verify availability, occurrence order and audio.
   Include Original on Mac rather than inferring parity from the iPhone result.
2. With downloads cellular-disabled, confirm a queued request waits rather than
   starting. Explicitly enable cellular and confirm progress. Cancel a transfer,
   verify completed content survives, then explicitly retry. This is a download
   policy check; streaming has its own preference. Restore the original preference.
3. Download P, the shared album and an explicit A. Remove only P's download owner;
   A must remain available. Separately confirm song removal's playlist warning,
   cancel first, then confirm removal while A plays. Audio must continue until its
   existing lease ends; bytes become reclaimable after all references/leases end.
4. In disposable P, change order/membership through an app edit and an external
   server edit. Verify launch, foreground and restored allowed connectivity trigger
   bounded reconciliation, preserve duplicate occurrences/order, acquire additions
   and release only unreferenced removals. Repeat with offline/failed refresh: the
   last usable snapshot must survive. No continuous polling is expected.
5. Sign-out/account-replacement checks require recoverable sanctioned accounts and
   the coordinator's established cleanup procedure. Verify playback releases,
   download tasks retire, account data is removed only after successful cleanup,
   failures remain explicit and another account does not see the prior inventory.
   Do not read/migrate/delete legacy Keychain items.
6. Use synthetic fixtures for corruption, interrupted staging, receive ceilings and
   unwritable storage. Do not fill the owner's disk or corrupt retained real media
   to simulate pressure. Actual low-storage response and signed device protection/
   backup-exclusion remain separate pending checks if not safely exercised.

Delayed real-manager fixtures confirmed two stale reconciliation defects: an old
snapshot can replace membership and delete newly downloaded files after either
owner removal/recreation or a newer explicit Download Again. The first fixture
failed six assertions at `14419c4`; its narrow fix `3787a19` then passed Mac82 and
iOS84 cases (one existing physical Data Protection skip). The Download Again
variant at `8b83aad` still failed five assertions, so that broader intent lifetime
was not fixed by the first guard. Reviewed source `21d5981` uses one nonpersisted
reconciliation identity, initialized for a new owner and rotated only after a
successful explicit reacquisition save. Exact final candidate `a0805ca` passes
Mac84 cases and iOS86 cases (85 passed, one existing physical Data Protection skip),
with no failures. Both stale-result regressions pass, and a third real-store
fixture verifies that a failed newer Download Again save does not retire the valid
in-flight refresh. Tests cover manager/account/quality suites; they are not a full
application suite or physical acceptance. Private aggregate receipts are retained
in the workspace's `milestone-validation/release060-download-acceptance-13/`.
These fixtures use actual manager, retention and file-store seams, without proving
physical downloads, system Settings storage or exhaustive reconciliation behavior.
#13 stays open until remaining criteria and corrections are verified and accepted.
