# Offline downloads — issue #13

This implementation retains original native-playable tracks, albums and playlists under one account-owned download store. The existing player prefers a complete local file; streaming remains the fallback. Playback leases prevent removal while a file is installed or being resolved. Playlist occurrences/order are independent of shared physical track storage.

Transfers default to Wi-Fi (or wired networking) with explicit cellular opt-in. A finite sequential native transfer worker exposes progress, cancellation and explicit retry. It does not promise background completion or resume unsupported partial files. Failed/unsupported/incomplete files never appear available. Low storage stops the affected download with an actionable failure; retained files are not silently evicted.

Downloaded playlists refresh on launch, foreground, restored allowed connectivity and successful in-app edits. Refresh triggers coalesce; no continuous polling or offline server mutation occurs. A failed refresh preserves the last usable snapshot. Complete successful snapshots replace membership/order, enqueue additions and release removed references. Files remain until their final track/album/playlist owner and active player lease release them.

The opaque account directory in Application Support holds a versioned JSON manifest, opaque media filenames and staging files. It is backup-excluded; files/directories receive complete-until-first-authentication protection on iOS and owner-only permissions on macOS. The manifest retains only browsing/membership metadata and file size/hash records, never authenticated URLs, headers or credentials. Relaunch verifies size/hash, removes unusable entries and owned orphan/staging files, and truthfully marks incomplete owners. Account cleanup cancels work before deletion and exposes failures; Keychain failure must preserve the active account and downloaded data.

Artwork is optional and is not persisted by this first download implementation. Offline artwork can remain a neutral placeholder. The existing current-artwork owner remains the sole shared owner; no cache, second downloader or prefetch is introduced. Storage totals include manifest/media/staging bytes.

Focused automated evidence belongs to the exact candidate handoff. Physical offline playback/seek, lock/background/routes, signed file protection/backup exclusion, actual storage pressure and sign-out/relaunch remain separate acceptance checks. Compiler/test success does not establish those outcomes or distribution availability.
