# Velacanto

Velacanto is a native Jellyfin music app for iPhone, iPad and Mac. Version **0.3.0**
is an alpha prerelease based on the accepted build 106 rebuild, replacing the
previous application implementation. Prior releases remain in Git history/tags.

The app is named **Velacanto**, bundle `com.chameleonenterprise.velacanto`.
Users upgrading from the original app may need to sign in again. No legacy
credential or queue-state migration is included.

## Current experience

Browse Home, New, Library and Search; play songs, albums and playlists; use
favorites, local pins, Play Next/Last, the queue and native seeking. Artist/album
pages include artwork, overviews and bounded server-supplied recommendations.
Jellyfin is the only implemented provider. The shared item/player interfaces keep
provider details inside the adapter without adding speculative provider systems.

Lyrics, in-app volume/AirPlay and app-provided system media controls are disabled.
Playback reporting is not implemented; server history/play-count shelves may not
reflect listening in this app. Offline/local libraries, playlist editing,
persistent shuffle/repeat and CarPlay are deferred. Collection Shuffle exists.
See [release notes](docs/0.3-release-notes.md) and [known issues](docs/0.3-known-issues.md).

## Development

Open `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`. These internal names preserve tested source boundaries;
the built product is `Velacanto.app`. No legacy app target remains.

```sh
./scripts/preflight.sh --skip-xcode
./scripts/build.sh all
./scripts/build.sh pr
```

Modes: `lint`, `macos`, `test`, `ios-simulator`, `ios-simulator-test`, `release`.
Builds use per-worktree derived data. Set `VELACANTO_IOS_SIMULATOR_DESTINATION`
for a dedicated test device and `VELACANTO_PACKAGES_PATH` for an existing package
checkout cache. The committed SwiftPM resolution is required. Current gates use
Xcode 27; declared deployment targets remain iOS 18/macOS 14 from 106. Those minimums
are not a claim of physical validation on every supported OS.

Existing 106 formatting findings are explicitly baselined in
`scripts/foundation-lint-baseline.txt` to preserve runtime sources byte-for-byte
for this checkpoint. New findings fail; strict compiler/test gates still apply.
Remove this formatting debt separately after release.

## Release and architecture

- [Acceptance and provenance](docs/0.3-acceptance-and-provenance.md)
- [Engineering history and investigations](docs/0.3-engineering-record.md)
- [Dependencies and notices](docs/0.3-dependencies.md)
- [Architecture](docs/architecture.md)
- [Current plan](docs/0.3-plan.md)
- [Agent instructions](AGENTS.md)

Approved 0.x builds may use internal TestFlight. This alpha prerelease does not
promote beta/preview/main or authorize public App Store submission. Credentials,
signing material and raw device traces never belong in the repository.

Publisher: Chameleon Enterprise Ltd. Velacanto is independent of Jellyfin and is
not affiliated with or endorsed by Jellyfin.
