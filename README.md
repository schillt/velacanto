# Velacanto

Velacanto is a native Jellyfin music app for iPhone, iPad and Mac. **0.4.0 is
in development on alpha**, with downloads, playlist management, queue restoration
and native platform refinements integrated at `488d0af` (build 124). Read the
[0.4 development and acceptance record](docs/0.4-development-record.md) for the
exact source, verification and remaining gates. TestFlight signing, upload,
processing and both-platform availability remain pending for this checkpoint.

The published [0.3.5 alpha prerelease](https://github.com/schillt/velacanto/releases/tag/0.3.5)
and its [historical acceptance record](docs/0.3.5-acceptance.md) retain their own
evidence. Earlier releases remain in Git history and tags.

The app is named **Velacanto**, bundle `com.chameleonenterprise.velacanto`.
Users upgrading from the original app may need to sign in again. No legacy
credential or queue-state migration is included.

## Current experience

Browse Home, New, Library and Search; play songs, albums and playlists; use
favorites, local pins, Play Next/Last, the queue and native seeking. Artist/album
pages include artwork, overviews and bounded server-supplied recommendations.
Jellyfin is the only implemented provider. The shared item/player interfaces keep
provider details inside the adapter without adding speculative provider systems.

Now Playing includes an inline queue, synchronized lyrics with line seeking and
idle follow, shared system artwork, Control Center/lock-screen commands, native
AirPlay selection and volume. Lyrics availability depends on the library.
iOS volume uses Apple's native control; Mac volume adjusts app playback gain.
Original-file track, album and playlist downloads use Wi-Fi defaults with explicit
cellular opt-in, progress/cancel/retry and account-owned storage controls. Downloaded
playlists reconcile on scoped lifecycle/edit triggers and preserve usable content
on refresh failure. Ready local files play through the same player.

Create, rename, delete and edit Jellyfin playlists, including song and album
additions. Up Next supports removal and native reordering; shuffle/repeat persist,
and relaunch restores the queue paused without a saved playback position. Favorites
loads Songs, Albums and Artists independently. Mac has persistent transport,
queue/lyrics sidebars and a shared native Settings window.

Playback reporting is not implemented; server history/play-count shelves may not
reflect listening in this app. Local-library indexing, server playlist reordering,
new providers and CarPlay remain deferred. Physical and server acceptance is still
tracked in the [0.4 record](docs/0.4-development-record.md); earlier known defects
are retained in the [0.3.5 history](docs/0.3.5-known-issues.md).

## Development

Open `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`. These internal names preserve tested source boundaries;
the built product is `Velacanto.app`. No legacy app target remains.

```sh
./scripts/preflight.sh --skip-xcode
./scripts/build.sh all
# For tests, first select an existing authorized OS 27 simulator:
# export VELACANTO_IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,id=<authorized-UUID>'
./scripts/build.sh pr
```

Modes: `lint`, `macos`, `test`, `ios-simulator`, `ios-simulator-test`, `release`.
Builds use per-worktree derived data. Set `VELACANTO_IOS_SIMULATOR_DESTINATION`
explicitly for an existing authorized test device and `VELACANTO_PACKAGES_PATH` for an existing package
checkout cache. The committed SwiftPM resolution is required. Current development
requires iOS/iPadOS 27 and macOS 27 for both app and tests, Debug and Release.
Use regular Xcode 27 or newer at `/Applications/Xcode.app/Contents/Developer`;
scripts honor an explicit `DEVELOPER_DIR` and never auto-select Xcode beta.
Preflight checks the selected Xcode and all three platform SDK versions. CI retains
the OS 27 Quality Gate and validates its existing simulator before testing; Xcode
26 is no longer a supported compatibility gate. The project is maintained directly
(no tracked generator). See the [platform decision update](docs/decisions/0013-rebuilt-03-release.md#035-development-platform-update).

The published 0.3.0 (108) minimums and historical acceptance remain unchanged.
The current integrated packaging identity is 0.4.0 (124); distribution must verify
that identity is available before upload.
Unsigned local/CI checks do not establish signed, physical or distribution
acceptance; signing/export and Apple processing remain tracked by issue #149.

The current lint run reports no new findings and zero retained build-106 findings.
`scripts/foundation-lint-baseline.txt` retains the historical baseline mechanism;
new findings fail and strict compiler/test gates still apply.

## Release and architecture

- [0.4 development and acceptance](docs/0.4-development-record.md)
- [0.4 execution plan](docs/0.4-plan.md)
- [Historical 0.3.5 acceptance and provenance](docs/0.3.5-acceptance.md)
- [Historical 0.3 acceptance](docs/0.3-acceptance-and-provenance.md)
- [Engineering history and investigations](docs/0.3-engineering-record.md)
- [Dependencies and notices](docs/0.3-dependencies.md)
- [Architecture](docs/architecture.md)
- [0.3.5 scope and remaining gates](docs/0.3.5-acceptance.md)
- [Historical 0.3 plan](docs/0.3-plan.md)
- [Agent instructions](AGENTS.md)

The 0.4 combined source is published to alpha. The prior accepted preview source
was promoted to main through PR #190; it excludes the newer 0.4 work. No 0.4 main
promotion or public App Store submission is implied. Freeze and verify an exact
candidate before release publication; record signed distribution separately.
Credentials, signing material and raw device traces never belong in the repository.

Publisher: Chameleon Enterprise Ltd. Velacanto is independent of Jellyfin and is
not affiliated with or endorsed by Jellyfin.
