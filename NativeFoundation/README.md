# Velacanto application source

This is the sole maintained app, replacing the legacy0.2.5 implementation.
The internal Foundation names are retained to avoid runtime refactoring during
release packaging. Product name: Velacanto. Bundle: com.chameleonenterprise.velacanto.
Version0.3.0, build 108; behavior baseline106.

Open VelacantoFoundation.xcodeproj, scheme VelacantoFoundation. Use the root
scripts/build.sh commands for the actual iOS/macOS build, test and Release gates.
See ../docs/0.3-release-notes.md, ../docs/0.3-engineering-record.md and
../docs/0.3-acceptance-and-provenance.md. Prior per-candidate notes are retained
under ../docs/archive/foundation-development and do not define current behavior.

Current playback is one native AVPlayer with Jellyfin universal direct-capable
audio delivery and server-selected conversion when required. Credentials use the
rebuilt Keychain format; old-app users may sign in again. Native networking,
player and credential runtime sources are unchanged from 106.107's media bridge
is excluded. Detailed diagnostics and synthetic launch mode remain DEBUG-only.
