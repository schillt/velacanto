# Velacanto roadmap

## Current development release: 0.3.0

0.3.0 is the **Native Player Foundation** release. It turns the proven 0.2
listening path into a coherent daily-use experience across iPhone, iPad, and
Mac while keeping catalog, actions, queue state, and playback presentation
usable by a future CarPlay surface.

The internal preview checkpoint is **August 19, 2026**. That date does not
override quality: the milestone remains open after preview, and final promotion
to `main` occurs only after every required acceptance row passes or records an
explicitly accepted limitation.

Required outcomes are maintained in the [0.3 plan](0.3-plan.md) and
[acceptance matrix](0.3-stability-acceptance.md).

## Release history

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

### 0.4.0 — Offline and Network Resilience

Offline downloads, storage controls, explicit artwork/offline policy, and
network-transition recovery. No date is committed.

### 0.5.0 — CarPlay and Connected Playback

Managed-entitlement readiness, a shallow CarPlay browse and Now Playing surface,
and casting evaluation. No CarPlay implementation belongs in 0.3.

### 0.6.0 — Accounts, Metadata, and Provider Expansion

Multiple saved accounts, playlist creation/editing, lyrics and richer metadata,
advanced playback controls, and Navidrome/OpenSubsonic support.

### 0.7.0 — Quality at Scale

Large-library performance, broad accessibility/adaptive-layout completion,
playback transition polish, search tolerance, and maintainability follow-ups.

### 0.8.0–1.0.0 — Security and Public Release

Token-bearing URL elimination, session hardening, release-candidate stabilization,
paid signing, CI/distribution automation, support policy, and launch readiness.

Later milestones intentionally have no provisional due dates. They are scoped
from the accepted state of the previous release.
