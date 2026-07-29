# Velacanto

Velacanto is an early-stage native music player for Apple platforms. It streams
music from a user's personal Jellyfin library.

> **Status:** Pre-alpha. The project is preparing its first functional
> prototype and is not ready for general use.

## Goal for 0.1.0

The first milestone will let a user:

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

The Xcode project and application source will be added during the project
foundation milestone.

## Project identity

- Publisher: Chameleon Enterprise Ltd
- Bundle identifier: `com.chameleonenterprise.velacanto`
- Primary language: English

Velacanto is an independent project and is not affiliated with or endorsed by
Jellyfin.
