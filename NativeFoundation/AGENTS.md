# Velacanto rebuilt-app contract

Read root AGENTS.md, ADR 0012 and ADR 0013. This directory is the sole maintained
application; the legacy app code/targets are removed. Internal Foundation names
remain implementation names, not a separate product or authorization to restore
old controllers. Use the exact assigned base; never edit another worktree.

## Release boundary

0.3.5 builds on the accepted 0.3.0 (108) Foundation replacement. The historical
0.3.0 freeze remains documented in ADR 0013; it does not disable the independently
implemented 0.3.5 features. Build 107 remains rejected. Read
`docs/0.3.5-release-notes.md`, `docs/0.3.5-known-issues.md` and
`docs/0.3.5-acceptance.md` for current scope and evidence limits. Never restore
legacy controllers or change playback/network ownership during cosmetic cleanup.

## Product

Jellyfin is the implemented provider. Use neutral catalog items and existing
adapter APIs; no speculative provider framework. Preserve occurrence identity
and explicit cancellable collection expansion. Retained loaded/empty destination
models avoid reloading; work follows live ownership. Native URLSession bounds
remain. No automatic retry, session retirement, cooldown, health checker, player
replacement layer, prefetch scans or new transport without demonstrated need.

Now Playing system controls, shared artwork, native AirPlay, synchronized lyrics,
inline queue and native iOS volume are implemented. macOS volume is existing-player
gain. The player owns playback intent and native items; the account-lifetime system
bridge forwards commands and metadata. Views must not create players, activate the
audio session, restore system volume or trigger catalog/artwork work on redraw.
Lyrics and artwork retain explicit cancellation and stale-result protection.
Collection Shuffle is supported; persistent shuffle/repeat, playlist editing,
offline/local libraries, new providers and playback reporting are not.

## Verification and delivery

Root scripts/build.sh targets this project and its current test suite. Compiler
warnings are errors. Existing 106 formatting debt is baselined only to preserve
the accepted source; do not add findings or expand that baseline. Run focused
checks for development and combined iOS/macOS/Release gates for integration.
Use serial Xcode slots and the existing retained simulators. Do not overwrite the
original-reference Simulator or build 106 physical comparison without instruction.

Workers commit only their assigned paths and proactively report exact base,
parent/final SHA, clean status, changed paths, deletions, commands/results and
limitations. The workspace maintainer publishes focused task PRs into alpha; acceptance and
audit review precede authorized serial merges. Root AGENTS.md governs PRs,
protected-branch policy and tagged release promotion to main. Do not use the
historical direct-push or alpha/beta/preview branch chain.
Passing synthetic tests is not physical streaming or TestFlight acceptance.

## Identity and privacy

Product Velacanto; bundle com.chameleonenterprise.velacanto. Keep the rebuilt
Keychain format/protections; fresh sign-in is allowed, no legacy migration.
Detailed diagnostics/test injection are internal DEBUG-only. Never log server
origins, credentials, headers, media names or account/item IDs. Retain original
signed build archives and sanitized aggregate findings; raw traces stay local.
