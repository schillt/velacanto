# Velacanto

Velacanto is an early-stage native music player for Apple platforms. It plays
device-local audio in place and streams from personal Jellyfin libraries. Its
shared music and playback boundaries are designed to support additional sources
and a future CarPlay surface without coupling those surfaces to Jellyfin.

> **Status:** Alpha. `0.2.0` is the current completed release. Development of
> `0.3.0`, the native-player foundation release, begins from that tag. The
> internal preview checkpoint is August 19, 2026; final release follows only
> after the acceptance gate passes.

## 0.3 direction

Version 0.3 completes the daily playback interface across iPhone, iPad, and Mac:

- provider-neutral catalog items and supported-action capabilities;
- synchronized favorite and unfavorite behavior;
- Play Next, Play Last, editable Up Next, shuffle, and repeat;
- artwork-led Home, library, search, and detail presentations using native
  SwiftUI components;
- adaptive Now Playing with playback-method visibility; and
- focused UI, accessibility, real-server, and physical-device validation.

Offline audio, playlist mutation, CarPlay implementation, gapless/crossfade,
new providers, and public distribution remain outside 0.3. CarPlay readiness in
this release means shared browse, action, queue, and playback contracts—not a
CarPlay target, entitlement, scene, or template.

## Project documentation

- [0.3 plan](docs/0.3-plan.md) — current scope, work packages, sequencing, and
  release boundaries.
- [0.3 acceptance](docs/0.3-stability-acceptance.md) — preview and final-release
  evidence matrix.
- [Roadmap](docs/roadmap.md) — current release and ordered later direction.
- [Architecture](docs/architecture.md) — component boundaries and runtime flow.
- [Native-player design](docs/design/README.md) — platform hierarchy, actions,
  states, and accessibility contract.
- [Decision records](docs/decisions/README.md) — durable technical choices.
- [Known issues](docs/known-issues.md) — current operational limitations.
- [Archive](docs/archive/README.md) — historical release plans, prototypes, and
  visualizations retained as evidence.

## Development

Run the pre-build check without Xcode:

```sh
./scripts/preflight.sh --skip-xcode
```

Build the macOS app, run the unit tests, and compile the iOS Simulator app:

```sh
./scripts/build.sh all
```

Run the stricter pull-request gate, including Release and static analysis:

```sh
./scripts/build.sh pr
```

Use `lint`, `macos`, `test`, `ios-simulator`, or `ios-simulator-test` instead
of `all` to run one step. Build output defaults to `VelacantoDerivedData` under
the system temporary directory.

The 0.2 baseline targets iOS 18 and macOS 15. ADR 0007 raises the 0.3 product
baseline to iOS/iPadOS 26 and macOS 26; the project deployment settings change
with the implementation work rather than this planning-only package.

### Jellyfin early access

Choose **Connect to Jellyfin**, enter the complete server address, connect, and
sign in with an existing account. Remote servers require HTTPS. Explicit HTTP
addresses are accepted only for loopback, private, link-local, `.local`, and
unqualified local-network hosts.

Velacanto pages through accessible libraries, albums, artists, songs,
playlists, and server-backed search results. Playback uses Jellyfin
`PlaybackInfo` negotiation, prefers a compatible direct path, and uses the
server-provided transcode fallback when required. The resolved media enters the
same app-lifetime player used for local files.

The access token is stored in a non-synchronizing Keychain item. Passwords are
never persisted, device identity remains stable across launches, and logout
removes the saved token and account-scoped cached content.

### Local playback

Choose **Open Audio File…** to play a file from its current URL. Velacanto does
not copy, import, upload, index, or persist a bookmark to that file. Access is
retained only while the selected item is active. **Play Test Tone** exercises
the same playback coordinator without personal media.

### 0.x deployment

Velacanto 0.x builds are local-development or sideloaded releases. App Store,
TestFlight, paid distribution, analytics, and release automation remain 1.0
work. Physical installs still require local Apple code signing.

## Project identity

- Publisher: Chameleon Enterprise Ltd
- Bundle identifier: `com.chameleonenterprise.velacanto`
- Primary language: English

Velacanto is an independent project and is not affiliated with or endorsed by
Jellyfin.
