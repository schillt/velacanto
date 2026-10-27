# Current VelaCanto architecture

The maintained application is NativeFoundation, scheme VelacantoFoundation.
The v0.6 development round starts from the corrected v0.5 runtime; see the
[development record](0.6-development-record.md) for exact integrated commits and
acceptance limits. Internal Foundation names preserve project/storage identity.
The legacy app remains historical evidence, not a second maintained implementation.

## Existing owners and boundaries

| Owner | Responsibility | Boundary to preserve |
| --- | --- | --- |
| FoundationAppModel | Current authenticated account, account epoch, library/player/actions/downloads/connectivity/system-media construction, replacement and retirement | One active account runtime. Late account work cannot publish into its replacement. Pending Mac reauthentication and ordinary sign-out have deliberately different retention rules. |
| FoundationLibrary / FoundationJellyfinLibrary | Neutral items/references and catalog operations; official Jellyfin requests through native networking; supported media resource resolution | Jellyfin is the implemented provider. Opaque source/item identity and capabilities stay outside endpoint-specific adapter behavior; no speculative plugin framework. |
| FoundationNetworkAdmission and shared artwork/catalog caches | Bounded remote reads, reserved playback/Now Playing capacity, request coalescing/promotion, cache publication and account retirement | Cached work bypasses admission; only playback/Now Playing are privileged. Independent browsing sections publish without whole-page barriers. |
| FoundationPlayer | One AVPlayer/current item, playback intent, occurrence-based queue, modes, paused restoration and native command outcomes | Audio/activation/resource resolution never waits on optional artwork/catalog/persistence. Queue occurrence identity is distinct from track ID. No second player/recovery state machine. |
| FoundationLibraryActions | Pins/favorite projection, cancellable collection Play/queue expansion, explicit outcomes/retry and track visibility | Collection expansion is sequential/bounded and commits only complete results. Explicit Play is protected work; ordinary additions remain browsing. Screen owners cancel only their own operations. |
| FoundationDownloads / storage / converted-download transport | Account-owned manifests, verified Original/AAC files, retained artwork, collection reconciliation, shared retention, storage totals, playback leases and removal | One authoritative manifest owner. Disposable caches do not remove retained music; a playing file survives until its lease ends. No credentials/media URLs in manifests. |
| FoundationPlaybackPreferences / connectivity | Streaming Wi-Fi/cellular and download policy, existing path observations and per-resource policy snapshots | iOS selectors live in system Settings; Mac streaming is Original. Auto is a path-policy heuristic, not measured-bandwidth adaptation. |
| SwiftUI destinations and browse models | Retained page state, explicit task ownership, local navigation/presentation, cancellation and stale-result rejection | Views do not create players or perform catalog/artwork work on redraw. Shared visual components take narrow inputs; normal browsing and Now Playing sheet contexts remain intentional. |
| FoundationNowPlaying / current artwork / Siri / CarPlay | Account-lifetime system metadata/commands and native integrations through current playback/catalog owners | Optional system artwork stays recoverable and independent of audio. Basic native controls do not imply advanced Apple Intelligence or arbitrary casting. |
| FoundationCredentials | Nonsynchronizing Keychain session; Mac Data Protection store with stable signed access groups | No legacy Mac read/migration/deletion/fallback. Cleanup errors are explicit; no prompt-free guarantee across all OS/signing situations. |

The current feature set includes HLS streaming, quality choices, verified
Original/AAC offline downloads, playlist lifecycle/membership management, persistent
queue modes/restoration, synchronized lyrics, native AirPlay, Siri and CarPlay.
Bounded Jellyfin reporting is implemented; live-server history/session acceptance
is separate. Multi-account, local-folder indexing, additional providers, Handoff,
iCloud pin sync and native HLS offline assets are not implemented by a plan alone.

## Maintainability during v0.6

The [priority review](0.6-priority-review.md) ties cleanup to playlist, CarPlay,
loading, queue/lyrics and desktop scrolling work. FoundationTrackQueueSelection
now centralizes equivalent already-loaded online/offline occurrence projection;
it does not resolve audio, fetch collections or replace the player. New source
must be described by its actual integration record, not a future design claim.

Prefer a small pure rule or a narrow presentation component when responsibilities
repeat. Keep one existing mutable owner and explicit lifetime/cancellation. Split
test fixtures by feature after overlapping active edits land; do not use file-size
reduction as a reason to rewrite account/download/player ownership. Measure view
invalidation, allocations and scroll routing before declaring a jank cause.

Detailed FoundationJournal instrumentation and synthetic fixture injection remain
DEBUG-only, bounded and excluded from Release. User privacy/terms, app privacy
metadata, native encryption declarations and actual runtime data handling are
separate contracts. Follow [development acceptance](development-acceptance.md).

Read
[ADR 0012](decisions/0012-foundation-rebuild-and-playback-freeze.md),
[ADR 0013](decisions/0013-rebuilt-03-release.md),
[playback protection](playback-protection.md), [pin storage](pin-storage-privacy.md),
[queue storage](queue-storage-privacy.md), [sign-out privacy](sign-out-privacy.md),
[modern Mac credentials](mac-keychain-modernization.md) and
[dependencies](0.3-dependencies.md). Historical candidate-stage text retains its
original evidence; current source and later scoped acceptance supersede old exclusions.
