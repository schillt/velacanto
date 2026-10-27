# VelaCanto application source

This is the maintained iOS/macOS app for active 0.6 development. Read the
[current checkpoint](../docs/0.6.0-alpha-checkpoint.md) for exact source, build,
verification and installation status. The current local signed/installed checkpoint
is0.6.0(233); the [issue matrix](../docs/0.6.0-issue-status.md) records remaining work. Historical 0.3/0.5 documents describe their own builds.

Open `VelacantoFoundation.xcodeproj`, scheme `VelacantoFoundation`. Use root
`scripts/build.sh` and the [agent handoff](../docs/0.6.0-agent-handoff.md) for
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
