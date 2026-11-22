# VelaCanto roadmap

## Owner-approved 0.7 scope — updated 2026-11-21

The native 0.7.0 goal is a reliable internal TestFlight candidate for iOS/iPadOS and macOS. Prioritize correctness, sign-out, playback, maintainability, measured performance and accessibility; retain search #46 and iPhone Duo adaptive support under #22. Artist policy #157, widget #227 and system-media evaluation #228 have owner-accepted dispositions. CarPlay implementation is retained, with physical verification explicitly moved to 0.8.0 under #209. The owner deferred animated artwork and every aspect of its integration on November 21: #231 is future work in 0.8.0, and the 0.7 candidate preserves static artwork only. The accepted #111 evaluation does not authorize animation integration. The owner requested a one-hour closeout, while explicitly retaining #15/#30/#214/#215/#216 acceptance in 0.7; the deadline does not mark missing evidence passed.

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

1. Verify live alpha, issue contracts and retained source/evidence before serial
   integration. Preserve scoped accepted repairs, and reconcile current tracking
   without treating a previous build or test count as release acceptance.
2. Complete sign-out and Keychain verification #30; bounded async and UI checks
   #201/#204; critical gate coverage #220; and native download validation #214
   with the owner-accepted in-flight storage limitation documented.
3. Complete the existing playback, reporting, continuity, performance, artwork,
   accessibility and Mac acceptance contracts #15/#47/#155/#213/#215/#216 and
   #14/#22/#24/#137/#168. Include iPhone Duo adaptive support under #22.
4. Complete discovery #46 against its acceptance criteria. Preserve the accepted
   #157 provider-limit disposition, widget #227 and system-media evaluation #228.
   Keep CarPlay's deferred physical verification under #209 in 0.8.0. Exclude
   deferred animation #231 from 0.7, preserving its unfinished work separately.
5. Prepare the exact 0.7 candidate for internal TestFlight on iOS/iPadOS and Mac;
   complete #63/#149/#169, the milestone disposition gate, applicable tests and
   separately authorized signing, hosted, promotion and distribution steps.

#112/#115 local-library work remains deferred to 0.8.0; #25 playback-URL privacy
remains unfinished and deferred to 0.9.0. General keyboard navigation remains
post-v1 under #226 except for a specific mandatory release repair. Production pin
sync is accepted; ordinary iCloud delivery lag alone does not reopen #198/#218.

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
