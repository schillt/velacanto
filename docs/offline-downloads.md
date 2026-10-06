# Offline downloads — issue #13

This implementation retains original native-playable tracks, albums and playlists under one account-owned download store. The existing player prefers a complete local file; streaming remains the fallback when online browsing is available. Confirmed unavailable or restricted network paths preserve the familiar tabs, navigation and already-loaded pages, with brief inline guidance to Library where content is unavailable. Useful downloaded pages and playback surfaces keep their normal layouts. An offline cold launch may begin in Library. Remote catalog tasks and mutations are suspended; retained ready tracks remain playable in their original queue order. Path observations are advisory: a normal, explicit Retry Online request can restore browsing even when the observation is stale; a reachable network is not proof the server is reachable. Playback leases prevent removal while a file is installed or being resolved. Playlist occurrences/order are independent of shared physical track storage.

Transfers default to Wi-Fi (or wired networking) with explicit cellular opt-in. A finite sequential native transfer worker exposes progress, cancellation and explicit retry. It does not promise background completion or resume unsupported partial files. Failed/unsupported/incomplete files never appear available. Low storage stops the affected download with an actionable failure; retained files are not silently evicted.

Downloaded playlists refresh on launch, foreground, restored allowed connectivity and successful in-app edits. Refresh triggers coalesce; no continuous polling or offline server mutation occurs. A failed refresh preserves the last usable snapshot. Complete successful snapshots replace membership/order, enqueue additions and release removed references. Files remain until their final track/album/playlist owner and active player lease release them.

The opaque account directory in Application Support holds a versioned JSON manifest, opaque media filenames and staging files. It is backup-excluded; files/directories receive complete-until-first-authentication protection on iOS and owner-only permissions on macOS. The manifest retains only browsing/membership metadata and file size/hash records, never authenticated URLs, headers or credentials. Relaunch verifies size/hash, removes unusable entries and owned orphan/staging files, and truthfully marks incomplete owners. Account cleanup cancels work before deletion and exposes failures; Keychain failure must preserve the active account and downloaded data.

Downloads is the last destination under Your Music. It browses local Songs, Albums and Playlists without catalog expansion. Downloads reuse the existing song rows, album/playlist cover grids and detail headers. A solid down-arrow icon marks complete retention without visible Downloaded badge text; accessibility describes availability. Partial, pending and failed retention keep distinct state descriptions. Continue Listening, mini-player, Now Playing and destinations opened from Now Playing suppress these badges. Saved playlist occurrences remain visible when a song is deliberately removed, but only validated ready occurrences play. Downloaded Music in app Settings shows unique audio/artwork/other storage, collection footprints and batch selection with the bytes currently reclaimable. Collection footprints can overlap; active playback leases defer physical deletion.

Removing a song retained by a downloaded playlist requires Remove/Cancel confirmation. Confirmed song removal releases it from every local owner and records an account-scoped exclusion, preserving the server snapshot/order and duplicates. Saved playlists and explicit albums remain browsable even when no tracks are available, so Download Again stays reachable. Automatic reconciliation does not reacquire excluded songs. Explicit Download Again clears the relevant exclusions. Removing a collection alone releases only that owner, preserving shared files used elsewhere.

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
