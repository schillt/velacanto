# VelaCanto rebuilt-app contract

Read root AGENTS.md, ADR 0012 and ADR 0013. This directory is the sole maintained
application; the legacy app code/targets are removed. Internal Foundation names
remain implementation names, not a separate product or authorization to restore
old controllers. Use the exact assigned base; never edit another worktree.

## Release boundary

Current candidate is **0.5.0 (216), Alpha Preview**, packaging accepted build 215
runtime with release metadata changes. Read `docs/0.5.0-acceptance.md` and the
0.5.0 release/TestFlight notes before relying on historical scope exclusions.
Alpha publication, exact-candidate hosted checks, signed distribution, Apple
processing and tester availability must be recorded separately. Beta/main
promotion is not implied. Earlier 0.3/0.4 documents retain historical evidence;
build 107 remains rejected. Preserve accepted runtime during release preparation.

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
Collection Shuffle, persistent shuffle/repeat, paused queue restoration, playlist
management and account-owned Original/AAC downloads are implemented. Remote playback
uses HLS; native HLS offline assets remain unimplemented. iOS quality selectors
live in system Settings; Mac streaming is Original. Native CarPlay browsing,
playback and view-only queue selection are implemented; queue editing stays off
CarPlay. Basic Siri/system control support does not imply Apple Intelligence.
Bounded Jellyfin playback reporting is implemented; live-server acceptance remains
open. Local-library indexing and new providers remain deferred or unimplemented.
Keep implementation distinct from physical/server acceptance.

## Playback and shared loading guardrails

Read and follow [Playback and Now Playing protection](../docs/playback-protection.md).
Only playback and Now Playing are privileged. Explicit collection Play resolution
is playback work; queue additions and every browsing screen remain ordinary.
Keep AVPlayer/audio-session ownership independent of optional loading. Preserve
cached/independent publication and bounded parallel browsing.

Changes to shared artwork or catalog components must preserve reserved worker and
pending capacity, promotion of coalesced requests, detached-task intent, cancellation
cleanup and account retirement. Keep current artwork sharp during upgrades, reset
identity before resolution comparisons, and retain defined missing-image recovery.
Use existing player intent/state/pending activation to drive protection; do not
create another player or state machine. Test protected work against held and
saturated ordinary work through production seams, then complete affected physical
audio acceptance before claiming the runtime change accepted. Documentation-only
edits do not require new builds or device installs.

## Verification and delivery

Root scripts/build.sh targets this project and its current test suite. Compiler
warnings are errors. Existing 106 formatting debt is baselined only to preserve
the accepted source; do not add findings or expand that baseline. Run focused
checks for development and combined iOS/macOS/Release gates for integration.
Use serial Xcode slots and the existing retained simulators. Do not overwrite the
original-reference Simulator or build 106 physical comparison without instruction.

Workers commit only their assigned paths and proactively report exact base,
parent/final SHA, clean status, changed paths, deletions, commands/results and
limitations. The workspace maintainer integrates accepted local work and publishes
it to alpha without remote task branches. Acceptance and audit precede publication;
alpha → beta promotion uses a PR and the exact-candidate release gate. Root
AGENTS.md governs authorization, protected branches and subsequent main release
promotion. Never force-push or bypass actual GitHub rules.
Passing synthetic tests is not physical streaming or TestFlight acceptance.

## Identity and privacy

Product VelaCanto; completed alpha display name VelaCanto Alpha; bundle com.chameleonenterprise.velacanto. Keep the rebuilt
Keychain format/protections; fresh sign-in is allowed, no legacy migration.
Detailed diagnostics/test injection are internal DEBUG-only. Never log server
origins, credentials, headers, media names or account/item IDs. Retain original
signed build archives and sanitized aggregate findings; raw traces stay local.
