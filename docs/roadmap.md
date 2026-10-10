# Velacanto roadmap

GitHub issues, latest owner scope comments and the [Development Project](https://github.com/users/schillt/projects/1) control current work. This roadmap records direction, not implementation or acceptance. No future milestone has a committed date.

## Current checkpoint: 0.4.0 development on alpha

The combined iOS/iPadOS and Mac source is integrated at `488d0af65f215d5a781f8c4077b521537cd7b5d2`,
version 0.4.0 (124). Downloads, playlist management, persistent queue modes/restoration,
shared account artwork and native platform refinements are implemented. Both Release
builds and 332 Mac tests passed on the final combined source. See the
[development and acceptance record](0.4-development-record.md) for exact handoffs,
security remediation, source-specific tests and outstanding physical/server gates.
This round did not establish a 0.4 release or both-platform TestFlight availability.

The earlier accepted preview `de7abe9` was promoted to main through
[PR #190](https://github.com/schillt/velacanto/pull/190) on 2026-10-07, preserving ancestry.
The newer 0.4 work is excluded from that release snapshot. The published 0.3.5
prerelease and its historical evidence remain intact. Fetch current alpha before
starting an assignment; the original 0.4 planning base is not the current source.

## 0.4.0 — Downloads, Playlists and Queue Management

See the [0.4 execution plan](0.4-plan.md). Major features are track/album downloads, automatically updated downloaded playlists, basic playlist management, and editable Up Next with persistent modes and paused queue restoration. Supporting work includes storage/artwork policy, collection/favorite outcomes, bounded playback reporting and verification of current alpha's remaining privacy/reliability checks.

Target internal iOS/iPadOS and Mac TestFlight. Exact candidate, signed distribution and actual tester availability remain distinct; coordinated upload/publication authorization is separate. No main promotion or public submission is implied.

## Ongoing UI and stability improvements

Every build improves touched flows, accessible interaction, async outcomes and regressions. Major bugs/enhancements remain actionable issues in milestone/Project buckets. Broad accessibility, performance and maintainability projects retain their own tracking; incremental quality does not wait for a polish release.

## Later direction

- **0.5.0:** CarPlay readiness, shallow native browse/Now Playing and casting evaluation.
- **0.6.0:** multiple accounts, richer metadata, quality choices, local catalog composition and Navidrome/OpenSubsonic. Basic playlists move to 0.4; server playlist reordering remains deferred.
- **0.7.0:** measured large-library performance, broad accessibility/adaptive layout, search tolerance and maintainability alongside ongoing quality work.
- **0.8.0–1.0.0:** operational policy, remaining session/security hardening, stabilization and public launch. Privacy issues already moved to 0.4 remain there.

## Historical releases

- [0.3.0](0.3-release-notes.md): native rebuilt alpha checkpoint; evidence remains scoped to its artifact.
- [0.2.5](0.2.5-release-notes.md): published stabilization checkpoint; later hosted failure remains preserved in #99.
- [0.2.0](archive/0.2/README.md) and [0.1.0](archive/0.1/README.md): preserved earlier lineages, not current implementation instructions.
