# Velacanto

Velacanto is a native Jellyfin music app for iPhone, iPad and Mac. **0.3.5 alpha prerelease**
restores system controls, lyrics, AirPlay and volume while improving playback and
Now Playing presentation. It follows the 0.3.0 Foundation replacement; earlier
releases remain in Git history and tags. Publication and distribution status are
recorded separately in the [release acceptance record](docs/0.3.5-acceptance.md).

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
Playback reporting is not implemented; server history/play-count shelves may not
reflect listening in this app. Offline/local libraries, playlist editing,
persistent shuffle/repeat and CarPlay are deferred. Collection Shuffle exists.
See [release notes](docs/0.3.5-release-notes.md) and [known issues](docs/0.3.5-known-issues.md), including the accepted volume-jump defect.

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
The 0.3.5 packaging candidate uses build 109; distribution must verify that identity is available before upload.
Unsigned local/CI checks do not establish signed, physical or distribution
acceptance; signing/export and Apple processing remain tracked by issue #149.

Existing 106 formatting findings are explicitly baselined in
`scripts/foundation-lint-baseline.txt` to avoid mixing historical formatting cleanup with functional changes. New findings fail; strict compiler/test gates still apply.
Remove this formatting debt separately after release.

## Release and architecture

- [0.3.5 acceptance and provenance](docs/0.3.5-acceptance.md)
- [Historical 0.3 acceptance](docs/0.3-acceptance-and-provenance.md)
- [Engineering history and investigations](docs/0.3-engineering-record.md)
- [Dependencies and notices](docs/0.3-dependencies.md)
- [Architecture](docs/architecture.md)
- [0.3.5 scope and remaining gates](docs/0.3.5-acceptance.md)
- [Historical 0.3 plan](docs/0.3-plan.md)
- [Agent instructions](AGENTS.md)

The owner authorized PR #174 into alpha after passing checks, a 0.3.5 GitHub
prerelease from alpha and internal TestFlight through the existing Xcode Cloud
workflow, with the documented known defects. Main promotion and public App Store
submission are not authorized.
Publication still requires recorded candidate checks and signed distribution verification. Credentials,
signing material and raw device traces never belong in the repository.

Publisher: Chameleon Enterprise Ltd. Velacanto is independent of Jellyfin and is
not affiliated with or endorsed by Jellyfin.
