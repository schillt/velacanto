# Offline downloads — issue #13

This implementation retains original native-playable tracks, albums and playlists under one account-owned download store. The existing player prefers a complete local file; streaming remains the fallback. Playback leases prevent removal while a file is installed or being resolved. Playlist occurrences/order are independent of shared physical track storage.

Transfers default to Wi-Fi (or wired networking) with explicit cellular opt-in. A finite sequential native transfer worker exposes progress, cancellation and explicit retry. It does not promise background completion or resume unsupported partial files. Failed/unsupported/incomplete files never appear available. Low storage stops the affected download with an actionable failure; retained files are not silently evicted.

Downloaded playlists refresh on launch, foreground, restored allowed connectivity and successful in-app edits. Refresh triggers coalesce; no continuous polling or offline server mutation occurs. A failed refresh preserves the last usable snapshot. Complete successful snapshots replace membership/order, enqueue additions and release removed references. Files remain until their final track/album/playlist owner and active player lease release them.

The opaque account directory in Application Support holds a versioned JSON manifest, opaque media filenames and staging files. It is backup-excluded; files/directories receive complete-until-first-authentication protection on iOS and owner-only permissions on macOS. The manifest retains only browsing/membership metadata and file size/hash records, never authenticated URLs, headers or credentials. Relaunch verifies size/hash, removes unusable entries and owned orphan/staging files, and truthfully marks incomplete owners. Account cleanup cancels work before deletion and exposes failures; Keychain failure must preserve the active account and downloaded data.

Artwork is optional and is not persisted by this first download implementation. Offline artwork can remain a neutral placeholder. The existing current-artwork owner remains the sole shared owner; no cache, second downloader or prefetch is introduced. Storage totals include manifest/media/staging bytes.

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
real credential store is used. Fixture entry requires DEBUG, the simulator, the
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
