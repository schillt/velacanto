# Velacanto

Velacanto is an early-stage native music player for Apple platforms. It plays
device-local audio in place and is being built to stream from personal Jellyfin
and Navidrome libraries through source adapters.

> **Status:** Alpha. Velacanto 0.1.0 is the completed baseline. Version 0.2 is
> a focused UI architecture and interface-quality release built from the tagged
> `main` state; see the [0.2 plan](docs/0.2-plan.md).

## Completed 0.1.0 goal

The first milestone will let a user:

- Open and play a local audio file without importing or copying it.
- Connect securely to a Jellyfin server.
- Sign in to an existing Jellyfin account.
- Browse the account's music library.
- Select and stream a track.
- Use basic playback and system media controls.

Velacanto is initially planned for iOS and macOS. CarPlay support will follow
after the core playback experience is proven.

## Project documentation

- [0.2 plan](docs/0.2-plan.md) — current scope, ownership guardrails, and
  release criteria.
- [0.1.0 plan](docs/0.1-plan.md) — scope and acceptance criteria.
- [0.1 stability acceptance](docs/0.1-stability-acceptance.md) — final
  device/server verification matrix.
- [Roadmap](docs/roadmap.md) — ordered work and exit gates.
- [Architecture](docs/architecture.md) — component and runtime diagrams.
- [Decision records](docs/decisions/README.md) — durable technical choices.
- [Foundational product design](docs/design/README.md) — approved iOS and macOS
  interface direction and interactive prototype.
- [Interactive architecture visualization](docs/visualizations/README.md) —
  standalone runtime and delivery-plan explorer.

## Development

Run the pre-build check without Xcode:

```sh
./scripts/preflight.sh --skip-xcode
```

Run the complete check after Xcode is installed:

```sh
./scripts/preflight.sh
```

Build the macOS app, run the foundation tests, and compile the iOS Simulator app
with the selected Xcode beta:

```sh
./scripts/build.sh all
```

Use `lint`, `macos`, `test`, `ios-simulator`, or `ios-simulator-test` instead
of `all` to run one step. To reproduce the pull-request quality gate (including
an iOS Simulator build, a Release build, and static analysis), use:

```sh
./scripts/build.sh pr
```

Local runs default to the installed Xcode beta and the iPhone Air simulator
running iOS 27.0. The GitHub Actions gate uses the hosted macOS 26 image,
Xcode 26.6, and the iPhone Air simulator running iOS 26.5. Set
`DEVELOPER_DIR` and `VELACANTO_IOS_SIMULATOR_DESTINATION` together to reproduce
the hosted gate locally when that Xcode/runtime pair is installed. The hosted
gate runs the platform-neutral unit suite on macOS and compiles the iOS app; its
iOS Simulator runtime test command remains available for local diagnostics.
Physical-device acceptance covers audio-session interruptions, routes,
background playback, and system-media controls. Seven audio-session and
system-command tests currently fail only in the iOS Simulator runtime suite;
their physical-device behavior passed the 0.1 acceptance review, so the
simulator results remain a documented diagnostic limitation rather than part of
the hosted gate. The current interface has working local-file playback and a
generated diagnostic tone, plus an early Jellyfin integration. Playback state
is owned at the app level, publishes Now Playing metadata and artwork, and
accepts system play, pause, previous, next, toggle, and seek commands. The
background path and Control Center pause/resume controls have been verified on
a sideloaded physical iPhone.

Build output defaults to `VelacantoDerivedData` under the system temporary
directory. Keeping build products outside a Documents folder managed by File
Provider prevents Finder metadata from being copied onto the macOS app and
rejected by code signing. To select another external location, set
`VELACANTO_DERIVED_DATA_PATH`:

```sh
VELACANTO_DERIVED_DATA_PATH=/private/tmp/velacanto-derived ./scripts/build.sh all
```

Check Swift formatting without changing files:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift-format lint --configuration .swift-format --strict \
  --recursive Velacanto VelacantoTests
```

### Jellyfin early access

Choose **Connect to Jellyfin**, enter the complete server address, connect, and
sign in with an existing Jellyfin account. Remote servers require HTTPS.
Explicit HTTP addresses are accepted only for loopback, private, link-local,
`.local`, and unqualified local-network hosts.

After sign-in, Velacanto pages through accessible music libraries, albums,
artists, songs, playlists, and server-backed search results with cached Jellyfin
artwork. Selecting a track negotiates a source and play session with Jellyfin,
uses direct play when the server confirms compatibility, and otherwise uses the
server's transcoding fallback. The resolved stream goes through the same
app-level player used for local files. The access token is stored in
Velacanto’s non-synchronizing Keychain entry, the password is never persisted,
the device identifier remains stable across launches, and logout removes the
saved token. Tokens saved by early pre-alpha preferences and private-file
implementations are migrated into Keychain when the session is restored.

The connection and session path is covered by unit tests and has been verified
against a real Jellyfin server on a physical iPhone, including relaunch and
logout. The paginated browser, shared artwork cache, two-item playback queue,
paused relaunch restoration, and system-media integration compile on both
platforms. The remaining device/server checks are listed in the
[0.1 stability acceptance matrix](docs/0.1-stability-acceptance.md).

### Local playback

Choose **Open Audio File…** to play a file directly from its current URL.
Velacanto does not copy, import, upload, index, or persist a bookmark to that
file. Access is retained only while the selected item is active. **Play Test
Tone** checks the same playback coordinator without using personal media.

### 0.x deployment

Velacanto 0.x builds are for local development and sideloading. The project
will not publish through the App Store or TestFlight before 1.0.

Physical iPhone and iPad installs still require Apple code signing. During 0.x,
contributors can use Xcode-managed signing with a free Apple Account
(`Personal Team`) where its provisioning limits are acceptable. Paid Apple
Developer Program enrollment, public distribution, and an App Store release
pipeline are deferred until the 1.0 milestone.

## Project identity

- Publisher: Chameleon Enterprise Ltd
- Bundle identifier: `com.chameleonenterprise.velacanto`
- Primary language: English

Velacanto is an independent project and is not affiliated with or endorsed by
Jellyfin.
