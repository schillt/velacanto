# VelaCanto roadmap

## Owner-approved 0.7 scope — 2026-11-12

The native 0.7.0 goal is a reliable internal TestFlight candidate for iOS/iPadOS and macOS. Prioritize correctness, sign-out, playback, maintainability, measured performance and accessibility; retain search #46, artist inclusion #157, CarPlay #209, widget #227, Live Activities evaluation #228, animated-art evaluation #111 and implementation #231 for animated album artwork in Now Playing and album detail views. Include iPhone Duo adaptive support under #22. No release date is committed.

Local-library work #112/#115 is deferred to 0.8.0. Playback URL credential elimination #25 is deferred to 0.9.0 and remains unfinished; operational log redaction/retention guidance still applies. The browser client is a separate workstream. Reconcile active Project tracking and apply the milestone disposition and separate publication/distribution gates in the current handoff. This section supersedes conflicting historical scope below.

Development is now **0.7.0**. The [live milestone](https://github.com/schillt/velacanto/milestone/7),
selected issue's latest contract/comments and current owner instructions govern
scope. Start with the [current handoff](0.7.0-agent-handoff.md). No date is committed.

## Accepted baseline

The accepted 0.6 development runtime is build309, source
`5adcf3a9fb4c8e3e66bb78d1742e56090f6ea91a`; 0.6 alpha source/configuration was
published through `90a74144471e36558599b57c298fc546b519b057`. The owner accepted
Production pin sync on November 2, 2026, including remaining iCloud delivery lag.
No app-controlled sync defect is currently reported. Preserve accepted queue,
playlist, lyrics, offline playback, browsing and continuity behavior. Read the
[historical checkpoint](0.6.0-alpha-checkpoint.md) for exact evidence limits.

## 0.7 execution order

1. Start with bounded async test synchronization #201; make missing events fail
   promptly with cleanup, without production changes or weaker assertions.
2. Address playback-URL privacy #25 and account/sign-out/pin cleanup #30/#179.
   Preserve working delivery and demonstrate a supported approach before transport
   changes. Coordinate #203 ownership work after the relevant baseline is reliable.
3. Measure Mac scrolling/artwork/large-library behavior #24/#14/#137 and playback
   stalls/compatibility #15/#155/#47. Investigate Mac AirPlay #212 and CarPlay #209
   against actual hardware; document external limits honestly.
4. Complete targeted lifecycle, continuity and reporting checks #213/#215/#216,
   affected accessibility #22, and conditional native-download budget work #214.
5. Use bounded maintainability work #168/#54/#200/#204/#202/#203 where it supports
   demonstrated needs. Retain #46 search, #112/#115 local-library groundwork,
   #157 artist classification and #111 animated-art evaluation in the existing
   milestone; do not silently expand the first batch or promise unsupported APIs.

The handoff inventories every open 0.7 item. Production-sync investigation #218
is closed by owner disposition; ordinary iCloud lag alone does not reopen it.

## Later milestones and distribution

Keep existing 0.8 session/operational scope, 0.9 stabilization #27, 1.0 release
operations/policy #28/#29 and Post-1.0 provider/account backlog in their live buckets.
No new provider, multi-account expansion or public launch is implied by 0.7 setup.

Main contains the older accepted 0.5 candidate through PR #217; beta/main are not
automatically advanced with alpha. Exact-source hosted checks, archive/export,
Apple processing and per-platform availability stay distinct. Historical artifact
provenance/acceptance #63/#149/#169 remains open under its own scope; do not repeat
accepted 0.6 basics solely to satisfy an old checkbox. The Swift CodeQL exception
in PR #217 was candidate-specific and is not a standing waiver.
