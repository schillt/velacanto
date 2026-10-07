# Offline downloads — issue #13

This implementation retains original native-playable tracks, albums and playlists under one account-owned download store. The existing player prefers a complete local file; streaming remains the fallback when online browsing is available. Confirmed unavailable or restricted network paths preserve the familiar tabs, navigation and already-loaded pages, with brief inline guidance to Library where content is unavailable. Useful downloaded pages and playback surfaces keep their normal layouts. An offline cold launch may begin in Library. Remote catalog tasks and mutations are suspended; retained ready tracks remain playable in their original queue order. Path observations are advisory: a normal, explicit Retry Online request can restore browsing even when the observation is stale; a reachable network is not proof the server is reachable. Playback leases prevent removal while a file is installed or being resolved. Playlist occurrences/order are independent of shared physical track storage.

Transfers default to Wi-Fi (or wired networking) with explicit cellular opt-in. A finite sequential native transfer worker exposes progress, cancellation and explicit retry. It does not promise background completion or resume unsupported partial files. Failed/unsupported/incomplete files never appear available. Low storage stops the affected download with an actionable failure; retained files are not silently evicted.

Downloaded playlists refresh on launch, foreground, restored allowed connectivity and successful in-app edits. Refresh triggers coalesce; no continuous polling or offline server mutation occurs. A failed refresh preserves the last usable snapshot. Complete successful snapshots replace membership/order, enqueue additions and release removed references. Files remain until their final track/album/playlist owner and active player lease release them.

The opaque account directory in Application Support holds a versioned JSON manifest, opaque media filenames and staging files. It is backup-excluded; files/directories receive complete-until-first-authentication protection on iOS and owner-only permissions on macOS. The manifest retains bounded browsing/membership metadata, download policy/intent and file size/hash records, never authenticated URLs, headers or credentials. Relaunch verifies size/hash, removes unusable entries and owned orphan/staging files, and truthfully marks incomplete owners. Account cleanup cancels work before deletion and exposes failures; Keychain failure must preserve the active account and downloaded data.

Downloads remains the last Library destination under Your Music. Its Songs, Albums and Playlists are local filters that open the same canonical content destinations as the normal catalog. An account-owned collection model preserves known membership, order and duplicates across both entry points. Online detail refresh uses the normal catalog; offline detail retains every known occurrence, with unavailable songs faded, disabled and described as unavailable to accessibility. A derived album subset is not treated as a complete server snapshot. Previously unknown membership requires connectivity; no general offline library scan or new artist/genre metadata persistence is added.

Availability is an inline native icon: `arrow.down.circle.fill` for complete retention and `arrow.down.circle.dotted` for partial retention. Collection icons sit beside the title; song icons sit immediately left of the ellipsis. Counts and state descriptions are accessibility values, without saved-count prose or an extra badge row. Songs has no additional Play All action; collection Play and Shuffle retain their normal behavior. Continue Listening, mini-player and Now Playing suppress badges. A thin persistent Browsing offline strip sits above the browsing shell, disappears online and preserves the current navigation. Page-specific recovery guidance remains available where local content is absent. Offline catalog and Home cover cards without ready local tracks are hidden.

Downloaded Music in app Settings shows unique audio/artwork/other storage, collection footprints and batch selection with the bytes currently reclaimable. Collection footprints can overlap; active playback leases defer physical deletion. The system Settings link has its own Playback & Downloads section; duplicate quality summaries are omitted.

The collection header places Download or Remove Downloads beside the ellipsis. Playlist Edit lives inside the action menu. Pending or failed owners expose Cancel Download and Retry Download there. Remove Downloads remains available while local bytes or explicit saved intent exist, including partial and excluded collections. Removing a song retained by a downloaded playlist requires Remove/Cancel confirmation. Confirmed song removal releases it from every local owner and records an account-scoped exclusion, preserving known order and duplicates. Automatic reconciliation does not reacquire excluded songs. Removing an explicitly owned collection releases only that owner, preserving shared files used elsewhere. Removing an unowned collection's shared songs uses the same exclusion and playlist-warning rules as song removal. Once retention is removed, Download can explicitly acquire the collection again. A collection already open remains browsable even with no ready tracks; offline cover grids hide it until ready local content exists.

An explicit collection Download persists a bounded reacquisition intent until its full membership expansion succeeds, including across a queued cold relaunch. Only successful complete expansion clears the fetched members' exclusions; failure preserves the last snapshot and retryable intent. Ordinary download/reconciliation keeps deliberate exclusions. A later song removal cancels pending reacquisition so the newer removal wins. Previously retained active playback files are size/hash verified and reused rather than replaced. The optional owner intent is absent/false in older version-two manifests; no catalog metadata or version migration is introduced.

Optional artwork is retained only for downloaded collection/album identities: one validated rendition up to 640 pixels, with bounded decoding and shared album references. Audio succeeds when optional artwork fails; a failed changed-tag read preserves the previous validated image. Last-reference removal and account cleanup release retained art. Local art feeds catalog presentation and the existing sole current-artwork owner; this is not a general catalog cache or prefetch scan. Storage totals include manifest/media/artwork/staging bytes.

Streaming and Downloads have independent cellular preferences. Defaults preserve cellular streaming while downloads require Wi-Fi or wired connectivity. Supported scalar controls appear in iOS system Settings and the app's Mac Settings; detailed inventory and removal stay in the app. Downloads retain Original quality. Streaming keeps the existing native/direct and AAC fallback behavior. Quality descriptions are read-only until additional supported presets are verified. HLS downloads/conversion remain deferred. A streaming-policy change detaches an already installed remote asset; explicit Play builds it with the new policy. Pending and installed local playback are preserved; no automatic restart or saved-position promise is added.

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
