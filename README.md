# Velacanto

Velacanto is an early-stage native music player for Apple platforms. It plays
device-local audio in place and is being built to stream from personal Jellyfin
and Navidrome libraries through source adapters.

> **Status:** Pre-alpha. The project is preparing its first functional
> prototype and is not ready for general use.

## Goal for 0.1.0

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

- [0.1.0 plan](docs/0.1-plan.md) — scope and acceptance criteria.
- [Roadmap](docs/roadmap.md) — ordered work and exit gates.
- [Architecture](docs/architecture.md) — component and runtime diagrams.
- [Decision records](docs/decisions/README.md) — durable technical choices.
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

Use `macos`, `test`, or `ios-simulator` instead of `all` to run one step. The
current interface has working local-file playback and a generated diagnostic
tone. Playback state is owned at the app level, publishes Now Playing metadata,
and accepts system play, pause, stop, toggle, and seek commands. Jellyfin
connectivity begins in the next delivery slice. The background path and Control
Center pause/resume controls have been verified on a sideloaded physical
iPhone.

Build output defaults to the ignored `DerivedData` directory. To keep generated
data outside the checkout, set `VELACANTO_DERIVED_DATA_PATH`:

```sh
VELACANTO_DERIVED_DATA_PATH=/private/tmp/velacanto-derived ./scripts/build.sh all
```

Check Swift formatting without changing files:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift-format lint --configuration .swift-format --strict \
  --recursive Velacanto VelacantoTests
```

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
