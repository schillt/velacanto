# Velacanto roadmap

## Current development target: 0.3.5

The released baseline is 0.3.0 (108), the native rebuild derived from Foundation 106.
Lyrics and active system controls were not delivered by that baseline. Historical
plans do not override the release notes or current GitHub issue contracts.

The [0.3.5 execution plan](0.3.5-execution-plan.md) sequences existing-player
correctness and background-network investigation, OS 27 toolchain/session work,
NowPlaying text/commands, native volume, AirPlay and shared static artwork. Target
minimums are iOS/iPadOS 27 and macOS 27; project/CI alignment is issue #161, not a
completed claim. Each stage requires independent exact-candidate acceptance.
No calendar date is committed. Distribution and prior 0.3 acceptance gaps remain
tracked separately; preparing 0.3.5 does not close them.

## Release history

### 0.2.5 — stabilization candidate

Packages the physically accepted playback, network-admission, and session-
restoration repairs as an internal test build. It preserves queue/cursor state
through navigation, interruption, backgrounding, and relaunch while keeping
slow media-start performance and nonfunctional queue reordering visible as
follow-up work. See the [0.2.5 release notes](0.2.5-release-notes.md).

### 0.2.0 — complete

Separated presentation ownership, resolved the scoped macOS and artwork defects,
added Play/Shuffle entry points, and improved persistence diagnostics. Historical
scope and release notes are retained in [`archive/0.2`](archive/0.2/README.md).

### 0.1.0 — complete

Established secure Jellyfin connection, browsing/search, local and Jellyfin
playback, background audio, system controls, native iPhone/Mac surfaces, and the
repeatable quality gate. Historical plans and evidence are retained in
[`archive/0.1`](archive/0.1/README.md).

## Ordered later direction

### 0.4.0 — Optional metadata and broader resilience

After accepted 0.3.5: bounded optional lyrics and Jellyfin reporting, broader
streaming/codec/queue follow-ups, measured artwork/storage policy and offline
downloads. New optional features preserve the accepted playback and network
boundaries. No date is committed.

### 0.5.0 — CarPlay and Connected Playback

Managed-entitlement readiness, a shallow CarPlay browse and Now Playing surface,
and casting evaluation. No CarPlay implementation belongs in 0.3.

### 0.6.0 — Accounts, Metadata, and Provider Expansion

Multiple saved accounts, playlist creation/editing, richer credits and metadata,
advanced playback controls, and Navidrome/OpenSubsonic support.

### 0.7.0 — Quality at Scale

Large-library performance, broad accessibility/adaptive-layout completion,
playback transition polish, search tolerance, and maintainability follow-ups.

### 0.8.0–1.0.0 — Security and Public Release

Token-bearing URL elimination, session hardening, release-candidate stabilization,
paid signing, CI/distribution automation, support policy, and launch readiness.

Later milestones intentionally have no provisional due dates. They are scoped
from the accepted state of the previous release.
