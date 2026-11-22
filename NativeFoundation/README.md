# VelaCanto application source

This is the maintained iOS/macOS app for active **0.7.0** development. Read the
[current handoff](../docs/0.7.0-agent-handoff.md) for exact source, installed review,
verification, owner acceptance and remaining work. Local source is labeled
**0.7.0 (322)** for a separate review candidate; earlier build321 acceptance remains
scoped to its recorded checks. Implementation remains unpublished.
The [0.6 checkpoint](../docs/0.6.0-alpha-checkpoint.md) and older records remain
historical evidence for their own artifacts.

Open `VelacantoFoundation.xcodeproj`, scheme `VelacantoFoundation`. Use root
`scripts/build.sh` and the [agent handoff](../docs/0.7.0-agent-handoff.md) for
current verification commands. Follow [current native instructions](AGENTS.md).
Internal Foundation names, bundle identifiers, Keychain services and storage keys
are retained for compatibility. Release displays VelaCanto; local Alpha builds
retain their established suffix.

Playback uses the existing native AVPlayer and Jellyfin delivery path. Native
Handoff transfers queue, position and playback modes; browsing continuation is
separate when playback is inactive. Browser/other-client continuation remains a
separate uncompiled prototype outside this checkpoint. Detailed diagnostics and
synthetic fixtures remain DEBUG-only. Optional iCloud application-data sync is
off by default; do not introduce synchronized development/output paths.


## Normal simulator review

The unsigned simulator build is a compile gate. For live-server UI review, use the normal signed **Debug** app with its canonical bundle and Keychain identity.
Verify the unique available dedicated `VelaCanto Duo Test Sim` and set `DUO_UUID` to its current identifier; preserve its existing data before an in-place update.
From the repository root, build with `xcodebuild -project NativeFoundation/VelacantoFoundation.xcodeproj -scheme VelacantoFoundation -configuration Debug -destination "platform=iOS Simulator,id=$DUO_UUID" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build`.
Use no synthetic fixture launch arguments or private probe flags; normal authentication connects to the owner's approved live server.
Read back the exact built and installed identity, then verify the live UI and normal session restoration after relaunch; do not reset or clear the Keychain.
Debug explicitly leaves iCloud pin sync unavailable; this simulator workflow does not establish Production CloudKit acceptance.
The verified local build driver is retained under `release-evidence-20261121/install-324/Duo/build-debug-review.py` in the workspace evidence root.
The existing unsigned compile gate and physical-device signing settings remain separate from this UI-review workflow.


## Progressive catalog loading

Mobile and desktop catalog lists, collection tracks, related shelves, genre pages
and playlist pickers continue as their visible end is reached. Each footer
appearance or new end-of-scroll gesture admits one bounded page; publishing a new
cursor does not by itself restart loading. Empty or duplicate filtered pages keep
truthful coverage guidance and require another scroll demand rather than draining
a catalog. Assistive technology can use the footer's Continue browsing action.
Errors retain explicit Retry. Foreground, network, query/source and cancellation
checks remain in force, including after waiting for an existing request to settle.
Related shelves load at their horizontal tail; genre pages reveal cached items.
CarPlay retains its native finite-template More navigation because no supported
near-end scrolling callback has been established for that surface.

## Synthetic UI feature checks

`Tests/FoundationDownloadsUITests.swift` owns the stable XCTest class and the
existing shared fixture launch/cleanup, navigation and failure-capture helpers.
`Foundation{Search,SignIn,DownloadLifecycle,Queue,Playlists,Playback,Library,Home,Genres,Settings,Layout}UITests.swift`
extend that same class. Feature-only scenarios, observations and assertions stay
with their feature; existing domain helpers used by multiple features retain a
concrete owner rather than becoming a generic fixture framework. Every existing
`VelacantoDownloadsUITests/FoundationDownloadsUITests/test…` selector is retained.

`FoundationUITestScenario` is a test-only value with named Search, playlist Search,
Sign-in, Downloads and Queue presets. Its validation rejects mutually exclusive
catalog providers, contradictory account roots, unsupported state strings and
failure/hold options missing their prerequisite. Validation runs before launch;
argument/environment construction preserves the separate synthetic bundle and a
fresh UUID fixture root. Launch readiness, teardown cleanup and their original
assertions/deadlines remain in the shared owner. The app's DEBUG-only fixture
and Release exclusions are unchanged.

Use the existing `../scripts/test-downloads-ui.sh --list-smokes` and
`../scripts/test-downloads-ui.sh --smoke <name>` entrypoint. The script verifies
selectors against the actual UI target source membership, including extensions;
orphaned source files cannot silently authorize a selector. It still checks the
unique available dedicated `VelaCanto Duo Test Sim` and rejects destination,
signing, configuration and action overrides. The coordinator serializes runs.

| Selection | Affected flow |
| --- | --- |
| `search` | Bounded coverage, visible-end continuation and scoped playlist search |
| `downloads` | Waiting/cancellation/retry/removal and cold playback/removal |
| `signin` | Branding/errors, large text cancellation and delayed-response cancellation |
| `queue` | Occurrence actions, reordering and playback continuity |
| `playlist` | Native playlist occurrence reordering and queue continuity |
| `adaptive` | Player/queue accessibility layout and native artwork/swipe actions |

Run the affected named selection after changing its UI path or fixture, then the
applicable broader integration/package gates. Release validation must account for
all affected selections and wider acceptance; these small synthetic selections do
not replace full-suite, physical accessibility, audible playback or real-server
checks. Source organization/selector parity is static evidence. Compile and
runtime enumeration on the exact candidate must still confirm enabled selectors;
prior runs do not establish acceptance of a later extraction.
